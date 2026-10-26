import 'dart:async';
import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';
import 'package:provider/provider.dart';
import 'package:firebase_database/firebase_database.dart';
import '../providers/app_state.dart';
import '../services/call_service.dart';
import 'active_call_page.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import '../services/user_database_service.dart';
import '../services/local_chat_database.dart';
import '../services/notification_service.dart';

class IncomingCallScreen extends StatefulWidget {
  final String callRoomId;
  final String callerId;
  final VoidCallback? onCallEnded;
  final String? callDatabaseURL;
  final bool isFreeIntroCall;

  const IncomingCallScreen({
    super.key,
    required this.callRoomId,
    required this.callerId,
    this.onCallEnded,
    this.callDatabaseURL,
    this.isFreeIntroCall = false,
  });

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late final CallService _callService;
  StreamSubscription<DatabaseEvent>? _callSub;
  bool _isDismissing = false;
  late Future<Map<String, dynamic>> _callerDataFuture;
  Timer? _vibrateTimer;

  String get _effectiveDatabaseUrl =>
      widget.callDatabaseURL ??
      'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app';

  Future<Map<String, dynamic>> _fetchCallerData() async {
    Map<String, dynamic> result = {
      'nickname': widget.isFreeIntroCall ? 'Female Expert' : 'User',
      'avatarUrl': null,
      'avatarIndex': 1,
      'coinBalance': 0,
    };
    try {
      // 1. Check room data on the active call database URL first (contains exact callerName & avatar)
      try {
        final rtdb = FirebaseDatabase.instanceFor(
          app: FirebaseDatabase.instance.app,
          databaseURL: _effectiveDatabaseUrl,
        );
        final roomSnap = await rtdb.ref('calls/${widget.callRoomId}').get();
        if (roomSnap.exists && roomSnap.value != null) {
          final rData = Map<String, dynamic>.from(roomSnap.value as Map);
          final roomCallerName = rData['callerName']?.toString().trim();
          if (roomCallerName != null && roomCallerName.isNotEmpty && roomCallerName != 'null') {
            result['nickname'] = roomCallerName;
          }
          if (rData['callerAvatar'] != null) {
            result['avatarUrl'] = rData['callerAvatar'].toString();
          }
          if (rData['callerAvatarIndex'] != null) {
            result['avatarIndex'] = (rData['callerAvatarIndex'] as num).toInt();
          }
          if (rData['callerCoins'] != null) {
            result['coinBalance'] = (rData['callerCoins'] as num).toInt();
          }
        }
      } catch (e) {
        debugPrint('[IncomingCall] Error fetching room data: $e');
      }

      // 2. Try checking user profile first (male caller)
      if (result['nickname'] == 'User' || result['nickname'] == 'Female Expert') {
        try {
          final data = await UserDatabaseService.instance
              .getUser(widget.callerId)
              .timeout(const Duration(seconds: 2));
          if (data != null) {
            if (data['nickname'] != null && data['nickname'].toString().isNotEmpty) {
              result['nickname'] = data['nickname'].toString();
            }
            if (result['avatarUrl'] == null) {
              result['avatarUrl'] = data['profileImageUrl'] ?? data['avatarUrl'];
            }
            result['avatarIndex'] = (data['avatarIndex'] as num?)?.toInt() ?? 1;
            if (result['coinBalance'] == 0) {
              result['coinBalance'] = (data['coinBalance'] as num?)?.toInt() ?? 0;
            }
          }
        } catch (_) {}
      }

      // 3. Fallback to expert profile (if caller is an expert)
      if (result['nickname'] == 'Female Expert' || result['nickname'] == 'User') {
        try {
          final expertData = await UserDatabaseService.instance
              .getExpert(widget.callerId)
              .timeout(const Duration(seconds: 1));
          if (expertData != null) {
            final eName = expertData['nickname'] ?? expertData['name'] ?? expertData['displayName'];
            if (eName != null && eName.toString().trim().isNotEmpty) {
              result['nickname'] = eName.toString().trim();
            }
            if (result['avatarUrl'] == null) {
              result['avatarUrl'] = expertData['profileImageUrl'] ?? expertData['avatarUrl'];
            }
            result['avatarIndex'] = (expertData['avatarIndex'] as num?)?.toInt() ?? 1;
          }
        } catch (_) {}
      }
    } catch (e) {
      debugPrint("Error fetching caller data: $e");
    }
    return result;
  }

