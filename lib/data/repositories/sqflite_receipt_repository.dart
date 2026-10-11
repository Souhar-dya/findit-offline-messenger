import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../domain/entities/delivery_receipt.dart';
import '../../domain/repositories/receipt_repository.dart';
import '../db/app_database.dart';

/// SQLite-backed [ReceiptRepository].
class SqfliteReceiptRepository implements ReceiptRepository {
  SqfliteReceiptRepository(this._database);

  final AppDatabase _database;

  @override
  Future<bool> insertIfAbsent(DeliveryReceipt receipt) async {
    final db = await _database.database;
    final rowId = await db.insert('delivery_receipts', {
      'message_id': receipt.messageId,
      'delivered_by_id': receipt.deliveredById,
      'original_sender_id': receipt.originalSenderId,
      'delivered_at_ms': receipt.deliveredAtMs,
      'signature': receipt.signature,
      'protocol_version': receipt.protocolVersion,
      'received_at_ms': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return rowId != 0;
  }

  @override
  Future<bool> hasReceiptFor(String messageId) async {
    final db = await _database.database;
    final rows = await db.query(
      'delivery_receipts',
      columns: ['message_id'],
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  @override
  Future<List<DeliveryReceipt>> receiptsForMessage(String messageId) async {
    final db = await _database.database;
    final rows = await db.query(
      'delivery_receipts',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<DeliveryReceipt>> outboundReceipts({int limit = 100}) async {
    final db = await _database.database;
    final rows = await db.query(
      'delivery_receipts',
      where: 'propagated_at_ms IS NULL',
      orderBy: 'received_at_ms ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<void> markPropagated(
    String messageId,
    String deliveredById,
    int nowMs,
  ) async {
    final db = await _database.database;
    await db.update(
      'delivery_receipts',
      {'propagated_at_ms': nowMs},
      where: 'message_id = ? AND delivered_by_id = ?',
      whereArgs: [messageId, deliveredById],
    );
  }

  @override
  Future<int> prune(int olderThanMs) async {
    final db = await _database.database;
    return db.delete(
      'delivery_receipts',
      where: 'received_at_ms <= ?',
      whereArgs: [olderThanMs],
    );
  }

  DeliveryReceipt _fromRow(Map<String, Object?> row) => DeliveryReceipt(
    messageId: row['message_id'] as String,
    originalSenderId: row['original_sender_id'] as String,
    deliveredById: row['delivered_by_id'] as String,
    deliveredAtMs: row['delivered_at_ms'] as int,
    signature: Uint8List.fromList(row['signature'] as List<int>),
    protocolVersion: row['protocol_version'] as int,
  );
}
