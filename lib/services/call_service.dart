import 'dart:async';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'block_service.dart';
import 'user_database_service.dart';

class CallService {
  final String databaseURL;
  final FirebaseDatabase _database;

  CallService({
    String? databaseURL,
  })  : databaseURL = databaseURL ?? 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app',
        _database = FirebaseDatabase.instanceFor(
          app: FirebaseDatabase.instance.app,
          databaseURL: databaseURL ?? 'https://zegochat-c44b0.asia-southeast1.firebasedatabase.app',
        );

  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;

  // Active listeners/subscriptions for call room updates
  final List<StreamSubscription> _subscriptions = [];

  // Dynamic listeners that can be updated after startCall/acceptCall
  Function(MediaStream stream)? onRemoteStreamListener;
  Function()? onCallEndedListener;
  Function()? onRingingListener;
  Function(RTCIceConnectionState state)? onIceConnectionStateListener;
  String? lastCallStatus;

  /// Update the active call callbacks dynamically
  void updateListeners({
    Function(MediaStream stream)? onRemoteStream,
    Function()? onCallEnded,
    Function()? onRinging,
    Function(RTCIceConnectionState state)? onIceConnectionState,
  }) {
    if (onRemoteStream != null) {
      onRemoteStreamListener = onRemoteStream;
    }
    if (onCallEnded != null) {
      onCallEndedListener = onCallEnded;
    }
    if (onRinging != null) {
      onRingingListener = onRinging;
    }
    if (onIceConnectionState != null) {
      onIceConnectionStateListener = onIceConnectionState;
    }
  }

