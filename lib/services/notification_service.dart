// lib/services/notification_service.dart
//
// Handles Firebase Cloud Messaging + flutter_callkit_incoming v3.x.
// Covers foreground, background, and terminated (killed) app states.
// ─────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/call_kit_params.dart';
import 'package:flutter_callkit_incoming/entities/android_params.dart';
import 'package:flutter_callkit_incoming/entities/ios_params.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_callkit_incoming/entities/call_event.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import '../firebase_options.dart';
import 'call_service.dart';
import 'block_service.dart';
import 'user_database_service.dart';

// ─── TOP-LEVEL BACKGROUND HANDLER ─────────────────────────────────────────
//
// MUST be a top-level function (outside any class).
// Called by Firebase in a separate isolate when app is background/terminated.
//
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      }
    } catch (e) {
      if (!e.toString().contains('duplicate-app')) {
        rethrow;
      }
    }
    debugPrint('[BG Handler] data: ${message.data}');
    final data = message.data;
    final type = data['type'] ?? '';

    // Gate check for Female Expert:
    // Only accept incoming calls and messages if:
    // 1. Online toggle is ON (isExpertOnline == true)
    // 2. App was NOT swiped away (!isAppSwipedAway)
    // 3. Background service is actively running (isBgServiceRunning == true)
    final prefs = await SharedPreferences.getInstance();
    final userRole = prefs.getString('userRole')?.toLowerCase() ?? '';
    final isExpertOnline = prefs.getBool('isExpertOnline') ?? false;
    final isAppSwipedAway = prefs.getBool('isAppSwipedAway') ?? false;

    bool isBgServiceRunning = false;
    try {
      isBgServiceRunning = await FlutterBackgroundService().isRunning();
    } catch (_) {}

    debugPrint('[BG Handler] userRole=$userRole, isExpertOnline=$isExpertOnline, isAppSwipedAway=$isAppSwipedAway, isBgServiceRunning=$isBgServiceRunning');

    final isFreeIntro = data['isFreeIntroCall'] == 'true' || data['isFreeIntroCall'] == true;
    if (userRole == 'female' && !isFreeIntro) {
      if (!isExpertOnline || isAppSwipedAway || !isBgServiceRunning) {
        debugPrint('[BG Handler] Female expert is OFFLINE or app was swiped away. Suppressing $type.');
        if (type == 'call') {
          // Reject call in RTDB immediately so male caller is not left waiting
          final callRoomId = data['callRoomId'] ?? '';
          final dbUrl = data['dbUrl'] as String? ?? 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app';
          if (callRoomId.isNotEmpty) {
            try {
              final rtdb = FirebaseDatabase.instanceFor(
                app: Firebase.app(),
                databaseURL: dbUrl,
              );
              await rtdb.ref('calls/$callRoomId').update({'status': 'rejected_offline'});
            } catch (e) {
              debugPrint('[BG Handler] Failed to update call status to rejected_offline: $e');
            }
          }
        }
        return; // Suppress notification / CallKit completely!
      }
    }

    if (type == 'call') {
      await _showCallkitIncoming(data);
    } else if (type == 'message') {
      final plugin = FlutterLocalNotificationsPlugin();
      const androidSettings = AndroidInitializationSettings('@drawable/ic_notification');
      const iosSettings = DarwinInitializationSettings();
      await plugin.initialize(
        settings: const InitializationSettings(android: androidSettings, iOS: iosSettings),
      );
      await showChatNotification(data);
    }
  } catch (e, stackTrace) {
    debugPrint('[BG Handler] ERROR: $e\n$stackTrace');
  }
}

// ─── LOCAL CHAT NOTIFICATION HELPER ──────────────────────────────────────────

