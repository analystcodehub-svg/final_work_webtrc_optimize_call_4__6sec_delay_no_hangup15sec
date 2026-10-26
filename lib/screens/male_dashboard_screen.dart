import "package:flutter/services.dart";
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'active_call_page.dart';
import 'package:provider/provider.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import '../providers/app_state.dart';
import '../models/female_expert.dart';
import 'wallet_recharge_screen.dart';
import 'matchmaking_screen.dart';
import 'profile_screen.dart';
import '../widgets/local_avatar_widget.dart';
import '../services/call_service.dart';
import '../services/notification_service.dart';
import '../services/hybrid_chat_service.dart';
import 'chat_list_screen.dart';
import 'hybrid_chat_screen.dart';

import 'expert_feed_screen.dart';
import '../services/foreground_task_service.dart';
import '../services/local_chat_database.dart';
import '../services/user_database_service.dart';

class MaleCallerDashboard extends StatefulWidget {
  const MaleCallerDashboard({super.key});

  @override
  State<MaleCallerDashboard> createState() => _MaleCallerDashboardState();
}

class _MaleCallerDashboardState extends State<MaleCallerDashboard> with WidgetsBindingObserver {
  bool _isNotificationPermissionGranted = true;
  bool _isIncomingCallActive = false;
  // Removed unused _callService

  // Navigation & filter states
  int _currentTab = 0; // 0 for Home, 1 for Call, 2 for Chats, 3 for Profile
  int _recentsSubTab = 0; // 0 for Call transactions, 1 for Chat transactions

  // Modern Color Palette Constants
  static const Color brandBg = Color(0xFFF8FAFC); // Slate 50
  static const Color brandPrimary = Color(0xFF4F46E5); // Indigo 600
  static const Color brandTextDark = Color(0xFF0F172A); // Slate 900
  static const Color brandTextGrey = Color(0xFF64748B); // Slate 500
  static const Color brandCardBg = Colors.white;

  final ScrollController _homeScrollController = ScrollController();
  StreamSubscription? _incomingCallSubscription;
  StreamSubscription? _walletSubscription;

  Future<List<Map<String, dynamic>>> _fetchEnrichedCallLogs(String uid) async {
    final docs = await LocalChatDatabase.instance.getRecentCallLogs(uid);
    final enriched = <Map<String, dynamic>>[];
    for (var data in docs) {
      final map = Map<String, dynamic>.from(data);
      final expertId = map['receiverId'] == uid ? map['callerId'] : map['receiverId'];
      
      final profile = await LocalChatDatabase.instance.getEnrichedProfile(
        expertId,
        defaultRole: 'expert',
      );
      
      map['enrichedName'] = profile['name'] ?? expertId;
      map['enrichedAvatarUrl'] = profile['avatarUrl'];
      map['enrichedAvatarIndex'] = profile['avatarIndex'] ?? 1;
      map['expertId'] = expertId;
      enriched.add(map);
    }
    return enriched;
  }

  Future<List<Map<String, dynamic>>> _fetchEnrichedChatTransactions(String uid) async {
    final docs = await LocalChatDatabase.instance.getRecentChatTransactions(uid);
    final enriched = <Map<String, dynamic>>[];
    for (var data in docs) {
      final map = Map<String, dynamic>.from(data);
      final otherUid = (map['otherUid'] ?? '').toString();
      
      final profile = await LocalChatDatabase.instance.getEnrichedProfile(
        otherUid,
        defaultRole: 'expert',
      );
      
      map['enrichedName'] = profile['name'] ?? otherUid;
      map['enrichedAvatarUrl'] = profile['avatarUrl'] ?? map['otherAvatarUrl'];
      map['enrichedAvatarIndex'] = profile['avatarIndex'] ?? map['otherAvatarIndex'] ?? 1;
      enriched.add(map);
    }
    return enriched;
  }

  int _unreadCount = 0;
  StreamSubscription<void>? _chatUpdatesSubscription;

