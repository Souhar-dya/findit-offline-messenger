import 'package:sqflite/sqflite.dart';

import '../../domain/entities/friend.dart';
import '../../domain/entities/friend_request.dart';
import '../../domain/repositories/friend_repository.dart';
import '../db/app_database.dart';

/// SQLite-backed [FriendRepository].
class SqfliteFriendRepository implements FriendRepository {
  SqfliteFriendRepository(this._database);

  final AppDatabase _database;

  @override
  Future<void> upsertFriend(FriendRecord friend) async {
    final db = await _database.database;
    await db.insert('friends', {
      'peer_id': friend.peerId,
      'display_name': friend.displayName,
      'status': friend.status.wire,
      'created_at_ms': friend.createdAtMs,
      'verified_ms': friend.verifiedAtMs,
      'last_seen_ms': friend.lastSeenAtMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<FriendRecord?> findFriend(String peerId) async {
    final db = await _database.database;
    final rows = await db.query(
      'friends',
      where: 'peer_id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  @override
  Future<List<FriendRecord>> allFriends() async {
    final db = await _database.database;
    final rows = await db.query('friends', orderBy: 'created_at_ms DESC');
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<FriendRecord>> acceptedFriends() async {
    final db = await _database.database;
    final rows = await db.query(
      'friends',
      where: 'status = ?',
      whereArgs: [FriendStatus.accepted.wire],
      orderBy: 'display_name ASC',
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<FriendRecord> acceptFriend(String peerId, int verifiedAtMs) async {
    final db = await _database.database;
    await db.update(
      'friends',
      {'status': FriendStatus.accepted.wire, 'verified_ms': verifiedAtMs},
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
    final friend = await findFriend(peerId);
    if (friend == null) {
      throw StateError('Cannot accept a friendship that does not exist');
    }
    return friend;
  }

  @override
  Future<void> deleteFriend(String peerId) async {
    final db = await _database.database;
    await db.delete('friends', where: 'peer_id = ?', whereArgs: [peerId]);
  }

  @override
  Future<bool> insertRequest(FriendRequestRecord request) async {
    final db = await _database.database;
    final rowId = await db.insert('friend_requests', {
      'request_id': request.requestId,
      'from_id': request.fromId,
      'to_id': request.toId,
      'direction': request.direction.name,
      'state': request.state.wire,
      'protocol_version': request.protocolVersion,
      'created_at_ms': request.createdAtMs,
      'expires_at_ms': request.expiresAtMs,
      'peer_display_name': request.peerDisplayName,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return rowId != 0;
  }

  @override
  Future<FriendRequestRecord?> findRequest(String requestId) async {
    final db = await _database.database;
    final rows = await db.query(
      'friend_requests',
      where: 'request_id = ?',
      whereArgs: [requestId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRequestRow(rows.first);
  }

  @override
  Future<FriendRequestRecord?> findPendingRequest({
    required String fromId,
    required String toId,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'friend_requests',
      where: 'from_id = ? AND to_id = ? AND state = ?',
      whereArgs: [fromId, toId, FriendRequestState.pending.wire],
      orderBy: 'created_at_ms DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRequestRow(rows.first);
  }

  @override
  Future<List<FriendRequestRecord>> pendingRequestsBetween(
    String a,
    String b,
  ) async {
    final db = await _database.database;
    final rows = await db.query(
      'friend_requests',
      where:
          'state = ? AND ((from_id = ? AND to_id = ?) OR (from_id = ? AND to_id = ?))',
      whereArgs: [FriendRequestState.pending.wire, a, b, b, a],
    );
    return rows.map(_fromRequestRow).toList();
  }

  @override
  Future<List<FriendRequestRecord>> allRequests() async {
    final db = await _database.database;
    final rows = await db.query(
      'friend_requests',
      orderBy: 'created_at_ms DESC',
    );
    return rows.map(_fromRequestRow).toList();
  }

  @override
  Future<List<FriendRequestRecord>> requestsForPeer(String peerId) async {
    final db = await _database.database;
    final rows = await db.query(
      'friend_requests',
      where: 'from_id = ? OR to_id = ?',
      whereArgs: [peerId, peerId],
      orderBy: 'created_at_ms DESC',
    );
    return rows.map(_fromRequestRow).toList();
  }

  @override
  Future<void> updateRequestState(
    String requestId,
    FriendRequestState state,
  ) async {
    final db = await _database.database;
    await db.update(
      'friend_requests',
      {'state': state.wire},
      where: 'request_id = ?',
      whereArgs: [requestId],
    );
  }

  @override
  Future<void> deleteRequest(String requestId) async {
    final db = await _database.database;
    await db.delete(
      'friend_requests',
      where: 'request_id = ?',
      whereArgs: [requestId],
    );
  }

  @override
  Future<int> expireRequests(int nowMs) async {
    final db = await _database.database;
    return db.update(
      'friend_requests',
      {'state': FriendRequestState.expired.wire},
      where: 'state = ? AND expires_at_ms <= ?',
      whereArgs: [FriendRequestState.pending.wire, nowMs],
    );
  }

  @override
  Future<void> setBlocked(
    String identityId, {
    required bool blocked,
    required int nowMs,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      if (blocked) {
        await txn.insert('blocked_identities', {
          'identity_id': identityId,
          'blocked_at_ms': nowMs,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.update(
          'friends',
          {'status': FriendStatus.blocked.wire},
          where: 'peer_id = ?',
          whereArgs: [identityId],
        );
      } else {
        await txn.delete(
          'blocked_identities',
          where: 'identity_id = ?',
          whereArgs: [identityId],
        );
        // Blocking changes the visible friend status. Restore an accepted
        // status on unblock so the contact is usable again; non-contact block
        // entries have no friends row and are unaffected.
        await txn.update(
          'friends',
          {'status': FriendStatus.accepted.wire},
          where: 'peer_id = ? AND status = ?',
          whereArgs: [identityId, FriendStatus.blocked.wire],
        );
      }
    });
  }

  @override
  Future<bool> isBlocked(String identityId) async {
    final db = await _database.database;
    final rows = await db.query(
      'blocked_identities',
      where: 'identity_id = ?',
      whereArgs: [identityId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<List<String>> blockedIds() async {
    final db = await _database.database;
    final rows = await db.query('blocked_identities', columns: ['identity_id']);
    return rows.map((row) => row['identity_id'] as String).toList();
  }

  FriendRecord _fromRow(Map<String, Object?> row) => FriendRecord(
    peerId: row['peer_id'] as String,
    displayName: row['display_name'] as String,
    status: FriendStatus.fromWire(row['status'] as String),
    createdAtMs: row['created_at_ms'] as int,
    verifiedAtMs: row['verified_ms'] as int?,
    lastSeenAtMs: row['last_seen_ms'] as int?,
  );

  FriendRequestRecord _fromRequestRow(Map<String, Object?> row) =>
      FriendRequestRecord(
        requestId: row['request_id'] as String,
        fromId: row['from_id'] as String,
        toId: row['to_id'] as String,
        direction: FriendRequestDirection.values.firstWhere(
          (value) => value.name == row['direction'],
        ),
        state: FriendRequestState.fromWire(row['state'] as String),
        protocolVersion: row['protocol_version'] as int,
        createdAtMs: row['created_at_ms'] as int,
        expiresAtMs: row['expires_at_ms'] as int,
        peerDisplayName: row['peer_display_name'] as String?,
      );
}