Future<void> showChatNotification(Map<String, dynamic> data) async {
  final plugin = FlutterLocalNotificationsPlugin();
  
  String senderName = data['senderName'] as String? ?? '';
  final senderId = data['senderId'] as String? ?? '';

  // Resolve sender nickname if senderName is empty, equals senderId, or looks like a raw Firebase UID
  if (senderId.isNotEmpty && (senderName.isEmpty || senderName == senderId || (senderName.length >= 20 && !senderName.contains(' ')))) {
    // 1. Check local SharedPreferences cache
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('user_nickname_$senderId');
      if (cached != null && cached.isNotEmpty && cached != senderId) {
        senderName = cached;
      }
    } catch (_) {}

    // 2. Fetch directly from new RTDB users/$senderId/nickname
    if (senderName.isEmpty || senderName == senderId || (senderName.length >= 20 && !senderName.contains(' '))) {
      try {
        final snap = await FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: 'https://zegochat-c44b0-4cbfb.asia-southeast1.firebasedatabase.app',
        ).ref('users/$senderId/nickname').get();
        if (snap.exists && snap.value != null && snap.value.toString().isNotEmpty) {
          senderName = snap.value.toString();
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('user_nickname_$senderId', senderName);
        } else {
          // Fallback to experts/$senderId/nickname
          final expSnap = await FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL: 'https://zegochat-c44b0-4cbfb.asia-southeast1.firebasedatabase.app',
          ).ref('experts/$senderId/nickname').get();
          if (expSnap.exists && expSnap.value != null && expSnap.value.toString().isNotEmpty) {
            senderName = expSnap.value.toString();
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('user_nickname_$senderId', senderName);
          }
        }
      } catch (e) {
        debugPrint('[FCM] Error resolving sender nickname from RTDB: $e');
      }
    }
  }

  if (senderName.isEmpty || senderName == senderId || (senderName.length >= 20 && !senderName.contains(' '))) {
    senderName = 'New Message';
  }

  ByteArrayAndroidBitmap? largeIcon;
  Uint8List? iconBytes;
  final avatarUrl = data['senderAvatar'] as String?;
  
  if (avatarUrl != null && avatarUrl.isNotEmpty) {
    try {
      final request = await HttpClient().getUrl(Uri.parse(avatarUrl));
      final response = await request.close();
      if (response.statusCode == 200) {
        iconBytes = await consolidateHttpClientResponseBytes(response);
        largeIcon = ByteArrayAndroidBitmap(iconBytes);
      }
    } catch (e) {
      debugPrint('[FCM] Error downloading avatar for notification: $e');
    }
  }

  // Fallback to static default avatar if no valid avatar was fetched
  if (iconBytes == null) {
    try {
      final receiverGender = data['receiverGender'] as String?;
      
      // If receiver is male, the message is FROM a female (use female avatar).
      // Otherwise, use male avatar.
      final assetPath = receiverGender == 'male' 
          ? 'assets/female_avatar_small.png' 
          : 'assets/male_avatar_small.png';
          
      final ByteData byteData = await rootBundle.load(assetPath);
      iconBytes = byteData.buffer.asUint8List();
      largeIcon = ByteArrayAndroidBitmap(iconBytes);
    } catch (e) {
      debugPrint('[FCM] Error loading default avatar asset: $e');
    }
  }

  // Use MessagingStyle for a chat-like premium look
  final person = Person(
    name: senderName,
    icon: iconBytes != null ? ByteArrayAndroidIcon(iconBytes) : null,
  );
  
  final styleInfo = MessagingStyleInformation(
    person,
    messages: [
      Message(data['body'] ?? '', DateTime.now(), person),
    ],
  );

  await plugin.show(
    id: senderId.isNotEmpty ? senderId.hashCode.abs() : (DateTime.now().millisecondsSinceEpoch ~/ 1000),
    title: senderName,
    body: data['body'] ?? '',
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        'messages_channel',
        'Messages',
        importance: Importance.high,
        priority: Priority.high,
        styleInformation: styleInfo,
        largeIcon: largeIcon,
      ),
    ),
    payload: jsonEncode(data),
  );
}

/// Dismisses CallKit screen natively via broadcast & MethodChannel.
/// Fixes the issue where remote cancellation stops the ringtone but leaves CallKit UI stuck on screen.
Future<void> dismissCallKitScreen() async {
  try {
    const channel1 = MethodChannel('com.techflow.co/auto_start_flutter');
    await channel1.invokeMethod('dismissCallKitScreen');
  } catch (_) {}
  try {
    const channel2 = MethodChannel('com.sajnire.app/auth');
    await channel2.invokeMethod('dismissCallKitScreen');
  } catch (_) {}
  try {
    await FlutterCallkitIncoming.endAllCalls();
  } catch (_) {}
}

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse details) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    }
  } catch (_) {}

  if (details.payload != null) {
    try {
      final data = jsonDecode(details.payload!) as Map<String, dynamic>;
      final callRoomId = data['callRoomId'] as String? ?? '';
      final dbUrl = data['dbUrl'] as String?;

      if (details.actionId == 'action_decline') {
        FlutterRingtonePlayer().stop();
        dismissCallKitScreen();
        if (callRoomId.isNotEmpty) {
          FlutterLocalNotificationsPlugin().cancel(id: callRoomId.hashCode.abs());
          CallService(databaseURL: dbUrl).endCall(callRoomId);
        }
      } else if (details.actionId == 'action_accept') {
        FlutterRingtonePlayer().stop();
        dismissCallKitScreen();
        if (callRoomId.isNotEmpty) {
          FlutterLocalNotificationsPlugin().cancel(id: callRoomId.hashCode.abs());
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('autoAccept_$callRoomId', true);
        }
      }
    } catch (_) {}
  }
}

// ─── CALL NOTIFICATION WITH ACTIONS (WhatsApp Style Accept / Decline) ──────

