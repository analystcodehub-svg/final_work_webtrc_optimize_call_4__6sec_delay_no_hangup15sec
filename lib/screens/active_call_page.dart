import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../providers/app_state.dart';
import '../services/call_service.dart';
import '../services/local_chat_database.dart';
import '../services/block_service.dart';
import '../services/user_database_service.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:vibration/vibration.dart';
import '../services/notification_service.dart';

class ActiveCallPage extends StatefulWidget {
  final String? callRoomId; // Supplied for receiver/expert, generated for caller
  final String receiverId;
  final String callerId;
  final String nickname;
  final bool isCaller;
  final double pricePerMin;
  final CallService? preStartedCallService;
  final String? avatarUrl;
  final int avatarIndex;
  final VoidCallback? onCallEnded;
  final int? callerCoinBalance;
  final String? callDatabaseURL;
  final bool isFreeIntroCall;
  final int? maxDurationSeconds;
  final String? callerLanguage;
  final bool autoAccept;

  const ActiveCallPage({
    super.key,
    this.callRoomId,
    required this.receiverId,
    required this.callerId,
    required this.nickname,
    required this.isCaller,
    required this.pricePerMin,
    this.preStartedCallService,
    this.avatarUrl,
    this.avatarIndex = 1,
    this.onCallEnded,
    this.callerCoinBalance,
    this.callDatabaseURL,
    this.isFreeIntroCall = false,
    this.maxDurationSeconds,
    this.callerLanguage,
    this.autoAccept = false,
  });

  @override
  State<ActiveCallPage> createState() => _ActiveCallPageState();
}

class _ActiveCallPageState extends State<ActiveCallPage> with TickerProviderStateMixin {
  late final CallService _callService;
  bool _isConnected = false;
  bool _callAccepted = false;
  String? _roomId;
  int _duration = 0;
  Timer? _timer;
  Timer? _ringingTimer;
  Timer? _availabilityTimer;
  Timer? _availabilityTicker;
  Timer? _countdownTicker;
  Timer? _iceDisconnectTimer;
  int _availabilityCountdown = 7;
  bool _isRemoteRingingConfirmed = false;

  bool _isMuted = false;
  bool _isSpeakerOn = false;
  bool _isHangingUp = false;
  bool _isHangupHandled = false;

  late bool _isFreeIntroCall;
  int _maxDurationSeconds = 60;
  late String _displayName;
  String? _displayAvatarUrl;
  int _displayAvatarIndex = 1;
  bool _callAttendedRecorded = false;

  // Dynamic candidate matchmaking state for intro calls
  late String _currentReceiverId;
  String _statusMessage = 'Searching availability...';

  // Availability checking state (4 seconds round animation)
  bool _isAvailabilityChecking = false;
  int _ringingCountdown = 15;
  late AnimationController _rippleController;

  // Tier-based expert earning rate (resolved from Firestore on connect)
  double _expertEarningRate = 1.2; // default Bronze ₹1.2/min
  int _creditedMinutes = 0; // Tracks minutes credited at 50s mark
  bool _tierResolved = false;
  int? _callerCoinBalance;
  StreamSubscription? _balanceSub;
  StreamSubscription<DatabaseEvent>? _roomStatusSub;
  Timer? _vibrateTimer;

  @override
  void initState() {
    super.initState();
    // Keep screen ON for entire call duration (prevents black screen on proximity)
    WakelockPlus.enable();
    _currentReceiverId = widget.receiverId;
    if (_currentReceiverId.isEmpty) {
      _currentReceiverId = FirebaseAuth.instance.currentUser?.uid ?? '';
    }
    _roomId = widget.callRoomId;
    _isFreeIntroCall = widget.isFreeIntroCall;
    // null means unlimited — call ends only when male runs out of coins, not by timer
    _maxDurationSeconds = widget.maxDurationSeconds ?? 99999;
    _displayName = widget.nickname;
    _displayAvatarUrl = widget.avatarUrl;
    _displayAvatarIndex = widget.avatarIndex;
    _statusMessage = 'Searching availability for $_displayName...';

    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    final effectiveDbUrl = widget.callDatabaseURL ??
        'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app';
    _callService = widget.preStartedCallService ?? CallService(databaseURL: effectiveDbUrl);
    
    if (widget.callerCoinBalance != null && widget.callerCoinBalance! > 0) {
      _callerCoinBalance = widget.callerCoinBalance;
    }

    if (!widget.isCaller) {
      _resolveRemoteData();
      _callAccepted = widget.autoAccept;
      if (!widget.autoAccept) {
        _statusMessage = 'Incoming Call...';
        FlutterRingtonePlayer().play(
          android: AndroidSounds.ringtone,
          ios: IosSounds.glass,
          looping: true,
          volume: 1.0,
          asAlarm: true,
        );
        _vibrateTimer = Timer.periodic(const Duration(seconds: 2), (_) {
          Vibration.vibrate(duration: 1000);
        });
      }
    }
    
    if (_isFreeIntroCall && widget.isCaller) {
      _isAvailabilityChecking = true;
      _availabilityCountdown = 7;
      _isRemoteRingingConfirmed = false;
    }

    _initRenderersAndCall();

    if (_roomId != null && _roomId!.isNotEmpty) {
      _subscribeToRoomStatus(_roomId!);
    }

    if (_isFreeIntroCall && widget.isCaller) {
      // Step 1: Show 4-second round animation searching availability
      _startAvailabilityCheck();
    } else if (widget.isCaller) {
      _startRingingTimeout(7);
    }
  }

