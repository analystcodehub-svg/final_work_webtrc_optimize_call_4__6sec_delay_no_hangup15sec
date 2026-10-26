import "package:flutter/services.dart";
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../providers/app_state.dart';
import 'gender_selection_screen.dart';
import 'main_navigation.dart';
import 'male_dashboard_screen.dart';
import '../services/user_database_service.dart';

class OtpVerificationScreen extends StatefulWidget {
  final String verificationId;
  final String mobileNumber;

  const OtpVerificationScreen({
    super.key,
    required this.verificationId,
    required this.mobileNumber,
  });

  @override
  State<OtpVerificationScreen> createState() => _OtpVerificationScreenState();
}

class _OtpVerificationScreenState extends State<OtpVerificationScreen> {
  final TextEditingController _otpController = TextEditingController();
  bool _isLoading = false;
  AppState? _appState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _checkAutoRetrievedSms();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newAppState = context.read<AppState>();
    if (_appState != newAppState) {
      _appState?.removeListener(_onAppStateChanged);
      _appState = newAppState;
      _appState?.addListener(_onAppStateChanged);
      _checkAutoRetrievedSms();
    }
  }

  void _onAppStateChanged() {
    _checkAutoRetrievedSms();
  }

  void _checkAutoRetrievedSms() {
    final autoCode = _appState?.autoRetrievedSmsCode;
    if (autoCode != null && autoCode.isNotEmpty && _otpController.text != autoCode) {
      if (mounted) {
        setState(() {
          _otpController.text = autoCode;
        });
      }
      // We STOP here. The user must manually press 'Proceed' to submit.
    }
  }

  @override
  void dispose() {
    _appState?.removeListener(_onAppStateChanged);
    _otpController.dispose();
    super.dispose();
  }

  void _verifyOtp() async {
    final otp = _otpController.text.trim();
    if (otp.length != 6) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid 6-digit OTP')),
      );
      }
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      User? currentUser = FirebaseAuth.instance.currentUser;
      
      // If user is not yet logged in, sign them in with credential or entered OTP
      if (currentUser == null) {
        final autoCredential = context.read<AppState>().autoRetrievedCredential;
        PhoneAuthCredential credential;
        if (autoCredential != null && (autoCredential.smsCode == otp || autoCredential.smsCode == null)) {
          credential = autoCredential;
        } else {
          credential = PhoneAuthProvider.credential(
            verificationId: widget.verificationId,
            smsCode: otp,
          );
        }

        UserCredential userCredential =
            await FirebaseAuth.instance.signInWithCredential(credential);
        currentUser = userCredential.user;
      }

      if (currentUser != null) {
        // Successful login, check if user exists in new RTDB (with lazy fallback)
        final uid = currentUser.uid;
        
        final userData = await UserDatabaseService.instance.getUser(uid);

        if (mounted) {
          if (!mounted) return;
          if (userData != null) {
            // Profile exists in users collection (Male Caller)
            final data = userData;

            // Load app state
            final appState = context.read<AppState>();
            appState.setMobileNumber(widget.mobileNumber);
            appState.setSelectedGender('Male');
            appState.setNickname((data['nickname'] ?? '').toString());
            
            // Navigate to Dashboard
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => const MaleCallerDashboard()),
              (route) => false,
            );
          } else {
            // Check if user exists in experts collection (Female Expert)
            final expertData = await UserDatabaseService.instance.getExpert(uid);

            if (!mounted) return;
            if (expertData != null) {
              final data = expertData;

              // Load app state
              final appState = context.read<AppState>();
              appState.setMobileNumber(widget.mobileNumber);
              appState.setSelectedGender('Female');
              appState.setNickname((data['nickname'] ?? '').toString());
              appState.setAudioVerified(true);
              
              // Navigate to Female Expert Dashboard
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (context) => const MainNavigation()),
                (route) => false,
              );
            } else {
              if (!mounted) return;
              // New user, navigate to Gender Selection to build profile
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const GenderSelectionScreen()),
              );
            }
          }
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        String message = 'Invalid OTP. Please try again.';
        if (e.code == 'invalid-verification-code') {
          message = 'The OTP you entered is incorrect.';
        } else if (e.code == 'session-expired') {
          message = 'The OTP has expired. Please request a new one.';
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
        }
      }
    } catch (e) {
      debugPrint("OTP Verification Error: \$e");
      debugPrint("Stack Trace: \$stackTrace");
      if (mounted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('An error occurred: \$e')),
        );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          statusBarBrightness: Brightness.light,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
          systemNavigationBarDividerColor: Color(0xFFE2E8F0),
        ),
      ),
      body: Stack(
        children: [
          // Background soft glow
          Center(
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF4C75F2).withValues(alpha: 0.15),
                    Colors.white.withValues(alpha: 0.0),
                  ],
                  stops: const [0.0, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 60),
                
                // Instructions Text
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 15,
                        color: Colors.black54,
                        height: 1.4,
                      ),
                      children: [
                        TextSpan(text: 'Your login OTP is sent to +91 ${widget.mobileNumber}.\n'),
                        const TextSpan(text: 'Not your number? '),
                        TextSpan(
                          text: 'Change here.',
                          style: const TextStyle(
                            color: Colors.black87,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                          recognizer: TapGestureRecognizer()..onTap = () {
                            Navigator.pop(context);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 40),
                
                // OTP Field with Gradient Border
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: const Color(0xFF4C75F2), // Solid blue border
                    ),
                    padding: const EdgeInsets.all(1.5), // Border thickness
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: Colors.white, // Inner background
                        borderRadius: BorderRadius.circular(7), // Slightly less than outer radius
                      ),
                      child: TextField(
                        controller: _otpController,
                        keyboardType: TextInputType.number,
                        autofillHints: const [AutofillHints.oneTimeCode],
                        maxLength: 6,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w500,
                          color: Colors.black87,
                          letterSpacing: 2,
                        ),
                        decoration: const InputDecoration(
                          counterText: "",
                          border: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          filled: true,
                          fillColor: Colors.transparent,
                          contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        ),
                        // Removed auto-verify from onChanged
                        onChanged: (value) {},
                      ),
                    ),
                  ),
                ),
                
                const SizedBox(height: 30),
                
                // Proceed Button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 70.0),
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _verifyOtp,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4C75F2),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text(
                            'Proceed',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
                
                const SizedBox(height: 24),
                
                // Resend OTP
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black87,
                      ),
                      children: [
                        const TextSpan(text: "Didn't receive an OTP? "),
                        TextSpan(
                          text: 'Resend code',
                          style: const TextStyle(
                            color: Color(0xFF4C75F2),
                          ),
                          recognizer: TapGestureRecognizer()..onTap = () async {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Resending OTP...')),
                            );
                            }
                            await FirebaseAuth.instance.verifyPhoneNumber(
                              phoneNumber: '+91${widget.mobileNumber}',
                              verificationCompleted: (PhoneAuthCredential credential) {},
                              verificationFailed: (FirebaseAuthException e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Failed to resend: ${e.message}')),
                                );
                                }
                              },
                              codeSent: (String verificationId, int? resendToken) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('OTP sent successfully!')),
                                );
                                }
                              },
                              codeAutoRetrievalTimeout: (String verificationId) {},
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