Future<void> showCallNotificationWithActions(
  Map<String, dynamic> data,
  String callerName, {
  bool isMale = false,
  bool notificationsEnabled = true,
}) async {
  try {
    final plugin = FlutterLocalNotificationsPlugin();
    const androidSettings = AndroidInitializationSettings('@drawable/ic_notification');
    const iosSettings = DarwinInitializationSettings();
    await plugin.initialize(
      settings: const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null) {
          try {
            final d = jsonDecode(details.payload!) as Map<String, dynamic>;
            final callRoomId = d['callRoomId'] as String? ?? '';
            final dbUrl = d['dbUrl'] as String?;
            if (details.actionId == 'action_accept') {
              FlutterRingtonePlayer().stop();
              dismissCallKitScreen();
              if (callRoomId.isNotEmpty) {
                plugin.cancel(id: callRoomId.hashCode.abs());
                NotificationService.instance._navigateToActiveCall(callRoomId, autoAccept: true);
              }
            } else if (details.actionId == 'action_decline') {
              FlutterRingtonePlayer().stop();
              dismissCallKitScreen();
              if (callRoomId.isNotEmpty) {
                plugin.cancel(id: callRoomId.hashCode.abs());
                CallService(databaseURL: dbUrl).endCall(callRoomId);
              }
            } else {
              // Tapped notification body
              FlutterRingtonePlayer().stop();
              dismissCallKitScreen();
              if (callRoomId.isNotEmpty) {
                plugin.cancel(id: callRoomId.hashCode.abs());
                NotificationService.instance._navigateToActiveCall(callRoomId, autoAccept: false);
              }
            }
          } catch (_) {}
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final callRoomId = data['callRoomId'] ?? '';
    final isFreeIntro = data['isFreeIntroCall'] == 'true' || data['isFreeIntroCall'] == true;

    final androidDetails = AndroidNotificationDetails(
      'calls_channel',
      'Incoming Calls',
      channelDescription: 'Incoming voice call notifications',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: !isFreeIntro,
      ongoing: true,
      autoCancel: false,
      largeIcon: const DrawableResourceAndroidBitmap('ic_female_avatar'),
      color: const Color(0xFF10B981),
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          'action_accept',
          isFreeIntro ? 'Receive' : 'Accept',
          titleColor: const Color(0xFF10B981),
          showsUserInterface: true,
          cancelNotification: true,
        ),
        const AndroidNotificationAction(
          'action_decline',
          'Decline',
          titleColor: Color(0xFFEF4444),
          showsUserInterface: false,
          cancelNotification: true,
        ),
      ],
    );

    final details = NotificationDetails(
      android: androidDetails,
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
      ),
    );

    final notifId = callRoomId.hashCode.abs();
    await plugin.show(
      id: notifId,
      title: callerName,
      body: isFreeIntro ? 'Incoming Voice Call • 1 Min Free Intro' : 'Incoming Audio Call...',
      notificationDetails: details,
      payload: jsonEncode(data),
    );
    debugPrint('[Notification] Displayed calling notification for $callerName (isMale: $isMale)');
  } catch (e) {
    debugPrint('[Notification] Error showing call notification: $e');
  }
}

// ─── CALLKIT HELPER (top-level, callable from background isolate) ──────────

