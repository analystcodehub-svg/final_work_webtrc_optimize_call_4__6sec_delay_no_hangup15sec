import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../theme/app_colors.dart';
import '../providers/app_state.dart';
import 'kyc_pan_screen.dart';
import 'withdrawal_history_screen.dart';
import 'payment_history_screen.dart';
import 'terms_condition_screen.dart';
import 'refund_cancellation_screen.dart';
import 'privacy_policy_screen.dart';
import 'referral_screen.dart';

import 'wallet_recharge_screen.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

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
        backgroundColor: AppColors.bgLight,
        body: SafeArea(
          child: Consumer<AppState>(
            builder: (context, appState, child) {
          final nickname = appState.nickname.isNotEmpty ? appState.nickname : 'User';
          final uid = appState.selectedGender == 'Female' ? appState.uid : appState.mobileNumber;
          final role = appState.selectedGender == 'Female' ? 'expert' : 'user';
              
          return SingleChildScrollView(
            child: Column(
              children: [
                // Header with Blue Background and overlapping Grid
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Top Blue Background
                    Container(
                      height: 120,
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          colors: [AppColors.gradientBlueStart, AppColors.gradientBlueEnd],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 20),
                          // Username
                          Text(
                            nickname,
                            style: const TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                // Spacing to push content below the header
                const SizedBox(height: 24),

                // KYC & Profile Sections
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (role == 'expert') ...[
                        _buildKycStatusSection(context, uid, appState.nickname),
                        const SizedBox(height: 12),
                      ] else ...[
                        _buildWalletShortcut(context, appState.coinBalance),
                        const SizedBox(height: 12),
                      ],
                      

                      
                      // History Section
                      if (role == 'expert') ...[
                        _buildSettingsTile(
                          title: 'Refer & Earn',
                          icon: Icons.card_giftcard_rounded,
                          iconColor: Colors.amber.shade700,
                          iconBgColor: Colors.amber.shade50,
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const ReferralScreen()),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                        _buildSettingsTile(
                          title: 'Withdrawal History',
                          icon: Icons.history_rounded,
                          iconColor: AppColors.primaryBlue,
                          iconBgColor: AppColors.primaryBlue.withValues(alpha: 0.1),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const WithdrawalHistoryScreen()),
                            );
                          },
                        ),
                      ] else ...[
                        _buildSettingsTile(
                          title: 'Payment History',
                          icon: Icons.history_rounded,
                          iconColor: AppColors.primaryBlue,
                          iconBgColor: AppColors.primaryBlue.withValues(alpha: 0.1),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const PaymentHistoryScreen()),
                            );
                          },
                        ),
                      ],
                      const SizedBox(height: 24),

                      // Settings & Support Section
                      Row(
                        children: [
                          Container(
                            width: 4,
                            height: 20,
                            color: AppColors.primaryBlue,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Settings & Support',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppColors.textDark,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildSettingsTile(
                        title: 'Terms & Condition',
                        icon: Icons.description,
                        iconColor: Colors.orange,
                        iconBgColor: Colors.orange.withValues(alpha: 0.1),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const TermsConditionScreen()),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      if (role != 'expert') ...[
                        _buildSettingsTile(
                          title: 'Refund & Cancellation',
                          icon: Icons.attach_money,
                          iconColor: AppColors.successGreen,
                          iconBgColor: AppColors.successGreen.withValues(alpha: 0.1),
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const RefundCancellationScreen()),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                      ],
                      _buildSettingsTile(
                        title: 'Privacy Policy',
                        icon: Icons.privacy_tip_outlined,
                        iconColor: AppColors.primaryBlue,
                        iconBgColor: AppColors.primaryBlue.withValues(alpha: 0.1),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
                          );
                        },
                      ),
                      const SizedBox(height: 12),
                      _buildSettingsTile(
                        title: 'Delete Account',
                        icon: Icons.delete_forever_rounded,
                        iconColor: Colors.red,
                        iconBgColor: Colors.red.withValues(alpha: 0.1),
                        onTap: () {
                          _showDeleteAccountDialog(context);
                        },
                      ),
                      const SizedBox(height: 24),

                      // Customer Care Section
                      Theme(
                        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                        child: Container(
                          decoration: BoxDecoration(
                            color: AppColors.primaryBlue.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.2)),
                          ),
                          child: const Material(
                            type: MaterialType.transparency,
                            child: ExpansionTile(
                            tilePadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            childrenPadding: EdgeInsets.only(left: 16, right: 16, bottom: 16),
                            title: Text(
                              'Customer Care Support',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppColors.textDark,
                              ),
                            ),
                            iconColor: AppColors.primaryBlue,
                            collapsedIconColor: AppColors.primaryBlue,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.phone_outlined, size: 18, color: AppColors.primaryBlue),
                                  SizedBox(width: 8),
                                  Text('Phone No- +91 8987108642', style: TextStyle(fontSize: 14, color: AppColors.textDark)),
                                ],
                              ),
                              SizedBox(height: 12),
                              Row(
                                children: [
                                  Icon(Icons.chat_outlined, size: 18, color: Colors.green),
                                  SizedBox(width: 8),
                                  Text('WhatsApp: +91 8987108642', style: TextStyle(fontSize: 14, color: AppColors.textDark)),
                                ],
                              ),
                              SizedBox(height: 12),
                              Row(
                                children: [
                                  Icon(Icons.email_outlined, size: 18, color: AppColors.primaryBlue),
                                  SizedBox(width: 8),
                                  Text('sajnireofficial@gmail.com', style: TextStyle(fontSize: 14, color: AppColors.textDark)),
                                ],
                              ),
                            ],
                          ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 30),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
        ),
        ),
      ),
    );
  }
  void _showDeleteAccountDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        bool isLoading = false;
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Text('Delete Account', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
              content: const Text(
                'Are you sure you want to delete your account? This action cannot be undone and all your data and wallet balance will be permanently lost.',
              ),
              actions: [
                TextButton(
                  onPressed: isLoading ? null : () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: AppColors.textGrey)),
                ),
                ElevatedButton(
                  onPressed: isLoading
                      ? null
                      : () async {
                          setState(() { isLoading = true; });
                          try {
                            final user = FirebaseAuth.instance.currentUser;
                            if (user != null) {
                              await user.delete();
                            }
                            if (context.mounted) {
                              Navigator.pop(context); // close dialog
                              // AuthWrapper will automatically redirect to Login
                            }
                          } on FirebaseAuthException catch (e) {
                            if (e.code == 'requires-recent-login') {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('For security reasons, please log out and log back in to verify your identity before deleting your account.')),
                                );
                                Navigator.pop(context);
                              }
                            } else {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Error: ${e.message}')),
                                );
                                setState(() { isLoading = false; });
                              }
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error: $e')),
                              );
                              setState(() { isLoading = false; });
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: isLoading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Delete', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildSettingsTile({
    required String title,
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    VoidCallback? onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Material(
        color: AppColors.cardWhite,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap ?? () {},
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: iconColor, size: 24),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textDark,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.grey),
              ],
            ),
          ),
        ),
      ),
    );
  }



  Widget _buildKycStatusSection(BuildContext context, String uid, String nickname) {
    // Query by expertId (new submissions) — no orderBy to avoid index requirement
    final stream = FirebaseFirestore.instance
        .collection('kyc_requests')
        .where('expertId', isEqualTo: uid)
        .limit(1)
        .snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          // Fallback: query by accountHolder name for old documents
          return _buildKycByAccountHolder(context, nickname, uid);
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildKycButton(context);
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) {
          // No doc with expertId — try accountHolder for pre-fix submissions
          return _buildKycByAccountHolder(context, nickname, uid);
        }

        final data = docs.first.data() as Map<String, dynamic>;
        return _kycCardForStatus(context, data['status'] ?? 'pending');
      },
    );
  }

  // Fallback query for documents submitted before expertId was added
  Widget _buildKycByAccountHolder(BuildContext context, String nickname, String uid) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('kyc_requests')
          .limit(5)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _buildKycButton(context);
        }

        final docs = snapshot.data?.docs ?? [];
        if (docs.isEmpty) return _buildKycButton(context);

        // Find any doc where accountHolder or panName matches
        QueryDocumentSnapshot? match;
        for (final doc in docs) {
          final d = doc.data() as Map<String, dynamic>;
          final holder = (d['accountHolder'] ?? '').toString().toLowerCase();
          final pan = (d['panName'] ?? '').toString().toLowerCase();
          final eid = (d['expertId'] ?? '').toString();
          if (holder == nickname.toLowerCase() ||
              pan == nickname.toLowerCase() ||
              eid == uid) {
            match = doc;
            break;
          }
        }

        if (match == null) return _buildKycButton(context);

        final data = match.data() as Map<String, dynamic>;
        return _kycCardForStatus(context, data['status'] ?? 'pending');
      },
    );
  }

  Widget _kycCardForStatus(BuildContext context, String status) {
    if (status == 'approved') return _buildKycApprovedCard();
    if (status == 'rejected') return _buildKycRejectedCard(context);
    return _buildKycPendingCard();
  }

  Widget _buildKycApprovedCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.green.shade400, width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.green.shade50,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.verified_user_rounded,
                color: Colors.green.shade600, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'KYC Successful ✅',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: Colors.green.shade700,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'You can now withdraw your earnings.',
                  style: TextStyle(fontSize: 12, color: AppColors.textGrey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKycPendingCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.orange.shade300, width: 1.5),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(12),
            ),
            child:
                Icon(Icons.hourglass_top_rounded, color: Colors.orange.shade700, size: 22),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'KYC Under Review ⏳',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textDark,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  'We\'ll verify your details within 24–48 hours.',
                  style: TextStyle(fontSize: 12, color: AppColors.textGrey),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKycRejectedCard(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const KycPanScreen()),
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.red.shade300, width: 1.5),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(12),
              ),
              child:
                  Icon(Icons.cancel_rounded, color: Colors.red.shade600, size: 22),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'KYC Rejected ❌',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Tap to re-submit your KYC details.',
                    style: TextStyle(fontSize: 12, color: AppColors.textGrey),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _buildKycButton(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const KycPanScreen()),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.4), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppColors.primaryBlue.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.lightBlueBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.verified_user_rounded,
                color: AppColors.primaryBlue,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'KYC Verification',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: AppColors.textDark,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Complete to enable withdrawals',
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textGrey,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.primaryBlue,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Text(
                'Start KYC',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWalletShortcut(BuildContext context, int coinBalance) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const WalletRechargeScreen()),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppColors.gradientBlueStart, AppColors.gradientBlueEnd],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF3B82F6).withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Text('₹', style: TextStyle(fontSize: 28, color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'My Wallet',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '₹ ${(coinBalance / 10).toStringAsFixed(1)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white, size: 20),
          ],
        ),
      ),
    );
  }
}
