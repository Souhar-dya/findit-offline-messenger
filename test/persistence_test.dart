import 'dart:io';
import 'dart:typed_data';

import 'package:findit/crypto/identity_service.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/data/db/app_database.dart';
import 'package:findit/domain/entities/chat_message.dart';
import 'package:findit/domain/entities/delivery_receipt.dart';
import 'package:findit/domain/entities/friend.dart';
import 'package:findit/domain/entities/known_identity.dart';
import 'package:findit/domain/entities/tombstone.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db.dart';
import 'support/harness.dart';

Future<LocalIdentity> newPeer(String name) => IdentityService(
  secretStore: InMemorySecretStore(),
).generate(displayName: name);

void main() {
  group('Schema and migrations', () {
    test('creates the full schema at the current version', () async {
      final directory = Directory.systemTemp.createTempSync('findit-schema-');
      final database = AppDatabase(
        factory: testDatabaseFactory,
        path: p.join(directory.path, 'schema.db'),
      );
      try {
        final db = await database.database;
        final rows = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'table'",
        );
        final tables = {for (final row in rows) row['name'] as String};

        expect(
          tables,
          containsAll(const [
            'identities',
            'friends',
            'friend_requests',
            'conversations',
            'messages',
            'delivery_receipts',
            'message_tombstones',
            'bundles',
            'bundle_forwards',
            'pending_transfers',
            'blocked_identities',
            'rate_limits',
          ]),
        );
        expect(await db.getVersion(), AppDatabase.schemaVersion);

        // Foreign keys must be enabled for the RESTRICT rules to apply.
        final foreignKeys = await db.rawQuery('PRAGMA foreign_keys');
        expect(foreignKeys.single.values.single, 1);
      } finally {
        await database.close();
        directory.deleteSync(recursive: true);
      }
    });

    test('enforces foreign keys', () async {
      final directory = Directory.systemTemp.createTempSync('findit-fk-');
      final database = AppDatabase(
        factory: testDatabaseFactory,
        path: p.join(directory.path, 'fk.db'),
      );
      try {
        final db = await database.database;
        // A friend must reference an existing identity row.
        await expectLater(
          db.insert('friends', {
            'peer_id': 'fid_missing',
            'display_name': 'Ghost',
            'status': 'accepted',
            'created_at_ms': 1,
          }),
          throwsA(isA<DatabaseException>()),
        );
      } finally {
        await database.close();
        directory.deleteSync(recursive: true);
      }
    });

    test('quarantines a corrupt database and recreates it', () async {
      final directory = Directory.systemTemp.createTempSync('findit-corrupt-');
      final path = p.join(directory.path, 'corrupt.db');

      final first = AppDatabase(factory: testDatabaseFactory, path: path);
      await first.database;
      await first.close();

      // Destroy the SQLite header so the file is no longer a valid database.
      final file = File(path);
      final bytes = await file.readAsBytes();
      final corrupted = Uint8List.fromList(bytes);
      for (var i = 0; i < 16 && i < corrupted.length; i++) {
        corrupted[i] = 0x00;
      }
      await file.writeAsBytes(corrupted, flush: true);

      final recovered = AppDatabase(factory: testDatabaseFactory, path: path);
      try {
        final db = await recovered.database;
        final rows = await db.rawQuery(
          'SELECT name FROM sqlite_master WHERE name = ?',
          ['identities'],
        );
        expect(rows, isNotEmpty);

        final backups = directory
            .listSync()
            .where((entity) => p.basename(entity.path).contains('.corrupt-'))
            .toList();
        expect(backups, isNotEmpty);
      } finally {
        await recovered.close();
        directory.deleteSync(recursive: true);
      }
    });
  });

  group('Persistence across restarts', () {
    test('recovers identity, messages and bundles from disk', () async {
      final directory = Directory.systemTemp.createTempSync('findit-restart-');
      final secretStore = InMemorySecretStore();
      final node = await TestNode.create(
        directory: directory,
        databaseName: 'restart',
        secretStore: secretStore,
        autoConnect: false,
      );
      final peer = await newPeer('Peer');
      await node.createIdentity('Alice');
      final identityId = node.id;
      final message = await node.core.messageService.sendText(
        recipient: peer.record,
        text: 'survive',
      );

      final reopened = await node.reopen();
      try {
        final loaded = await reopened.core.loadIdentity();
        expect(loaded, isNotNull);
        expect(loaded!.identityId, identityId);
        expect(reopened.core.identityHolder.identity!.identityId, identityId);

        final restored = await reopened.core.messages.find(message.id);
        expect(restored, isNotNull);
        expect(restored!.text, 'survive');
        expect(await reopened.core.bundles.exists(message.id), isTrue);
      } finally {
        await reopened.dispose();
      }
    });
  });

  group('Maintenance and cleanup', () {
    test('expires messages and bundles and writes tombstones', () async {
      final node = await TestNode.create();
      final peer = await newPeer('Peer');
      await node.createIdentity('Alice');
      try {
        final message = await node.core.messageService.sendText(
          recipient: peer.record,
          text: 'perish',
        );
        node.clock.advance(node.config.messageTtl + const Duration(seconds: 1));

        final report = await node.core.maintenance.runOnce();
        expect(report.messagesExpired, 1);
        expect(report.bundlesExpired, 1);

        final expired = await node.core.messages.find(message.id);
        expect(expired!.status, MessageStatus.expired);
        expect(expired.text, isNull);
        expect(await node.core.bundles.exists(message.id), isFalse);
        expect(await node.core.bundles.hasTombstone(message.id), isTrue);
      } finally {
        await node.dispose();
      }
    });

    test('bounds tombstones and prunes expired ones', () async {
      final node = await TestNode.create();
      await node.createIdentity('Alice');
      try {
        final now = node.clock.now().millisecondsSinceEpoch;
        for (var i = 0; i < 5; i++) {
          await node.core.bundles.addTombstone(
            MessageTombstone(
              bundleIdHex: 'bundle-$i',
              reason: TombstoneReason.expired,
              createdAtMs: now + i,
              expiresAtMs: now + 100000,
            ),
          );
        }
        await node.core.bundles.pruneTombstones(now, maxCount: 2);
        final db = await node.core.database.database;
        final kept = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM message_tombstones',
        );
        expect(kept.single['c'], 2);

        // An expired tombstone is dropped regardless of the configured bound.
        await node.core.bundles.addTombstone(
          MessageTombstone(
            bundleIdHex: 'stale',
            reason: TombstoneReason.expired,
            createdAtMs: now,
            expiresAtMs: now - 1,
          ),
        );
        await node.core.bundles.pruneTombstones(now, maxCount: 100);
        final after = await db.rawQuery(
          'SELECT COUNT(*) AS c FROM message_tombstones',
        );
        expect(after.single['c'], 2);
      } finally {
        await node.dispose();
      }
    });

    test('prunes retained delivery receipts', () async {
      final node = await TestNode.create();
      await node.createIdentity('Alice');
      try {
        final now = node.clock.now().millisecondsSinceEpoch;
        await node.core.receipts.insertIfAbsent(
          DeliveryReceipt(
            messageId: 'msg-1',
            originalSenderId: node.id,
            deliveredById: 'fid_other',
            deliveredAtMs: now,
            signature: Uint8List(64),
            protocolVersion: 1,
          ),
        );
        expect(
          (await node.core.receipts.receiptsForMessage('msg-1')).length,
          1,
        );

        final threshold = DateTime.now().millisecondsSinceEpoch + 1000;
        expect(await node.core.receipts.prune(threshold), 1);
        expect(await node.core.receipts.receiptsForMessage('msg-1'), isEmpty);
      } finally {
        await node.dispose();
      }
    });
  });

  group('Constraints and references', () {
    test('deduplicates messages and protects referenced identities', () async {
      final node = await TestNode.create();
      await node.createIdentity('Alice');
      try {
        final peer = await newPeer('Peer');
        final now = node.clock.now().millisecondsSinceEpoch;
        await node.core.identities.upsert(
          KnownIdentity(
            record: peer.record,
            isLocal: false,
            firstSeenMs: now,
            lastSeenMs: now,
          ),
        );

        const conversationId = 'fid_peer';
        final message = ChatMessage(
          id: 'aabbccddeeff00112233445566778899',
          senderId: node.id,
          recipientId: peer.identityId,
          peerId: conversationId,
          direction: MessageDirection.incoming,
          status: MessageStatus.received,
          payloadType: MessagePayloadType.text,
          createdAtMs: now,
          expiresAtMs: now + 600000,
          text: 'once',
        );
        expect(await node.core.messages.insertIfAbsent(message), isTrue);
        expect(await node.core.messages.insertIfAbsent(message), isFalse);
        expect(
          (await node.core.messages.conversation(conversationId)).length,
          1,
        );

        await node.core.friends.upsertFriend(
          FriendRecord(
            peerId: peer.identityId,
            displayName: peer.displayName,
            status: FriendStatus.accepted,
            createdAtMs: now,
          ),
        );
        // ON DELETE RESTRICT: a referenced identity cannot be removed.
        await expectLater(
          node.core.identities.delete(peer.identityId),
          throwsA(isA<DatabaseException>()),
        );
        expect(await node.core.identities.find(peer.identityId), isNotNull);

        await node.core.friends.deleteFriend(peer.identityId);
        await node.core.identities.delete(peer.identityId);
        expect(await node.core.identities.find(peer.identityId), isNull);

        // The local identity is never deletable through the repository.
        await node.core.identities.delete(node.id);
        expect(await node.core.identities.find(node.id), isNotNull);
      } finally {
        await node.dispose();
      }
    });

    test('tracks incomplete transfers without promoting them', () async {
      final node = await TestNode.create();
      await node.createIdentity('Alice');
      try {
        expect(await node.core.bundles.countPendingTransfers(), 0);
        await node.core.bundles.upsertPendingTransfer(
          transferId: 't1',
          peerId: 'p1',
          receivedBytes: 10,
          totalBytes: 100,
          updatedAtMs: 1,
        );
        await node.core.bundles.upsertPendingTransfer(
          transferId: 't1',
          peerId: 'p1',
          receivedBytes: 40,
          totalBytes: 100,
          updatedAtMs: 2,
        );
        expect(await node.core.bundles.countPendingTransfers(), 1);

        final db = await node.core.database.database;
        final row = (await db.query(
          'pending_transfers',
          where: 'transfer_id = ?',
          whereArgs: ['t1'],
        )).single;
        expect(row['received_bytes'], 40);
        expect(row['received_bytes'], isNot(row['total_bytes']));

        await node.core.bundles.deletePendingTransfer('t1');
        expect(await node.core.bundles.countPendingTransfers(), 0);
      } finally {
        await node.dispose();
      }
    });
  });
}