Future<void> _showCallkitIncoming(Map<String, dynamic> data) async {
  debugPrint('[CallKit] _showCallkitIncoming triggered with data: $data');
  final uuid         = data['callRoomId']  ?? 'uuid-${DateTime.now().millisecondsSinceEpoch}';
  String callerName   = data['callerName']  ?? 'Unknown Caller';
  final callRoomId   = data['callRoomId']  ?? '';
  final callerId     = data['callerId']    ?? '';
  final dbUrl        = data['dbUrl'] as String? ?? 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app';
  final isFreeIntro  = data['isFreeIntroCall'] == 'true' || data['isFreeIntroCall'] == true;

  // Resolve caller nickname if callerName is empty, equals callerId, or looks like a raw Firebase UID
  if (callerId.isNotEmpty && (callerName.isEmpty || callerName == callerId || callerName == 'Unknown Caller' || (callerName.length >= 20 && !callerName.contains(' ')))) {
    // 1. Try reading callerName directly from active call room
    try {
      final snap = await FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: dbUrl,
      ).ref('calls/$callRoomId/callerName').get();
      if (snap.exists && snap.value != null && snap.value.toString().isNotEmpty) {
        callerName = snap.value.toString();
      }
    } catch (_) {}

    // 2. Try experts/$callerId/nickname (female caller is an expert)
    if (callerName.isEmpty || callerName == callerId || callerName == 'Unknown Caller' || (callerName.length >= 20 && !callerName.contains(' '))) {
      try {
        final expSnap = await FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: 'https://zegochat-c44b0-4cbfb.asia-southeast1.firebasedatabase.app',
        ).ref('experts/$callerId/nickname').get();
        if (expSnap.exists && expSnap.value != null && expSnap.value.toString().isNotEmpty) {
          callerName = expSnap.value.toString();
        }
      } catch (_) {}
    }

    // 3. Try users/$callerId/nickname
    if (callerName.isEmpty || callerName == callerId || callerName == 'Unknown Caller' || (callerName.length >= 20 && !callerName.contains(' '))) {
      try {
        final snap = await FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: 'https://zegochat-c44b0-4cbfb.asia-southeast1.firebasedatabase.app',
        ).ref('users/$callerId/nickname').get();
        if (snap.exists && snap.value != null && snap.value.toString().isNotEmpty) {
          callerName = snap.value.toString();
        }
      } catch (e) {
        debugPrint('[CallKit] Error resolving caller nickname from RTDB: $e');
      }
    }

    if (callerName.isEmpty || callerName == callerId || callerName == 'Unknown Caller' || (callerName.length >= 20 && !callerName.contains(' '))) {
      callerName = isFreeIntro ? 'Female Host' : 'Incoming Call';
    }
  }

  // 1. Check if caller is blocked locally before ringing
  if (callerId.isNotEmpty) {
    debugPrint('[CallKit] Checking if blocked: $callerId');
    try {
      bool isBlocked = await BlockService.instance.isUserBlockedAnywhereAsync(callerId);
      if (isBlocked) {
        debugPrint('[CallKit] Caller $callerId is blocked locally. Suppressing call.');
        return;
      }
    } catch(e) {
      debugPrint('[CallKit] Error checking block status: $e');
    }
  }

  debugPrint('[CallKit] Proceeding to ring...');

  // Mark call as ringing in RTDB so female caller knows the notification arrived and switches to 15s ringing screen
  if (callRoomId.isNotEmpty) {
    try {
      final roomRef = FirebaseDatabase.instanceFor(
        app: Firebase.app(),
        databaseURL: dbUrl,
      ).ref('calls/$callRoomId');

      roomRef.child('status').get().then((currentSnap) {
        final currentStatus = currentSnap.value?.toString();
        if (currentStatus == null || currentStatus == 'calling' || currentStatus == 'dialing') {
          roomRef.update({
            'status': 'ringing',
            'ringDeliveredAt': ServerValue.timestamp,
          });
          debugPrint('[CallKit] Notification delivered to recipient! Updated status to ringing for room: $callRoomId on $dbUrl');
        } else {
          debugPrint('[CallKit] Skip setting ringing, current room status is: $currentStatus');
        }
      }).catchError((e) {
        debugPrint('[CallKit] Error checking/updating room status: $e');
      });
    } catch (e) {
      debugPrint('[CallKit] Failed to set ringing status in room: $e');
    }
  }

  NotificationService.lastCallerName = callerName;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('callerName_$callRoomId', callerName);
  await prefs.setString('callerId_$callRoomId', callerId);
  await prefs.setString('dbUrl_$callRoomId', dbUrl);
  await prefs.setBool('isFreeIntroCall_$callRoomId', isFreeIntro);

  // 1. Check if this call is already actively being displayed via full-screen IncomingCallScreen
  // If so, exit IMMEDIATELY to prevent playing a 2nd duplicate ringtone or showing duplicate UI!
  final isAlreadyHandled = prefs.getBool('is_in_incoming_call_$callRoomId') ?? false;
  if (isAlreadyHandled) {
    debugPrint('[CallKit] Call $callRoomId is already active in IncomingCallScreen, skipping CallKit display and duplicate ringtone.');
    return;
  }

  // Pre-fetch caller's balance from RTDB in background without blocking CallKit display!
  if (callerId.isNotEmpty) {
    Future(() async {
      try {
        final coinSnap = await FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: 'https://zegochat-c44b0-4cbfb.asia-southeast1.firebasedatabase.app',
        ).ref('users/$callerId/coinBalance').get();
        if (coinSnap.exists && coinSnap.value != null) {
          final coins = (coinSnap.value as num).toInt();
          await prefs.setInt('callerCoins_$callRoomId', coins);
          debugPrint('[CallKit] Cached caller coins: $coins for $callRoomId');
        }
      } catch (e) {
        debugPrint('[CallKit] Error caching caller coins: $e');
      }

      try {
        final roomSnap = await FirebaseDatabase.instanceFor(
          app: Firebase.app(),
          databaseURL: dbUrl,
        ).ref('calls/$callRoomId/callerCoins').get();
        if (roomSnap.exists && roomSnap.value != null) {
          final coins = (roomSnap.value as num).toInt();
          await prefs.setInt('callerCoins_$callRoomId', coins);
          debugPrint('[CallKit] Cached caller coins from room: $coins for $callRoomId');
        }
      } catch (_) {}
    });
  }

  final params = CallKitParams(
    id: uuid,
    nameCaller: callerName,
    appName: 'SajniRe',
    handle: isFreeIntro ? '1 Min Intro Call' : 'calling ....',
    type: 0,          
    duration: 35000,  // auto-dismiss after 35s
    extra: <String, dynamic>{
      'callRoomId': callRoomId,
      'callerName': callerName,
      'dbUrl': dbUrl,
      'isFreeIntroCall': isFreeIntro,
    },
    headers: <String, dynamic>{'platform': 'android'},
    android: const AndroidParams(
      isCustomNotification: true,
      isShowLogo: false,
      isShowCallID: true,
      ringtonePath: '', // Handled manually
      backgroundColor: '#0A0A0A',
      actionColor: '#10B981',
      textColor: '#ffffff',
      isShowFullLockedScreen: true,
      isImportant: true,
      isFullScreen: true,
    ),
    ios: const IOSParams(
      iconName: 'CallKitLogo',
      handleType: '',
      supportsVideo: false,
      maximumCallGroups: 2,
      maximumCallsPerCallGroup: 1,
      supportsDTMF: true,
      supportsHolding: true,
      supportsGrouping: false,
      supportsUngrouping: false,
      ringtonePath: 'system_ringtone_default',
      audioSessionMode: 'default',
      audioSessionActive: true,
      audioSessionPreferredSampleRate: 44100.0,
      audioSessionPreferredIOBufferDuration: 0.005,
    ),
  );

  final userRole = prefs.getString('userRole') ?? '';
  final isMale = userRole == 'male' || isFreeIntro;

  // Check if system notifications are enabled on this device
  bool notificationsEnabled = true;
  try {
    final localNotif = FlutterLocalNotificationsPlugin();
    final androidPlugin = localNotif.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final enabled = await androidPlugin?.areNotificationsEnabled();
    if (enabled != null) {
      notificationsEnabled = enabled;
    } else {
      notificationsEnabled = await Permission.notification.isGranted;
    }
  } catch (e) {
    debugPrint('[CallKit] Error checking notification permission: $e');
    try {
      notificationsEnabled = await Permission.notification.isGranted;
    } catch (_) {}
  }
  debugPrint('[CallKit] isMale: $isMale, notificationsEnabled: $notificationsEnabled');

  if (isFreeIntro) {
    // For free intro calls in background / killed state: show ONLY notification with Receive and Decline options
    debugPrint('[CallKit] Free intro call in bg/killed state: showing ONLY notification with Receive/Decline buttons via CallKit heads-up banner');
    final introParams = CallKitParams(
      id: uuid,
      nameCaller: callerName,
      appName: 'SajniRe',
      handle: '1 Min Free Intro Call',
      type: 0,
      duration: 15000, // Strictly 15s timeout
      extra: <String, dynamic>{
        'callRoomId': callRoomId,
        'callerName': callerName,
        'callerId': callerId,
        'dbUrl': dbUrl,
        'isFreeIntroCall': true,
        'maxDurationSeconds': 60,
      },
      headers: <String, dynamic>{'platform': 'android'},
      android: const AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        isShowCallID: true,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0A0A0A',
        actionColor: '#10B981',
        textColor: '#ffffff',
        isShowFullLockedScreen: false,
        isImportant: true,
        isFullScreen: false, // NOT FULL SCREEN: Shows heads-up notification banner with Receive & Decline
        textAccept: 'Receive',
        textDecline: 'Decline',
      ),
      ios: const IOSParams(
        iconName: 'CallKitLogo',
        handleType: '',
        supportsVideo: false,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );
    await FlutterCallkitIncoming.showCallkitIncoming(introParams);
  } else {
    // Regular paid calls (completely untouched):
    debugPrint('[CallKit] Showing full-screen CallKit display and playing ringtone');
    FlutterRingtonePlayer().play(
      android: AndroidSounds.ringtone,
      ios: IosSounds.glass,
      looping: true,
      volume: 1.0,
      asAlarm: true,
    );
    await FlutterCallkitIncoming.showCallkitIncoming(params);
    await showCallNotificationWithActions(
      data,
      callerName,
      isMale: isMale,
      notificationsEnabled: notificationsEnabled,
    );
  }

  // Keep background isolate alive until call ends or times out
  final completer = Completer<void>();

  late StreamSubscription<CallEvent?> callkitEventSub;
  callkitEventSub = FlutterCallkitIncoming.onEvent.listen((event) {
    if (event is CallEventActionCallAccept ||
        event is CallEventActionCallDecline ||
        event is CallEventActionCallTimeout ||
        event is CallEventActionCallEnded) {
      FlutterRingtonePlayer().stop();
      FlutterLocalNotificationsPlugin().cancel(id: callRoomId.hashCode.abs());
      if (!completer.isCompleted) completer.complete();
    }
  });

  // Listen for remote call termination using the active database instance!
  StreamSubscription? rtdbSub;
  if (callRoomId.isNotEmpty) {
    rtdbSub = FirebaseDatabase.instanceFor(
      app: Firebase.app(),
      databaseURL: dbUrl,
    ).ref('calls/$callRoomId').onValue.listen((event) {
      // 1. If caller hangs up before answering, the node is deleted (value == null). Stop ringtone & dismiss CallKit immediately!
      if (!event.snapshot.exists || event.snapshot.value == null) {
        debugPrint('[CallKit] Remote call room was removed by caller. Stopping ringtone & dismissing CallKit immediately.');
        FlutterRingtonePlayer().stop();
        FlutterLocalNotificationsPlugin().cancel(id: callRoomId.hashCode.abs());
        dismissCallKitScreen();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final val = event.snapshot.value;
      if (val is Map) {
        final data = Map<String, dynamic>.from(val);
        final status = data['status']?.toString();
        if (status == 'ended' || status == 'cancelled' || status == 'missed' || status == 'rejected_blocked' || status == 'rejected_already_used') {
          debugPrint('[CallKit] Remote call ended with status: $status. Stopping ringtone & dismissing CallKit immediately.');
          FlutterRingtonePlayer().stop();
          FlutterLocalNotificationsPlugin().cancel(id: callRoomId.hashCode.abs());
          dismissCallKitScreen();
          if (!completer.isCompleted) completer.complete();
        }
      }
    });
  }

  // Failsafe timer: 16 seconds for free intro, 36 seconds for paid call
  final failsafeSeconds = isFreeIntro ? 16 : 36;
  Timer(Duration(seconds: failsafeSeconds), () {
    FlutterRingtonePlayer().stop();
    dismissCallKitScreen();
    if (!completer.isCompleted) completer.complete();
  });

  await completer.future;
  
  callkitEventSub.cancel();
  rtdbSub?.cancel();
}

