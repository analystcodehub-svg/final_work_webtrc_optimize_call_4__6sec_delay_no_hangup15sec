// lib/services/general_feed_service.dart
//
// Dedicated service for Female General Feed & Language Buckets.
// Strictly communicates ONLY with the isolated RTDB instance:
// https://zegochat-c44b0-42f39.asia-southeast1.firebasedatabase.app
//
// Features:
// 1. general_buckets/{language}/{uid} - Active fresh male feed.
// 2. used_free_messages/{language}/{uid} - Blacklist of users who used 5 free messages.
// 3. Smart local Gatekeeper (SharedPreferences) to eliminate redundant network hits.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GeneralFeedService {
  static final GeneralFeedService instance = GeneralFeedService._internal();
  GeneralFeedService._internal();

  static const String databaseUrl =
      'https://zegochat-c44b0-42f39.asia-southeast1.firebasedatabase.app';

  late final FirebaseDatabase _db = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL: databaseUrl,
  );

  DatabaseReference get _generalBucketsRef => _db.ref('general_buckets');
  DatabaseReference get _usedFreeMessagesRef => _db.ref('used_free_messages');

  /// Gatekeeper Check & Register:
  /// 1. Reads local SharedPreferences flag `has_used_5_free_msgs_$uid`.
  ///    If true ➔ 0 database hits! Exits immediately.
  /// 2. If false, queries `used_free_messages/$language/$uid`.
  ///    If exists ➔ caches local flag = true and exits without adding to bucket.
  ///    If does NOT exist ➔ registers male user into `general_buckets/$language/$uid`.
  Future<void> registerMaleIfEligible({
    required String uid,
    required String nickname,
    required int avatarIndex,
    String? avatarUrl,
    required String language,
  }) async {
    if (uid.isEmpty) return;

    final effectiveLang = language.isNotEmpty ? language : 'Hindi';

    try {
      final prefs = await SharedPreferences.getInstance();
      final localExhausted = prefs.getBool('has_used_5_free_msgs_$uid') ?? false;

      // Gatekeeper Step 1: 0 database calls if user is already known exhausted locally
      if (localExhausted) {
        debugPrint('[GeneralFeedService] Gatekeeper: $uid already exhausted free messages locally. Skipping.');
        return;
      }

      // Gatekeeper Step 2: Check remote used_free_messages node
      final usedSnap = await _usedFreeMessagesRef.child(effectiveLang).child(uid).get();
      if (usedSnap.exists && usedSnap.value == true) {
        await prefs.setBool('has_used_5_free_msgs_$uid', true);
        debugPrint('[GeneralFeedService] Gatekeeper: $uid found in used_free_messages. Cached locally & skipping.');
        return;
      }

      // Eligible fresh user ➔ register / update into active general bucket with timestamp index
      await _generalBucketsRef.child(effectiveLang).child(uid).set({
        'uid': uid,
        'nickname': nickname.isNotEmpty ? nickname : 'User',
        'avatarIndex': avatarIndex,
        'avatarUrl': avatarUrl ?? '',
        'language': effectiveLang,
        'timestamp': ServerValue.timestamp,
      });

      debugPrint('[GeneralFeedService] Registered eligible male $uid into bucket [$effectiveLang]');
    } catch (e) {
      debugPrint('[GeneralFeedService] Error in registerMaleIfEligible: $e');
    }
  }

  /// Triggered when male user consumes his 5th free message (freeMessagesUsed >= 5):
  /// 1. Sets local SharedPreferences flag to true.
  /// 2. Writes used_free_messages/$language/$uid = true in RTDB.
  /// 3. Permanently removes user from general_buckets/$language/$uid.
  Future<void> markFreeMessagesExhausted({
    required String uid,
    required String language,
  }) async {
    if (uid.isEmpty) return;

    final effectiveLang = language.isNotEmpty ? language : 'Hindi';

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_used_5_free_msgs_$uid', true);

      // Record in used_free_messages and remove from active bucket atomically/concurrently
      await Future.wait([
        _usedFreeMessagesRef.child(effectiveLang).child(uid).set(true),
        _generalBucketsRef.child(effectiveLang).child(uid).remove(),
      ]);

      debugPrint('[GeneralFeedService] Successfully marked $uid as exhausted in [$effectiveLang] and removed from bucket.');
    } catch (e) {
      debugPrint('[GeneralFeedService] Error in markFreeMessagesExhausted: $e');
    }
  }

  /// Fetches up to [count] (default 20) fresh male candidates speaking [femaleLanguage].
  /// Uses indexed `orderByChild('timestamp')` and performs an in-memory random shuffle.
  Future<List<Map<String, dynamic>>> fetchShuffledMales({
    required String femaleLanguage,
    int count = 20,
  }) async {
    final effectiveLang = femaleLanguage.isNotEmpty ? femaleLanguage : 'Hindi';

    try {
      final snap = await _generalBucketsRef
          .child(effectiveLang)
          .orderByChild('timestamp')
          .limitToLast(60)
          .get();

      if (!snap.exists || snap.value == null) {
        return [];
      }

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      final list = <Map<String, dynamic>>[];

      for (final entry in raw.entries) {
        if (entry.value is Map) {
          final data = Map<String, dynamic>.from(entry.value as Map);
          list.add(data);
        }
      }

      // Random shuffle so each time the screen loads/refreshes, a fresh combination appears
      list.shuffle();

      if (list.length > count) {
        return list.sublist(0, count);
      }
      return list;
    } catch (e) {
      debugPrint('[GeneralFeedService] Error fetching shuffled males for [$effectiveLang]: $e');
      return [];
    }
  }
}

