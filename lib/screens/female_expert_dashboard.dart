import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'phone_auth_screen.dart';
import '../services/matchmaking_service.dart';
import '../services/local_chat_database.dart';
import '../widgets/local_avatar_widget.dart';
import '../screens/blocked_users_screen.dart';
import '../utils/auto_start_helper.dart';
import '../services/foreground_task_service.dart';
import '../services/user_database_service.dart';
import '../services/hybrid_chat_service.dart';


class FemaleExpertDashboard extends StatefulWidget {
  const FemaleExpertDashboard({super.key});

  @override
  State<FemaleExpertDashboard> createState() => _FemaleExpertDashboardState();
}

class _FemaleExpertDashboardState extends State<FemaleExpertDashboard> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late final MatchmakingService _matchingService;
  bool _isInCall = false; // guard against re-starting listener during active call

  @override
  void initState() {
    super.initState();
    _matchingService = MatchmakingService();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    WidgetsBinding.instance.addObserver(this);

    // Start listening for calls if already online
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      _loadEarningsFromFirestore(appState);
      
      // Sync call logs from Firestore to local database
      final currentUserId = appState.mobileNumber.isNotEmpty ? appState.mobileNumber : appState.uid;
      LocalChatDatabase.instance.syncCallLogsFromFirestore(currentUserId);

      if (appState.uid.isNotEmpty) {
        HybridChatService.instance.initListeners(appState.uid);
      }
    });
  }

  Future<void> _loadEarningsFromFirestore(AppState appState) async {
    try {
      final expertId = appState.uid.isNotEmpty ? appState.uid : appState.mobileNumber;
      if (expertId.isEmpty) return;
      final data = await UserDatabaseService.instance.getExpert(expertId);
      if (data != null) {
        final earnings = (data['totalEarnings'] as num?)?.toDouble() ?? 0.0;
        appState.addEarnings(earnings - appState.totalEarnings);
      }
    } catch (e) {
      debugPrint('Error loading earnings: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_isInCall) {
      // Re-sync RTDB presence ONLY when NOT already in an incoming/active call.
      // If we refresh during a call, it re-starts the listener and freezes buttons.
      final appState = context.read<AppState>();
      if (appState.isOnline) {
        _updateOnlineStatus(true);
      }
    }
  }

  Future<void> _updateOnlineStatus(bool value) async {
    final appState = context.read<AppState>();
    appState.setOnlineStatus(value);
    
    final String expertId = appState.uid;
    if (expertId.isNotEmpty) {
      try {
        await _matchingService.setExpertOnlineStatus(
          expertId: expertId,
          isOnline: value,
          gender: 'female',
          language: appState.primaryLanguage,
        );
      } catch (e) {
        debugPrint('Error updating online status: $e');
      }
    }

    if (!mounted) return;

    if (value) {
      // Ask for auto-start permission when they go online, so they receive background calls.
      AutoStartHelper.checkAndRequestAutoStart(context);
      // Keep app alive in background while online
      ForegroundTaskService.startService();
    } else {
      // Stop background service when offline to save battery
      ForegroundTaskService.stopService();
    }
  }



  void _logout() {
    final appState = context.read<AppState>();
    final String expertId = appState.uid;
    if (expertId.isNotEmpty) {
      _matchingService.setExpertOnlineStatus(
          expertId: expertId,
          isOnline: false,
          gender: 'female',
          language: appState.primaryLanguage,
      ).catchError((e) {
        debugPrint('Error removing expert from queue: $e');
      });

    }
    appState.reset();
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (context) => const PhoneAuthScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final isOnline = appState.isOnline;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Color(0xFFE2E8F0),
      ),
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Expert Dashboard'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.block, color: Colors.grey),
            tooltip: 'Blocked Users',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const BlockedUsersScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: Colors.redAccent),
            tooltip: 'Logout / Reset',
            onPressed: _logout,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),

              // Avatar with Online indicator pulse
              Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (isOnline)
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (context, child) {
                          return Container(
                            width: 170 + (_pulseController.value * 30),
                            height: 170 + (_pulseController.value * 30),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.green.withValues(alpha: 0.2 * (1 - _pulseController.value)),
                            ),
                          );
                        },
                      ),
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isOnline ? Colors.green : AppTheme.borderGrey,
                          width: 4.0,
                        ),
                      ),
                      child: LocalAvatarWidget(
                        uid: appState.uid,
                        role: 'expert',
                        radius: 80,
                      ),
                    ),
                    Positioned(
                      bottom: 8,
                      right: 12,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isOnline ? Colors.green : Colors.grey,
                          border: Border.all(color: Colors.white, width: 2.0),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Nickname
              Text(
                appState.nickname.isNotEmpty ? appState.nickname : 'Expert Name',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textBlack,
                ),
              ),
              const SizedBox(height: 4),

              // Primary Language Tag
              Text(
                'Primary Language: ${appState.primaryLanguage}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.textGrey,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 40),

              // Total Earnings Card
              Container(
                padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
                decoration: BoxDecoration(
                  color: AppTheme.inputBg,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.borderGrey, width: 1.0),
                ),
                child: Column(
                  children: [
                    const Text(
                      'TOTAL EARNINGS',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.textGrey,
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '₹${appState.totalEarnings % 1 == 0 ? appState.totalEarnings.toStringAsFixed(0) : appState.totalEarnings.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryBlue,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),

              // Switch Online / Offline controls
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    decoration: BoxDecoration(
                      color: isOnline ? Colors.green.withValues(alpha: 0.08) : AppTheme.inputBg,
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        color: isOnline ? Colors.green.withValues(alpha: 0.3) : AppTheme.borderGrey,
                        width: 1.0,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isOnline ? 'ONLINE' : 'OFFLINE',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: isOnline ? Colors.green : AppTheme.textGrey,
                          ),
                        ),
                        Switch(
                          value: isOnline,
                          activeThumbColor: Colors.green,
                          inactiveThumbColor: Colors.grey,
                          inactiveTrackColor: Colors.grey.withValues(alpha: 0.2),
                          onChanged: (bool value) {
                            _updateOnlineStatus(value);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Turn ON to receive incoming calls from users',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppTheme.textGrey,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
}
