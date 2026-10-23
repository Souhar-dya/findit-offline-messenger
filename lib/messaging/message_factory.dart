import 'dart:typed_data';

import '../core/errors/app_exception.dart';
import '../domain/entities/chat_message.dart';

/// Wire payload keys for a chat message. Kept short because they are part of
/// every signed envelope.
class MessageFields {
  MessageFields._();

  static const String messageId = 'mid';
  static const String kind = 'k';
  static const String createdAt = 'iat';
  static const String expiresAt = 'exp';
  static const String disappears = 'dis';
  static const String retentionExpiresAt = 'del';
  static const String text = 't';
  static const String image = 'img';
  static const String imageHash = 'h';
  static const String imageWidth = 'w';
  static const String imageHeight = 'ht';
  static const String imageFilename = 'fn';
}

/// A parsed, structurally valid message payload.
class MessagePayload {
  const MessagePayload({
    required this.messageIdHex,
    required this.kind,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.disappears,
    required this.retentionExpiresAtMs,
    this.text,
    this.imageBytes,
    this.imageContentHashHex,
    this.imageWidth,
    this.imageHeight,
    this.imageFilename,
  });

  final String messageIdHex;
  final MessagePayloadType kind;
  final int createdAtMs;
  final int expiresAtMs;
  final bool disappears;
  final int? retentionExpiresAtMs;
  final String? text;
  final Uint8List? imageBytes;
  final String? imageContentHashHex;
  final int? imageWidth;
  final int? imageHeight;
  final String? imageFilename;

  bool get isImage => kind == MessagePayloadType.png;
}

/// Pure builder / parser for chat message payloads.
///
/// No compression, resizing or re-encoding happens here: PNG bytes are carried
/// verbatim so the image is preserved losslessly.
class MessageFactory {
  MessageFactory._();

  static Map<String, Object?> buildText({
    required String messageIdHex,
    required int createdAtMs,
    required int expiresAtMs,
    bool disappears = true,
    int? retentionExpiresAtMs,
    required String text,
  }) => {
    MessageFields.messageId: messageIdHex,
    MessageFields.kind: MessagePayloadType.text.wire,
    MessageFields.createdAt: createdAtMs,
    MessageFields.expiresAt: expiresAtMs,
    MessageFields.disappears: disappears,
    if (disappears)
      MessageFields.retentionExpiresAt:
          retentionExpiresAtMs ??
          createdAtMs + const Duration(hours: 24).inMilliseconds,
    MessageFields.text: text,
  };

  static Map<String, Object?> buildPng({
    required String messageIdHex,
    required int createdAtMs,
    required int expiresAtMs,
    bool disappears = true,
    int? retentionExpiresAtMs,
    required Uint8List bytes,
    required String contentHashHex,
    required int width,
    required int height,
    required String filename,
  }) => {
    MessageFields.messageId: messageIdHex,
    MessageFields.kind: MessagePayloadType.png.wire,
    MessageFields.createdAt: createdAtMs,
    MessageFields.expiresAt: expiresAtMs,
    MessageFields.disappears: disappears,
    if (disappears)
      MessageFields.retentionExpiresAt:
          retentionExpiresAtMs ??
          createdAtMs + const Duration(hours: 24).inMilliseconds,
    MessageFields.image: bytes,
    MessageFields.imageHash: contentHashHex,
    MessageFields.imageWidth: width,
    MessageFields.imageHeight: height,
    MessageFields.imageFilename: filename,
  };

  /// Parses and validates the structure of a message payload. Image integrity
  /// (CRC/hash/dimensions) is verified separately by `PngValidator`.
  static MessagePayload parse(Map<String, Object?> payload) {
    try {
      final id = payload[MessageFields.messageId] as String;
      final kind = MessagePayloadType.fromWire(
        payload[MessageFields.kind] as String,
      );
      final createdAt = payload[MessageFields.createdAt] as int;
      final expiresAt = payload[MessageFields.expiresAt] as int;
      final legacyPolicy = payload[MessageFields.disappears] == null;
      final disappears =
          payload[MessageFields.disappears] as bool? ?? true;
      final retentionExpiresAt =
          payload[MessageFields.retentionExpiresAt] as int? ??
          (legacyPolicy ? expiresAt : null);
      if (id.isEmpty || expiresAt <= createdAt) {
        throw const ProtocolException('Message has invalid timestamps');
      }
      if ((disappears && retentionExpiresAt == null) ||
          (!disappears && retentionExpiresAt != null) ||
          (retentionExpiresAt != null &&
              (retentionExpiresAt <= createdAt ||
                  retentionExpiresAt >
                      createdAt + const Duration(hours: 24).inMilliseconds))) {
        throw const ProtocolException('Message has invalid retention policy');
      }
      if (!legacyPolicy && disappears &&
          retentionExpiresAt !=
              createdAt + const Duration(hours: 24).inMilliseconds) {
        throw const ProtocolException('Message retention must be 24 hours');
      }
      if (kind == MessagePayloadType.text) {
        final text = payload[MessageFields.text] as String?;
        if (text == null) {
          throw const ProtocolException('Text message is missing its body');
        }
        return MessagePayload(
          messageIdHex: id,
          kind: kind,
          createdAtMs: createdAt,
          expiresAtMs: expiresAt,
          disappears: disappears,
          retentionExpiresAtMs: retentionExpiresAt,
          text: text,
        );
      }
      final image = payload[MessageFields.image];
      final hash = payload[MessageFields.imageHash];
      final width = payload[MessageFields.imageWidth];
      final height = payload[MessageFields.imageHeight];
      if (image is! List<int> ||
          hash is! String ||
          width is! int ||
          height is! int) {
        throw const ProtocolException('PNG message is missing image fields');
      }
      return MessagePayload(
        messageIdHex: id,
        kind: kind,
        createdAtMs: createdAt,
        expiresAtMs: expiresAt,
        disappears: disappears,
        retentionExpiresAtMs: retentionExpiresAt,
        imageBytes: image is Uint8List ? image : Uint8List.fromList(image),
        imageContentHashHex: hash,
        imageWidth: width,
        imageHeight: height,
        imageFilename:
            (payload[MessageFields.imageFilename] as String?) ?? 'image.png',
      );
    } on ProtocolException {
      rethrow;
    } catch (error) {
      throw ProtocolException('Malformed message payload', cause: error);
    }
  }
}
