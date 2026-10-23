import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../domain/entities/chat_message.dart';
import '../../domain/entities/conversation_summary.dart';
import '../../domain/repositories/message_repository.dart';
import '../db/app_database.dart';

/// SQLite-backed [MessageRepository].
///
/// Deduplication relies on the `message_id` primary key and `INSERT OR IGNORE`
/// inside a transaction, never on a read-then-write race.
class SqfliteMessageRepository implements MessageRepository {
  SqfliteMessageRepository(this._database);

  final AppDatabase _database;

  @override
  Future<bool> insertIfAbsent(ChatMessage message) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final rowId = await txn.insert(
        'messages',
        _toRow(message),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (rowId == 0) return false;
      await _touchConversation(txn, message);
      return true;
    });
  }

  @override
  Future<ChatMessage?> find(String id) async {
    final db = await _database.database;
    final rows = await db.query(
      'messages',
      where: 'message_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  @override
  Future<bool> exists(String id) async {
    final db = await _database.database;
    final rows = await db.query(
      'messages',
      columns: ['message_id'],
      where: 'message_id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> updateStatus(
    String id,
    MessageStatus status, {
    int? deliveredAtMs,
    int? receivedAtMs,
  }) async {
    final db = await _database.database;
    await db.update(
      'messages',
      {
        'status': status.wire,
        'delivered_at_ms': ?deliveredAtMs,
        'received_at_ms': ?receivedAtMs,
      },
      where: 'message_id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> markConversationRead(String peerId, int nowMs) async {
    final db = await _database.database;
    await db.update(
      'messages',
      {'read_at_ms': nowMs},
      where: 'conversation_id = ? AND direction = ? AND read_at_ms IS NULL',
      whereArgs: [peerId, MessageDirection.incoming.name],
    );
  }

  @override
  Future<List<ChatMessage>> conversation(
    String peerId, {
    int limit = 500,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [peerId],
      // Order by the local clock (receive time for inbound, creation time for
      // outbound) so a device whose clock differs can never interleave.
      orderBy: 'COALESCE(received_at_ms, created_at_ms) ASC, created_at_ms ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<ChatMessage>> recentMessages({int limit = 100}) async {
    final db = await _database.database;
    final rows = await db.query(
      'messages',
      orderBy: 'created_at_ms DESC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<ChatMessage>> outboundWithStatus(
    Set<MessageStatus> statuses, {
    int limit = 200,
  }) async {
    if (statuses.isEmpty) return const [];
    final db = await _database.database;
    final placeholders = List.filled(statuses.length, '?').join(', ');
    final rows = await db.query(
      'messages',
      where: 'direction = ? AND status IN ($placeholders)',
      whereArgs: [
        MessageDirection.outgoing.name,
        ...statuses.map((status) => status.wire),
      ],
      orderBy: 'created_at_ms ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<ConversationSummary>> conversations() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT
        c.peer_id                 AS peer_id,
        c.last_message_at_ms      AS last_at,
        c.last_preview            AS preview,
        m.status                  AS last_status,
        COALESCE(f.display_name, i.display_name) AS display_name,
        f.status                  AS friend_status,
        (SELECT COUNT(*) FROM messages mu
           WHERE mu.conversation_id = c.peer_id
             AND mu.direction = 'incoming'
             AND mu.read_at_ms IS NULL)       AS unread
      FROM conversations c
      LEFT JOIN friends f   ON f.peer_id = c.peer_id
      LEFT JOIN identities i ON i.identity_id = c.peer_id
      LEFT JOIN messages m   ON m.message_id = c.last_message_id
      ORDER BY c.last_message_at_ms DESC
    ''');
    return rows.map((row) {
      final peerId = row['peer_id'] as String;
      return ConversationSummary(
        peerId: peerId,
        displayName: (row['display_name'] as String?) ?? _shortId(peerId),
        lastMessageAtMs: (row['last_at'] as int?) ?? 0,
        lastMessagePreview: (row['preview'] as String?) ?? '',
        lastStatus: row['last_status'] == null
            ? MessageStatus.received
            : MessageStatus.fromWire(row['last_status'] as String),
        isFriend: (row['friend_status'] as String?) == 'accepted',
        unreadCount: (row['unread'] as int?) ?? 0,
      );
    }).toList();
  }

  @override
  Future<int> evictOldest(int maxPayloadBytes) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      // Only ids and sizes are read; the blobs themselves never leave SQLite.
      final rows = await txn.rawQuery('''
        SELECT message_id AS id,
               COALESCE(LENGTH(image_bytes), LENGTH(text_content), 0) AS size
        FROM messages
        ORDER BY COALESCE(received_at_ms, created_at_ms) ASC,
                 created_at_ms ASC,
                 message_id ASC
      ''');
      var total = 0;
      for (final row in rows) {
        total += (row['size'] as int?) ?? 0;
      }
      if (total <= maxPayloadBytes) return 0;

      var removed = 0;
      for (final row in rows) {
        if (total <= maxPayloadBytes) break;
        final id = row['id'] as String;
        final size = (row['size'] as int?) ?? 0;
        await txn.delete('messages', where: 'message_id = ?', whereArgs: [id]);
        total -= size;
        removed++;
      }
      return removed;
    });
  }

  @override
  Future<int> totalPayloadBytes() async {
    final db = await _database.database;
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(
        COALESCE(LENGTH(image_bytes), LENGTH(text_content), 0)
      ), 0) AS total FROM messages
    ''');
    return (rows.first['total'] as int?) ?? 0;
  }

  @override
  Future<int> expireMessages(
    int nowMs, {
    required int tombstoneExpiresAtMs,
  }) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final expired = await txn.query(
        'messages',
        columns: ['message_id', 'bundle_id'],
        where: 'direction = ? AND expires_at_ms <= ? AND status NOT IN (?, ?)',
        whereArgs: [
          MessageDirection.outgoing.name,
          nowMs,
          MessageStatus.expired.wire,
          MessageStatus.delivered.wire,
        ],
      );
      if (expired.isEmpty) return 0;
      for (final row in expired) {
        final bundleId = row['bundle_id'] as String?;
        if (bundleId != null) {
          await txn.insert('message_tombstones', {
            'bundle_id': bundleId,
            'reason': 'expired',
            'created_at_ms': nowMs,
            'expires_at_ms': tombstoneExpiresAtMs,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      final count = await txn.update(
        'messages',
        {
          'status': MessageStatus.expired.wire,
          'text_content': null,
          'image_bytes': null,
          'image_hash': null,
          'image_width': null,
          'image_height': null,
          'image_filename': null,
        },
        where: 'direction = ? AND expires_at_ms <= ? AND status NOT IN (?, ?)',
        whereArgs: [
          MessageDirection.outgoing.name,
          nowMs,
          MessageStatus.expired.wire,
          MessageStatus.delivered.wire,
        ],
      );
      return count;
    });
  }

  @override
  Future<int> deleteDisappearingMessages(
    int nowMs, {
    required int tombstoneExpiresAtMs,
  }) async {
    final db = await _database.database;
    return db.transaction((txn) async {
      final expired = await txn.query(
        'messages',
        columns: ['message_id', 'bundle_id', 'conversation_id'],
        where: 'disappears = 1 AND retention_expires_at_ms <= ?',
        whereArgs: [nowMs],
      );
      if (expired.isEmpty) return 0;

      final conversations = <String>{};
      for (final row in expired) {
        final bundleId = row['bundle_id'] as String?;
        if (bundleId != null) {
          await txn.insert('message_tombstones', {
            'bundle_id': bundleId,
            'reason': 'disappeared',
            'created_at_ms': nowMs,
            'expires_at_ms': tombstoneExpiresAtMs,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        conversations.add(row['conversation_id'] as String);
        await txn.delete(
          'messages',
          where: 'message_id = ?',
          whereArgs: [row['message_id']],
        );
      }

      // Keep the chat list preview in sync with the messages that remain.
      for (final peerId in conversations) {
        final lastRows = await txn.query(
          'messages',
          where: 'conversation_id = ?',
          whereArgs: [peerId],
          orderBy: 'COALESCE(received_at_ms, created_at_ms) DESC, created_at_ms DESC',
          limit: 1,
        );
        if (lastRows.isEmpty) {
          await txn.delete(
            'conversations',
            where: 'peer_id = ?',
            whereArgs: [peerId],
          );
          continue;
        }
        final last = lastRows.first;
        final preview = last['payload_type'] == MessagePayloadType.png.wire
            ? 'PNG image'
            : ((last['text_content'] as String?) ?? '');
        final timestamp =
            (last['received_at_ms'] as int?) ??
            (last['created_at_ms'] as int);
        await txn.update(
          'conversations',
          {
            'last_message_id': last['message_id'],
            'last_message_at_ms': timestamp,
            'last_preview': preview,
            'updated_at_ms': timestamp,
          },
          where: 'peer_id = ?',
          whereArgs: [peerId],
        );
      }
      return expired.length;
    });
  }

  @override
  Future<void> delete(String id) async {
    final db = await _database.database;
    await db.delete('messages', where: 'message_id = ?', whereArgs: [id]);
  }

  Future<void> _touchConversation(Transaction txn, ChatMessage message) async {
    final preview = message.payloadType == MessagePayloadType.png
        ? 'PNG image'
        : (message.text ?? '');
    // Use the local observation time so the Chats list orders by the same
    // clock as the conversation itself.
    final observedAt = message.receivedAtMs ?? message.createdAtMs;
    await txn.rawInsert(
      '''
      INSERT INTO conversations(peer_id, last_message_id, last_message_at_ms, last_preview, updated_at_ms)
      VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(peer_id) DO UPDATE SET
        last_message_id = excluded.last_message_id,
        last_message_at_ms = excluded.last_message_at_ms,
        last_preview = excluded.last_preview,
        updated_at_ms = excluded.updated_at_ms
      WHERE excluded.last_message_at_ms >= conversations.last_message_at_ms
      ''',
      [
        message.peerId,
        message.id,
        observedAt,
        preview,
        observedAt,
      ],
    );
  }

  Map<String, Object?> _toRow(ChatMessage message) => {
    'message_id': message.id,
    'bundle_id': message.id,
    'conversation_id': message.peerId,
    'sender_id': message.senderId,
    'recipient_id': message.recipientId,
    'direction': message.direction.name,
    'status': message.status.wire,
    'payload_type': message.payloadType.wire,
    'created_at_ms': message.createdAtMs,
    'expires_at_ms': message.expiresAtMs,
    'disappears': message.disappears ? 1 : 0,
    'retention_expires_at_ms': message.retentionExpiresAtMs,
    'received_at_ms': message.receivedAtMs,
    'delivered_at_ms': message.deliveredAtMs,
    'read_at_ms': message.readAtMs,
    'text_content': message.text,
    'image_bytes': message.imageBytes,
    'image_hash': message.imageContentHashHex,
    'image_width': message.imageWidth,
    'image_height': message.imageHeight,
    'image_filename': message.imageFilename,
  };

  ChatMessage _fromRow(Map<String, Object?> row) {
    final image = row['image_bytes'] as List<int>?;
    return ChatMessage(
      id: row['message_id'] as String,
      senderId: row['sender_id'] as String,
      recipientId: row['recipient_id'] as String,
      peerId: row['conversation_id'] as String,
      direction: MessageDirection.values.firstWhere(
        (value) => value.name == row['direction'],
      ),
      status: MessageStatus.fromWire(row['status'] as String),
      payloadType: MessagePayloadType.fromWire(row['payload_type'] as String),
      createdAtMs: row['created_at_ms'] as int,
      expiresAtMs: row['expires_at_ms'] as int,
      disappears: (row['disappears'] as int? ?? 1) != 0,
      retentionExpiresAtMs: row['retention_expires_at_ms'] as int?,
      receivedAtMs: row['received_at_ms'] as int?,
      deliveredAtMs: row['delivered_at_ms'] as int?,
      readAtMs: row['read_at_ms'] as int?,
      text: row['text_content'] as String?,
      imageBytes: image == null ? null : Uint8List.fromList(image),
      imageContentHashHex: row['image_hash'] as String?,
      imageWidth: row['image_width'] as int?,
      imageHeight: row['image_height'] as int?,
      imageFilename: row['image_filename'] as String?,
    );
  }

  String _shortId(String id) =>
      id.length <= 12 ? id : '${id.substring(0, 10)}…';
}