// ─── NOTIFICATION SERVICE CLASS ───────────────────────────────────────────

class NotificationService {
  static String? lastCallerName;
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _messaging = FirebaseMessaging.instance;
  final _localNotifications = FlutterLocalNotificationsPlugin();

  /// Global NavigatorKey — set from main.dart.
  /// Used to push routes after accepting a call from the lock screen.
  static GlobalKey<NavigatorState>? navigatorKey;

  // ── INITIALIZE ──────────────────────────────────────────────────────────

  Future<void> initialize({required GlobalKey<NavigatorState> navKey}) async {
    navigatorKey = navKey;

    // Permissions (like push notifications) should now be requested gracefully 
    // via PermissionHelper bottom sheet in the dashboard, NOT here.

    // 2.5 Request System Alert Window (Display over other apps)

    try {
      if (Platform.isAndroid) {
         // Moved SystemAlertWindow request to Dashboards via AutoStartHelper
      }
    } catch (e) {
      debugPrint('[Permission] Error requesting system alert window: $e');
    }

    // 3. iOS: don't show system banner for FCM — we use CallKit instead
    await _messaging.setForegroundNotificationPresentationOptions(
      alert: false,
      badge: true,
      sound: false,
    );

    // 4. Set up local notification channels
    await _initLocalNotifications();

    // 5. Foreground handler (app is open and visible)
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // 6. Background tap handler (app was suspended but not killed)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // 7. Terminated state tap handler (app was completely killed)
    final initial = await _messaging.getInitialMessage();
    if (initial != null) _handleMessageOpenedApp(initial);

    // 8. Listen to CallKit events (Accept / Decline from lock screen)
    _listenCallKitEvents();

    // 9. Check if app was launched by accepting a CallKit call from killed state
    await _checkKilledStateAcceptedCall();
  }

