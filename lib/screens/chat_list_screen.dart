import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme/app_colors.dart';
import '../providers/app_state.dart';
import '../services/local_chat_database.dart';
import '../widgets/local_avatar_widget.dart';
import 'hybrid_chat_screen.dart';
import '../services/user_database_service.dart';
import '../services/matchmaking_service.dart';
import '../services/foreground_task_service.dart';

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  late String _currentUserMobile;
  late final MatchmakingService _matchingService;
  final Set<String> _pinnedUids = {};

  @override
  void initState() {
    super.initState();
    _matchingService = MatchmakingService();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<List<Map<String, dynamic>>> _fetchEnrichedChats(String myUid, bool isCurrentMale) async {
    final chatDocs = await LocalChatDatabase.instance.getRecentChats(myUid);
    final enrichedDocs = <Map<String, dynamic>>[];

    for (var doc in chatDocs) {
      final data = Map<String, dynamic>.from(doc);
      final otherUser = data['otherUserId'] as String;
      
      // If current user is male, other user is expert (female). If female, other user is user (male).
      final String expectedRole = isCurrentMale ? 'expert' : 'user';

      final profile = await LocalChatDatabase.instance.getEnrichedProfile(
        otherUser,
        defaultRole: expectedRole,
      );

      data['displayName'] = profile['name'] ?? otherUser;
      data['avatarUrl'] = profile['avatarUrl'];
      data['avatarIndex'] = profile['avatarIndex'] ?? 1;
      data['role'] = profile['role'] ?? expectedRole;
      enrichedDocs.add(data);
    }
    
    return enrichedDocs;
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    _currentUserMobile = appState.mobileNumber;
    if (_currentUserMobile.isEmpty) _currentUserMobile = "test_mobile";

    final String myUid = appState.uid;
    final bool isCurrentMale = appState.selectedGender != 'Female';
    final bool isFemaleOnline = appState.isOnline;

    return Scaffold(
      backgroundColor: AppColors.bgLight,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
              color: AppColors.bgLight,
              child: const Text(
                'Chats',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: AppColors.textDark,
                ),
              ),
            ),
            // Offline Warning Banner for Female Expert
            if (!isCurrentMale && !isFemaleOnline)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: const BoxDecoration(
                  color: Color(0xFFFFF1F2),
                  border: Border(
                    bottom: BorderSide(color: Color(0xFFFECDD3), width: 1),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.wifi_off_rounded, color: Color(0xFFE11D48), size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "You're offline. Go online to chat & call.",
                        style: TextStyle(
                          color: Color(0xFF9F1239),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => _showGoOnlinePrompt(context, appState),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE11D48),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Text(
                          'Go Online',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _buildFriendsTab(
                context,
                appState,
                myUid,
                isCurrentMale,
                isOnline: isCurrentMale ? true : isFemaleOnline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── TAB 1: FRIENDS (Only Messages) ──────────────────────────────────────

  Widget _buildFriendsTab(
    BuildContext context,
    AppState appState,
    String myUid,
    bool isCurrentMale, {
    required bool isOnline,
  }) {
    return StreamBuilder<void>(
      stream: LocalChatDatabase.instance.updates,
      builder: (context, snapshot) {
        return FutureBuilder<List<Map<String, dynamic>>>(
          future: _fetchEnrichedChats(myUid, isCurrentMale),
          builder: (context, futureSnapshot) {
            if (futureSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator(color: Color(0xFFE11D48)));
            }

            if (futureSnapshot.hasError) {
              return Center(child: Text('Error loading chats: ${futureSnapshot.error}'));
            }

            final chatDocs = futureSnapshot.data ?? [];
            if (chatDocs.isEmpty) {
              return _buildEmptyState();
            }

            // Pinned chats appear first
            chatDocs.sort((a, b) {
              final aPinned = _pinnedUids.contains(a['otherUserId']);
              final bPinned = _pinnedUids.contains(b['otherUserId']);
              if (aPinned && !bPinned) return -1;
              if (!aPinned && bPinned) return 1;
              return 0;
            });

            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 12),
              itemCount: chatDocs.length,
              itemBuilder: (context, index) {
                final data = chatDocs[index];
                final otherUser = data['otherUserId'] as String;
                final lastMessage = data['lastMessage'] as String;
                final timestamp = data['timestamp'] as int;
                final unreadCount = data['unreadCount'] as int;
                final displayName = data['displayName'] as String;
                final dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
                final now = DateTime.now();
                String dayText;
                if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
                  dayText = TimeOfDay.fromDateTime(dt).format(context);
                } else {
                  dayText = '${dt.day}/${dt.month}';
                }

                final role = data['role'] as String? ?? 'user';

                return _buildFriendChatCard(
                  uid: otherUser,
                  role: role,
                  name: displayName,
                  subtitle: lastMessage.isNotEmpty ? lastMessage : 'Tap to open chat',
                  trailingText: dayText,
                  unreadCount: unreadCount,
                  avatarUrl: data['avatarUrl'] as String?,
                  avatarIndex: (data['avatarIndex'] as num?)?.toInt() ?? 1,
                  isOnline: isOnline,
                  onDisabledTap: () => _showGoOnlinePrompt(context, appState),
                  onMessageTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => HybridChatScreen(
                          myUid: myUid,
                          otherUid: otherUser,
                          otherUserName: displayName,
                          otherUserAvatarUrl: data['avatarUrl'] as String?,
                          otherUserAvatarIndex: (data['avatarIndex'] as num?)?.toInt() ?? 1,
                        ),
                      ),
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }

  // ─── FRIENDS CARD DESIGN (Single-Line Modern Design) ─────────────────────

  Widget _buildFriendChatCard({
    required String uid,
    required String role,
    required String name,
    required String subtitle,
    required String trailingText,
    required int unreadCount,
    String? avatarUrl,
    int? avatarIndex,
    bool isOnline = true,
    VoidCallback? onDisabledTap,
    required VoidCallback onMessageTap,
  }) {
    final isPinned = _pinnedUids.contains(uid);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isPinned ? const Color(0xFFE11D48).withValues(alpha: 0.35) : const Color(0xFFE2E8F0),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: isOnline ? onMessageTap : onDisabledTap,
        borderRadius: BorderRadius.circular(20),
        child: Row(
          children: [
            // Avatar
            LocalAvatarWidget(
              uid: uid,
              role: role,
              radius: 26,
              avatarIndex: avatarIndex ?? 1,
              avatarUrl: avatarUrl,
            ),
            const SizedBox(width: 12),

            // Name and Last Message
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 13,
                      color: unreadCount > 0 ? AppColors.textDark : AppColors.textGrey,
                      fontWeight: unreadCount > 0 ? FontWeight.bold : FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),

            // Time / Badge
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  trailingText,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF94A3B8),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (unreadCount > 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: const BoxDecoration(
                      color: Color(0xFFE11D48),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      unreadCount.toString(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(width: 10),

            // Blue Message Button on the same single line!
            Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: isOnline ? onMessageTap : onDisabledTap,
                borderRadius: BorderRadius.circular(16),
                child: Ink(
                  height: 40,
                  width: 40,
                  decoration: BoxDecoration(
                    gradient: isOnline
                        ? const LinearGradient(
                            colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          )
                        : const LinearGradient(
                            colors: [Color(0xFFE2E8F0), Color(0xFFCBD5E1)],
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                          ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: isOnline
                        ? [
                            BoxShadow(
                              color: const Color(0xFF3B82F6).withValues(alpha: 0.35),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ]
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                  ),
                  child: Center(
                    child: Icon(
                      Icons.chat_bubble_rounded,
                      color: isOnline ? Colors.white : const Color(0xFF94A3B8),
                      size: 19,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── PROMPT & GO ONLINE HANDLERS ─────────────────────────────────────────

  Future<void> _handleGoOnline(AppState appState) async {
    // 1. Check Notifications Permission
    final hasNotif = await Permission.notification.request().isGranted;
    if (!hasNotif) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Notifications permission is required to receive calls.')),
        );
      }
      return;
    }

    // 2. Check System Alert Window (Display over other apps)
    final hasAlert = await Permission.systemAlertWindow.request().isGranted;
    if (!hasAlert) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Display over other apps permission is required for incoming calls.')),
        );
      }
      return;
    }

    // 3. Check Microphone Permission
    final micStatus = await Permission.microphone.status;
    bool hasMic = micStatus.isGranted;
    if (!hasMic) {
      final req = await Permission.microphone.request();
      hasMic = req.isGranted;
    }
    if (!hasMic) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required to talk on calls.')),
        );
      }
      return;
    }

    if (!mounted) return;
    appState.setOnlineStatus(true);

    final String expertId = appState.uid;
    debugPrint('[STATUS] ChatList going online: expertId=$expertId');
    if (expertId.isNotEmpty) {
      try {
        await _matchingService.setExpertOnlineStatus(
          expertId: expertId,
          isOnline: true,
          gender: 'female',
          language: appState.primaryLanguage,
        );
        await UserDatabaseService.instance.updateExpert(expertId, {
          'nickname': appState.nickname,
          'mobileNumber': appState.mobileNumber,
          'age': 2026 - appState.birthYear,
          'pricePerMin': 4,
          'languages': appState.primaryLanguage,
          'rating': 4.8,
        });
        await UserDatabaseService.instance.joinExpertBucket(expertId, appState.primaryLanguage);
        debugPrint('[STATUS] ChatList successfully joined expert bucket and online queue');
      } catch (e) {
        debugPrint('[STATUS] Error going online from ChatList: $e');
      }

      try {
        ForegroundTaskService.startService();
      } catch (e) {
        debugPrint('[STATUS] Error starting ForegroundTaskService: $e');
      }
    }

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle_rounded, color: Colors.greenAccent),
              SizedBox(width: 8),
              Text('You are now Online! 🟢 Chat & Calls enabled.'),
            ],
          ),
          backgroundColor: Color(0xFF1E293B),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showGoOnlinePrompt(BuildContext context, AppState appState) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (bottomSheetContext) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(28),
              topRight: Radius.circular(28),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Pull Handle
              Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              const SizedBox(height: 20),

              // Glowing Offline Icon
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF1F2),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFFECDD3),
                    width: 2,
                  ),
                ),
                child: const Center(
                  child: Icon(
                    Icons.power_settings_new_rounded,
                    color: Color(0xFFE11D48),
                    size: 36,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Title
              const Text(
                "You're Currently Offline",
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textDark,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),

              // Description
              const Text(
                "Please go online to start messaging, making intro calls, and talking to users.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: AppColors.textGrey,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),

              // Benefit perks container
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: const Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.mark_chat_unread_rounded, size: 18, color: Color(0xFF10B981)),
                        SizedBox(width: 10),
                        Text('Chat & reply to user messages', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textDark)),
                      ],
                    ),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.call_rounded, size: 18, color: Color(0xFFA855F7)),
                        SizedBox(width: 10),
                        Text('1-minute free intro & incoming calls', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textDark)),
                      ],
                    ),
                    SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(Icons.monetization_on_rounded, size: 18, color: Color(0xFFF59E0B)),
                        SizedBox(width: 10),
                        Text('Earn real money on every call minute', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textDark)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Primary "Go Online Now" CTA Button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(bottomSheetContext);
                    await _handleGoOnline(appState);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE11D48),
                    foregroundColor: Colors.white,
                    elevation: 3,
                    shadowColor: const Color(0xFFE11D48).withValues(alpha: 0.35),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.flash_on_rounded, size: 20),
                      SizedBox(width: 8),
                      Text(
                        'Go Online Now',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Dismiss Button
              TextButton(
                onPressed: () => Navigator.pop(bottomSheetContext),
                child: const Text(
                  'Stay Offline',
                  style: TextStyle(
                    color: Color(0xFF94A3B8),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline, size: 64, color: AppColors.textGrey),
          SizedBox(height: 16),
          Text(
            'No active chats.',
            style: TextStyle(fontSize: 18, color: AppColors.textGrey),
          ),
        ],
      ),
    );
  }
}
