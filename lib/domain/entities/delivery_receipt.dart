import 'dart:typed_data';

/// An authenticated delivery receipt.
///
/// The receipt is signed by the *recipient* of the original message and proves
/// they accepted it. It is deliberately separate from read receipts.
class DeliveryReceipt {
  const DeliveryReceipt({
    required this.messageId,
    required this.originalSenderId,
    required this.deliveredById,
    required this.deliveredAtMs,
    required this.signature,
    required this.protocolVersion,
  });

  /// Hex message id of the message being acknowledged.
  final String messageId;

  /// Identity id of the message's original sender.
  final String originalSenderId;

  /// Identity id of the device that accepted the message and signed this.
  final String deliveredById;
  final int deliveredAtMs;
  final Uint8List signature;
  final int protocolVersion;
}