  // ── LOCAL NOTIFICATION SETUP ───────────────────────────────────────────

  Future<void> _initLocalNotifications() async {
    await _localNotifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_notification'),
        iOS: DarwinInitializationSettings(),
      ),
      onDidReceiveNotificationResponse: (details) {
        if (details.payload != null) {
          try {
            final data = jsonDecode(details.payload!) as Map<String, dynamic>;
            final callRoomId = data['callRoomId'] as String? ?? '';
            final dbUrl = data['dbUrl'] as String?;

            if (details.actionId == 'action_accept') {
              FlutterRingtonePlayer().stop();
              FlutterCallkitIncoming.endAllCalls();
              if (callRoomId.isNotEmpty) {
                _localNotifications.cancel(id: callRoomId.hashCode.abs());
                _navigateToActiveCall(callRoomId, autoAccept: true);
              }
            } else if (details.actionId == 'action_decline') {
              FlutterRingtonePlayer().stop();
              FlutterCallkitIncoming.endAllCalls();
              if (callRoomId.isNotEmpty) {
                _localNotifications.cancel(id: callRoomId.hashCode.abs());
                CallService(databaseURL: dbUrl).endCall(callRoomId);
              }
            } else {
              _routeFromNotification(data);
            }
          } catch (e) {
            debugPrint('[Notification] Error handling response: $e');
          }
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    // Create Android channels
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'calls_channel',
        'Incoming Calls',
        description: 'Native incoming call notifications',
        importance: Importance.max,
        playSound: true,
      ),
    );

