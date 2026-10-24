import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'user_database_service.dart';

class LocalChatDatabase {
  static final LocalChatDatabase instance = LocalChatDatabase._init();
  static Database? _database;

  // We use a StreamController to broadcast changes to listeners (like the ChatListScreen)
  final StreamController<void> _updateController = StreamController<void>.broadcast();

  Stream<void> get updates => _updateController.stream;

  LocalChatDatabase._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('chat_database.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getApplicationDocumentsDirectory();
    final path = join(dbPath.path, filePath);

    return await openDatabase(
      path,
      version: 6, // Upgraded for deductedAmount in call_logs and chat_transactions table
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE call_logs (
              logId TEXT PRIMARY KEY,
              callerId TEXT NOT NULL,
              receiverId TEXT NOT NULL,
              durationSeconds INTEGER NOT NULL,
              status TEXT NOT NULL,
              timestamp INTEGER NOT NULL
            )
          ''');
          await db.execute('CREATE INDEX idx_call_timestamp ON call_logs (timestamp DESC)');
        }
        if (oldVersion < 3) {
          try {
            await db.execute('ALTER TABLE call_logs ADD COLUMN otherUserName TEXT');
          } catch (e) {
            debugPrint('Error altering call_logs table: $e');
          }
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE user_profiles (
              uid TEXT PRIMARY KEY,
              name TEXT,
              avatarUrl TEXT,
              avatarIndex INTEGER,
              role TEXT,
              timestamp INTEGER
            )
          ''');
        }
        if (oldVersion < 5) {
          try {
            await db.execute('ALTER TABLE messages ADD COLUMN isEarned INTEGER DEFAULT 0');
          } catch (e) {
            debugPrint('Error altering messages table: $e');
          }
        }
        if (oldVersion < 6) {
          try {
            await db.execute('ALTER TABLE call_logs ADD COLUMN deductedAmount REAL DEFAULT 0.0');
          } catch (e) {
            debugPrint('Error adding deductedAmount to call_logs table: $e');
          }
          try {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS chat_transactions (
                txId TEXT PRIMARY KEY,
                userId TEXT NOT NULL,
                otherUid TEXT NOT NULL,
                otherUserName TEXT,
                otherAvatarUrl TEXT,
                otherAvatarIndex INTEGER,
                amount REAL NOT NULL,
                timestamp INTEGER NOT NULL
              )
            ''');
            await db.execute('CREATE INDEX IF NOT EXISTS idx_chat_tx_timestamp ON chat_transactions (timestamp DESC)');
          } catch (e) {
            debugPrint('Error creating chat_transactions table: $e');
          }
        }
      },
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE messages (
        msgId TEXT PRIMARY KEY,
        roomId TEXT NOT NULL,
        senderId TEXT NOT NULL,
        text TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        status INTEGER NOT NULL,
        isEarned INTEGER DEFAULT 0
      )
    ''');
    // Index to speed up roomId queries
    await db.execute('CREATE INDEX idx_roomId ON messages (roomId)');

    await db.execute('''
      CREATE TABLE call_logs (
        logId TEXT PRIMARY KEY,
        callerId TEXT NOT NULL,
        receiverId TEXT NOT NULL,
        durationSeconds INTEGER NOT NULL,
        status TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        otherUserName TEXT,
        deductedAmount REAL DEFAULT 0.0
      )
    ''');
    await db.execute('CREATE INDEX idx_call_timestamp ON call_logs (timestamp DESC)');

    await db.execute('''
      CREATE TABLE user_profiles (
        uid TEXT PRIMARY KEY,
        name TEXT,
        avatarUrl TEXT,
        avatarIndex INTEGER,
        role TEXT,
        timestamp INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE chat_transactions (
        txId TEXT PRIMARY KEY,
        userId TEXT NOT NULL,
        otherUid TEXT NOT NULL,
        otherUserName TEXT,
        otherAvatarUrl TEXT,
        otherAvatarIndex INTEGER,
        amount REAL NOT NULL,
        timestamp INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_chat_tx_timestamp ON chat_transactions (timestamp DESC)');
  }

  // Generate a deterministic room ID using double-underscore separator
  // so UIDs that contain underscores are not split incorrectly.
  static String generateRoomId(String uid1, String uid2) {
    final users = [uid1, uid2];
    users.sort();
    return users.join('__');
  }

  // Extract other user ID from room ID
  static String getOtherUserIdFromRoomId(String roomId, String myUid) {
    // Split on double-underscore only
    final parts = roomId.split('__');
    if (parts.length == 2) {
      return parts[0] == myUid ? parts[1] : parts[0];
    }
    // Legacy fallback: single underscore (old room IDs)
    final idx = roomId.indexOf(myUid);
    if (idx == 0) {
      // myUid is at the start, other is after myUid + '_'
      final rest = roomId.substring(myUid.length);
      if (rest.startsWith('_')) return rest.substring(1);
    } else if (idx > 0) {
      // myUid is at the end
      final rest = roomId.substring(0, idx);
      if (rest.endsWith('_')) return rest.substring(0, rest.length - 1);
    }
    return '';
  }

  // ==== USER PROFILES CACHE & ONLINE FALLBACK ====
  Future<Map<String, dynamic>?> getUserProfile(String uid) async {
    if (uid.isEmpty) return null;
    final db = await instance.database;
    final result = await db.query(
      'user_profiles',
      where: 'uid = ?',
      whereArgs: [uid],
    );
    if (result.isNotEmpty) {
      return result.first;
    }
    return null;
  }

  /// Retrieves profile from local cache. If missing or if avatarUrl is empty/null,
  /// fetches fresh data from online (RTDB/Firestore) and saves back into local cache!
  Future<Map<String, dynamic>> getEnrichedProfile(String uid, {String defaultRole = 'expert'}) async {
    if (uid.isEmpty) {
      return {'uid': uid, 'name': uid, 'avatarUrl': null, 'avatarIndex': 1, 'role': defaultRole};
    }

    // 1. Try local cache first
    try {
      final cached = await getUserProfile(uid);
      final cachedAvatar = cached?['avatarUrl']?.toString().trim();
      final cachedName = cached?['name']?.toString().trim();

      // If local cache has both a valid name and a non-empty avatarUrl, return immediately!
      if (cached != null &&
          cachedAvatar != null &&
          cachedAvatar.isNotEmpty &&
          cachedName != null &&
          cachedName.isNotEmpty &&
          cachedName != uid) {
        return Map<String, dynamic>.from(cached);
      }
    } catch (e) {
      debugPrint('[LocalChatDatabase] Error reading profile cache for $uid: $e');
    }

    // 2. If avatarUrl was null/empty or local profile was missing: FETCH FROM ONLINE!
    try {
      Map<String, dynamic>? onlineData;
      if (defaultRole == 'expert') {
        onlineData = await UserDatabaseService.instance.getExpert(uid);
        onlineData ??= await UserDatabaseService.instance.getUser(uid);
      } else {
        onlineData = await UserDatabaseService.instance.getUser(uid);
        onlineData ??= await UserDatabaseService.instance.getExpert(uid);
      }

      if (onlineData != null) {
        String resolvedName = (onlineData['nickname'] ??
                onlineData['name'] ??
                onlineData['displayName'] ??
                onlineData['fullName'] ??
                uid)
            .toString()
            .trim();
        if (resolvedName.isEmpty) resolvedName = uid;

        String? resolvedAvatar = (onlineData['profileImageUrl'] ??
                onlineData['avatarUrl'] ??
                onlineData['photoUrl'])
            ?.toString()
            .trim();
        if (resolvedAvatar != null && resolvedAvatar.isEmpty) resolvedAvatar = null;

        int resolvedIndex = (onlineData['avatarIndex'] as num?)?.toInt() ?? 1;
        String resolvedRole = onlineData['role']?.toString().trim() ?? defaultRole;

        final profileMap = {
          'uid': uid,
          'name': resolvedName,
          'avatarUrl': resolvedAvatar,
          'avatarIndex': resolvedIndex,
          'role': resolvedRole,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        };

        // 3. STORE IN LOCAL STORAGE AGAIN!
        await saveUserProfile(profileMap);

        return profileMap;
      }
    } catch (e) {
      debugPrint('[LocalChatDatabase] Error fetching online profile fallback for $uid: $e');
    }

    // 4. Return whatever local cache had (or fallback defaults)
    final fallbackCached = await getUserProfile(uid);
    if (fallbackCached != null) {
      return Map<String, dynamic>.from(fallbackCached);
    }

    return {
      'uid': uid,
      'name': uid,
      'avatarUrl': null,
      'avatarIndex': 1,
      'role': defaultRole,
    };
  }

  Future<void> saveUserProfile(Map<String, dynamic> profile) async {
    final db = await instance.database;
    await db.insert(
      'user_profiles',
      profile,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
  // ============================

  Future<void> saveMessageLocally(Map<String, dynamic> message) async {
    final db = await instance.database;
    final row = Map<String, dynamic>.from(message);
    if (!row.containsKey('isEarned')) {
      row['isEarned'] = 0;
    }
    await db.insert(
      'messages',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _updateController.add(null);
  }

  Future<void> updateMessageStatus(String msgId, int newStatus) async {
    final db = await instance.database;
    await db.update(
      'messages',
      {'status': newStatus},
      where: 'msgId = ? AND status < ?',
      whereArgs: [msgId, newStatus],
    );
    _updateController.add(null);
  }

  Future<List<Map<String, dynamic>>> fetchChatHistory(String roomId) async {
    final db = await instance.database;
    return await db.query(
      'messages',
      where: 'roomId = ?',
      whereArgs: [roomId],
      orderBy: 'timestamp ASC',
    );
  }

  Future<List<Map<String, dynamic>>> getUnreadMessages(String roomId, String senderId) async {
    final db = await instance.database;
    return await db.query(
      'messages',
      where: 'roomId = ? AND senderId = ? AND status < 3',
      whereArgs: [roomId, senderId],
    );
  }

  Future<int> getTotalUnreadCount(String myUid) async {
    final db = await instance.database;
    final result = await db.rawQuery('''
      SELECT COUNT(*) as total
      FROM messages
      WHERE senderId != ? AND status < 3
    ''', [myUid]);
    if (result.isNotEmpty) {
      return (result.first['total'] as int?) ?? 0;
    }
    return 0;
  }

  // getRecentChats for ChatListScreen
  Future<List<Map<String, dynamic>>> getRecentChats(String myUid) async {
    final db = await instance.database;
    
    // Query to get the latest message for each room, plus count unread messages from the OTHER person
    final List<Map<String, dynamic>> result = await db.rawQuery('''
      SELECT 
        m1.roomId,
        m1.text as lastMessage,
        m1.timestamp,
        m1.senderId as lastSenderId,
        (
          SELECT COUNT(*) 
          FROM messages m2 
          WHERE m2.roomId = m1.roomId 
            AND m2.senderId != ? 
            AND m2.status < 3
        ) as unreadCount
      FROM messages m1
      INNER JOIN (
          SELECT roomId, MAX(timestamp) as maxTime
          FROM messages
          GROUP BY roomId
      ) grouped_m ON m1.roomId = grouped_m.roomId AND m1.timestamp = grouped_m.maxTime
      ORDER BY m1.timestamp DESC
    ''', [myUid]);

    // Enhance the result with otherUserId
    return result.map((row) {
      final mutableRow = Map<String, dynamic>.from(row);
      mutableRow['otherUserId'] = getOtherUserIdFromRoomId(row['roomId'] as String, myUid);
      return mutableRow;
    }).toList();
  }

  Future<void> saveCallLogLocally(Map<String, dynamic> log) async {
    final db = await instance.database;
    await db.insert(
      'call_logs',
      log,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Auto-prune phone SQLite: keep maximum 30 calls per user as requested
    final callerId = log['callerId']?.toString() ?? '';
    final receiverId = log['receiverId']?.toString() ?? '';
    if (callerId.isNotEmpty) {
      await _pruneLocalCallLogs(callerId, 30);
    }
    if (receiverId.isNotEmpty && receiverId != callerId) {
      await _pruneLocalCallLogs(receiverId, 30);
    }

    _updateController.add(null);
  }

  Future<void> _pruneLocalCallLogs(String uid, int maxKeep) async {
    try {
      final db = await instance.database;
      final rows = await db.query(
        'call_logs',
        columns: ['logId'],
        where: 'callerId = ? OR receiverId = ?',
        whereArgs: [uid, uid],
        orderBy: 'timestamp DESC',
      );
      if (rows.length > maxKeep) {
        final toDelete = rows.sublist(maxKeep).map((r) => r['logId'] as String).toList();
        final placeholders = List.filled(toDelete.length, '?').join(',');
        await db.delete(
          'call_logs',
          where: 'logId IN ($placeholders)',
          whereArgs: toDelete,
        );
      }
    } catch (e) {
      debugPrint('Error pruning local call logs for $uid: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getRecentCallLogs(String myId) async {
    final db = await instance.database;
    return await db.query(
      'call_logs',
      where: 'callerId = ? OR receiverId = ?',
      whereArgs: [myId, myId],
      orderBy: 'timestamp DESC',
      limit: 30,
    );
  }

  Future<void> clearCallLogs(String myId) async {
    final db = await instance.database;
    await db.delete(
      'call_logs',
      where: 'callerId = ? OR receiverId = ?',
      whereArgs: [myId, myId],
    );
    _updateController.add(null);
  }

  // ==== CHAT TRANSACTIONS LOCAL STORAGE ====

  Future<void> saveChatTransactionLocally(Map<String, dynamic> tx) async {
    final db = await instance.database;
    await db.insert(
      'chat_transactions',
      tx,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Auto-prune phone SQLite: maximum 30 chat transactions in local storage
    final userId = tx['userId']?.toString() ?? '';
    if (userId.isNotEmpty) {
      await _pruneLocalChatTransactions(userId, 30);
    }

    _updateController.add(null);
  }

  Future<void> _pruneLocalChatTransactions(String userId, int maxKeep) async {
    try {
      final db = await instance.database;
      final rows = await db.query(
        'chat_transactions',
        columns: ['txId'],
        where: 'userId = ?',
        whereArgs: [userId],
        orderBy: 'timestamp DESC',
      );
      if (rows.length > maxKeep) {
        final toDelete = rows.sublist(maxKeep).map((r) => r['txId'] as String).toList();
        final placeholders = List.filled(toDelete.length, '?').join(',');
        await db.delete(
          'chat_transactions',
          where: 'txId IN ($placeholders)',
          whereArgs: toDelete,
        );
      }
    } catch (e) {
      debugPrint('Error pruning local chat transactions for $userId: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getRecentChatTransactions(String userId) async {
    final db = await instance.database;
    return await db.query(
      'chat_transactions',
      where: 'userId = ?',
      whereArgs: [userId],
      orderBy: 'timestamp DESC',
      limit: 30,
    );
  }

  Future<void> syncChatTransactionsFromRtdb(String myId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasSynced = prefs.getBool('has_synced_chat_tx_$myId') ?? false;
      if (hasSynced) return;

      final rtdbTx = await UserDatabaseService.instance.getUserChatTransactions(myId, limit: 5);
      if (rtdbTx.isNotEmpty) {
        final db = await instance.database;
        final batch = db.batch();
        for (var data in rtdbTx) {
          batch.insert(
            'chat_transactions',
            {
              'txId': data['txId'] ?? '',
              'userId': data['userId'] ?? myId,
              'otherUid': data['otherUid'] ?? '',
              'otherUserName': data['otherUserName'] ?? '',
              'otherAvatarUrl': data['otherAvatarUrl'],
              'otherAvatarIndex': (data['otherAvatarIndex'] as num?)?.toInt() ?? 1,
              'amount': (data['amount'] as num?)?.toDouble() ?? 0.50,
              'timestamp': data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        _updateController.add(null);
        await prefs.setBool('has_synced_chat_tx_$myId', true);
      }
    } catch (e) {
      debugPrint('Error syncing chat transactions: $e');
    }
  }

  // ==========================================

  // Sync last 10 call logs from RTDB (Fallback to Firestore if empty)
  Future<void> syncCallLogsFromFirestore(String myId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasSynced = prefs.getBool('has_synced_call_logs_$myId') ?? false;

      if (hasSynced) {
        return; // Already synced once
      }

      // 1. Try new RTDB user_call_logs (Capped at 10)
      final rtdbLogs = await UserDatabaseService.instance.getUserCallLogs(myId, limit: 10);
      if (rtdbLogs.isNotEmpty) {
        final db = await instance.database;
        final batch = db.batch();
        for (var data in rtdbLogs) {
          batch.insert(
            'call_logs',
            {
              'logId': data['logId'] ?? '',
              'callerId': data['callerId'] ?? '',
              'receiverId': data['receiverId'] ?? '',
              'durationSeconds': data['durationSeconds'] ?? 0,
              'status': data['status'] ?? 'unknown',
              'timestamp': data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
              'otherUserName': data['otherUserName'] ?? '',
              'deductedAmount': (data['deductedAmount'] as num?)?.toDouble() ?? 0.0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        _updateController.add(null);
        await prefs.setBool('has_synced_call_logs_$myId', true);
        return;
      }

      // 2. Fallback to Firestore call_logs
      final snapshot = await FirebaseFirestore.instance
          .collection('call_logs')
          .where(Filter.or(
            Filter('callerId', isEqualTo: myId),
            Filter('receiverId', isEqualTo: myId),
          ))
          .orderBy('timestamp', descending: true)
          .limit(30)
          .get();

      if (snapshot.docs.isNotEmpty) {
        final db = await instance.database;
        final batch = db.batch();
        for (var doc in snapshot.docs) {
          final data = doc.data();
          batch.insert(
            'call_logs',
            {
              'logId': doc.id,
              'callerId': data['callerId'] ?? '',
              'receiverId': data['receiverId'] ?? '',
              'durationSeconds': data['durationSeconds'] ?? 0,
              'status': data['status'] ?? 'unknown',
              'timestamp': data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
              'otherUserName': data['otherUserName'] ?? '',
              'deductedAmount': (data['deductedAmount'] as num?)?.toDouble() ?? 0.0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
        _updateController.add(null);
      }
      
      // Mark as synced
      await prefs.setBool('has_synced_call_logs_$myId', true);
    } catch (e) {
      debugPrint('Error syncing call logs: $e');
    }
  }

  Future<void> close() async {
    final db = await instance.database;
    db.close();
  }
}