  void _subscribeToRoomStatus(String roomId) {
    _roomStatusSub?.cancel();
    final effectiveDbUrl = widget.callDatabaseURL ??
        'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app';

    _roomStatusSub = FirebaseDatabase.instanceFor(
      app: FirebaseDatabase.instance.app,
      databaseURL: effectiveDbUrl,
    ).ref('calls/$roomId/status').onValue.listen((event) {
      if (!mounted || _isHangingUp || _isHangupHandled) return;
      if (event.snapshot.exists && event.snapshot.value != null) {
        final status = event.snapshot.value.toString();
        debugPrint('[ActiveCallPage] calls/$roomId status updated: $status');
        if (status == 'ringing') {
          _onRemoteRingingReceived();
        } else if (status == 'connected') {
          debugPrint('[ActiveCallPage] calls/$roomId status updated to connected. Marking call connected.');
          _markCallConnected();
        } else if (status == 'ended' || status == 'rejected' || status == 'rejected_blocked') {
          FlutterRingtonePlayer().stop();
          _vibrateTimer?.cancel();
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Call ended')),
            );
            _hangupLocal();
          }
        }
      }
    });
  }

  void _markCallConnected() {
    if (!mounted || _isConnected) return;
    debugPrint('[ActiveCallPage] Call marked connected. Cancelling ringing and availability timers.');
    FlutterRingtonePlayer().stop();
    _vibrateTimer?.cancel();
    _availabilityTimer?.cancel();
    _availabilityTicker?.cancel();
    _ringingTimer?.cancel();
    _countdownTicker?.cancel();
    _iceDisconnectTimer?.cancel();
    _iceDisconnectTimer = null;

    setState(() {
      _isConnected = true;
      _isAvailabilityChecking = false;
      _isSpeakerOn = true;
      _statusMessage = 'Connected';
    });

    // Cancel onDisconnect in RTDB so screen-off or background socket drop NEVER deletes room
    if (_roomId != null) {
      _callService.cancelOnDisconnect(_roomId!);
    }

    // Assert speakerphone immediately, at 500ms, and at 1500ms to override any Android audio mode resets
    Helper.setSpeakerphoneOn(true);
    Future.delayed(const Duration(milliseconds: 500), () {
      Helper.setSpeakerphoneOn(true);
    });
    Future.delayed(const Duration(milliseconds: 1500), () {
      Helper.setSpeakerphoneOn(true);
    });

    _startCallTimer();
    _handleCallAttended();
  }

  void _handleIceConnectionState(RTCIceConnectionState state) {
    if (!mounted || _isHangingUp) return;
    debugPrint('[ActiveCallPage] WebRTC ICE State: $state');

    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      // ICE connection is healthy: cancel any running disconnect grace timer
      _iceDisconnectTimer?.cancel();
      _iceDisconnectTimer = null;
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      // 6-second internet disconnect rule: If either user's internet is turned off for 6s, hang up
      if (_iceDisconnectTimer == null || !_iceDisconnectTimer!.isActive) {
        debugPrint('[ActiveCallPage] ICE Disconnected detected. Starting 6-second grace timer...');
        _iceDisconnectTimer = Timer(const Duration(seconds: 6), () {
          if (mounted && !_isHangingUp) {
            debugPrint('[ActiveCallPage] 6 seconds elapsed in Disconnected state. Terminating call due to network loss.');
            _triggerHangup();
          }
        });
      }
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
        state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
      _iceDisconnectTimer?.cancel();
      _iceDisconnectTimer = null;
      debugPrint('[ActiveCallPage] Terminal WebRTC failure ($state) -> Ending call.');
      _triggerHangup();
    }
  }

  void _onRemoteRingingReceived() {
    if (!mounted || _isConnected || _isHangingUp) return;

    _isRemoteRingingConfirmed = true;
    debugPrint('[ActiveCallPage] Remote ringing CONFIRMED for $_displayName!');

    if (!_isAvailabilityChecking && _ringingTimer != null && _ringingTimer!.isActive) {
      return;
    }

    debugPrint('[ActiveCallPage] Ringing verified! Switching immediately from availability check to 15s ringing countdown.');
    _availabilityTimer?.cancel();
    _availabilityTicker?.cancel();

    setState(() {
      _isAvailabilityChecking = false;
      _availabilityCountdown = 0;
      _statusMessage = 'Ringing $_displayName...';
    });

    _startRingingCountdownAndTimeout(15);
  }

  void _startAvailabilityCheck() {
    _availabilityTimer?.cancel();
    _availabilityTicker?.cancel();
    _ringingTimer?.cancel();
    _countdownTicker?.cancel();
    _isRemoteRingingConfirmed = false;

    setState(() {
      _isAvailabilityChecking = true;
      _availabilityCountdown = 7;
      _statusMessage = 'Searching availability for $_displayName...';
    });

    _availabilityTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _isConnected || _isHangingUp || !_isAvailabilityChecking) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_availabilityCountdown > 1) {
          _availabilityCountdown--;
        } else {
          timer.cancel();
        }
      });
    });

    _availabilityTimer = Timer(const Duration(seconds: 7), () {
      _availabilityTicker?.cancel();
      if (!mounted || _isConnected || _isHangingUp) return;

      // ── CRITICAL CHECK: Did remote phone confirm ringing within 7s? ──
      if (!_isRemoteRingingConfirmed) {
        debugPrint('[ActiveCallPage] 7s availability check expired with NO ringing confirmed for $_displayName. Auto-connecting to next candidate immediately!');
        _handleUnreachableOrTimeout(reason: 'unreachable');
        return;
      }

      debugPrint('[ActiveCallPage] 7s availability search finished and ringing was confirmed for $_displayName. Transitioning to 15s ringing screen...');
      setState(() {
        _isAvailabilityChecking = false;
        _availabilityCountdown = 0;
      });
      _startRingingCountdownAndTimeout(15);
    });
  }

  void _startRingingCountdownAndTimeout(int seconds) {
    _ringingTimer?.cancel();
    _countdownTicker?.cancel();
    _ringingCountdown = seconds;

    _countdownTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _isConnected || _isHangingUp) {
        timer.cancel();
        return;
      }
      setState(() {
        if (_ringingCountdown > 0) {
          _ringingCountdown--;
        } else {
          timer.cancel();
        }
      });
    });

    _ringingTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_isConnected && !_isHangingUp) {
        debugPrint('[ActiveCallPage] 15s ringing timed out. Connecting to other user...');
        _handleUnreachableOrTimeout(reason: 'timeout');
      }
    });
  }

  void _startRingingTimeout(int seconds) {
    _ringingTimer?.cancel();
    _ringingTimer = Timer(Duration(seconds: seconds), () {
      if (mounted && !_isConnected && !_isHangingUp) {
        debugPrint('[ActiveCallPage] Ringing timed out after ${seconds}s.');
        _handleUnreachableOrTimeout(reason: 'timeout');
      }
    });
  }

  Future<void> _initRenderersAndCall() async {
    try {
      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Microphone permission is required for WebRTC audio calling.')),
          );
        }
        return;
      }

      // Audio-only call: no RTCVideoRenderer surfaces are initialized
      // (saves ~100-200ms of GL texture setup). WebRTC plays remote audio
      // tracks automatically without a renderer.
      if (widget.preStartedCallService != null) {
        await _initCall();
        return;
      }

      if (!widget.isCaller) {
        if (_callAccepted) {
          await _acceptIncomingCall();
        }
        return;
      }

      if (widget.isCaller) {
        try {
          final maleCoins = mounted ? context.read<AppState>().coinBalance : null;
          final femaleLang = widget.callerLanguage ??
              (mounted ? context.read<AppState>().primaryLanguage : null) ??
              'Hindi';
          final femaleNick = mounted ? context.read<AppState>().nickname : 'Female Expert';
          final femaleAvatarIndex = mounted ? context.read<AppState>().avatarIndex : 1;

          Map<String, dynamic>? extra;
          if (_isFreeIntroCall) {
            extra = {
              'isFreeIntroCall': true,
              'maxDurationSeconds': _maxDurationSeconds,
              'callerName': femaleNick.isNotEmpty ? femaleNick : 'Female Expert',
              'callerAvatar': 'assets/avatars/female_$femaleAvatarIndex.png',
              'callerAvatarIndex': femaleAvatarIndex,
              'callerLanguage': femaleLang,
            };
          }

          final generatedRoomId = await _callService.startCall(
            expertId: widget.receiverId,
            callerId: widget.callerId,
            callerCoins: maleCoins,
            pricePerMin: widget.pricePerMin,
            extraRoomData: extra,
            onRemoteStream: (stream) {
              if (mounted) {
                _markCallConnected();
              }
            },
            onCallEnded: _onCallEndedCallback,
            onRinging: _onRemoteRingingReceived,
            onIceConnectionState: _handleIceConnectionState,
          );
          if (mounted) {
            setState(() {
              _roomId = generatedRoomId;
            });
            _subscribeToRoomStatus(generatedRoomId);
          } else {
            _callService.endCall(generatedRoomId);
          }
        } catch (e) {
          debugPrint('Error starting call: $e');
          _hangupLocal();
        }
      }
    } catch (e) {
      debugPrint('Error in _initRenderersAndCall: $e');
      _hangupLocal();
    }
  }

  Future<void> _resolveRemoteData() async {
    if (_tierResolved) return;
    _tierResolved = true;
    try {
      String actualExpertId = widget.receiverId;
      String actualCallerId = widget.callerId;

      debugPrint('[_resolveRemoteData] Initial - expert: $actualExpertId, caller: $actualCallerId');

      if (widget.callRoomId != null) {
        try {
          final String callDbUrl = widget.callDatabaseURL ??
              'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app';
          final FirebaseDatabase database = FirebaseDatabase.instanceFor(
            app: FirebaseDatabase.instance.app,
            databaseURL: callDbUrl,
          );
          final callDoc = await database.ref('calls/${widget.callRoomId}').get();
          if (callDoc.exists) {
            final data = Map<String, dynamic>.from(callDoc.value as Map);
            actualCallerId = data['callerId'] ?? actualCallerId;
            actualExpertId = data['receiverId'] ?? actualExpertId;
            if (data['isFreeIntroCall'] == true) {
              _isFreeIntroCall = true;
              if (mounted) setState(() {});
            }
            if (data['maxDurationSeconds'] != null) {
              _maxDurationSeconds = (data['maxDurationSeconds'] as num).toInt();
            }
            debugPrint('[_resolveRemoteData] Fetched from calls - expert: $actualExpertId, caller: $actualCallerId, isFree: $_isFreeIntroCall');
            if (data['callerCoins'] != null && _callerCoinBalance == null) {
              final c = (data['callerCoins'] as num).toInt();
              if (mounted) {
                setState(() {
                  _callerCoinBalance = c;
                });
              }
            }

            // Resolve female caller display name & avatar if current user is receiving the call
            if (!widget.isCaller) {
              final roomCallerName = data['callerName'] as String?;
              if (roomCallerName != null && roomCallerName.isNotEmpty && roomCallerName != 'User') {
                _displayName = roomCallerName;
              }
              final roomAvatar = data['callerAvatar'] as String?;
              if (roomAvatar != null && roomAvatar.isNotEmpty) {
                _displayAvatarUrl = roomAvatar;
              }
              if (data['callerAvatarIndex'] != null) {
                _displayAvatarIndex = (data['callerAvatarIndex'] as num).toInt();
              }
            }
            if (mounted) setState(() {});
          }
        } catch (e) {
          debugPrint('[_resolveRemoteData] Error fetching callDoc: $e');
        }
      }

      // Fallback: If female caller name is still unknown/User, resolve from local profile cache or RTDB
      if (!widget.isCaller && (_displayName.isEmpty || _displayName == 'User' || _displayName == actualCallerId)) {
        try {
          final cached = await LocalChatDatabase.instance.getUserProfile(actualCallerId);
          if (cached != null && cached['name'] != null && cached['name'].toString().isNotEmpty) {
            _displayName = cached['name'].toString();
            if (cached['avatarUrl'] != null) _displayAvatarUrl = cached['avatarUrl'].toString();
            if (cached['avatarIndex'] != null) _displayAvatarIndex = (cached['avatarIndex'] as num).toInt();
            if (mounted) setState(() {});
          } else {
            final expertData = await UserDatabaseService.instance.getExpert(actualCallerId);
            if (expertData != null) {
              final eName = (expertData['nickname'] ?? expertData['name'])?.toString().trim() ?? '';
              if (eName.isNotEmpty) {
                _displayName = eName;
                _displayAvatarUrl = expertData['profileImageUrl'] ?? expertData['avatarUrl'];
                _displayAvatarIndex = (expertData['avatarIndex'] as num?)?.toInt() ?? 1;
                if (mounted) setState(() {});
              }
            }
          }
        } catch (e) {
          debugPrint('[_resolveRemoteData] Error resolving caller profile: $e');
        }
      }

      if (actualExpertId.isNotEmpty) {
        final expertData = await UserDatabaseService.instance.getExpert(actualExpertId);
        if (expertData != null) {
          final tier = expertData['tier'] as String? ?? 'bronze';
          if (mounted) {
            setState(() {
              _expertEarningRate = tier == 'silver' ? 1.6 : 1.2;
            });
          }
        }
      }

      if (actualCallerId.isNotEmpty) {
        if (_callerCoinBalance == null || _callerCoinBalance == 0) {
          final callerData = await UserDatabaseService.instance.getUser(actualCallerId);
          debugPrint('[_resolveRemoteData] callerData exists: ${callerData != null}');
          if (callerData != null) {
            final b = (callerData['coinBalance'] as num?)?.toInt() ?? 0;
            debugPrint('[_resolveRemoteData] Setting balance: $b');
            if (mounted && (_callerCoinBalance == null || _callerCoinBalance == 0)) {
              setState(() {
                _callerCoinBalance = b;
              });
            }
          }
        }

        // Listen for balance changes in real time (e.g. caller recharge during call)
        _balanceSub?.cancel();
        _balanceSub = UserDatabaseService.instance.usersRef
            .child(actualCallerId)
            .child('coinBalance')
            .onValue
            .listen((event) {
          if (event.snapshot.exists && event.snapshot.value != null) {
            final latestCoins = (event.snapshot.value as num).toInt();
            if (mounted) {
              if (_callerCoinBalance == null || _callerCoinBalance == 0) {
                setState(() {
                  _callerCoinBalance = latestCoins;
                });
              } else if (latestCoins > _callerCoinBalance!) {
                final added = latestCoins - _callerCoinBalance!;
                setState(() {
                  _callerCoinBalance = (_callerCoinBalance ?? 0) + added;
                });
              }
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Error resolving remote data: $e');
    }
  }

  void _handleCallAttended() {
    if (_callAttendedRecorded) return;
    if (!_isConnected || _duration < 5) return;
    _callAttendedRecorded = true;
  }

  void _onCallEndedCallback() {
    if (_isHangupHandled) return;
    _hangupLocal();
  }

  Future<void> _handleUnreachableOrTimeout({required String reason}) async {
    if (_isHangingUp || _isConnected) return;
    _hangupLocal();
  }

  Future<void> _initCall() async {
    if (widget.preStartedCallService != null) {
      // Call is already pre-started by MatchingService
      _callService.updateListeners(
        onRemoteStream: (stream) {
          if (mounted) {
            _markCallConnected();
          }
        },
        onCallEnded: _onCallEndedCallback,
        onRinging: _onRemoteRingingReceived,
        onIceConnectionState: _handleIceConnectionState,
      );

      if (mounted) {
        if (_callService.remoteStream != null) {
          _markCallConnected();
        }
      }
      return;
    }

    if (widget.isCaller) {
      try {
        final maleNick = context.read<AppState>().nickname;
        final maleAvatarIdx = context.read<AppState>().avatarIndex;
        final generatedRoomId = await _callService.startCall(
          expertId: widget.receiverId,
          callerId: widget.callerId,
          callerCoins: context.read<AppState>().coinBalance,
          pricePerMin: widget.pricePerMin,
          extraRoomData: {
            'callerName': maleNick.isNotEmpty ? maleNick : 'User',
            'callerAvatarIndex': maleAvatarIdx,
          },
          onRemoteStream: (stream) {
            if (mounted) {
              _markCallConnected();
            }
          },
          onCallEnded: _onCallEndedCallback,
          onIceConnectionState: _handleIceConnectionState,
        );
        if (mounted) {
          setState(() {
            _roomId = generatedRoomId;
          });
          _subscribeToRoomStatus(generatedRoomId);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to place call: $e')),
          );
          Navigator.pop(context);
        }
      }
    } else {
      await _acceptIncomingCall();
    }
  }

  Future<void> _acceptIncomingCall() async {
    FlutterRingtonePlayer().stop();
    _vibrateTimer?.cancel();
    setState(() {
      _callAccepted = true;
      _statusMessage = 'Connecting...';
    });

    try {
      if (_roomId == null || _roomId!.isEmpty) {
        debugPrint('[ActiveCallPage] Cannot accept call: _roomId is null or empty');
        return;
      }
      await _callService.acceptCall(
        callRoomId: _roomId!,
        onRemoteStream: (stream) {
          if (mounted) {
            _markCallConnected();
          }
        },
        onCallEnded: _hangupLocal,
        onIceConnectionState: _handleIceConnectionState,
      );
    } catch (e) {
      debugPrint('[ActiveCallPage] Error accepting call: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect incoming call: $e')),
        );
        _hangupLocal();
      }
    }
  }

  void _startCallTimer() {
    if (_timer != null && _timer!.isActive) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _duration++;
      });

      // Free Intro Call: strictly enforce 1 minute (60s) cap for new users who haven't recharged
      if (_isFreeIntroCall) {
        if (_duration == 5) {
          _handleCallAttended();
        }
        if (_duration >= _maxDurationSeconds && !_isHangingUp) {
          _triggerHangup();
          return;
        }
      }

      // Female never auto-hangups; call continues until user presses red button
      // Caller (male) manages coin deductions and balance.

      // Check and deduct balances on every first second of minute start (1s, 61s, 121s, 181s...) - Regular Paid Calls ONLY
      if (!_isFreeIntroCall && _duration > 0 && (_duration - 1) % 60 == 0) {
        if (widget.isCaller) {
          final requiredCoins = (widget.pricePerMin * 10).toInt() > 0
              ? (widget.pricePerMin * 10).toInt()
              : 40;
          final currentBalance = context.read<AppState>().coinBalance;
          
          if (currentBalance < requiredCoins) {
            _triggerHangup();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Call ended: Insufficient balance')),
            );
            return;
          } else {
            context.read<AppState>().deductCoinBalance(requiredCoins);
            // Deduct new RTDB in background without interrupting the call
            UserDatabaseService.instance.deductUserCoins(widget.callerId, requiredCoins).catchError((e) {
              debugPrint('[ActiveCallPage] Non-fatal error deducting coins: $e');
              return false;
            });
          }
          
          // Male incrementally logs the duration!
          _saveCallLogIncremental();
        }
      }

      // Female earns at the 50th second of each minute (50s, 110s, 170s, 230s...)
      if (!widget.isCaller && !_isFreeIntroCall && _duration >= 50 && (_duration % 60 == 50)) {
        final minuteToCredit = (_duration ~/ 60) + 1;
        if (minuteToCredit > _creditedMinutes) {
          _creditedMinutes = minuteToCredit;
          _creditExpertMinuteEarning(_expertEarningRate);
        }
      }
    });
  }

  void _triggerHangup() {
    if (_isHangupHandled) return;
    if (_roomId != null) {
      _callService.endCall(_roomId!);
    }
    _hangupLocal();
  }

  void _hangupLocal() {
    if (_isHangupHandled) return;
    _isHangupHandled = true;
    _isHangingUp = true;

    // Immediately stop audio & vibration and cancel all timers/listeners
    FlutterRingtonePlayer().stop();
    _vibrateTimer?.cancel();
    _vibrateTimer = null;
    _iceDisconnectTimer?.cancel();
    _iceDisconnectTimer = null;
    _roomStatusSub?.cancel();
    _roomStatusSub = null;
    _timer?.cancel();
    _timer = null;
    _ringingTimer?.cancel();
    _ringingTimer = null;
    _availabilityTimer?.cancel();
    _availabilityTimer = null;
    _availabilityTicker?.cancel();
    _availabilityTicker = null;
    _countdownTicker?.cancel();
    _countdownTicker = null;
    
    // Clear CallKit Native Notifications
    dismissCallKitScreen();
    
    // Unlock both parties safely (unlockUserFromCall checks experts collection internally)
    _callService.unlockUserFromCall(widget.callerId);
    _callService.unlockUserFromCall(_currentReceiverId);
    
    final int finalDuration = _duration;
    final status = finalDuration > 0 ? 'ended' : 'missed';
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final logId = 'log_${_roomId ?? timestamp}';

    final String resolvedOtherName = _displayName.isNotEmpty ? _displayName : widget.nickname;
    final otherUid = widget.isCaller ? _currentReceiverId : widget.callerId;

    // Save profile into local SQLite so male user sees female in Recent Calls screen
    final otherRole = widget.isCaller ? 'expert' : 'user';
    LocalChatDatabase.instance.saveUserProfile({
      'uid': otherUid,
      'name': resolvedOtherName,
      'avatarUrl': _displayAvatarUrl ?? widget.avatarUrl ?? '',
      'avatarIndex': _displayAvatarIndex,
      'role': otherRole,
      'timestamp': timestamp,
    });

    final int billedMinutes = finalDuration > 0 ? (finalDuration ~/ 60) + (finalDuration % 60 > 0 ? 1 : 0) : 0;
    final double deductedRupees = _isFreeIntroCall ? 0.0 : (billedMinutes * 4.0);

    final logData = {
      'logId': logId,
      'callerId': widget.callerId,
      'receiverId': _currentReceiverId,
      'otherUserName': resolvedOtherName,
      'durationSeconds': finalDuration,
      'status': status,
      'timestamp': timestamp,
      'deductedAmount': deductedRupees,
    };

    // ALWAYS save to local SQLite on this device immediately!
    LocalChatDatabase.instance.saveCallLogLocally(logData);

    // ALWAYS save final call log to RTDB (syncs to both caller & receiver)
    UserDatabaseService.instance.saveCallLog(
      logId,
      logData,
      isFinal: true,
    );

    // Credit expert earnings and update talk time at end of call (only if >= 50 seconds)
    if (!widget.isCaller && !_isFreeIntroCall) {
      int eligibleMinutes = finalDuration ~/ 60;
      if (finalDuration % 60 >= 50) {
        eligibleMinutes += 1;
      }
      if (eligibleMinutes > _creditedMinutes) {
        final uncredited = eligibleMinutes - _creditedMinutes;
        final earned = _expertEarningRate * uncredited;
        _creditedMinutes = eligibleMinutes;
        _creditExpertMinuteEarning(earned);
      }
      _updateExpertTalkSeconds(finalDuration, 'hindi');
      debugPrint('Expert final stats updated: total credited $eligibleMinutes min (${finalDuration}s at ₹$_expertEarningRate/min)');

      if (eligibleMinutes == 0 && finalDuration > 0) {
        // Female talked for less than 50 seconds -> Earns Rs 0
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Aapko Rs 1.2 earn karne ke liye kam se kam 50 seconds baat karni hogi.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
    }
    
    if (mounted) {
      widget.onCallEnded?.call();
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pushReplacementNamed('/');
      }
    }
  }

  Future<void> _creditExpertMinuteEarning(double amount) async {
    try {
      String expertId = widget.receiverId;
      if (expertId.isEmpty) {
        expertId = FirebaseAuth.instance.currentUser?.uid ?? '';
      }
      if (expertId.isEmpty) return;

      await UserDatabaseService.instance.incrementExpertStats(
        expertId,
        earned: amount,
        seconds: 0,
        minutesToAdd: 1,
      );
      debugPrint('[ActiveCallPage] Credited expert $expertId with ₹$amount for 50s mark.');
    } catch (e) {
      debugPrint('[ActiveCallPage] Error crediting expert minute earning: $e');
    }
  }

  Future<void> _updateExpertTalkSeconds(int seconds, String language) async {
    try {
      String expertId = widget.receiverId;
      if (expertId.isEmpty) {
        expertId = FirebaseAuth.instance.currentUser?.uid ?? '';
      }
      if (expertId.isEmpty) return;

      // 1. Update talk seconds in stats
      await UserDatabaseService.instance.incrementExpertStats(
        expertId,
        earned: 0.0,
        seconds: seconds,
        minutesToAdd: 0,
      );

      // 2. Direct RTDB Update using ServerValue.increment
      try {
        final rtdb = FirebaseDatabase.instanceFor(
          app: FirebaseDatabase.instance.app,
          databaseURL: 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app',
        );
        
        // Update presence status node
        await rtdb.ref('status/$expertId').update({
          'totalTalkSeconds': ServerValue.increment(seconds),
        });
        
        // Safely update queue node if it exists using a transaction (100% ghost node proof)
        final lang = language.isNotEmpty ? language.toLowerCase() : 'hindi';
        final queueRef = rtdb.ref('queues/female_$lang/$expertId');
        
        await queueRef.runTransaction((Object? mutableData) {
          if (mutableData == null) {
            return Transaction.abort(); // Node doesn't exist, don't create ghost node
          }
          
          Map<Object?, Object?> data = Map<Object?, Object?>.from(mutableData as Map);
          int currentSeconds = (data['totalTalkSeconds'] as num?)?.toInt() ?? 0;
          data['totalTalkSeconds'] = currentSeconds + seconds;
          
          return Transaction.success(data);
        });
      } catch (rtdbError) {
        debugPrint('Error updating RTDB stats: $rtdbError');
      }
    } catch (e) {
      debugPrint('Error updating expert stats: $e');
    }
  }

  Future<void> _saveCallLogIncremental() async {
    try {
      final status = _duration > 0 ? 'ended' : 'missed';
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final logId = 'log_${_roomId ?? timestamp}';
      
      final String resolvedOtherName = _displayName.isNotEmpty ? _displayName : widget.nickname;
      final int billedMinutes = _duration > 0 ? (_duration ~/ 60) + (_duration % 60 > 0 ? 1 : 0) : 0;
      final double deductedRupees = _isFreeIntroCall ? 0.0 : (billedMinutes * 4.0);

      final logData = {
        'logId': logId,
        'callerId': widget.callerId,
        'receiverId': widget.receiverId,
        'otherUserName': resolvedOtherName,
        'durationSeconds': _duration,
        'status': status,
        'timestamp': timestamp,
        'deductedAmount': deductedRupees,
      };

      if (widget.isCaller) {
        // INCREMENTAL FIX: Continuously sync the exact duration to the database!
        await UserDatabaseService.instance.saveCallLog(
          logId,
          logData,
          isFinal: _isHangingUp,
        );
        
        // Only save to local SQLite at the very end of the call to avoid UI flickering
        if (_isHangingUp) {
          await LocalChatDatabase.instance.saveCallLogLocally(logData);
        }
      }
    } catch (e) {
      debugPrint('Error saving incremental call log: $e');
    }
  }


  void _toggleMute() {
    if (_callService.localStream != null) {
      final audioTracks = _callService.localStream!.getAudioTracks();
      if (audioTracks.isNotEmpty) {
        final newMuted = !_isMuted;
        for (var track in audioTracks) {
          track.enabled = !newMuted;
        }
        setState(() {
          _isMuted = newMuted;
        });
      }
    }
  }

  void _toggleSpeaker() {
    final newSpeaker = !_isSpeakerOn;
    Helper.setSpeakerphoneOn(newSpeaker);
    setState(() {
      _isSpeakerOn = newSpeaker;
    });
  }

  String _formatDuration(int sec) {
    // Expert (female) sees a countdown based strictly on caller's maximum affordable minutes
    if (!widget.isCaller) {
      if (_isFreeIntroCall) {
        int remaining = _maxDurationSeconds - sec;
        if (remaining < 0) remaining = 0;
        final m = (remaining ~/ 60).toString().padLeft(2, '0');
        final s = (remaining % 60).toString().padLeft(2, '0');
        return '$m:$s';
      }

      final balance = _callerCoinBalance ?? widget.callerCoinBalance ?? 40;
      int reqCoins = (widget.pricePerMin * 10).toInt();
      if (reqCoins <= 0) reqCoins = 40;
      
      int maxMins = balance ~/ reqCoins;
      if (maxMins <= 0 && balance > 0) {
        maxMins = 1;
      }
      
      int maxSecs = maxMins * 60;
      int remaining = maxSecs - sec;
      if (remaining < 0) remaining = 0;
      
      final m = (remaining ~/ 60).toString().padLeft(2, '0');
      final s = (remaining % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    // Caller (male) sees a normal count-up timer
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    FlutterRingtonePlayer().stop();
    _vibrateTimer?.cancel();
    _iceDisconnectTimer?.cancel();
    _iceDisconnectTimer = null;
    _timer?.cancel();
    _ringingTimer?.cancel();
    _availabilityTimer?.cancel();
    _availabilityTicker?.cancel();
    _countdownTicker?.cancel();
    _roomStatusSub?.cancel();
    _rippleController.dispose();
    _balanceSub?.cancel();
    _callService.disposeCall();
    // Release wakelock when call ends so screen can sleep normally
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const callOverlayStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarColor: Color(0xFF0F172A),
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    );

    if (_isAvailabilityChecking && !_isConnected) {
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: callOverlayStyle,
        child: WillPopScope(
          onWillPop: () async {
            _triggerHangup();
            return false;
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF0F172A),
            body: _buildAvailabilityCheckingView(),
          ),
        ),
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: callOverlayStyle,
      child: WillPopScope(
      onWillPop: () async {
        _triggerHangup();
        return false;
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF1C1C1E),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Align(
                alignment: Alignment.topRight,
                child: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Colors.white70),
                  onSelected: (value) async {
                    if (value == 'report') {
                      final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
                      final reporterId = widget.isCaller ? widget.callerId : (widget.receiverId.isEmpty ? currentUid : widget.receiverId);
                      final reportedId = widget.isCaller ? widget.receiverId : widget.callerId;
                      await UserDatabaseService.instance.submitReport({
                        'reporterId': reporterId,
                        'reportedId': reportedId,
                        'reportedName': _displayName.isNotEmpty ? _displayName : widget.nickname,
                        'reason': 'Inappropriate behavior on call',
                      });
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('User reported successfully. We will review this shortly.')),
                        );
                      }
                    } else if (value == 'block') {
                      final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
                      final myId = widget.isCaller ? widget.callerId : (widget.receiverId.isEmpty ? currentUid : widget.receiverId);
                      final otherId = widget.isCaller ? widget.receiverId : widget.callerId;
                      await BlockService.instance.blockUser(myId, otherId);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('User blocked.')),
                        );
                        _triggerHangup();
                      }
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: 'report',
                      child: Row(
                        children: [
                          Icon(Icons.flag_outlined, color: Colors.red, size: 20),
                          SizedBox(width: 8),
                          Text('Report User', style: TextStyle(color: Colors.red)),
                        ],
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'block',
                      child: Row(
                        children: [
                          Icon(Icons.block, color: Colors.black54, size: 20),
                          SizedBox(width: 8),
                          Text('Block & End Call'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              
              // Call header containing Profile details
              Column(
                children: [
                  const SizedBox(height: 10),
                  
                  // ── Male & Female Image Avatars ──────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Male Image Avatar
                      _buildImageAvatar(
                        imagePath: 'assets/male_avatar.png',
                        color: const Color(0xFF3B82F6),
                        label: 'Male',
                      ),

                      // Animated connection arrows
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0.4, end: 1.0),
                              duration: const Duration(milliseconds: 900),
                              curve: Curves.easeInOut,
                              builder: (_, val, _) {
                                return Row(
                                  children: List.generate(3, (i) {
                                    return Container(
                                      margin: const EdgeInsets.symmetric(horizontal: 2),
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: const Color(0xFF34D399).withValues(
                                          alpha: i == 0 ? val : i == 1 ? (val * 0.7) : (val * 0.4),
                                        ),
                                      ),
                                    );
                                  }),
                                );
                              },
                            ),
                            const SizedBox(height: 4),
                            const Icon(Icons.compare_arrows_rounded,
                                color: Color(0xFF34D399), size: 24),
                          ],
                        ),
                      ),

                      // Female Image Avatar
                      _buildImageAvatar(
                        imagePath: 'assets/female.jpeg',
                        color: const Color(0xFFEC4899),
                        label: 'Female',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),

                  Text(
                    _displayName.isNotEmpty ? _displayName : widget.nickname,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _isConnected
                        ? 'Connected'
                        : (!widget.isCaller
                            ? (_callAccepted ? 'Connecting...' : 'Incoming Call...')
                            : (_isFreeIntroCall ? 'Ringing $_displayName... (${_ringingCountdown}s)' : _statusMessage)),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _isConnected ? const Color(0xFF34D399) : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!_isConnected && _isFreeIntroCall) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3B82F6).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.5), width: 1.0),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.timer_outlined, size: 14, color: Color(0xFF60A5FA)),
                          const SizedBox(width: 6),
                          Text(
                            'Connecting to next user in ${_ringingCountdown}s if unanswered',
                            style: const TextStyle(
                              color: Color(0xFF93C5FD),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  if (_isConnected) ...[
                    const SizedBox(height: 4),
                    Text(
                      _formatDuration(_duration),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontFamily: 'monospace',
                        letterSpacing: 2.0,
                      ),
                    ),
                  ],
                  if (_isFreeIntroCall) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF43F5E).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFF43F5E), width: 1.2),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.timer_outlined, size: 16, color: Color(0xFFFF8599)),
                          const SizedBox(width: 6),
                          Text(
                            _isConnected
                                ? '1-Min Free: ${(60 - _duration).clamp(0, 60)}s left'
                                : '1-Min Free Intro Call',
                            style: const TextStyle(
                              color: Color(0xFFFF8599),
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),

              // Action controls for incoming call vs connected call
              if (!widget.isCaller && !_isConnected)
                Padding(
                  padding: const EdgeInsets.only(bottom: 24.0),
                  child: _callAccepted
                      ? Column(
                          children: [
                            const SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(
                                strokeWidth: 3,
                                color: Color(0xFF34D399),
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              'Connecting audio...',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 36),
                            GestureDetector(
                              onTap: _triggerHangup,
                              child: Column(
                                children: [
                                  Container(
                                    width: 68,
                                    height: 68,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.red,
                                    ),
                                    child: const Icon(
                                      Icons.call_end_rounded,
                                      color: Colors.white,
                                      size: 32,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text('Cancel',
                                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                                ],
                              ),
                            ),
                          ],
                        )
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            // Decline Button (Red)
                            GestureDetector(
                              onTap: _triggerHangup,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 76,
                                    height: 76,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Colors.red.shade600,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.red.withValues(alpha: 0.45),
                                          blurRadius: 18,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.call_end_rounded,
                                      color: Colors.white,
                                      size: 38,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'Decline',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Accept Button (Green)
                            GestureDetector(
                              onTap: _acceptIncomingCall,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 76,
                                    height: 76,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: const Color(0xFF22C55E),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF22C55E).withValues(alpha: 0.55),
                                          blurRadius: 18,
                                          spreadRadius: 2,
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.call_rounded,
                                      color: Colors.white,
                                      size: 38,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'Accept',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                )
              else
                Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildCallActionCircle(
                          icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                          label: _isMuted ? 'Mic On' : 'Mic Off',
                          isActive: _isMuted,
                          onTap: _toggleMute,
                        ),
                        _buildCallActionCircle(
                          icon: _isSpeakerOn ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                          label: 'Speaker',
                          isActive: _isSpeakerOn,
                          onTap: _toggleSpeaker,
                        ),
                      ],
                    ),
                    const SizedBox(height: 44),
                    
                    // Interactive Slide to End Call Slider
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: SlideToEndCallButton(
                        onSlideComplete: _triggerHangup,
                      ),
                    ),
                    const SizedBox(height: 28),
                  ],
                ),
            ],
          ),
        ),
      ),
      ),
    ),
  );
}

  Widget _buildCallActionCircle({
    required IconData icon,
    required String label,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isActive ? Colors.white : Colors.white.withValues(alpha: 0.08),
            ),
            child: Icon(
              icon,
              color: isActive ? Colors.black : Colors.white,
              size: 24,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildImageAvatar({
    required String imagePath,
    required Color color,
    required String label,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 120,
          height: 130,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: color.withValues(alpha: 0.8),
              width: 2.0,
            ),
            boxShadow: [
              BoxShadow(
                color: color.withValues(alpha: 0.4),
                blurRadius: 24,
                spreadRadius: 3,
              ),
            ],
            image: DecorationImage(
              image: ResizeImage(AssetImage(imagePath), width: 300),
              fit: BoxFit.cover,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAvailabilityCheckingView() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Top Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 20),
                  onPressed: _triggerHangup,
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFFE11D48), Color(0xFF9333EA)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bolt, color: Colors.amber, size: 16),
                      SizedBox(width: 4),
                      Text(
                        '1-MIN FREE INTRO',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 40),
              ],
            ),

            // Center Radar Animation & User Info
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildRadarAnimation(),
                  const SizedBox(height: 32),
                  Text(
                    _displayName.isNotEmpty ? _displayName : widget.nickname,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE11D48).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFFE11D48).withValues(alpha: 0.4),
                        width: 1.2,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFFB7185),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Searching availability (${_availabilityCountdown}s)...',
                          style: const TextStyle(
                            color: Color(0xFFFB7185),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20.0),
                    child: Text(
                      'If user is offline or unreachable, auto-connecting to another user',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Bottom Cancel Control
            Column(
              children: [
                GestureDetector(
                  onTap: _triggerHangup,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFE11D48),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFE11D48).withValues(alpha: 0.4),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Cancel',
                  style: TextStyle(
                    color: Colors.white60,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRadarAnimation() {
    return AnimatedBuilder(
      animation: _rippleController,
      builder: (context, child) {
        return SizedBox(
          width: 260,
          height: 260,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Concentric ripple rings (3 waves)
              ...List.generate(3, (index) {
                final offset = index * 0.33;
                final progress = (_rippleController.value + offset) % 1.0;
                final size = 110.0 + (progress * 150.0);
                final opacity = (1.0 - progress).clamp(0.0, 1.0);

                return Container(
                  width: size,
                  height: size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFE11D48).withValues(alpha: opacity * 0.7),
                      width: 2.0,
                    ),
                    color: const Color(0xFFE11D48).withValues(alpha: opacity * 0.08),
                  ),
                );
              }),

              // Center Circular Avatar
              Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFE11D48),
                    width: 3.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFE11D48).withValues(alpha: 0.5),
                      blurRadius: 24,
                      spreadRadius: 4,
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/male_avatar.png',
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      color: const Color(0xFF1E293B),
                      child: const Icon(Icons.person, color: Colors.white, size: 54),
                    ),
                  ),
                ),
              ),

              // Small pulsating radar scan ping dot
              Positioned(
                top: 40,
                right: 40,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.greenAccent,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.greenAccent.withValues(alpha: 0.8),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Interactive Slide to End Call Button
/// Replaces the static red button with an intuitive swipe-to-hangup slider.
class SlideToEndCallButton extends StatefulWidget {
  final VoidCallback onSlideComplete;
  final double height;

  const SlideToEndCallButton({
    super.key,
    required this.onSlideComplete,
    this.height = 64.0,
  });

  @override
  State<SlideToEndCallButton> createState() => _SlideToEndCallButtonState();
}

class _SlideToEndCallButtonState extends State<SlideToEndCallButton>
    with TickerProviderStateMixin {
  double _dragOffset = 0.0;
  bool _isCompleted = false;

  late AnimationController _springController;
  late Animation<double> _springAnimation;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _springController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.35, end: 0.95).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _springController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details, double maxDrag) {
    if (_isCompleted) return;
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dx).clamp(0.0, maxDrag);
    });
  }

  void _onDragEnd(DragEndDetails details, double maxDrag) {
    if (_isCompleted) return;
    final progress = maxDrag > 0 ? (_dragOffset / maxDrag) : 0.0;
    if (progress >= 0.78) {
      // Reached completion threshold
      setState(() {
        _isCompleted = true;
        _dragOffset = maxDrag;
      });
      HapticFeedback.heavyImpact();
      widget.onSlideComplete();
    } else {
      // Snap back smoothly with spring physics
      _springAnimation = Tween<double>(
        begin: _dragOffset,
        end: 0.0,
      ).animate(
        CurvedAnimation(parent: _springController, curve: Curves.easeOutCubic),
      )..addListener(() {
          setState(() {
            _dragOffset = _springAnimation.value;
          });
        });
      _springController.forward(from: 0.0);
    }
  }

  @override
  Widget build(BuildContext context) {
    const thumbPadding = 4.0;
    final thumbSize = widget.height - (thumbPadding * 2);

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        final maxDrag = (totalWidth - thumbSize - (thumbPadding * 2)).clamp(0.0, double.infinity);
        final progress = maxDrag > 0 ? (_dragOffset / maxDrag).clamp(0.0, 1.0) : 0.0;

        return Container(
          width: totalWidth,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.height / 2),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF261014),
                Color(0xFF19090B),
              ],
            ),
            border: Border.all(
              color: Colors.red.withValues(alpha: 0.45 + (0.35 * progress)),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.red.withValues(alpha: 0.2 + (0.2 * progress)),
                blurRadius: 16,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              // Active sliding progress fill behind thumb
              Container(
                width: _dragOffset + thumbSize + thumbPadding,
                height: widget.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.height / 2),
                  gradient: LinearGradient(
                    colors: [
                      Colors.red.withValues(alpha: 0.4),
                      Colors.red.withValues(alpha: 0.15),
                    ],
                  ),
                ),
              ),

              // Animated "Slide to end call" track text + pulsing chevrons
              Center(
                child: Opacity(
                  opacity: (1.0 - (progress * 1.4)).clamp(0.0, 1.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 44), // Offset slightly to account for the thumb
                      Text(
                        'Slide to end call',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedBuilder(
                        animation: _pulseAnimation,
                        builder: (context, child) {
                          return Opacity(
                            opacity: _pulseAnimation.value,
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 20),
                                Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 20),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),

              // Draggable Red Thumb
              Positioned(
                left: thumbPadding + _dragOffset,
                top: thumbPadding,
                child: GestureDetector(
                  onHorizontalDragUpdate: (details) => _onDragUpdate(details, maxDrag),
                  onHorizontalDragEnd: (details) => _onDragEnd(details, maxDrag),
                  onHorizontalDragCancel: () => _onDragEnd(DragEndDetails(), maxDrag),
                  child: Container(
                    width: thumbSize,
                    height: thumbSize,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color(0xFFFF3B30),
                          Color(0xFFDC2626),
                          Color(0xFF991B1B),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFEF4444).withValues(alpha: 0.55),
                          blurRadius: 14,
                          spreadRadius: 2,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.call_end_rounded,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