    // Pre-create CallKit ongoing channel to prevent Android 8+ foreground service crash
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'callkit_ongoing_channel_id',
        'Ongoing Call',
        description: 'Ongoing Call Notification',
        importance: Importance.low,
      ),
    );
    await androidPlugin?.createNotificationChannel(
      const AndroidNotificationChannel(
        'messages_channel',
        'Messages',
        description: 'Chat message notifications',
        importance: Importance.high,
        playSound: true,
      ),
    );
  }

  // ── FCM TOKEN MANAGEMENT ───────────────────────────────────────────────

  /// Call this after login to bind FCM token to the Firestore user document.
  ///
  /// [userId]     = lowercase nickname (experts) or mobile number (users)
  /// [collection] = 'experts' for female experts, 'users' for male callers
  Future<void> saveTokenForUser({
    required String userId,
    required String collection,
  }) async {
    try {
      final token = await _messaging.getToken();
      if (token == null || userId.isEmpty) return;

      // 1. Save to new RTDB
      if (collection == 'experts') {
        await UserDatabaseService.instance.updateExpert(userId, {'fcmToken': token});
      } else {
        await UserDatabaseService.instance.updateUser(userId, {'fcmToken': token});
      }

      // 2. Also save to Firestore so Cloud Functions onCallInitiated can lookup fcmToken
      try {
        await FirebaseFirestore.instance.collection(collection).doc(userId).set({
          'fcmToken': token,
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('[FCM] Firestore token sync error: $e');
      }

      debugPrint('[FCM] Token saved → $collection/$userId');

      // Auto-refresh when token rotates
      _messaging.onTokenRefresh.listen((t) async {
        if (collection == 'experts') {
          await UserDatabaseService.instance.updateExpert(userId, {'fcmToken': t});
        } else {
          await UserDatabaseService.instance.updateUser(userId, {'fcmToken': t});
        }
        try {
          await FirebaseFirestore.instance.collection(collection).doc(userId).set({
            'fcmToken': t,
          }, SetOptions(merge: true));
        } catch (_) {}

        debugPrint('[FCM] Token refreshed → $collection/$userId');
      });
    } catch (e) {
      debugPrint('[FCM] Error saving token: $e');
    }
  }

  // ── FOREGROUND HANDLER ────────────────────────────────────────────────

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    debugPrint('[FCM] Foreground: ${message.data}');
    final data = message.data;
    final type = data['type'] ?? '';

    // Note: Backend already checks if the expert is online before sending FCM.
    // We trust the backend and just process the notification.

    if (type == 'call') {
      final isFreeIntro = data['isFreeIntroCall'] == 'true' || data['isFreeIntroCall'] == true;
      if (isFreeIntro) {
        // For free intro calls: In app foreground, in-app incoming call screen handles it directly via RTDB listener - don't show notification
        debugPrint('[FCM] Foreground free intro call received. In app foreground dont show notification.');
        return;
      }
      debugPrint('[FCM] Foreground call received, displaying Native CallKit screen directly.');
      await _showCallkitIncoming(data);
    } else if (type == 'message') {
      // User requested not to show heads-up notifications when the app is in the foreground.
      // The chat screen will update automatically via Firestore streams.
      debugPrint('[FCM] Received message in foreground, skipping local notification.');
    }
  }

  // ── BACKGROUND TAP HANDLER ────────────────────────────────────────────

  void _handleMessageOpenedApp(RemoteMessage message) {
    debugPrint('[FCM] Notification tapped from background: ${message.data}');
    _routeFromNotification(message.data);
  }

  void _routeFromNotification(Map<String, dynamic> data) async {
    if (data['type'] == 'call') {
      final callRoomId = data['callRoomId'] as String? ?? '';
      if (callRoomId.isNotEmpty) {
        FlutterRingtonePlayer().stop();
        dismissCallKitScreen();
        _localNotifications.cancel(id: callRoomId.hashCode.abs());
        _navigateToActiveCall(callRoomId, autoAccept: false);
      }
      return;
    }

    if (data['type'] == 'message') {
      final senderId = data['senderId'] ?? '';
      String senderName = data['senderName'] ?? 'User';
      
      try {
        final prefs = await SharedPreferences.getInstance();
        final cached = prefs.getString('user_nickname_$senderId');
        if (cached != null && cached.isNotEmpty && cached != senderId) {
          senderName = cached;
        }
      } catch (_) {}

      if (senderName.isEmpty || senderName == senderId || (senderName.length >= 20 && !senderName.contains(' '))) {
        senderName = 'User';
      }

      int retries = 0;
      void pushRoute() {
        final currentState = navigatorKey?.currentState;
        
        if (currentState != null) {
          try {
            currentState.pushNamed(
              '/chat',
              arguments: <String, dynamic>{
                'otherUid': senderId,
                'otherUserName': senderName,
              },
            );
            debugPrint('[FCM] Successfully routed to chat!');
          } catch (e) {
            debugPrint('[FCM] Error routing to chat: $e');
            if (retries < 20) {
              retries++;
              Future.delayed(const Duration(milliseconds: 500), pushRoute);
            }
          }
        } else {
          if (retries < 20) {
            retries++;
            Future.delayed(const Duration(milliseconds: 500), pushRoute);
          }
        }
      }
      // Wait slightly before the first try to ensure UI is ready
      Future.delayed(const Duration(milliseconds: 300), pushRoute);
    }
  }

  // ── CALLKIT EVENT LISTENER ────────────────────────────────────────────

  /// Checks if the app was launched by accepting an incoming call while killed.
  Future<void> _checkKilledStateAcceptedCall() async {
    // 1. Check Native MainActivity intent via MethodChannel
    try {
      const channel = MethodChannel('com.sajnire.app/auth');
      final initialCallId = await channel.invokeMethod<String>('getInitialCallId');
      if (initialCallId != null && initialCallId.isNotEmpty) {
        debugPrint('[CallKit] Found initial accepted call from killed state via intent: $initialCallId');
        _navigateToActiveCall(initialCallId, autoAccept: true);
        return;
      }
    } catch (e) {
      debugPrint('[CallKit] Error checking initialCallId: $e');
    }

    // 2. Check active calls in flutter_callkit_incoming
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      if (calls.isNotEmpty) {
        debugPrint('[CallKit] Active calls on launch: $calls');
        for (final c in calls) {
          if (c.isAccepted && c.id.isNotEmpty) {
            debugPrint('[CallKit] Navigating to active call from activeCalls: ${c.id}');
            _navigateToActiveCall(c.id, autoAccept: true);
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('[CallKit] Error checking activeCalls: $e');
    }

    // 3. Check Local Notification launch details (if user tapped Accept on notification when killed)
    try {
      final launchDetails = await _localNotifications.getNotificationAppLaunchDetails();
      if (launchDetails != null && launchDetails.didNotificationLaunchApp) {
        final response = launchDetails.notificationResponse;
        if (response != null && response.payload != null) {
          final data = jsonDecode(response.payload!) as Map<String, dynamic>;
          final callRoomId = data['callRoomId'] as String? ?? '';
          if (callRoomId.isNotEmpty) {
            final isAccept = response.actionId == 'action_accept';
            debugPrint('[Notification] Found initial call from local notification launch: $callRoomId (autoAccept: $isAccept)');
            _navigateToActiveCall(callRoomId, autoAccept: isAccept);
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('[Notification] Error checking launchDetails: $e');
    }
  }

  /// Centralized routing to ActiveCallPage on call acceptance.
  /// Handles retries if navigatorKey is not yet mounted (e.g. killed state launch).
  void _navigateToActiveCall(String callRoomId, {bool autoAccept = false}) async {
    FlutterRingtonePlayer().stop();
    final prefs = await SharedPreferences.getInstance();
    final prefAutoAccept = prefs.getBool('autoAccept_$callRoomId') ?? false;
    final shouldAutoAccept = autoAccept || prefAutoAccept;
    if (prefAutoAccept) {
      await prefs.remove('autoAccept_$callRoomId');
    }

    final storedCallerName = prefs.getString('callerName_$callRoomId');
    String resolvedCallerId = prefs.getString('callerId_$callRoomId') ?? '';
    String resolvedName = storedCallerName ?? NotificationService.lastCallerName ?? 'Female Expert';
    final storedCallerCoins = prefs.getInt('callerCoins_$callRoomId');
    String? storedDbUrl = prefs.getString('dbUrl_$callRoomId');
    bool storedIsFreeIntro = prefs.getBool('isFreeIntroCall_$callRoomId') ?? false;

    int retries = 0;
    void pushRoute() {
      final state = navigatorKey?.currentState;
      if (state != null) {
        state.pushNamed(
          '/active-call',
          arguments: <String, dynamic>{
            'callRoomId': callRoomId,
            'callerName': resolvedName,
            'callerId': resolvedCallerId,
            'callerCoins': storedCallerCoins,
            'dbUrl': storedDbUrl,
            'isFreeIntroCall': storedIsFreeIntro,
            // maxDurationSeconds only for free intro calls; paid calls run until balance exhausted
            'maxDurationSeconds': storedIsFreeIntro == true ? 60 : null,
            'autoAccept': shouldAutoAccept,
          },
        );
      } else {
        if (retries < 30) {
          retries++;
          Future.delayed(const Duration(milliseconds: 200), pushRoute);
        }
      }
    }
    pushRoute();
  }

  /// Listens to OS-level CallKit events.
  /// On Accept → navigates to ActiveCallPage.
  /// On Decline → marks call as 'ended' in RTDB.
  void _listenCallKitEvents() {
    // Fallback: Listen to Native MainActivity intent for "Accept"
    final channel = MethodChannel('com.sajnire.app/auth');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onCallAcceptFallback') {
        final callRoomId = call.arguments as String?;
        debugPrint('[CallKit] Accepted via Fallback: $callRoomId');
        if (callRoomId != null && callRoomId.isNotEmpty) {
          _navigateToActiveCall(callRoomId, autoAccept: true);
        }
      }
    });

    FlutterCallkitIncoming.onEvent.listen((CallEvent? event) async {
      if (event == null) return;
      debugPrint('[CallKit] Event: ${event.eventName}');

      if (event is CallEventActionCallAccept) {
        final callRoomId = event.callKitParams.id;
        debugPrint('[CallKit] Accepted: $callRoomId');
        if (callRoomId.isNotEmpty) {
          _navigateToActiveCall(callRoomId, autoAccept: true);
        }
      } else if (event is CallEventActionCallDecline) {
        FlutterRingtonePlayer().stop();
        final callRoomId = event.callKitParams.id;
        debugPrint('[CallKit] Declined: $callRoomId');

        // End call properly via CallService (this also unlocks both users in RTDB)
        if (callRoomId.isNotEmpty) {
          try {
            final prefs = await SharedPreferences.getInstance();
            final storedDbUrl = prefs.getString('dbUrl_$callRoomId') ??
                'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app';
            await CallService(databaseURL: storedDbUrl).endCall(callRoomId);
          } catch (e) {
            debugPrint('[CallKit] RTDB error: $e');
          }
        }
        await dismissCallKitScreen();
      } else if (event is CallEventActionCallTimeout) {
        final callRoomId = event.id;
        debugPrint('[CallKit] Call timed out: $callRoomId');
        
        // End call properly via CallService to release locks
        if (callRoomId.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          final storedDbUrl = prefs.getString('dbUrl_$callRoomId');
          await CallService(databaseURL: storedDbUrl).endCall(callRoomId);
        }
        await dismissCallKitScreen();
      }
    });
  }

  /// Dismiss all CallKit screens programmatically.
  /// Call when the expert goes offline to cancel any shown call screens.
  Future<void> endAllCallkitScreens() async {
    await dismissCallKitScreen();
  }
}
