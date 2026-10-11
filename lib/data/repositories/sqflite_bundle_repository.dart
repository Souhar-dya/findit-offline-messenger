import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../core/protocol/envelope.dart';
import '../../domain/entities/stored_bundle.dart';
import '../../domain/entities/tombstone.dart';
import '../../domain/repositories/bundle_repository.dart';
import '../db/app_database.dart';

/// SQLite-backed [BundleRepository]: the store-carry-forward queue.
class SqfliteBundleRepository implements BundleRepository {
  SqfliteBundleRepository(this._database);

  final AppDatabase _database;

  @override
  Future<bool> insertIfAbsent(StoredBundle bundle) async {
    final db = await _database.database;
    final rowId = await db.insert('bundles', {
      'bundle_id': bundle.bundleIdHex,
      'type': bundle.type.wire,
      'recipient_id': bundle.recipientId,
      'expires_at_ms': bundle.expiresAtMs,
      'stored_at_ms': bundle.storedAtMs,
      'size_bytes': bundle.sizeBytes,
      'payload': bundle.bytes,
      'replication_count': bundle.replicationCount,
      'source_peer_id': bundle.sourcePeerId,
      'last_forwarded_at_ms': bundle.lastForwardedAtMs,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return rowId != 0;
  }

  @override
  Future<StoredBundle?> find(String bundleIdHex) async {
    final db = await _database.database;
    final rows = await db.query(
      'bundles',
      where: 'bundle_id = ?',
      whereArgs: [bundleIdHex],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final forwards = await db.query(
      'bundle_forwards',
      columns: ['peer_id'],
      where: 'bundle_id = ?',
      whereArgs: [bundleIdHex],
    );
    final forwarded = {for (final row in forwards) row['peer_id'] as String};
    return _fromRow(rows.first, forwarded);
  }

  @override
  Future<bool> exists(String bundleIdHex) async {
    final db = await _database.database;
    final rows = await db.query(
      'bundles',
      columns: ['bundle_id'],
      where: 'bundle_id = ?',
      whereArgs: [bundleIdHex],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<List<StoredBundle>> claimForwardable({
    required int nowMs,
    required int replicationBudget,
    String? peerId,
    int limit = 50,
  }) async {
    final db = await _database.database;
    final where = <String>[
      'b.expires_at_ms > ?',
      'b.replication_count < ?',
      'NOT EXISTS (SELECT 1 FROM message_tombstones t WHERE t.bundle_id = b.bundle_id)',
      if (peerId != null)
        'NOT EXISTS (SELECT 1 FROM bundle_forwards f WHERE f.bundle_id = b.bundle_id AND f.peer_id = ?)',
    ];
    final args = <Object?>[nowMs, replicationBudget, ?peerId];
    final rows = await db.rawQuery(
      '''
      SELECT b.* FROM bundles b
      WHERE ${where.join(' AND ')}
      ORDER BY (CASE b.type WHEN 'msg' THEN 0 ELSE 1 END) ASC, b.expires_at_ms ASC
      LIMIT ?
      ''',
      [...args, limit],
    );
    return rows.map((row) => _fromRow(row, const {})).toList();
  }

  @override
  Future<void> recordForwarded(
    String bundleIdHex,
    String peerId,
    int nowMs, {
    required int replicationBudget,
  }) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.insert('bundle_forwards', {
        'bundle_id': bundleIdHex,
        'peer_id': peerId,
        'forwarded_at_ms': nowMs,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await txn.rawUpdate(
        '''
        UPDATE bundles
        SET replication_count = (
              SELECT COUNT(*) FROM bundle_forwards f WHERE f.bundle_id = bundles.bundle_id
            ),
            last_forwarded_at_ms = ?
        WHERE bundle_id = ?
        ''',
        [nowMs, bundleIdHex],
      );
    });
  }

  @override
  Future<void> delete(String bundleIdHex) async {
    final db = await _database.database;
    await db.delete(
      'bundles',
      where: 'bundle_id = ?',
      whereArgs: [bundleIdHex],
    );
  }

  @override
  Future<int> deleteRelayedBundles() async {
    final db = await _database.database;
    // Bundles we originated have a null source_peer_id; anything with a source
    // was received from a peer, i.e. carried for someone else.
    return db.delete('bundles', where: 'source_peer_id IS NOT NULL');
  }

  @override
  Future<int> totalBytes() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(size_bytes), 0) AS total FROM bundles',
    );
    return (rows.first['total'] as int?) ?? 0;
  }

  @override
  Future<int> expireBundles(int nowMs, int tombstoneExpiresAtMs) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final expired = await txn.query(
        'bundles',
        columns: ['bundle_id'],
        where: 'expires_at_ms <= ?',
        whereArgs: [nowMs],
      );
      for (final row in expired) {
        await txn.insert('message_tombstones', {
          'bundle_id': row['bundle_id'] as String,
          'reason': TombstoneReason.expired.wire,
          'created_at_ms': nowMs,
          'expires_at_ms': tombstoneExpiresAtMs,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return txn.delete(
        'bundles',
        where: 'expires_at_ms <= ?',
        whereArgs: [nowMs],
      );
    });
  }

  @override
  Future<void> addTombstone(MessageTombstone tombstone) async {
    final db = await _database.database;
    await db.insert('message_tombstones', {
      'bundle_id': tombstone.bundleIdHex,
      'reason': tombstone.reason.wire,
      'created_at_ms': tombstone.createdAtMs,
      'expires_at_ms': tombstone.expiresAtMs,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  @override
  Future<bool> hasTombstone(String bundleIdHex) async {
    final db = await _database.database;
    final rows = await db.query(
      'message_tombstones',
      columns: ['bundle_id'],
      where: 'bundle_id = ?',
      whereArgs: [bundleIdHex],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> pruneTombstones(int nowMs, {required int maxCount}) async {
    final db = await _database.database;
    await db.delete(
      'message_tombstones',
      where: 'expires_at_ms <= ?',
      whereArgs: [nowMs],
    );
    await db.rawDelete(
      '''
      DELETE FROM message_tombstones
      WHERE bundle_id IN (
        SELECT bundle_id FROM message_tombstones
        ORDER BY created_at_ms DESC
        LIMIT -1 OFFSET ?
      )
      ''',
      [maxCount],
    );
  }

  @override
  Future<void> upsertPendingTransfer({
    required String transferId,
    required String peerId,
    required int receivedBytes,
    required int totalBytes,
    required int updatedAtMs,
  }) async {
    final db = await _database.database;
    await db.insert('pending_transfers', {
      'transfer_id': transferId,
      'peer_id': peerId,
      'received_bytes': receivedBytes,
      'total_bytes': totalBytes,
      'updated_at_ms': updatedAtMs,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> deletePendingTransfer(String transferId) async {
    final db = await _database.database;
    await db.delete(
      'pending_transfers',
      where: 'transfer_id = ?',
      whereArgs: [transferId],
    );
  }

  @override
  Future<int> countPendingTransfers() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM pending_transfers',
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  StoredBundle _fromRow(Map<String, Object?> row, Set<String> forwarded) {
    final payload = row['payload'] as List<int>;
    return StoredBundle(
      bundleIdHex: row['bundle_id'] as String,
      type: EnvelopeType.fromWire(row['type'] as String),
      recipientId: row['recipient_id'] as String,
      expiresAtMs: row['expires_at_ms'] as int,
      storedAtMs: row['stored_at_ms'] as int,
      sizeBytes: row['size_bytes'] as int,
      bytes: Uint8List.fromList(payload),
      replicationCount: row['replication_count'] as int,
      sourcePeerId: row['source_peer_id'] as String?,
      lastForwardedAtMs: row['last_forwarded_at_ms'] as int?,
      forwardedPeerIds: forwarded,
    );
  }
}
