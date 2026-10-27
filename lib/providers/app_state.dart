import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/user_database_service.dart';
import '../services/general_feed_service.dart';
import 'package:firebase_database/firebase_database.dart';

class AppState extends ChangeNotifier {
  // Authentication state
  String _mobileNumber = '';
  String get mobileNumber => _mobileNumber;

  // Gender / Role selection state
  String _selectedGender = ''; // 'Male' or 'Female' or ''
  String get selectedGender => _selectedGender;

  // Auto-retrieved SMS credential & code (for visible filling without automatic login)
  PhoneAuthCredential? _autoRetrievedCredential;
  PhoneAuthCredential? get autoRetrievedCredential => _autoRetrievedCredential;

  String? _autoRetrievedSmsCode;
  String? get autoRetrievedSmsCode => _autoRetrievedSmsCode;

  // Female Onboarding flow state
  String _nickname = '';
  String get nickname => _nickname;

  final String _uid = '';
  String get uid {
    if (_uid.isNotEmpty) return _uid;
    return FirebaseAuth.instance.currentUser?.uid ?? '';
  }

  int _birthYear = 2001;
  int get birthYear => _birthYear;

  int _avatarIndex = 1;
  int get avatarIndex => _avatarIndex;

  String _primaryLanguage = 'Hindi';
  String get primaryLanguage => _primaryLanguage;

  final List<String> _otherLanguages = [];
  List<String> get otherLanguages => List.unmodifiable(_otherLanguages);

  bool _isAudioVerified = false;
  bool get isAudioVerified => _isAudioVerified;

  String _enteredReferralCode = '';
  String get enteredReferralCode => _enteredReferralCode;

  // Female Expert Dashboard state
  bool _isOnline = false;
  bool get isOnline => _isOnline;

  double _totalEarnings = 0.0;
  double get totalEarnings => _totalEarnings;

  // Male Caller Dashboard state
  int _coinBalance = 0;
  int get coinBalance => _coinBalance;


  int _freeMessagesUsed = 0;
  int get freeMessagesUsed => _freeMessagesUsed;

  // Setters
  void setMobileNumber(String number) {
    _mobileNumber = number;
    notifyListeners();
  }

  void setSelectedGender(String gender) {
    _selectedGender = gender;
    SharedPreferences.getInstance().then((prefs) => prefs.setString('userRole', gender.toLowerCase()));
    notifyListeners();
  }

  void setAutoRetrievedCredential(PhoneAuthCredential? credential) {
    _autoRetrievedCredential = credential;
    notifyListeners();
  }

  void setAutoRetrievedSmsCode(String? code) {
    _autoRetrievedSmsCode = code;
    notifyListeners();
  }

  void setNickname(String name) {
    _nickname = name;
    notifyListeners();
  }

  void setBirthYear(int year) {
    _birthYear = year;
    notifyListeners();
  }

  void setAvatarIndex(int index) {
    _avatarIndex = index;
    notifyListeners();
  }

  void setPrimaryLanguage(String lang) {
    _primaryLanguage = lang;
    notifyListeners();
  }

  void toggleOtherLanguage(String lang) {
    if (_otherLanguages.contains(lang)) {
      _otherLanguages.remove(lang);
    } else {
      _otherLanguages.add(lang);
    }
    notifyListeners();
  }

  void clearOtherLanguages() {
    _otherLanguages.clear();
    notifyListeners();
  }

  void setAudioVerified(bool verified) {
    _isAudioVerified = verified;
    notifyListeners();
  }

  void setEnteredReferralCode(String code) {
    _enteredReferralCode = code;
    notifyListeners();
  }

  void setOnlineStatus(bool online) {
    _isOnline = online;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('isExpertOnline', online);
      if (online) {
        prefs.setBool('isAppSwipedAway', false);
      }
    });
    notifyListeners();
  }

  void addEarnings(double amount) {
    _totalEarnings += amount;
    notifyListeners();
  }

  void setCoinBalance(int balance) {
    _coinBalance = balance;
    notifyListeners();
  }


  void setFreeMessagesUsed(int count) {
    _freeMessagesUsed = count;
    notifyListeners();
  }

  void incrementFreeMessagesUsed() {
    _freeMessagesUsed++;
    notifyListeners();
  }

  void addCoinBalance(int amount) {
    _coinBalance += amount;
    notifyListeners();
  }

  void deductCoinBalance(int amount) {
    if (_coinBalance >= amount) {
      _coinBalance -= amount;
    } else {
      _coinBalance = 0;
    }
    notifyListeners();
  }

  // --- SharedPreferences Chat Billing Optimization ---
  int _pendingChatCoins = 0;
  int _pendingChatFreeMsgs = 0;

  int get pendingChatCoins => _pendingChatCoins;
  int get pendingChatFreeMsgs => _pendingChatFreeMsgs;

  Future<void> addPendingChatDeduction({required int coins, required int freeMsgs}) async {
    final prefs = await SharedPreferences.getInstance();
    
    if (coins > 0) {
      _pendingChatCoins += coins;
      await prefs.setInt('pendingChatCoins', _pendingChatCoins);
      deductCoinBalance(coins); // instant UI update
    }
    if (freeMsgs > 0) {
      _pendingChatFreeMsgs += freeMsgs;
      await prefs.setInt('pendingChatFreeMsgs', _pendingChatFreeMsgs);
      incrementFreeMessagesUsed(); // instant UI update
      if (_freeMessagesUsed >= 5 && uid.isNotEmpty) {
        GeneralFeedService.instance.markFreeMessagesExhausted(
          uid: uid,
          language: _primaryLanguage,
        );
      }
    }
    
    final myUid = uid.isNotEmpty ? uid : "test_uid";
    await prefs.setString('pendingChatUid', myUid);
  }

  void clearPendingChatDeductionsLocally() {
    _pendingChatCoins = 0;
    _pendingChatFreeMsgs = 0;
  }

  static Future<void> syncPendingChatDeductions() async {
    final prefs = await SharedPreferences.getInstance();
    final coinsToDeduct = prefs.getInt('pendingChatCoins') ?? 0;
    final freeMsgsToSync = prefs.getInt('pendingChatFreeMsgs') ?? 0;
    
    if (coinsToDeduct == 0 && freeMsgsToSync == 0) return;
    
    final myUid = prefs.getString('pendingChatUid') ?? '';
    if (myUid.isEmpty) return;

    await prefs.remove('pendingChatCoins');
    await prefs.remove('pendingChatFreeMsgs');
    await prefs.remove('pendingChatUid');

    if (coinsToDeduct > 0) {
      await UserDatabaseService.instance.deductUserCoins(myUid, coinsToDeduct);
    }
    if (freeMsgsToSync > 0) {
      try {
        final ref = UserDatabaseService.instance.usersRef.child(myUid).child('freeMessagesUsed');
        await ref.runTransaction((cur) {
          final val = (cur as num?)?.toInt() ?? 0;
          return Transaction.success(val + freeMsgsToSync);
        });
      } catch (e) {
        debugPrint('Failed to sync freeMessagesUsed in new RTDB: $e');
      }
    }
  }

  void reset() {
    _mobileNumber = '';
    _selectedGender = '';
    _nickname = '';
    _birthYear = 2001;
    _avatarIndex = 1;
    _primaryLanguage = 'Hindi';
    _otherLanguages.clear();
    _isAudioVerified = false;
    _isOnline = false;
    _totalEarnings = 0.0;
    _coinBalance = 0;
    _freeMessagesUsed = 0;
    _autoRetrievedSmsCode = null;
    _autoRetrievedCredential = null;
    notifyListeners();
  }
}