  // WebRTC ICE Configuration.
  // - 1 STUN server (Google Anycast): returns public IP with zero duplicate
  //   candidates (= faster gathering, fewer RTDB candidate writes).
  // - TURN is KEPT as a fallback: many Indian mobile carriers (Jio/Airtel CGNAT)
  //   use symmetric NAT where STUN alone fails. Because we use trickle ICE,
  //   TURN gathering runs in parallel and does not delay calls that succeed
  //   via STUN/host candidates.
  // - iceCandidatePoolSize pre-gathers candidates as soon as the peer
  //   connection is created, before the offer/answer is generated.
  final Map<String, dynamic> _iceConfiguration = {
    'iceServers': [
      {
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
          'stun:stun2.l.google.com:19302',
          'stun:stun3.l.google.com:19302',
          'stun:stun4.l.google.com:19302',
        ]
      },
      {
        'urls': [
          'turn:openrelay.metered.ca:80',
          'turn:openrelay.metered.ca:443?transport=tcp'
        ],
        'username': 'openrelayproject',
        'credential': 'openrelayproject'
      }
    ],
    'sdpSemantics': 'unified-plan',
    'iceCandidatePoolSize': 2,
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
  };

  // Getters
  RTCPeerConnection? get peerConnection => _peerConnection;
  MediaStream? get localStream => _localStream;
  MediaStream? get remoteStream => _remoteStream;

  /// Listen for incoming calls for an expert.
  /// Trigger [onCallReceived] when another user creates a call with status 'calling'.
  StreamSubscription<DatabaseEvent> listenForIncomingCalls({
    required String expertId,
    required Function(String callRoomId, String callerId) onCallReceived,
  }) {
    return _database
        .ref('calls')
        .orderByChild('receiverId')
        .equalTo(expertId)
        .onChildAdded
        .listen((event) {
      if (event.snapshot.value != null) {
        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        if (data['status'] == 'calling') {
          final callRoomId = event.snapshot.key!;
          final callerId = data['callerId'] ?? 'unknown';
          
          if (BlockService.instance.isBlocked(callerId)) {
            debugPrint('Auto-rejecting incoming call from blocked user: $callerId');
            _database.ref('calls/$callRoomId/status').set('rejected_blocked');
            return;
          }
          
          onCallReceived(callRoomId, callerId);
        }
      }
    }, onError: (e) {
      debugPrint('Error listening for incoming calls: $e');
    });
  }

  /// Caller (Male Caller) initiates the call
  Future<String> startCall({
    required String expertId,
    required String callerId,
    required Function(MediaStream stream) onRemoteStream,
    required Function() onCallEnded,
    Function()? onRinging,
    Function(RTCIceConnectionState state)? onIceConnectionState,
    int? callerCoins,
    double pricePerMin = 4.0,
    Map<String, dynamic>? extraRoomData,
  }) async {
    onRemoteStreamListener = onRemoteStream;
    onCallEndedListener = onCallEnded;
    onRingingListener = onRinging;
    if (onIceConnectionState != null) {
      onIceConnectionStateListener = onIceConnectionState;
    }
    try {
      // 1 + 2. Initialize local audio and peer connection IN PARALLEL
      // (independent steps; the call doc — and therefore the FCM ring on the
      // female phone — is created sooner).
      final setup = await Future.wait<dynamic>([
        navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          },
          'video': false,
        }),
        createPeerConnection(_iceConfiguration),
      ]);
      _localStream = setup[0] as MediaStream;
      _peerConnection = setup[1] as RTCPeerConnection;

      // 3. Add local track to connection
      _localStream!.getTracks().forEach((track) {
        if (track.kind == 'audio') {
          track.enabled = true;
        }
        _peerConnection!.addTrack(track, _localStream!);
      });

      // 4. Listen for remote track / audio streams
      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          for (var track in _remoteStream!.getAudioTracks()) {
            track.enabled = true;
          }
          onRemoteStreamListener?.call(_remoteStream!);
        } else {
          event.track.enabled = true;
        }
      };
      _peerConnection!.onAddStream = (MediaStream stream) {
        _remoteStream = stream;
        for (var track in _remoteStream!.getAudioTracks()) {
          track.enabled = true;
        }
        onRemoteStreamListener?.call(_remoteStream!);
      };

      // Detect terminal network failure via WebRTC ICE state
      _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
        debugPrint('[WebRTC] Caller ICE State: $state');
        onIceConnectionStateListener?.call(state);
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          onCallEndedListener?.call();
        }
      };

      // 5. Create call document in RTDB
      final DatabaseReference roomRef = _database.ref('calls').push();
      final String roomId = roomRef.key!;
      
      // Ensure the room is deleted if the caller disconnects abruptly before connection
      await roomRef.onDisconnect().remove();

      // 6. Handle local ICE candidates and upload them
      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          roomRef.child('callerCandidates').push().set({
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        }
      };

      // 7. Generate SDP Offer
      final RTCSessionDescription offer = await _peerConnection!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _peerConnection!.setLocalDescription(offer);

      // 8. Upload SDP Offer to call document
      await roomRef.set({
        'offer': {
          'sdp': offer.sdp,
          'type': offer.type,
        },
        'callerId': callerId,
        'receiverId': expertId,
        'status': 'calling',
        'callerCoins': ?callerCoins,
        'pricePerMin': pricePerMin,
        ...?extraRoomData,
      });

      bool remoteDescriptionSet = false;
      final List<RTCIceCandidate> pendingRemoteCandidates = [];

      // 9. Subscribe to call document updates to catch SDP Answer
      final roomSub = roomRef.onValue.listen((event) async {
        if (event.snapshot.value == null) {
          // If already connected, do not hang up on temporary null snapshot from background socket drop!
          if (!remoteDescriptionSet) {
            onCallEndedListener?.call();
          }
          return;
        }

        final data = Map<String, dynamic>.from(event.snapshot.value as Map);
        final status = data['status'] as String?;
        if (status == 'ringing') {
          onRingingListener?.call();
        }
        if (status == 'ended' ||
            status == 'rejected_blocked' ||
            status == 'rejected_offline' ||
            status == 'rejected' ||
            status == 'busy') {
          debugPrint('[CallService] Room $roomId terminal status: $status');
          lastCallStatus = status;
          onCallEndedListener?.call();
          return;
        }

        // Set Remote Description when answer is received
        if (data['answer'] != null && !remoteDescriptionSet) {
          remoteDescriptionSet = true;
          final answerMap = Map<String, dynamic>.from(data['answer']);
          final description = RTCSessionDescription(
            answerMap['sdp'],
            answerMap['type'],
          );
          await _peerConnection!.setRemoteDescription(description);

          // Add all queued remote candidates
          for (var candidate in pendingRemoteCandidates) {
            try {
              await _peerConnection!.addCandidate(candidate);
            } catch (e) {
              debugPrint('[CallService] Error adding candidate: $e');
            }
          }
          pendingRemoteCandidates.clear();

          // Cancel onDisconnect on roomRef now that connection is established!
          try {
            await roomRef.onDisconnect().cancel();
            debugPrint('[CallService] Caller cancelled onDisconnect for room: $roomId');
          } catch (e) {
            debugPrint('[CallService] Error cancelling onDisconnect: $e');
          }
        }
      });
      _subscriptions.add(roomSub);

      // 10. Subscribe to remote ICE candidates (expertCandidates)
      final candidatesSub = roomRef
          .child('expertCandidates')
          .onChildAdded
          .listen((event) async {
        if (event.snapshot.value != null && _peerConnection != null) {
          try {
            final data = Map<String, dynamic>.from(event.snapshot.value as Map);
            final candidate = RTCIceCandidate(
              data['candidate'],
              data['sdpMid'],
              data['sdpMLineIndex'],
            );
            if (remoteDescriptionSet) {
              await _peerConnection!.addCandidate(candidate);
            } else {
              pendingRemoteCandidates.add(candidate);
            }
          } catch (e) {
            debugPrint('[CallService] Caller addCandidate error (non-fatal): $e');
          }
        }
      });
      _subscriptions.add(candidatesSub);

      return roomId;
    } catch (e) {
      debugPrint('Error starting WebRTC call: $e');
      await disposeCall();
      rethrow;
    }
  }

  /// Receiver (Female Expert) accepts the incoming call
  Future<void> acceptCall({
    required String callRoomId,
    required Function(MediaStream stream) onRemoteStream,
    required Function() onCallEnded,
    Function(RTCIceConnectionState state)? onIceConnectionState,
  }) async {
    onRemoteStreamListener = onRemoteStream;
    onCallEndedListener = onCallEnded;
    if (onIceConnectionState != null) {
      onIceConnectionStateListener = onIceConnectionState;
    }
    try {
      final DatabaseReference roomRef = _database.ref('calls/$callRoomId');

      // PARALLEL SETUP: previously these 3 steps ran one after another
      // (RTDB read → mic hardware spin-up → peer connection). They are
      // independent, so run them concurrently. Total wait becomes the
      // slowest single step (~mic spin-up) instead of the sum of all three.
      final results = await Future.wait<dynamic>([
        roomRef.get(),
        navigator.mediaDevices.getUserMedia({
          'audio': {
            'echoCancellation': true,
            'noiseSuppression': true,
            'autoGainControl': true,
          },
          'video': false,
        }),
        createPeerConnection(_iceConfiguration),
      ]);

      final roomSnapshot = results[0] as DataSnapshot;
      // 1. Local media audio track
      _localStream = results[1] as MediaStream;
      // 2. Peer connection (already pre-gathering ICE via iceCandidatePoolSize)
      _peerConnection = results[2] as RTCPeerConnection;

      if (!roomSnapshot.exists) {
        throw Exception('Call room not found');
      }

      final roomData = Map<String, dynamic>.from(roomSnapshot.value as Map);
      final offerMap = roomData['offer'] != null ? Map<String, dynamic>.from(roomData['offer']) : null;
      if (offerMap == null) {
        throw Exception('No SDP Offer found in room');
      }

      // 3. Add local track to connection
      _localStream!.getTracks().forEach((track) {
        if (track.kind == 'audio') {
          track.enabled = true;
        }
        _peerConnection!.addTrack(track, _localStream!);
      });

      // 4. Listen for remote track / audio streams
      _peerConnection!.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          _remoteStream = event.streams[0];
          for (var track in _remoteStream!.getAudioTracks()) {
            track.enabled = true;
          }
          onRemoteStreamListener?.call(_remoteStream!);
        } else {
          event.track.enabled = true;
        }
      };
      _peerConnection!.onAddStream = (MediaStream stream) {
        _remoteStream = stream;
        for (var track in _remoteStream!.getAudioTracks()) {
          track.enabled = true;
        }
        onRemoteStreamListener?.call(_remoteStream!);
      };

      // Detect terminal network failure via WebRTC ICE state
      _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {
        debugPrint('[WebRTC] Receiver ICE State: $state');
        onIceConnectionStateListener?.call(state);
        if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
            state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
          onCallEndedListener?.call();
        }
      };

      // 5. Handle local ICE candidates and upload them
      _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
        if (candidate.candidate != null) {
          roomRef.child('expertCandidates').push().set({
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          });
        }
      };

      // 6. Set Remote Description (SDP Offer)
      final RTCSessionDescription remoteDescription = RTCSessionDescription(
        offerMap['sdp'],
        offerMap['type'],
      );
      await _peerConnection!.setRemoteDescription(remoteDescription);

      // Subscribe to remote ICE candidates (callerCandidates) IMMEDIATELY after
      // the offer is applied — no need to wait for the answer write round-trip.
      // onChildAdded also replays candidates the caller already uploaded.
      final candidatesSub = roomRef
          .child('callerCandidates')
          .onChildAdded
          .listen((event) async {
        if (event.snapshot.value != null && _peerConnection != null) {
          try {
            final data = Map<String, dynamic>.from(event.snapshot.value as Map);
            await _peerConnection!.addCandidate(
              RTCIceCandidate(
                data['candidate'],
                data['sdpMid'],
                data['sdpMLineIndex'],
              ),
            );
          } catch (e) {
            debugPrint('[WebRTC] Receiver addCandidate error (non-fatal): $e');
          }
        }
      });
      _subscriptions.add(candidatesSub);

      // 7. Generate SDP Answer
      final RTCSessionDescription answer = await _peerConnection!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _peerConnection!.setLocalDescription(answer);

      // 8. Update RTDB document with SDP Answer and change status to connected
      await roomRef.update({
        'answer': {
          'sdp': answer.sdp,
          'type': answer.type,
        },
        'status': 'connected',
      });

      // Cancel onDisconnect on roomRef so receiver screen sleep never deletes room
      try {
        await roomRef.onDisconnect().cancel();
        debugPrint('[CallService] Receiver cancelled onDisconnect for $callRoomId');
      } catch (e) {
        debugPrint('[CallService] Receiver error cancelling onDisconnect: $e');
      }

      // 9. Subscribe to call document updates to monitor ended state
      final roomSub = roomRef.child('status').onValue.listen((event) {
        final val = event.snapshot.value?.toString();
        // Do NOT trigger onCallEnded if snapshot is null (happens when socket drops on sleep)
        if (val == 'ended' ||
            val == 'rejected' ||
            val == 'rejected_offline' ||
            val == 'rejected_blocked') {
          onCallEndedListener?.call();
        }
      });
      _subscriptions.add(roomSub);
    } catch (e) {
      debugPrint('Error accepting WebRTC call: $e');
      await disposeCall();
      rethrow;
    }
  }

  /// Cancels any scheduled onDisconnect actions for this call room on Firebase RTDB.
  Future<void> cancelOnDisconnect(String roomId) async {
    try {
      final DatabaseReference roomRef = _database.ref('calls/$roomId');
      await roomRef.onDisconnect().cancel();
      debugPrint('[CallService] Cancelled onDisconnect for calls/$roomId');
    } catch (e) {
      debugPrint('[CallService] Error cancelling onDisconnect for $roomId: $e');
    }
  }

  /// Hangs up and clean up WebRTC resources and deletes the RTDB call document
  Future<void> endCall(String callRoomId) async {
    try {
      final DatabaseReference roomRef = _database.ref('calls/$callRoomId');
      
      // Fetch caller and receiver ID to forcefully unlock them
      final snapshot = await roomRef.get();
      if (snapshot.exists) {
        final data = Map<String, dynamic>.from(snapshot.value as Map);
        final callerId = data['callerId']?.toString();
        final receiverId = data['receiverId']?.toString();
        
        // Unlock both parties FIRST before trying to update/remove the room (which might fail due to permissions)
        if (callerId != null) {
          await unlockUserFromCall(callerId);
        }
        if (receiverId != null) {
          await unlockUserFromCall(receiverId);
        }
        
        // Update room status to ended and schedule node removal
        try {
          await roomRef.update({'status': 'ended'});
          await roomRef.onDisconnect().cancel();
          // Delay node removal by 4 seconds so the remote client reliably receives 'status': 'ended'
          Future.delayed(const Duration(seconds: 4), () async {
            try {
              await roomRef.remove();
            } catch (_) {}
          });
        } catch (e) {
          debugPrint('Could not update/remove room: $e');
        }
      } else {
        try {
          await roomRef.update({'status': 'ended'});
          await roomRef.onDisconnect().cancel();
          Future.delayed(const Duration(seconds: 4), () async {
            try {
              await roomRef.remove();
            } catch (_) {}
          });
        } catch (e) {
          debugPrint('Could not update/remove room: $e');
        }
      }
    } catch (e) {
      debugPrint('Error ending call document: $e');
    } finally {
      // CRITICAL FIX: Always guarantee that the current user is unlocked, even if the room was already deleted!
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null) {
        await unlockUserFromCall(currentUser.uid);
      }
      await disposeCall();
    }
  }

  /// Cleans up local media streams, peer connections, and cancels active listeners
  Future<void> disposeCall() async {
    // Cancel all RTDB stream subscriptions
    for (var sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();

    // Stop and dispose local stream tracks
    if (_localStream != null) {
      for (var track in _localStream!.getTracks()) {
        await track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    _remoteStream = null;

    // Close peer connection
    if (_peerConnection != null) {
      _peerConnection!.onIceConnectionState = null;
      _peerConnection!.onConnectionState = null;
      await _peerConnection!.close();
      _peerConnection = null;
    }
    onIceConnectionStateListener = null;
  }

  /// Realtime Database Transaction to safely lock an expert before calling.
  /// Prevents race conditions if two users try to call simultaneously.
  Future<bool> lockExpertForCall(String expertId) async {
    try {
      final DatabaseReference ref = _database.ref("status/$expertId");
      
      final TransactionResult result = await ref.runTransaction((Object? post) {
        if (post == null) {
          // If node doesn't exist, we can't lock. Return abort.
          return Transaction.abort();
        }

        Map<String, dynamic> data = Map<String, dynamic>.from(post as Map);
        
        // Read current status
        String status = data['status']?.toString() ?? 'online';
        bool isOnline = data['isOnline'] == true;
        
        // If expert is not online or already busy, abort
        if (!isOnline || status == 'busy' || status == 'in-call') {
          return Transaction.abort();
        }
        
        // Expert is available, apply lock
        data['status'] = 'busy';
        data['lastChanged'] = ServerValue.timestamp;
        
        return Transaction.success(data);
      });
      
      if (result.committed) {
        // We no longer remove from a global queue here because the queue is language-specific 
        // (e.g., queues/female_hindi) and handled by MatchmakingService. 
        // The expert's 'status': 'busy' in the status node is enough to prevent concurrent calls.
      }
      
      return result.committed;
    } catch (e) {
      debugPrint('Error locking expert $expertId: $e');
      return false;
    }
  }

  /// Realtime Database Transaction to safely lock a user before calling.
  Future<bool> lockUserForCall(String userId) async {
    try {
      final DatabaseReference ref = _database.ref("status/$userId");
      
      final TransactionResult result = await ref.runTransaction((Object? post) {
        if (post == null) {
          return Transaction.success({
            'isOnline': false,
            'status': 'busy',
            'lastChanged': ServerValue.timestamp,
          });
        }

        Map<String, dynamic> data = Map<String, dynamic>.from(post as Map);
        String status = data['status']?.toString() ?? 'online';
        
        if (status == 'busy' || status == 'in-call') {
          return Transaction.abort();
        }
        
        data['status'] = 'busy';
        data['lastChanged'] = ServerValue.timestamp;
        
        return Transaction.success(data);
      });
      
      return result.committed;
    } catch (e) {
      debugPrint('Error locking user $userId: $e');
      return false;
    }
  }

  /// Reverts an expert's status to online and re-adds them to the experts queue if they were online.
  Future<void> unlockExpertFromCall(String expertId) async {
    try {
      final DatabaseReference ref = _database.ref("status/$expertId");
      
      final snapshot = await ref.get();
      if (snapshot.exists) {
        final data = Map<String, dynamic>.from(snapshot.value as Map);
        if (data['isOnline'] == true) {
          // Revert to online
          await ref.update({
            'status': 'online',
            'lastChanged': ServerValue.timestamp,
          });
          
          // We no longer add to experts_queue because the app uses dynamic language queues 
          // (like queues/female_hindi) managed by MatchmakingService. The expert is still in 
          // that queue, and their 'status' is now 'online', making them available again.
        } else {
          // They toggled offline during the call, just set status offline
          await ref.update({
            'status': 'offline',
            'lastChanged': ServerValue.timestamp,
          });
        }
      }
      
      // Crucial Fix: Clear the active_calls lock so the expert is not permanently stuck as busy
      await _database.ref('active_calls/$expertId').remove();
    } catch (e) {
      debugPrint('Error unlocking expert $expertId: $e');
    }
  }

  /// Reverts a user's status to online.
  Future<void> unlockUserFromCall(String userId) async {
    // Both users and experts use the same status node now. We can safely just call unlockExpertFromCall
    // because unlockExpertFromCall now checks Firestore before adding to the experts_queue!
    await unlockExpertFromCall(userId);
  }

  /// Safely deduct coin balance in new RTDB using atomic transaction.
  /// Validates sufficient balance and prevents concurrent deduction race conditions.
  Future<void> deductCoinBalance({required String userId, required int callCost}) async {
    try {
      final success = await UserDatabaseService.instance.deductUserCoins(userId, callCost);
      if (!success) {
        throw Exception("Failed to deduct coins: Insufficient balance or user missing.");
      }
      debugPrint('Successfully deducted $callCost coins from user $userId in new RTDB.');
    } catch (e) {
      debugPrint('Error deducting coin balance for $userId: $e');
      rethrow;
    }
  }
}
