import 'dart:typed_data';

import '../../crypto/identity_record.dart';
import '../../domain/entities/known_identity.dart';
import '../../domain/repositories/identity_repository.dart';
import '../db/app_database.dart';

/// SQLite-backed [IdentityRepository].
class SqfliteIdentityRepository implements IdentityRepository {
  SqfliteIdentityRepository(this._database);

  final AppDatabase _database;

  @override
  Future<void> upsert(KnownIdentity identity) async {
    final db = await _database.database;
    final existing = await find(identity.identityId);
    if (existing != null && existing.isLocal && !identity.isLocal) {
      // A local identity record is authoritative and is never overwritten by a
      // record claimed by another peer. Only presence metadata is refreshed.
      await touch(
        identity.identityId,
        identity.lastSeenMs ?? identity.firstSeenMs,
      );
      return;
    }
    await db.rawInsert(
      '''
      INSERT INTO identities (
        identity_id, display_name, format_version, key_version,
        signing_public_key, agreement_public_key, signature, is_local,
        first_seen_ms, last_seen_ms, verified_ms
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(identity_id) DO UPDATE SET
        display_name = excluded.display_name,
        format_version = excluded.format_version,
        key_version = excluded.key_version,
        signing_public_key = excluded.signing_public_key,
        agreement_public_key = excluded.agreement_public_key,
        signature = excluded.signature,
        is_local = excluded.is_local,
        first_seen_ms = excluded.first_seen_ms,
        last_seen_ms = excluded.last_seen_ms,
        verified_ms = excluded.verified_ms
      ''',
      [
        identity.identityId,
        identity.record.displayName,
        identity.record.formatVersion,
        identity.record.keyVersion,
        identity.record.signingPublicKey,
        identity.record.agreementPublicKey,
        identity.record.signature,
        identity.isLocal ? 1 : 0,
        identity.firstSeenMs,
        identity.lastSeenMs,
        identity.verifiedAtMs,
      ],
    );
  }

  @override
  Future<KnownIdentity?> find(String identityId) async {
    final db = await _database.database;
    final rows = await db.query(
      'identities',
      where: 'identity_id = ?',
      whereArgs: [identityId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  @override
  Future<KnownIdentity?> localIdentity() async {
    final db = await _database.database;
    final rows = await db.query('identities', where: 'is_local = 1', limit: 1);
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  @override
  Future<List<KnownIdentity>> allKnown() async {
    final db = await _database.database;
    final rows = await db.query('identities', orderBy: 'first_seen_ms DESC');
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<KnownIdentity>> verifiedIdentities() async {
    final db = await _database.database;
    final rows = await db.query(
      'identities',
      where: 'verified_ms IS NOT NULL',
      orderBy: 'verified_ms DESC',
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<void> touch(String identityId, int nowMs) async {
    final db = await _database.database;
    await db.update(
      'identities',
      {'last_seen_ms': nowMs},
      where: 'identity_id = ?',
      whereArgs: [identityId],
    );
  }

  @override
  Future<void> markVerified(String identityId, int nowMs) async {
    final db = await _database.database;
    await db.update(
      'identities',
      {'verified_ms': nowMs},
      where: 'identity_id = ?',
      whereArgs: [identityId],
    );
  }

  @override
  Future<void> delete(String identityId) async {
    final db = await _database.database;
    await db.delete(
      'identities',
      where: 'identity_id = ? AND is_local = 0',
      whereArgs: [identityId],
    );
  }

  @override
  Future<bool> isReferenced(String identityId) async {
    final db = await _database.database;
    final checks = <List<Object?>>[
      ['SELECT 1 FROM friends WHERE peer_id = ? LIMIT 1', identityId],
      [
        'SELECT 1 FROM friend_requests WHERE from_id = ? OR to_id = ? LIMIT 1',
        identityId,
        identityId,
      ],
      [
        'SELECT 1 FROM messages WHERE sender_id = ? OR recipient_id = ? LIMIT 1',
        identityId,
        identityId,
      ],
      ['SELECT 1 FROM bundles WHERE recipient_id = ? LIMIT 1', identityId],
      [
        'SELECT 1 FROM delivery_receipts WHERE original_sender_id = ? LIMIT 1',
        identityId,
      ],
    ];
    for (final check in checks) {
      final rows = await db.rawQuery(
        check.first! as String,
        check.sublist(1).cast<Object?>(),
      );
      if (rows.isNotEmpty) return true;
    }
    return false;
  }

  @override
  Future<KnownIdentity> storeVerified(
    IdentityRecord record, {
    required int nowMs,
    bool isLocal = false,
  }) async {
    final existing = await find(record.identityId);
    final known = KnownIdentity(
      record: record,
      isLocal: isLocal || (existing?.isLocal ?? false),
      firstSeenMs: existing?.firstSeenMs ?? nowMs,
      lastSeenMs: nowMs,
      verifiedAtMs: nowMs,
    );
    await upsert(known);
    return known;
  }

  KnownIdentity _fromRow(Map<String, Object?> row) {
    final record = IdentityRecord(
      formatVersion: row['format_version'] as int,
      keyVersion: row['key_version'] as int,
      identityId: row['identity_id'] as String,
      signingPublicKey: Uint8List.fromList(
        row['signing_public_key'] as List<int>,
      ),
      agreementPublicKey: Uint8List.fromList(
        row['agreement_public_key'] as List<int>,
      ),
      displayName: row['display_name'] as String,
      signature: Uint8List.fromList(row['signature'] as List<int>),
    );
    return KnownIdentity(
      record: record,
      isLocal: (row['is_local'] as int) == 1,
      firstSeenMs: row['first_seen_ms'] as int,
      lastSeenMs: row['last_seen_ms'] as int?,
      verifiedAtMs: row['verified_ms'] as int?,
    );
  }
}
