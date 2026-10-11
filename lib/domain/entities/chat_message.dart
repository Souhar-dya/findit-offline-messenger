import 'dart:typed_data';

/// Payload kind. Only text and PNG are supported in this version.
enum MessagePayloadType {
  text('text'),
  png('png');

  const MessagePayloadType(this.wire);

  final String wire;

  static MessagePayloadType fromWire(String wire) {
    for (final value in MessagePayloadType.values) {
      if (value.wire == wire) return value;
    }
    throw ArgumentError('Unknown payload type: $wire');
  }
}

/// Delivery lifecycle of a message as shown to the user.
///
/// * [pending] – created locally, not yet handed to a peer.
/// * [queued] – waiting in the outbound forwarding queue.
/// * [unconfirmed] – relayed at least once, no authenticated receipt yet.
/// * [delivered] – an authenticated delivery receipt was received.
/// * [received] – an inbound message that we accepted and stored.
/// * [expired] – passed its immutable expiry without delivery.
/// * [failed] – permanently rejected (invalid recipient, quota, etc.).
enum MessageStatus {
  pending('pending'),
  queued('queued'),
  unconfirmed('unconfirmed'),
  delivered('delivered'),
  received('received'),
  expired('expired'),
  failed('failed');

  const MessageStatus(this.wire);

  final String wire;

  static MessageStatus fromWire(String wire) {
    for (final value in MessageStatus.values) {
      if (value.wire == wire) return value;
    }
    throw ArgumentError('Unknown message status: $wire');
  }

  /// Whether a receipt-backed "delivered" state is possible.
  bool get isOutgoing =>
      this == pending ||
      this == queued ||
      this == unconfirmed ||
      this == delivered ||
      this == failed ||
      this == expired;
}

/// Direction relative to the local user.
enum MessageDirection { incoming, outgoing }

/// A message as stored and displayed by the application.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.peerId,
    required this.direction,
    required this.status,
    required this.payloadType,
    required this.createdAtMs,
    required this.expiresAtMs,
    this.text,
    this.imageBytes,
    this.imageContentHashHex,
    this.imageWidth,
    this.imageHeight,
    this.imageFilename,
    this.receivedAtMs,
    this.deliveredAtMs,
    this.readAtMs,
  });

  /// Hex-encoded 128-bit message id.
  final String id;
  final String senderId;
  final String recipientId;

  /// The other party in the conversation (recipient for outgoing messages,
  /// sender for incoming ones).
  final String peerId;
  final MessageDirection direction;
  final MessageStatus status;
  final MessagePayloadType payloadType;
  final int createdAtMs;
  final int expiresAtMs;

  final String? text;
  final Uint8List? imageBytes;
  final String? imageContentHashHex;
  final int? imageWidth;
  final int? imageHeight;
  final String? imageFilename;

  final int? receivedAtMs;
  final int? deliveredAtMs;

  /// When the local user read an inbound message (optional, separate from
  /// delivery receipts).
  final int? readAtMs;

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  /// Size of the stored payload, used for storage-quota accounting.
  int get payloadBytes => imageBytes?.length ?? (text?.length ?? 0);

  ChatMessage copyWith({
    MessageStatus? status,
    int? receivedAtMs,
    int? deliveredAtMs,
    int? readAtMs,
  }) {
    return ChatMessage(
      id: id,
      senderId: senderId,
      recipientId: recipientId,
      peerId: peerId,
      direction: direction,
      status: status ?? this.status,
      payloadType: payloadType,
      createdAtMs: createdAtMs,
      expiresAtMs: expiresAtMs,
      text: text,
      imageBytes: imageBytes,
      imageContentHashHex: imageContentHashHex,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      imageFilename: imageFilename,
      receivedAtMs: receivedAtMs ?? this.receivedAtMs,
      deliveredAtMs: deliveredAtMs ?? this.deliveredAtMs,
      readAtMs: readAtMs ?? this.readAtMs,
    );
  }
}
