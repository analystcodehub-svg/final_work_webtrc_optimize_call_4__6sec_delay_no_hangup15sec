import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'nickname_page.dart';
import 'primary_language_page.dart';
import 'package:provider/provider.dart';
import '../../providers/app_state.dart';
import '../male_dashboard_screen.dart';
import '../avatar_selection_page.dart';
import '../../services/user_database_service.dart';
import '../../services/general_feed_service.dart';

class MaleOnboardingParent extends StatefulWidget {
  const MaleOnboardingParent({super.key});

  @override
  State<MaleOnboardingParent> createState() => _MaleOnboardingParentState();
}

class _MaleOnboardingParentState extends State<MaleOnboardingParent> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  int get _totalPages => 3;
  bool _isSaving = false;

  void _nextPage() async {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    } else {
      if (_isSaving) return;
      setState(() {
        _isSaving = true;
      });

      final appState = context.read<AppState>();
      final mobile = appState.mobileNumber.isNotEmpty ? appState.mobileNumber : "test_mobile";
      final nickname = appState.nickname.isNotEmpty ? appState.nickname : "User";

      try {
        await UserDatabaseService.instance.setUser(appState.uid, {
          'uid': appState.uid,
          'mobileNumber': mobile,
          'nickname': nickname,
          'gender': 'male',
          'primaryLanguage': appState.primaryLanguage,
          'avatarIndex': appState.avatarIndex,
          'coinBalance': appState.coinBalance,
          'freeMessagesUsed': 0,
        });

        // Register new male user in General Feed bucket (zegochat-c44b0-42f39)
        GeneralFeedService.instance.registerMaleIfEligible(
          uid: appState.uid,
          nickname: nickname,
          avatarIndex: appState.avatarIndex,
          language: appState.primaryLanguage,
        );

        if (mounted) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => const MaleCallerDashboard()),
            (route) => false,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error saving profile: $e')),
          );
        }
      } finally {
        if (mounted) {
          setState(() {
            _isSaving = false;
          });
        }
      }
    }
  }


  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_currentPage + 1) / _totalPages;

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(
          'Step ${_currentPage + 1} of $_totalPages',
          style: const TextStyle(
            fontSize: 14,
            color: AppTheme.textGrey,
            fontWeight: FontWeight.w600,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Linear Progress Indicator
            Container(
              height: 4,
              width: double.infinity,
              color: AppTheme.inputBg,
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: MediaQuery.of(context).size.width * progress,
                  color: AppTheme.primaryBlue,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Page Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0),
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(), // Force sequential navigation
                  onPageChanged: (page) {
                    setState(() {
                      _currentPage = page;
                    });
                  },
                  children: [
                    NicknamePage(onNext: _nextPage),
                    PrimaryLanguagePage(onNext: _nextPage),
                    AvatarSelectionPage(onNext: _nextPage, gender: 'Male'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
