import '../entities/delivery_receipt.dart';

/// Persistence for authenticated delivery receipts.
abstract class ReceiptRepository {
  /// Inserts a receipt. Returns `false` if an identical receipt id already
  /// exists. The receipt id is the (messageId, deliveredById) pair.
  Future<bool> insertIfAbsent(DeliveryReceipt receipt);

  Future<bool> hasReceiptFor(String messageId);

  Future<List<DeliveryReceipt>> receiptsForMessage(String messageId);

  /// Receipts the local device should still propagate to their origin.
  Future<List<DeliveryReceipt>> outboundReceipts({int limit = 100});

  Future<void> markPropagated(
    String messageId,
    String deliveredById,
    int nowMs,
  );

  Future<int> prune(int olderThanMs);
}
