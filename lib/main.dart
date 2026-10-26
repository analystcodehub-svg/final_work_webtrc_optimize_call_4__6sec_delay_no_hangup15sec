import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';

import 'firebase_options.dart';
import 'providers/app_state.dart';
import 'theme/app_theme.dart';
import 'screens/active_call_page.dart';
import 'screens/auth_wrapper.dart';
import 'services/notification_service.dart';
import 'services/foreground_task_service.dart';
import 'package:firebase_database/firebase_database.dart';
import 'screens/maintenance_screen.dart';
import 'screens/hybrid_chat_screen.dart';
import 'dart:isolate';

/// Global navigator key — used by NotificationService to navigate
/// after a call is accepted from the background / lock screen.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── Memory Optimization (Google Play Vitals & Bitmap Thresholds) ──────
  // 1. Cap memory image cache from default 100MB+ down to 35MB
  PaintingBinding.instance.imageCache.maximumSizeBytes = 35 << 20; // 35 MB
  PaintingBinding.instance.imageCache.maximumSize = 60; // 60 images

  // 2. Automatically release bitmap memory when app is backgrounded or hidden
  AppLifecycleListener(
    onHide: () {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      debugPrint('[Memory] App backgrounded: Released non-visible bitmap caches.');
    },
    onPause: () {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    },
  );

  // Register port to reliably identify if UI isolate is alive from the background
  IsolateNameServer.removePortNameMapping('ui_isolate');
  IsolateNameServer.registerPortWithName(ReceivePort().sendPort, 'ui_isolate');

  // Lock app to portrait mode — prevents overflow on landscape rotation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Always show status bar (network, battery, time) and navigation bar
  SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.manual,
    overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom],
  );
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark, // Dark icons (network, battery, time) on light backgrounds
    statusBarBrightness: Brightness.light,    // Dark icons for iOS
    systemNavigationBarColor: Colors.white,
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Color(0xFFE2E8F0),
  ));

  // ── 1. Initialize Firebase ──────────────────────────────────────────────
  bool firebaseInitialized = false;
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    
    // Pass all uncaught "fatal" errors from the framework to Crashlytics
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    // Pass all uncaught asynchronous errors that aren't handled by the Flutter framework to Crashlytics
    PlatformDispatcher.instance.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
    firebaseInitialized = true;
    debugPrint('Firebase initialized successfully.');
  } catch (e) {
    debugPrint('Firebase initialization failed: $e');
    if (e.toString().contains('duplicate-app')) {
      firebaseInitialized = true;
    }
  }

  // ── 2. Initialize Notification Service (FCM + CallKit) ─────────────────
  if (firebaseInitialized) {
    // CRITICAL: Register background handler BEFORE NotificationService.initialize()
    // This must be a top-level function call, not inside any class.
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    
    AppState.syncPendingChatDeductions();
    await NotificationService.instance.initialize(navKey: navigatorKey);
    // Initialize Foreground Task Service
    await ForegroundTaskService().initializeService();
  }

  runApp(
    ChangeNotifierProvider(
      create: (context) => AppState(),
      child: const SajniReApp(),
    ),
  );
}

class SajniReApp extends StatefulWidget {
  const SajniReApp({super.key});

  @override
  State<SajniReApp> createState() => _SajniReAppState();
}

class _SajniReAppState extends State<SajniReApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Limit ImageCache size globally for memory optimization
    PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024; // 50 MB
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      // Clear bitmap memory when app goes to background (Android Vitals optimization)
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SajniRe',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,

      // Provide the global navigatorKey so NotificationService can
      // push routes after accepting a call from a terminated state.
      navigatorKey: navigatorKey,

      builder: (context, child) {
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
            systemNavigationBarColor: Colors.white,
            systemNavigationBarIconBrightness: Brightness.dark,
            systemNavigationBarDividerColor: Color(0xFFE2E8F0),
          ),
          child: StreamBuilder<DatabaseEvent>(
            stream: FirebaseDatabase.instance.ref('app_settings/maintenance_mode').onValue,
            builder: (context, snapshot) {
              bool isMaintenance = false;
              if (snapshot.hasData && snapshot.data!.snapshot.value != null) {
                final value = snapshot.data!.snapshot.value;
                if (value is bool) {
                  isMaintenance = value;
                } else if (value is String) {
                  isMaintenance = value.toLowerCase() == 'true';
                }
              }
              
              if (isMaintenance) {
                return const MaintenanceScreen();
              }
              
              return child ?? const SizedBox.shrink();
            },
          ),
        );
      },

      home: const AuthWrapper(),

      // Named routes used by NotificationService._listenCallKitEvents()
      routes: {
        '/active-call': (context) {
          final args = ModalRoute.of(context)!.settings.arguments
              as Map<String, dynamic>;
          
          final appState = Provider.of<AppState>(context, listen: false);
          
          // Resolve callerId properly from arguments if available, fallback to name
          final callerNameStr = args['callerName']?.toString() ?? 'Female Expert';
          final passedCallerId = args['callerId'] as String?;
          final resolvedCallerId = (passedCallerId != null && passedCallerId.isNotEmpty) 
              ? passedCallerId 
              : callerNameStr;

          final isFree = args['isFreeIntroCall'] == true || args['isFreeIntroCall'] == 'true';
          final resolvedDbUrl = args['dbUrl'] as String?;

          String receiverUid = appState.uid;
          if (receiverUid.isEmpty) {
            receiverUid = FirebaseAuth.instance.currentUser?.uid ?? '';
          }

          final autoAccept = args['autoAccept'] == true || args['autoAccept'] == 'true';

          return ActiveCallPage(
            callRoomId: args['callRoomId'] as String,
            receiverId: receiverUid,
            callerId:   resolvedCallerId,
            nickname:   callerNameStr,
            pricePerMin: isFree
                ? 0.0
                : ((args['pricePerMin'] as num?)?.toDouble() ?? 4.0),
            isCaller: false,     // Receiver is accepting
            callerCoinBalance: args['callerCoins'] as int?,
            callDatabaseURL: resolvedDbUrl,
            isFreeIntroCall: isFree,
            maxDurationSeconds: (args['maxDurationSeconds'] as num?)?.toInt() ??
                (isFree ? 60 : null),
            autoAccept: autoAccept,
          );
        },
        '/chat': (context) {
          final args = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>;
          final appState = Provider.of<AppState>(context, listen: false);
          return HybridChatScreen(
            myUid: appState.uid,
            otherUid: args['otherUid'] as String,
            otherUserName: args['otherUserName'] as String,
          );
        },
      },
    );
  }
}
