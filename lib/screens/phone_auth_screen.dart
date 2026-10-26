import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../providers/app_state.dart';
import '../theme/app_theme.dart';
import 'otp_verification_screen.dart';
import 'terms_condition_screen.dart';
import 'privacy_policy_screen.dart';
import 'package:smart_auth/smart_auth.dart';
import 'package:flutter/gestures.dart';
class PhoneAuthScreen extends StatefulWidget {
  const PhoneAuthScreen({super.key});

  @override
  State<PhoneAuthScreen> createState() => _PhoneAuthScreenState();
}

class _PhoneAuthScreenState extends State<PhoneAuthScreen> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _referralController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final PageController _bannerController = PageController();
  int _currentBannerPage = 0;
  Timer? _bannerTimer;
  bool _referralValid = false;
  bool _referralChecking = false;
  bool _isLoading = false;
  String? _referralError;
  bool _showReferralField = false;

  final List<Map<String, dynamic>> _bannerSlides = [
    {
      'icon': Icons.favorite_rounded,
      'title': 'Real Connections',
      'subtitle': 'Find your perfect companion & talk with experts instantly.',
    },
    {
      'icon': Icons.security_rounded,
      'title': '100% Safe & Secure',
      'subtitle': 'Your privacy is our priority. Talk securely and anonymously.',
    },
    {
      'icon': Icons.phone_in_talk_rounded,
      'title': 'Instant Audio Calls',
      'subtitle': 'Connect directly with experts starting at just ₹4/min.',
    },
  ];

  @override
  void initState() {
    super.initState();
    _startBannerAutoPlay();
    _requestPhoneHint();
  }

  Future<void> _requestPhoneHint() async {
    try {
      final res = await SmartAuth.instance.requestPhoneNumberHint();
      if (res.hasData && res.data != null) {
        String phone = res.data!.replaceAll(RegExp(r'[^\d+]'), '');
        if (phone.startsWith('+91')) {
          phone = phone.substring(3);
        } else if (phone.startsWith('91') && phone.length == 12) {
          phone = phone.substring(2);
        } else if (phone.startsWith('0') && phone.length == 11) {
          phone = phone.substring(1);
        }
        if (phone.length == 10 && mounted) {
          setState(() {
            _phoneController.text = phone;
          });
        }
      }
    } catch (e) {
      debugPrint('Phone hint error: \$e');
    }
  }

  void _startBannerAutoPlay() {
    _bannerTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
      if (_bannerController.hasClients) {
        int nextPage = _currentBannerPage + 1;
        if (nextPage >= _bannerSlides.length) {
          nextPage = 0;
        }
        _bannerController.animateToPage(
          nextPage,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _referralController.dispose();
    _bannerController.dispose();
    _bannerTimer?.cancel();
    super.dispose();
  }

  // Check if referral code exists in Firestore and is valid
  Future<void> _validateReferralCode(String code) async {
    if (code.trim().isEmpty) {
      setState(() {
        _referralValid = false;
        _referralError = null;
      });
      return;
    }
    setState(() {
      _referralChecking = true;
      _referralError = null;
    });
    try {
      // Check experts collection for matching referral code
      final snap = await FirebaseFirestore.instance
          .collection('experts')
          .where('referralCode', isEqualTo: code.trim().toUpperCase())
          .limit(1)
          .get();
      if (snap.docs.isNotEmpty) {
        setState(() {
          _referralValid = true;
          _referralError = null;
        });
        if (mounted) {
          context.read<AppState>().setEnteredReferralCode(code.trim().toUpperCase());
        }
      } else {
        setState(() {
          _referralValid = false;
          _referralError = 'Invalid referral code';
        });
      }
    } catch (_) {
      setState(() {
        _referralValid = false;
        _referralError = 'Could not verify code. Try again.';
      });
    } finally {
      setState(() => _referralChecking = false);
    }
  }

    void _onGetOtpPressed() async {
    if (_isLoading) return;
    if (_formKey.currentState!.validate()) {
      final phone = _phoneController.text.trim();
      final phoneNumber = '+91$phone';
      
      setState(() {
        _isLoading = true;
      });

      try {
        await FirebaseAuth.instance.verifyPhoneNumber(
          phoneNumber: phoneNumber,
          verificationCompleted: (PhoneAuthCredential credential) async {
            // Auto-retrieval / Instant verification on Android:
            // Do NOT sign in here automatically!
            // Store the credential & SMS code so OtpVerificationScreen autofills it.
            // The user must manually click 'Proceed' to submit and trigger sign-in & permissions.
            try {
              if (mounted) {
                if (credential.smsCode != null && credential.smsCode!.isNotEmpty) {
                  context.read<AppState>().setAutoRetrievedSmsCode(credential.smsCode);
                }
                context.read<AppState>().setAutoRetrievedCredential(credential);
                setState(() => _isLoading = false);
              }
            } catch (e) {
              debugPrint('Auto-retrieval credential error: $e');
              if (mounted) {
                setState(() => _isLoading = false);
              }
            }
          },
          verificationFailed: (FirebaseAuthException e) {
            if (mounted) {
              setState(() => _isLoading = false);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Verification failed: ${e.message}')),
              );
            }
          },
          codeSent: (String verificationId, int? resendToken) {
            if (mounted) {
              setState(() => _isLoading = false);
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => OtpVerificationScreen(
                    verificationId: verificationId,
                    mobileNumber: phone,
                  ),
                ),
              );
            }
          },
          codeAutoRetrievalTimeout: (String verificationId) {
            // Timeout handling if necessary
          },
          timeout: const Duration(seconds: 60),
        );
      } catch (e) {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent, // transparent status bar
        statusBarIconBrightness: Brightness.dark, // dark icons for Android
        statusBarBrightness: Brightness.light, // dark icons for iOS
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Color(0xFFE2E8F0),
      ),
      child: Scaffold(
        body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24.0,
                    vertical: 10.0,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header Logo
                      Column(
                        children: [
                          const SizedBox(height: 10),
                          Text(
                            'SajniRe!',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.yellowtail(
                              fontSize: 42,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.primaryBlue,
                            ),
                          ),
                          const SizedBox(height: 20),
                          Container(
                            height: 190,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [
                                  AppTheme.primaryBlue,
                                  Color(0xFFE2859B), // Soft rose/pink matching the logo's warmth
                                ],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: AppTheme.primaryBlue.withValues(alpha: 0.15),
                                  blurRadius: 15,
                                  offset: const Offset(0, 5),
                                ),
                              ],
                            ),
                            child: PageView.builder(
                              controller: _bannerController,
                              onPageChanged: (index) {
                                setState(() {
                                  _currentBannerPage = index;
                                });
                              },
                              itemCount: _bannerSlides.length,
                              itemBuilder: (context, index) {
                                final slide = _bannerSlides[index];
                                return Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          slide['icon'] as IconData,
                                          size: 64,
                                          color: Colors.white,
                                        ),
                                        const SizedBox(height: 16),
                                        Text(
                                          slide['title'] as String,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          slide['subtitle'] as String,
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 13,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Page Indicators
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(_bannerSlides.length, (index) {
                              final isSelected = _currentBannerPage == index;
                              return AnimatedContainer(
                                duration: const Duration(milliseconds: 300),
                                margin: const EdgeInsets.symmetric(horizontal: 4.0),
                                width: isSelected ? 12.0 : 8.0,
                                height: 8.0,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(4),
                                  color: isSelected
                                      ? AppTheme.primaryBlue
                                      : AppTheme.primaryBlue.withValues(alpha: 0.3),
                                ),
                              );
                            }),
                          ),
                        ],
                      ),

                      // Input and Action
                      Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 20),
                            // Phone Number Field
                            Container(
                              decoration: BoxDecoration(
                                color: AppTheme.inputBg,
                                borderRadius: BorderRadius.circular(15),
                                border: Border.all(
                                  color: AppTheme.borderGrey,
                                  width: 1.0,
                                ),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                children: [
                                  // Country Prefix +91 Dropdown
                                  Row(
                                    children: [
                                      Image.network(
                                        'https://flagcdn.com/w40/in.png',
                                        width: 24,
                                        errorBuilder:
                                            (context, error, stackTrace) =>
                                                const Icon(
                                                  Icons.flag,
                                                  size: 24,
                                                ),
                                      ),
                                      const SizedBox(width: 8),
                                      const Text(
                                        '+91',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.textBlack,
                                        ),
                                      ),
                                      const Icon(
                                        Icons.keyboard_arrow_down,
                                        color: AppTheme.textGrey,
                                        size: 18,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(width: 12),
                                  Container(
                                    height: 24,
                                    width: 1,
                                    color: AppTheme.borderGrey,
                                  ),
                                  const SizedBox(width: 12),
                                  // Mobile input
                                  Expanded(
                                    child: TextFormField(
                                      controller: _phoneController,
                                      keyboardType: TextInputType.phone,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: AppTheme.textBlack,
                                      ),
                                      decoration: const InputDecoration(
                                        hintText: 'Your Mobile Number',
                                        hintStyle: TextStyle(
                                          color: AppTheme.textGrey,
                                          fontWeight: FontWeight.normal,
                                        ),
                                        filled: false,
                                        border: InputBorder.none,
                                        enabledBorder: InputBorder.none,
                                        focusedBorder: InputBorder.none,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      validator: (value) {
                                        if (value == null || value.isEmpty) {
                                          return 'Please enter mobile number';
                                        }
                                        if (value.length < 10) {
                                          return 'Please enter a valid 10-digit number';
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            // Optional Referral Code Field
                            if (!_showReferralField)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () {
                                    setState(() {
                                      _showReferralField = true;
                                    });
                                  },
                                  child: const Text(
                                    'Have a referral code?',
                                    style: TextStyle(
                                      color: AppTheme.primaryBlue,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                              )
                            else
                              Container(
                                decoration: BoxDecoration(
                                  color: _referralValid
                                      ? Colors.green.shade50
                                      : AppTheme.inputBg,
                                  borderRadius: BorderRadius.circular(15),
                                  border: Border.all(
                                    color: _referralValid
                                        ? Colors.green.shade400
                                        : _referralError != null
                                            ? Colors.red.shade300
                                            : AppTheme.borderGrey,
                                    width: 1.2,
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: Row(
                                  children: [
                                    Icon(
                                      _referralValid
                                          ? Icons.check_circle_rounded
                                          : Icons.card_giftcard_rounded,
                                      color: _referralValid
                                          ? Colors.green
                                          : AppTheme.textGrey,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: TextFormField(
                                        controller: _referralController,
                                        textCapitalization:
                                            TextCapitalization.characters,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                          color: _referralValid
                                              ? Colors.green.shade700
                                              : AppTheme.textBlack,
                                          letterSpacing: 2,
                                        ),
                                        decoration: InputDecoration(
                                          hintText: 'Referral Code (Optional)',
                                          hintStyle: const TextStyle(
                                            color: AppTheme.textGrey,
                                            fontWeight: FontWeight.normal,
                                            letterSpacing: 0,
                                            fontSize: 14,
                                          ),
                                          filled: false,
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding: EdgeInsets.zero,
                                          errorText: _referralError,
                                        ),
                                        onChanged: (v) {
                                          if (v.trim().length >= 6) {
                                            _validateReferralCode(v);
                                          } else if (v.isEmpty) {
                                            setState(() {
                                              _referralValid = false;
                                              _referralError = null;
                                            });
                                          }
                                        },
                                      ),
                                    ),
                                    if (_referralChecking)
                                      const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: AppTheme.primaryBlue),
                                      ),
                                    if (_referralValid)
                                      const Text(
                                        'Applied!',
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.green,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            if (_referralValid)
                              Padding(
                                padding: const EdgeInsets.only(top: 6, left: 4),
                                child: Text(
                                  '🎉 Referral code applied successfully!',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.green.shade700,
                                      fontWeight: FontWeight.w500),
                                ),
                              ),
                            const SizedBox(height: 20),
                             // Get OTP Button (Now acts as bypass)
                             ElevatedButton(
                               onPressed: _isLoading ? null : _onGetOtpPressed,
                               child: _isLoading
                                   ? const SizedBox(
                                       width: 20,
                                       height: 20,
                                       child: CircularProgressIndicator(
                                         color: Colors.white,
                                         strokeWidth: 2,
                                       ),
                                     )
                                   : const Text('Get OTP'),
                             ),
                            const SizedBox(height: 20),
                            // Footer Agreement Text
                            RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textGrey,
                                  height: 1.4,
                                  fontFamily: 'Roboto', // Or whatever default family is used
                                ),
                                children: [
                                  const TextSpan(text: 'By tapping, you agree to our '),
                                  TextSpan(
                                    text: 'Terms of Use',
                                    style: const TextStyle(
                                      color: AppTheme.primaryBlue,
                                      decoration: TextDecoration.underline,
                                    ),
                                    recognizer: TapGestureRecognizer()
                                      ..onTap = () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(builder: (context) => const TermsConditionScreen()),
                                        );
                                      },
                                  ),
                                  const TextSpan(text: ' and '),
                                  TextSpan(
                                    text: 'Privacy Policy',
                                    style: const TextStyle(
                                      color: AppTheme.primaryBlue,
                                      decoration: TextDecoration.underline,
                                    ),
                                    recognizer: TapGestureRecognizer()
                                      ..onTap = () {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(builder: (context) => const PrivacyPolicyScreen()),
                                        );
                                      },
                                  ),
                                  const TextSpan(text: '.\nAll your details are 100% safe & secure.'),
                                ],
                              ),
                            ),
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        ),
      ),
    );
  }
}