  void _updateUnreadCount(String uid) async {
    final count = await LocalChatDatabase.instance.getTotalUnreadCount(uid);
    if (mounted) {
      setState(() {
        _unreadCount = count;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkNotificationPermission();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Ensure we have a valid Firebase Auth session (anonymous) so Firestore
      // rules (request.auth != null) are satisfied before any reads.
      if (FirebaseAuth.instance.currentUser == null) {
        try {
          await FirebaseAuth.instance.signInAnonymously();
          debugPrint('[MALE_DASH] signInAnonymously success uid=${FirebaseAuth.instance.currentUser?.uid}');
        } catch (e) {
          debugPrint('[MALE_DASH] signInAnonymously error: $e');
        }
      } else {
        debugPrint('[MALE_DASH] already signed in uid=${FirebaseAuth.instance.currentUser?.uid}');
      }

      if (!mounted) return;

      _setupMalePresenceAndCallListener();
      _fetchInitialWalletBalance();
      // Initialize Chat Listeners
      final appState = context.read<AppState>();
      final myUid = appState.uid;
      HybridChatService.instance.initListeners(myUid);
      LocalChatDatabase.instance.syncCallLogsFromFirestore(myUid);
      LocalChatDatabase.instance.syncChatTransactionsFromRtdb(myUid);
      
      // Update initial unread count and listen for updates
      _updateUnreadCount(myUid);
      _chatUpdatesSubscription = LocalChatDatabase.instance.updates.listen((_) {
        _updateUnreadCount(myUid);
      });
      
      // Check notification permission and show bottom sheet if disabled
      _checkAndPromptNotification();
      
      // Keep app alive in background (always ON for male users)
      ForegroundTaskService.startService();
    });
  }

  Future<void> _checkNotificationPermission() async {
    try {
      final isGranted = await Permission.notification.isGranted;
      if (mounted && _isNotificationPermissionGranted != isGranted) {
        setState(() {
          _isNotificationPermissionGranted = isGranted;
        });
      }
    } catch (e) {
      debugPrint('[MALE_DASH] checkNotificationPermission error: $e');
    }
  }

  Future<void> _checkAndPromptNotification({bool force = false}) async {
    try {
      final status = await Permission.notification.status;
      if (status.isGranted) {
        if (mounted && !_isNotificationPermissionGranted) {
          setState(() {
            _isNotificationPermissionGranted = true;
          });
        }
        return;
      }

      if (mounted && _isNotificationPermissionGranted) {
        setState(() {
          _isNotificationPermissionGranted = false;
        });
      }

      // 1. If not permanently denied, trigger the Android NATIVE bottom-up popup directly!
      // This shows the system prompt: "Allow SajniRe to send you notifications? [Don't allow] [Allow]"
      // When the user taps 'Allow', notifications turn ON directly without opening Settings!
      if (!status.isPermanentlyDenied) {
        final newStatus = await Permission.notification.request();
        if (mounted && _isNotificationPermissionGranted != newStatus.isGranted) {
          setState(() {
            _isNotificationPermissionGranted = newStatus.isGranted;
          });
        }
        return;
      }

      // 2. If permanently denied (disabled in phone Settings):
      // Only open settings if the user explicitly clicked "चालू करें" (force == true)
      if (force && mounted) {
        openAppSettings();
      }
    } catch (e) {
      debugPrint('[MALE_DASH] checkAndPromptNotification error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndPromptNotification();
    }
  }

  void _showFreeMessagesPopup() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          elevation: 0,
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 10)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0xFFEFF6FF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.mark_chat_unread_rounded,
                    size: 48,
                    color: Color(0xFF3B82F6),
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  '5 मुफ़्त मैसेज!',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'आपको मिले हैं 5 मुफ़्त चैट मैसेज!\nअपनी पसंदीदा एक्सपर्ट से तुरंत चैटिंग शुरू करें।',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 15,
                    color: Color(0xFF64748B),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF3B82F6),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text(
                      'चैट शुरू करें',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showZeroBalancePopup() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          elevation: 0,
          backgroundColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 10)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFEF3C7),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.account_balance_wallet_rounded,
                    size: 44,
                    color: Color(0xFFF59E0B),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Zero Balance (₹0)',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Your wallet is empty. Recharge now (starting at just ₹20) to connect with experts via voice call and chat!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: Color(0xFF64748B),
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const WalletRechargeScreen()),
                      );
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF97316),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 2,
                    ),
                    child: const Text(
                      'Recharge Wallet',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Maybe Later',
                    style: TextStyle(
                      color: Color(0xFF94A3B8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _setupMalePresenceAndCallListener() {

    final appState = context.read<AppState>();
    final myUid = appState.uid;
    
    // Setup RTDB Presence
    final presenceRef = FirebaseDatabase.instanceFor(
      app: FirebaseDatabase.instance.app,
      databaseURL: 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app',
    ).ref('status/$myUid');
    
    presenceRef.set({
      'isOnline': true,
      'status': 'online',
      'lastChanged': ServerValue.timestamp,
    });
    presenceRef.onDisconnect().update({
      'isOnline': false,
      'status': 'offline',
      'lastChanged': ServerValue.timestamp,
    });

    // Listen for incoming calls
    _incomingCallSubscription = CallService().listenForIncomingCalls(
      expertId: myUid, // Male user receives the call
      onCallReceived: (roomId, callerId) {
        // Foreground user receives immediate in-app incoming call screen
        if (mounted) {
          _openIncomingCallScreen(roomId, callerId, isIntro: false);
        }
      },
    );

    // Listen to real-time wallet balance changes
    _walletSubscription?.cancel();
    _walletSubscription = UserDatabaseService.instance.usersRef
        .child(myUid)
        .child('coinBalance')
        .onValue
        .listen((event) {
      if (event.snapshot.exists && event.snapshot.value != null && mounted) {
        final coins = (event.snapshot.value as num).toInt();
        context.read<AppState>().setCoinBalance(coins);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // We don't dispose the singleton, just let it run or implement a cleanup method if needed.
    // HybridChatService.instance.dispose();
    _chatUpdatesSubscription?.cancel();
    _incomingCallSubscription?.cancel();
    _walletSubscription?.cancel();
    _homeScrollController.dispose();
    super.dispose();
  }

  // (Old _onScroll, _refreshExperts, _fetchExperts removed)

  Future<void> _fetchInitialWalletBalance() async {
    final appState = context.read<AppState>();
    final myUid = appState.uid;
    try {
      final data = await UserDatabaseService.instance.getUser(myUid);
      if (data != null) {
        int coinBalance = (data['coinBalance'] as num?)?.toInt() ?? 0;
        final freeMessagesUsed = (data['freeMessagesUsed'] as num?)?.toInt() ?? 0;
        final bool seenFreeMessagesPopup = data['seenFreeMessagesPopup'] as bool? ?? false;
        appState.setCoinBalance(coinBalance);
        appState.setFreeMessagesUsed(freeMessagesUsed);

        // Show Free 5 Messages Popup in Hindi if not seen yet and free messages available
        if (!seenFreeMessagesPopup && freeMessagesUsed < 5) {
          await UserDatabaseService.instance.updateUser(myUid, {
            'seenFreeMessagesPopup': true,
          });
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _showFreeMessagesPopup();
            });
          }
        } else if (coinBalance <= 0 && mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showZeroBalancePopup();
          });
        }
        
        final nickname = data['nickname'] as String? ?? '';
        if (nickname.isNotEmpty) {
          appState.setNickname(nickname);
        }
      } else {
        await UserDatabaseService.instance.setUser(myUid, {
          'uid': myUid,
          'coinBalance': 0,
          'seenFreeMessagesPopup': true,
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'freeMessagesUsed': 0,
          'gender': 'male',
        });
        appState.setCoinBalance(0);
        appState.setFreeMessagesUsed(0);
        
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _showFreeMessagesPopup();
          });
        }
      }
      
      // Save FCM Token for push notifications
      await NotificationService.instance.saveTokenForUser(
        userId: myUid,
        collection: 'users',
      );
    } catch (e) {
      debugPrint("Error fetching initial balance: $e");
    }
  }

  void _addMoneyDialog() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const WalletRechargeScreen()),
    );
  }

  void _triggerCall(FemaleExpert expert) async {
    try {
      final rtdb = FirebaseDatabase.instanceFor(
        app: FirebaseDatabase.instance.app,
        databaseURL: 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app',
      );
      final event = await rtdb.ref('status/${expert.id}/isOnline').once();
      bool isOnline = false;
      if (event.snapshot.value != null) {
        isOnline = event.snapshot.value == true;
      }
      
      if (!isOnline) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${expert.nickname} is currently offline. Routing to another expert...')),
          );
          _startRandomMatchmaking();
        }
        return;
      }
    } catch (e) {
      debugPrint('Error checking RTDB status: $e');
    }

    if (!mounted) return;
    final appState = context.read<AppState>();
    final balance = appState.coinBalance;

    const overridePricePerMin = 4.0; // Enforce ₹4/min for male callers
    
    if (balance < (overridePricePerMin * 10).toInt()) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(
            'Insufficient Balance',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Your balance is ₹${(balance / 10).toStringAsFixed(1)}. You need at least ₹$overridePricePerMin to place a call.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Cancel',
                style: TextStyle(color: brandTextGrey),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _addMoneyDialog();
              },
              style: ElevatedButton.styleFrom(backgroundColor: brandPrimary),
              child: const Text('Recharge'),
            ),
          ],
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => MatchmakingScreen(
          requestedExpert: expert,
          isRandomMode: false,
        ),
      ),
    );
  }

  void _startRandomMatchmaking() {
    final appState = context.read<AppState>();
    final balance = appState.coinBalance;

    const requiredCoins = 40; // equivalent to ₹4/min
    
    if (balance < requiredCoins) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text(
            'Insufficient Balance',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Text(
            'Your balance is ₹${(balance / 10).toStringAsFixed(1)}. You need at least ₹${(requiredCoins / 10).toStringAsFixed(1)} to start random matchmaking.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Cancel',
                style: TextStyle(color: brandTextGrey),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _addMoneyDialog();
              },
              style: ElevatedButton.styleFrom(backgroundColor: brandPrimary),
              child: const Text('Recharge'),
            ),
          ],
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const MatchmakingScreen(
          isRandomMode: true,
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_currentTab) {
      case 0: return _buildHomeTab();
      case 1: return _buildRecentsTab();
      case 2: return const ChatListScreen();
      case 3: return const ProfileScreen();
      default: return _buildHomeTab();
    }
  }

  Widget _buildIconWithBadge(IconData icon, String count, {bool isActive = false}) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon, size: 26),
        if (count.isNotEmpty)
          Positioned(
            top: -4,
            right: -4,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
              child: Text(
                count,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
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
        backgroundColor: brandBg,
        body: SafeArea(
          child: _buildBody(),
        ),
            bottomNavigationBar: Container(
        decoration: BoxDecoration(
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: BottomNavigationBar(
          currentIndex: _currentTab,
          onTap: (index) {
            setState(() {
              _currentTab = index;
            });
            if (!_isNotificationPermissionGranted) {
              _checkAndPromptNotification();
            }
          },
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          selectedItemColor: brandPrimary,
          unselectedItemColor: Colors.grey.shade500,
          selectedLabelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.normal, fontSize: 12),
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined, size: 26),
              activeIcon: Icon(Icons.home_rounded, size: 26),
              label: 'Home',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.phone_outlined, size: 26),
              activeIcon: Icon(Icons.phone_rounded, size: 26),
              label: 'Call',
            ),
            BottomNavigationBarItem(
              icon: _buildIconWithBadge(Icons.chat_bubble_outline_rounded, _unreadCount > 0 ? (_unreadCount > 99 ? '99+' : _unreadCount.toString()) : ''),
              activeIcon: _buildIconWithBadge(Icons.chat_bubble_rounded, _unreadCount > 0 ? (_unreadCount > 99 ? '99+' : _unreadCount.toString()) : '', isActive: true),
              label: 'Chat',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.person_outline_rounded, size: 26),
              activeIcon: Icon(Icons.person_rounded, size: 26),
              label: 'Profile',
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _buildNotificationWarningBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB), // Warm amber 50
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFDE68A), width: 1.5), // Amber 200
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.08),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: Color(0xFFFEF3C7),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.notifications_off_rounded,
              color: Color(0xFFD97706),
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'कॉल नोटिफिकेशन बंद हैं!',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF92400E),
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'लड़कियों की incoming calls मिस न हों, नोटिफिकेशन ऑन करें।',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFFB45309),
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () {
              _checkAndPromptNotification(force: true);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD97706),
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              textStyle: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            child: const Text('चालू करें'),
          ),
        ],
      ),
    );
  }

  Future<Map<String, dynamic>> _fetchCallerInfo(String callerId, {String? roomId, String? dbUrl}) async {
    // 1. Try checking room data first from RTDB (contains exact callerName e.g. "heena")
    if (roomId != null && roomId.isNotEmpty) {
      try {
        final rtdb = FirebaseDatabase.instanceFor(
          app: FirebaseDatabase.instance.app,
          databaseURL: dbUrl ?? 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app',
        );
        final rSnap = await rtdb.ref('calls/$roomId').get();
        if (rSnap.exists && rSnap.value != null) {
          final rData = Map<String, dynamic>.from(rSnap.value as Map);
          final cName = rData['callerName']?.toString().trim();
          if (cName != null && cName.isNotEmpty && cName != 'null') {
            return {
              'name': cName,
              'avatarUrl': rData['callerAvatar'] as String?,
              'avatarIndex': (rData['callerAvatarIndex'] as num?)?.toInt() ?? 1,
            };
          }
        }
      } catch (_) {}
    }

    try {
      final cachedProfile = await LocalChatDatabase.instance.getUserProfile(callerId);
      if (cachedProfile != null) {
        return {
          'name': cachedProfile['name'] as String? ?? 'सजनी',
          'avatarUrl': cachedProfile['avatarUrl'] as String?,
          'avatarIndex': (cachedProfile['avatarIndex'] as num?)?.toInt() ?? 1,
        };
      }
      final expertData = await UserDatabaseService.instance.getExpert(callerId);
      if (expertData != null) {
        final name = expertData['nickname'] ?? expertData['name'] ?? 'सजनी';
        final avatarUrl = expertData['profileImageUrl'] ?? expertData['avatarUrl'];
        final avatarIndex = (expertData['avatarIndex'] as num?)?.toInt() ?? 1;
        await LocalChatDatabase.instance.saveUserProfile({
          'uid': callerId,
          'name': name,
          'avatarUrl': avatarUrl,
          'avatarIndex': avatarIndex,
          'role': 'expert',
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        });
        return {
          'name': name,
          'avatarUrl': avatarUrl,
          'avatarIndex': avatarIndex,
        };
      }
    } catch (e) {
      debugPrint('[IN_APP_CALL] _fetchCallerInfo error: $e');
    }
    return {
      'name': 'सजनी',
      'avatarUrl': null,
      'avatarIndex': 1,
    };
  }

  void _openIncomingCallScreen(String roomId, String callerId, {bool isIntro = false}) async {
    if (_isIncomingCallActive) return;
    _isIncomingCallActive = true;

    final dbUrl = 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app';
    final callerInfo = await _fetchCallerInfo(callerId, roomId: roomId, dbUrl: dbUrl);
    if (!mounted) {
      _isIncomingCallActive = false;
      return;
    }

    final callerName = callerInfo['name'] as String? ?? 'सजनी';
    final callerAvatarUrl = callerInfo['avatarUrl'] as String?;
    final callerAvatarIndex = (callerInfo['avatarIndex'] as num?)?.toInt() ?? 1;
    final myUid = context.read<AppState>().uid;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ActiveCallPage(
          callRoomId: roomId,
          callerId: callerId,
          receiverId: myUid,
          nickname: callerName,
          avatarUrl: callerAvatarUrl,
          avatarIndex: callerAvatarIndex,
          isCaller: false,
          pricePerMin: 0.0,
          isFreeIntroCall: isIntro,
          callDatabaseURL: dbUrl,
          autoAccept: false,
        ),
      ),
    );

    _isIncomingCallActive = false;
  }

  // Home Tab view (Redesigned 60-70% similar)
  Widget _buildHomeTab() {
    final appState = context.watch<AppState>();

    return SingleChildScrollView(
      controller: _homeScrollController,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
            // Redesigned Top Custom Header Row
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Text(
                    'SajniRe',
                    style: GoogleFonts.yellowtail(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      color: brandTextDark,
                    ),
                  ),
                  const Spacer(),
                  // Wallet Pill (Redesigned with Slate 800 + Amber tag)
                  GestureDetector(
                    onTap: _addMoneyDialog,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFFF59E0B), Color(0xFFD97706)],
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text(
                              '₹ Wallet',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '₹${(appState.coinBalance / 10).toStringAsFixed(1)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.add_circle_outline_rounded,
                            color: Colors.amber,
                            size: 14,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            if (!_isNotificationPermissionGranted)
              _buildNotificationWarningBanner(),

            // Wallet Recharge Banner
            GestureDetector(
              onTap: _addMoneyDialog,
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF1D4ED8), Color(0xFF2563EB), Color(0xFF3B82F6)], // Vibrant Blue
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF1D4ED8).withValues(alpha: 0.45),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: Stack(
                    children: [
                      // Shine circle top-right
                      Positioned(
                        right: -20,
                        top: -20,
                        child: Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                        child: Row(
                          children: [
                            // Icon
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Text('💰', style: TextStyle(fontSize: 24)),
                            ),
                            const SizedBox(width: 14),
                            // Text block
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  RichText(
                                    text: const TextSpan(
                                      children: [
                                        TextSpan(
                                          text: 'Call only ',
                                          style: TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        TextSpan(
                                          text: '₹4',
                                          style: TextStyle(
                                            color: Colors.yellowAccent,
                                            fontSize: 24,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: -0.5,
                                          ),
                                        ),
                                        TextSpan(
                                          text: '/min',
                                          style: TextStyle(
                                            color: Colors.yellowAccent,
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Add button
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Text(
                                'Add ₹',
                                style: TextStyle(
                                  color: Color(0xFF1D4ED8),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),



            // Promotional Banner (5 FREE MESSAGES + SALE)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [Color(0xFF3B82F6), Color(0xFF1E3A8A)], // Vibrant Blue Gradient
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF1E3A8A).withValues(alpha: 0.3),
                    blurRadius: 15,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  children: [
                    // Background pattern (optional shine)
                    Positioned(
                      right: -30,
                      top: -30,
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (appState.freeMessagesUsed < 5) ...[
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: const BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Text('💬', style: TextStyle(fontSize: 16)),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        '5 FREE MESSAGES!',
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                      Text(
                                        'You have ${5 - appState.freeMessagesUsed} messages left ✨',
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Divider(color: Colors.white.withValues(alpha: 0.2), height: 1),
                            const SizedBox(height: 16),
                          ],
                          
                          // Discount Offer Section
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF59E0B), // Amber badge
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text(
                                      'LIMITED TIME OFFER',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  const Text(
                                    '40 Messages',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  const Text(
                                    '₹40',
                                    style: TextStyle(
                                      color: Colors.white60,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      decoration: TextDecoration.lineThrough,
                                    ),
                                  ),
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: const [
                                      Text(
                                        '₹',
                                        style: TextStyle(
                                          color: Colors.yellowAccent,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        '20',
                                        style: TextStyle(
                                          color: Colors.yellowAccent,
                                          fontSize: 28,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Section Header
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Featured Experts',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: brandTextDark,
                  ),
                ),
              ),
            ),

            // Integrated Expert Feed Screen (Live Real-Time Stream with Progressive Pagination)
            ExpertFeedScreen(scrollController: _homeScrollController),
          ],
        ),
      );
  }

  void _triggerCallByExpertId(String expertId) async {
    try {
      final data = await UserDatabaseService.instance.getExpert(expertId);
      if (data != null) {
        
        bool isOnline = false;
        try {
          final rtdb = FirebaseDatabase.instanceFor(
            app: FirebaseDatabase.instance.app,
            databaseURL: 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app',
          );
          final event = await rtdb.ref('status/$expertId/isOnline').once();
          if (event.snapshot.value != null) {
            isOnline = event.snapshot.value == true;
          }
        } catch (e) {
          debugPrint('Error fetching RTDB status: $e');
        }

        final expert = FemaleExpert(
          id: expertId,
          nickname: data['nickname'] ?? 'Expert',
          pricePerMin: (data['pricePerMin'] as num?)?.toInt() ?? 4,
          languages: data['languages'] ?? 'Hindi',
          rating: (data['rating'] ?? 4.5).toDouble(),
          isOnline: isOnline,
          avatarUrl: data['profileImageUrl'] ?? data['avatarUrl'],
          avatarIndex: (data['avatarIndex'] as num?)?.toInt() ?? 1,
          age: (data['age'] as num?)?.toInt() ?? 22,
        );
        _triggerCall(expert);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Expert not found')));
        }
      }
    } catch (e) {
      debugPrint('Error fetching expert: $e');
    }
  }

  String _formatLogTimestamp(BuildContext context, int? timestamp) {
    if (timestamp == null) return 'Just now';
    final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final now = DateTime.now();
    final isToday = dt.year == now.year && dt.month == now.month && dt.day == now.day;
    final isYesterday = dt.year == now.year && dt.month == now.month && dt.day == now.day - 1;
    final timeStr = TimeOfDay.fromDateTime(dt).format(context);
    if (isToday) {
      return 'Today $timeStr';
    } else if (isYesterday) {
      return 'Yesterday $timeStr';
    } else {
      return '${dt.day}/${dt.month} $timeStr';
    }
  }

  // Call & Chat Transaction History View
  Widget _buildRecentsTextTab({
    required String title,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                color: isSelected ? brandTextDark : const Color(0xFF94A3B8),
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: 3.5,
              width: 32,
              decoration: BoxDecoration(
                color: isSelected ? brandPrimary : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentsTab() {
    final appState = context.watch<AppState>();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top 2-Column Text Tabs: Call & Chats with Center Alignment
          Padding(
            padding: const EdgeInsets.only(top: 4.0, bottom: 8.0),
            child: Row(
              children: [
                Expanded(
                  child: _buildRecentsTextTab(
                    title: 'Call',
                    isSelected: _recentsSubTab == 0,
                    onTap: () {
                      if (_recentsSubTab != 0) {
                        setState(() => _recentsSubTab = 0);
                      }
                    },
                  ),
                ),
                Expanded(
                  child: _buildRecentsTextTab(
                    title: 'Chats',
                    isSelected: _recentsSubTab == 1,
                    onTap: () {
                      if (_recentsSubTab != 1) {
                        setState(() => _recentsSubTab = 1);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          
          Expanded(
            child: StreamBuilder<void>(
              stream: LocalChatDatabase.instance.updates,
              builder: (context, snapshot) {
                if (_recentsSubTab == 0) {
                  // ==== CALL TRANSACTION HISTORY ====
                  return FutureBuilder<List<Map<String, dynamic>>>(
                    future: _fetchEnrichedCallLogs(appState.uid),
                    builder: (context, futureSnapshot) {
                      if (futureSnapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final docs = futureSnapshot.data ?? [];
                      if (docs.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.phone_missed_rounded, size: 54, color: Colors.grey.shade400),
                              const SizedBox(height: 12),
                              const Text(
                                'No call transaction history',
                                style: TextStyle(color: brandTextGrey, fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final data = docs[index];
                          final expertId = data['expertId'] as String;
                          final durationSeconds = data['durationSeconds'] ?? 0;
                          
                          final m = durationSeconds ~/ 60;
                          final s = durationSeconds % 60;
                          final durationStr = durationSeconds > 0 ? '${m}m ${s}s' : 'Missed';
                          final formattedTime = _formatLogTimestamp(context, data['timestamp']);

                          final displayName = data['enrichedName'] as String;
                          final avatarUrl = data['enrichedAvatarUrl'] as String?;
                          final avatarIndex = data['enrichedAvatarIndex'] as int;

                          // Deducted balance calculation (NO coins displayed!)
                          final num? rawDeducted = data['deductedAmount'] as num?;
                          final double callCost = rawDeducted != null
                              ? rawDeducted.toDouble()
                              : (durationSeconds > 0
                                  ? (((durationSeconds ~/ 60) + (durationSeconds % 60 > 0 ? 1 : 0)) * 4.0)
                                  : 0.0);

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              color: brandCardBg,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.03),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                // Avatar
                                Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.blue.shade100,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: LocalAvatarWidget(
                                    uid: expertId,
                                    role: 'expert',
                                    radius: 26,
                                    avatarUrl: avatarUrl,
                                    avatarIndex: avatarIndex,
                                  ),
                                ),
                                const SizedBox(width: 14),

                                // Details: Name, Duration/Time, Deducted Balance
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        displayName,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: brandTextDark,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '$durationStr • $formattedTime',
                                        style: const TextStyle(color: brandTextGrey, fontSize: 13),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        '- ₹${callCost % 1 == 0 ? callCost.toStringAsFixed(0) : callCost.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFFDC2626), // Deducted balance
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // Purple Re-dial Call Button
                                GestureDetector(
                                  onTap: () => _triggerCallByExpertId(expertId),
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: brandPrimary,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: brandPrimary.withValues(alpha: 0.25),
                                          blurRadius: 8,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.phone_in_talk_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  );
                } else {
                  // ==== CHAT TRANSACTION HISTORY ====
                  return FutureBuilder<List<Map<String, dynamic>>>(
                    future: _fetchEnrichedChatTransactions(appState.uid),
                    builder: (context, futureSnapshot) {
                      if (futureSnapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final docs = futureSnapshot.data ?? [];
                      if (docs.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.chat_bubble_outline_rounded, size: 54, color: Colors.grey.shade400),
                              const SizedBox(height: 12),
                              const Text(
                                'No chat transaction history',
                                style: TextStyle(color: brandTextGrey, fontSize: 15, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        );
                      }

                      return ListView.builder(
                        itemCount: docs.length,
                        itemBuilder: (context, index) {
                          final data = docs[index];
                          final otherUid = (data['otherUid'] ?? '').toString();
                          final formattedTime = _formatLogTimestamp(context, data['timestamp']);

                          final displayName = data['enrichedName'] as String;
                          final avatarUrl = data['enrichedAvatarUrl'] as String?;
                          final avatarIndex = data['enrichedAvatarIndex'] as int;

                          // Deducted balance for message (NO coins displayed!)
                          final double amount = (data['amount'] as num?)?.toDouble() ?? 0.50;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              color: brandCardBg,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.03),
                                  blurRadius: 10,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Row(
                              children: [
                                // Avatar
                                Container(
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.indigo.shade100,
                                      width: 1.5,
                                    ),
                                  ),
                                  child: LocalAvatarWidget(
                                    uid: otherUid,
                                    role: 'expert',
                                    radius: 26,
                                    avatarUrl: avatarUrl,
                                    avatarIndex: avatarIndex,
                                  ),
                                ),
                                const SizedBox(width: 14),

                                // Details: Name, Timestamp, Deducted Balance
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        displayName,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: brandTextDark,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        formattedTime,
                                        style: const TextStyle(color: brandTextGrey, fontSize: 13),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        amount < 1.0
                                            ? '- ${(amount * 100).round()}paisa'
                                            : '- ₹${amount % 1 == 0 ? amount.toStringAsFixed(0) : amount.toStringAsFixed(2)}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFFDC2626), // Deducted balance
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                // Direct Chat Button
                                GestureDetector(
                                  onTap: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (context) => HybridChatScreen(
                                          myUid: appState.uid,
                                          otherUid: otherUid,
                                          otherUserName: displayName,
                                          otherUserAvatarUrl: avatarUrl,
                                          otherUserAvatarIndex: avatarIndex,
                                        ),
                                      ),
                                    );
                                  },
                                  child: Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: brandPrimary,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: brandPrimary.withValues(alpha: 0.25),
                                          blurRadius: 8,
                                          offset: const Offset(0, 4),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.chat_bubble_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

