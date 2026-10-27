import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/local_chat_database.dart';
import '../services/hybrid_chat_service.dart';
import '../theme/app_colors.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import '../widgets/local_avatar_widget.dart';
import 'wallet_recharge_screen.dart';
import '../services/block_service.dart';
import '../services/user_database_service.dart';
import '../services/general_feed_service.dart';
class HybridChatScreen extends StatefulWidget {
  final String myUid;
  final String otherUid;
  final String otherUserName;
  final String? otherUserAvatarUrl;
  final int otherUserAvatarIndex;

  const HybridChatScreen({
    super.key,
    required this.myUid,
    required this.otherUid,
    required this.otherUserName,
    this.otherUserAvatarUrl,
    this.otherUserAvatarIndex = 1,
  });

  @override
  State<HybridChatScreen> createState() => _HybridChatScreenState();
}

class _HybridChatScreenState extends State<HybridChatScreen> with WidgetsBindingObserver {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final HybridChatService _chatService = HybridChatService.instance;
  
  late String _roomId;
  List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _dbUpdateSubscription;
  Future<Map<String, dynamic>>? _profileFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _profileFuture ??= _fetchProfileData();
  }

  Future<Map<String, dynamic>> _fetchProfileData() async {
    final appState = context.read<AppState>();
    final otherRole = appState.selectedGender == 'Female' ? 'user' : 'expert';
    
    // 1. Try local cache
    final cachedProfile = await LocalChatDatabase.instance.getUserProfile(widget.otherUid);
    if (cachedProfile != null) {
      return cachedProfile;
    }
    
    // 2. Fallback to new RTDB
    try {
      final data = otherRole == 'expert'
          ? await UserDatabaseService.instance.getExpert(widget.otherUid)
          : await UserDatabaseService.instance.getUser(widget.otherUid);
      if (data != null) {
        final profile = {
          'uid': widget.otherUid,
          'name': data['nickname'] ?? data['name'] ?? data['displayName'] ?? data['fullName'] ?? widget.otherUserName,
          'avatarUrl': data['profileImageUrl'] ?? data['avatarUrl'],
          'avatarIndex': (data['avatarIndex'] as num?)?.toInt() ?? 1,
          'role': otherRole,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };
        
        // Save to cache for next time
        await LocalChatDatabase.instance.saveUserProfile(profile);
        return profile;
      }
    } catch (e) {
      debugPrint('Error fetching profile for chat appbar: $e');
    }
    
    return {
      'avatarIndex': 1,
      'avatarUrl': null,
    };
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _roomId = LocalChatDatabase.generateRoomId(widget.myUid, widget.otherUid);
    
    // Set active room to prevent false delivery ACKs when we are actually reading
    HybridChatService.activeChatRoomId = _roomId;

    final appState = context.read<AppState>();
    HybridChatService.isFemaleUser = (appState.selectedGender == 'Female');
    HybridChatService.onLiveMessageEarned = (amount) {
      if (mounted) {
        context.read<AppState>().addEarnings(amount);
      }
    };

    // Ensure listeners are active
    HybridChatService.instance.initListeners(widget.myUid);

    // Listen to local DB updates (so ticks update instantly)
    _dbUpdateSubscription = LocalChatDatabase.instance.updates.listen((_) {
      if (mounted) _loadMessages();
    });

    _initChat();
  }

  Future<void> _initChat() async {
    await _loadMessages();

    // Fetch unread messages from the OTHER user and mark them as read
    final unreadMsgs = await LocalChatDatabase.instance.getUnreadMessages(_roomId, widget.otherUid);
    for (var msg in unreadMsgs) {
      await _chatService.markAsRead(msg['msgId'] as String, widget.otherUid, widget.myUid);
    }
    
    if (unreadMsgs.isNotEmpty) {
      await _loadMessages(); // Refresh UI after marking read
    }
  }

  Future<void> _loadMessages() async {
    final messages = await LocalChatDatabase.instance.fetchChatHistory(_roomId);
    if (mounted) {
      setState(() {
        _messages = messages;
      });
      // Scroll to bottom
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    HybridChatService.activeChatRoomId = null;
    HybridChatService.onLiveMessageEarned = null;
    HybridChatService.isFemaleUser = null;
    WidgetsBinding.instance.removeObserver(this);
    AppState.syncPendingChatDeductions();
    _dbUpdateSubscription?.cancel();
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      AppState.syncPendingChatDeductions();
    }
  }

  void _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    if (BlockService.instance.isBlocked(widget.otherUid)) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('User Blocked'),
          content: const Text('You have blocked this user. Unblock to send a message.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context);
                await BlockService.instance.unblockUser(widget.myUid, widget.otherUid);
                if (context.mounted) {
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('User unblocked successfully.')),
                  );
                }
              },
              child: const Text('Unblock'),
            ),
          ],
        ),
      );
      return;
    }


    final appState = context.read<AppState>();
    
    // If the sender is a Male User, deduct coins or use free messages
    if (appState.selectedGender == 'Male') {
      double deductedAmount = 0.50;
      if (appState.freeMessagesUsed < 5) {
        // Use a free message
        appState.addPendingChatDeduction(coins: 0, freeMsgs: 1);
        deductedAmount = 0.00;
        if (appState.freeMessagesUsed >= 5) {
          GeneralFeedService.instance.markFreeMessagesExhausted(
            uid: appState.uid,
            language: appState.primaryLanguage,
          );
        }
      } else {
        // Deduct 5 coins (50 paise = ₹0.50)
        if (appState.coinBalance < 5) {
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: const Row(
                children: [
                  Icon(Icons.account_balance_wallet_rounded, color: Colors.red, size: 28),
                  SizedBox(width: 10),
                  Text('Low Balance', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
                ],
              ),
              content: const Text(
                'You need 50 paise to send a message. Please recharge your wallet to continue chatting.',
                style: TextStyle(fontSize: 15, color: Colors.black87, height: 1.4),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context); // close dialog
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const WalletRechargeScreen()),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primaryBlue,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  ),
                  child: const Text('Recharge Now', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
          return;
        }
        
        // Deduct locally and save to SharedPreferences
        appState.addPendingChatDeduction(coins: 5, freeMsgs: 0);
        deductedAmount = 0.50;
      }
      
      // Save chat transaction: local SQLite (max 30) & RTDB (max 5)
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final txId = 'ctx_${widget.myUid}_$timestamp';
      final txData = {
        'txId': txId,
        'userId': widget.myUid,
        'otherUid': widget.otherUid,
        'otherUserName': widget.otherUserName,
        'otherAvatarUrl': widget.otherUserAvatarUrl,
        'otherAvatarIndex': widget.otherUserAvatarIndex,
        'amount': deductedAmount,
        'timestamp': timestamp,
      };
      LocalChatDatabase.instance.saveChatTransactionLocally(txData);
      UserDatabaseService.instance.saveChatTransaction(widget.myUid, txData);

      // Batch sync rule: Sync after 5 messages
      if (appState.pendingChatFreeMsgs >= 5 || appState.pendingChatCoins >= 25) {
        AppState.syncPendingChatDeductions();
        appState.clearPendingChatDeductionsLocally();
      }
    }

    _textController.clear();
    
    await _chatService.sendMessage(
      roomId: _roomId,
      senderUid: widget.myUid,
      receiverUid: widget.otherUid,
      text: text,
    );
  }

  Widget _buildTickIcon(int status) {
    if (status == 1) {
      // Sent: Single Grey Tick
      return const Icon(Icons.check, size: 16, color: Color(0xFF8696A0));
    } else if (status == 2) {
      // Delivered: Double Grey Tick
      return const Icon(Icons.done_all, size: 16, color: Color(0xFF8696A0));
    } else if (status >= 3) {
      // Read: Double Blue Tick (WhatsApp Blue)
      return const Icon(Icons.done_all, size: 16, color: Color(0xFF53BDEB));
    }
    return const SizedBox(width: 16);
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    final isFemale = appState.selectedGender == 'Female';
    final otherRole = isFemale ? 'user' : 'expert';

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F5), // WhatsApp-like background
      appBar: AppBar(
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarDividerColor: Color(0xFFE2E8F0),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [AppColors.gradientBlueStart, AppColors.gradientBlueEnd],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Stack(
              children: [
                FutureBuilder<Map<String, dynamic>>(
                  future: _profileFuture,
                  initialData: {
                    'avatarIndex': widget.otherUserAvatarIndex,
                    'avatarUrl': widget.otherUserAvatarUrl,
                  },
                  builder: (context, snapshot) {
                    int avatarIndex = 1;
                    String? avatarUrl;
                    if (snapshot.hasData) {
                      final data = snapshot.data!;
                      avatarIndex = (data['avatarIndex'] as num?)?.toInt() ?? 1;
                      avatarUrl = data['avatarUrl'] as String?;
                    }
                    return LocalAvatarWidget(
                      uid: widget.otherUid,
                      role: otherRole,
                      radius: 20,
                      avatarIndex: avatarIndex,
                      avatarUrl: avatarUrl,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.otherUserName,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) async {
              if (value == 'report') {
                await UserDatabaseService.instance.submitReport({
                  'reporterId': widget.myUid,
                  'reportedId': widget.otherUid,
                  'reportedName': widget.otherUserName,
                  'reason': 'Inappropriate behavior in chat',
                });
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('User reported successfully. We will review this shortly.')),
                  );
                }
              } else if (value == 'block') {
                await BlockService.instance.blockUser(widget.myUid, widget.otherUid);
                if (context.mounted) {
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('User blocked. You will no longer receive messages from them.')),
                  );
                }
              } else if (value == 'unblock') {
                await BlockService.instance.unblockUser(widget.myUid, widget.otherUid);
                if (context.mounted) {
                  setState(() {});
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('User unblocked successfully.')),
                  );
                }
              }
            },
            itemBuilder: (context) {
              bool isBlocked = BlockService.instance.isBlocked(widget.otherUid);
              return [
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
                PopupMenuItem(
                  value: isBlocked ? 'unblock' : 'block',
                  child: Row(
                    children: [
                      Icon(isBlocked ? Icons.lock_open : Icons.block, color: Colors.black54, size: 20),
                      const SizedBox(width: 8),
                      Text(isBlocked ? 'Unblock User' : 'Block User'),
                    ],
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (isFemale)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
              color: const Color(0xFFFFF9E6),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.monetization_on_outlined, size: 16, color: Color(0xFFB78103)),
                  SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'You can earn 10 paise on message in live chat only',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8A5D00),
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isMe = msg['senderId'] == widget.myUid;
                final text = (msg['text'] ?? '').toString();
                final timestamp = (msg['timestamp'] is num) ? (msg['timestamp'] as num).toInt() : DateTime.now().millisecondsSinceEpoch;
                final status = (msg['status'] is num) ? (msg['status'] as num).toInt() : 0;
                final isEarned = (msg['isEarned'] is num) ? (msg['isEarned'] as num).toInt() : 0;
                final isEarnedLive = !isMe && isFemale && isEarned == 1;
                
                final timeStr = TimeOfDay.fromDateTime(DateTime.fromMillisecondsSinceEpoch(timestamp)).format(context);

                return Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: EdgeInsets.only(bottom: isEarnedLive ? 2 : 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isMe ? AppColors.lightBlueBg : Colors.white,
                          borderRadius: BorderRadius.circular(12).copyWith(
                            bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(12),
                            bottomLeft: !isMe ? const Radius.circular(0) : const Radius.circular(12),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.05),
                              blurRadius: 2,
                              offset: const Offset(0, 1),
                            )
                          ]
                        ),
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.end,
                          children: [
                            Text(
                              text,
                              style: const TextStyle(fontSize: 15, color: Colors.black87),
                            ),
                            const SizedBox(width: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  timeStr,
                                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                                ),
                                if (isMe) ...[
                                  const SizedBox(width: 4),
                                  _buildTickIcon(status),
                                ]
                              ],
                            )
                          ],
                        ),
                      ),
                      if (isEarnedLive)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF2E7D32)),
                              SizedBox(width: 3),
                              Text(
                                '10 paise earned',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF2E7D32),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          _buildMessageInput(),
        ],
      ),
    );
  }

  Widget _buildMessageInput() {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      padding: EdgeInsets.only(left: 8, right: 8, top: 8, bottom: 8 + bottomInset),
      color: Colors.white,
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFF0F2F5),
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _textController,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendMessage(),
                decoration: const InputDecoration(
                  hintText: 'Type a message...',
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _sendMessage,
            child: CircleAvatar(
              radius: 24,
              backgroundColor: AppColors.primaryBlue,
              child: const Icon(Icons.send, color: Colors.white, size: 20),
            ),
          ),
        ],
      ),
    );
  }
}