  @override
  void initState() {
    super.initState();
    _callService = CallService(databaseURL: _effectiveDatabaseUrl);
    _callerDataFuture = _fetchCallerData();
    
    // Start playing system ringtone and vibration when the screen opens
    FlutterRingtonePlayer().play(
      android: AndroidSounds.ringtone,
      ios: IosSounds.glass,
      looping: true,
      volume: 1.0,
      asAlarm: true, // Forces it to play out loud
    );
    
    // Continuous real vibration using vibration package
    _vibrateTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      Vibration.vibrate(duration: 1000); // Vibrate for 1 second every 2 seconds
    });
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appState = context.read<AppState>();
      // For experts, their Firestore document ID is ALWAYS appState.uid.
      final String currentUserId = appState.uid;
      
      if (currentUserId.isNotEmpty) {
        // Crucial for MatchmakingService: set 'status' to 'ringing' in active_calls lock
        FirebaseDatabase.instanceFor(
          app: FirebaseDatabase.instance.app,
          databaseURL: _effectiveDatabaseUrl,
        ).ref('active_calls/$currentUserId').update({
          'status': 'ringing',
        }).catchError((e) => debugPrint('Error setting active_calls status: $e'));

        // Keep the existing profile status update as well
        FirebaseDatabase.instanceFor(
          app: FirebaseDatabase.instance.app,
          databaseURL: _effectiveDatabaseUrl,
        ).ref('status/$currentUserId').update({
          'callStatus': 'ringing',
        }).catchError((e) => debugPrint('Error setting ringing status: $e'));
      }
    });

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _callSub = FirebaseDatabase.instanceFor(
      app: FirebaseDatabase.instance.app,
      databaseURL: _effectiveDatabaseUrl,
    )
        .ref('calls/${widget.callRoomId}')
        .onValue
        .listen((event) {
      if (!event.snapshot.exists || event.snapshot.value == null) {
        _handleCallEndedRemotely();
        return;
      }
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final status = data['status']?.toString();
      if (status == 'ended' || status == 'cancelled' || status == 'missed' || status == 'rejected_blocked') {
        _handleCallEndedRemotely();
      }
    });
  }

  void _handleCallEndedRemotely() {
    if (_isDismissing) return;
    _isDismissing = true;
    
    _vibrateTimer?.cancel();
    FlutterRingtonePlayer().stop();
    dismissCallKitScreen();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Missed Call: Caller disconnected')),
      );
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _vibrateTimer?.cancel();
    FlutterRingtonePlayer().stop();
    dismissCallKitScreen();
    _callSub?.cancel();
    _pulseController.dispose();
    super.dispose();
  }

  void _acceptCall() async {
    if (_isDismissing) return;
    _isDismissing = true;
    
    final appState = context.read<AppState>();
    // For experts, their Firestore document ID is ALWAYS appState.uid.
    final currentUserId = appState.uid;
    
    final callerData = await _callerDataFuture;
    
    _vibrateTimer?.cancel();
    FlutterRingtonePlayer().stop();
    dismissCallKitScreen();
    
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => ActiveCallPage(
            callRoomId: widget.callRoomId,
            receiverId: currentUserId,
            callerId: widget.callerId,
            nickname: callerData['nickname'] ?? 'User',
            avatarUrl: callerData['avatarUrl'] as String?,
            avatarIndex: (callerData['avatarIndex'] as num?)?.toInt() ?? 1,
            pricePerMin: widget.isFreeIntroCall ? 0.0 : 4.0,
            isCaller: false,
            callerCoinBalance: (callerData['coinBalance'] as num?)?.toInt() ?? 0,
            onCallEnded: widget.onCallEnded,
            callDatabaseURL: widget.callDatabaseURL,
            isFreeIntroCall: widget.isFreeIntroCall,
            maxDurationSeconds: widget.isFreeIntroCall ? 60 : null,
          ),
        ),
      );
    }
  }

  void _declineCall() {
    if (_isDismissing) return;
    _isDismissing = true;
    
    _vibrateTimer?.cancel();
    FlutterRingtonePlayer().stop();
    dismissCallKitScreen();
    
    final appState = context.read<AppState>();
    final currentUserId = appState.uid;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final logId = 'log_${widget.callRoomId}';
    
    _callerDataFuture.then((callerData) {
      final logData = {
        'logId': logId,
        'callerId': widget.callerId,
        'receiverId': currentUserId,
        'otherUserName': callerData['nickname'] ?? 'User',
        'durationSeconds': 0,
        'status': 'missed',
        'timestamp': timestamp,
      };
      LocalChatDatabase.instance.saveCallLogLocally(logData);
      UserDatabaseService.instance.saveCallLog(logId, logData, isFinal: true);
    }).catchError((_) {});

    if (mounted) {
      Navigator.pop(context);
    }
    
    // Perform network call asynchronously after popping
    _callService.endCall(widget.callRoomId).catchError((e) {
      debugPrint('Error ending call: $e');
    });
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        _declineCall();
        return false;
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 80),

                // Caller name
                FutureBuilder<Map<String, dynamic>>(
                  future: _callerDataFuture,
                  builder: (context, snapshot) {
                    final name = (snapshot.data?['nickname'] as String?) ?? 'User';
                    return Text(
                      name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    );
                  },
                ),

                const SizedBox(height: 8),

                const Text(
                  'calling ....',
                  style: TextStyle(
                    color: Color(0xFFA3A3A3),
                    fontSize: 18,
                  ),
                ),

                if (widget.isFreeIntroCall)
                  Container(
                    margin: const EdgeInsets.only(top: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFF10B981), width: 1.2),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.card_giftcard_rounded, size: 14, color: Color(0xFF10B981)),
                        SizedBox(width: 6),
                        Text(
                          '1-Min Free Intro Call',
                          style: TextStyle(
                            color: Color(0xFF10B981),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),

                const Spacer(),

                // ─── Action Buttons ───────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.only(
                      left: 40, right: 40, bottom: 60, top: 40),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // Decline (Left)
                      _buildActionButton(
                        label: 'Decline',
                        icon: Icons.call_end,
                        color: const Color(0xFFEF4444),
                        onTap: _declineCall,
                      ),

                      // Accept (Right)
                      _buildActionButton(
                        label: 'Accept',
                        icon: Icons.call,
                        color: const Color(0xFF10B981),
                        onTap: _acceptCall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
    );
  }

  // ─── Helper Widgets ──────────────────────────────────────────────────────

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFD1D5DB),
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}
