import 'dart:async';
import 'dart:typed_data';

import '../core/config/app_config.dart';
import '../core/errors/app_exception.dart';
import '../core/protocol/envelope.dart';
import '../core/settings/settings_service.dart';
import '../core/utils/bytes.dart';
import '../core/utils/clock.dart';
import '../core/utils/ids.dart';
import '../crypto/identity_holder.dart';
import '../crypto/identity_record.dart';
import '../domain/entities/chat_message.dart';
import '../domain/entities/known_identity.dart';
import '../domain/repositories/identity_repository.dart';
import '../domain/repositories/message_repository.dart';
import '../messaging/bundle_outbox.dart';
import '../messaging/message_changes.dart';
import '../messaging/png_validator.dart';
import '../messaging/receipt_service.dart';
import '../messaging/signed_bundle.dart';
import 'message_factory.dart';

/// Outcome of ingesting an inbound chat message.
enum MessageInboundOutcome { stored, duplicate, expired, invalid, ignored }

/// Builds, stores and ingests chat messages.
///
/// The message id is the logical identity: it is also the bundle id, so a
/// relayed copy deduplicates at both the routing and storage layers. Expiry is
/// immutable and is *never* reset when a message is relayed.
class MessageService {
  MessageService({
    required MessageRepository messages,
    required IdentityRepository identities,
    required BundleOutbox outbox,
    required ReceiptService receipts,
    required IdentityHolder identityHolder,
    required Clock clock,
    required AppConfig config,
    required MessageChanges changes,
    required SettingsService settings,
  }) : _messages = messages,
       _identities = identities,
       _outbox = outbox,
       _receipts = receipts,
       _identityHolder = identityHolder,
       _clock = clock,
       _config = config,
       _changes = changes,
       _settings = settings;

  final MessageRepository _messages;
  final IdentityRepository _identities;
  final BundleOutbox _outbox;
  final ReceiptService _receipts;
  final IdentityHolder _identityHolder;
  final Clock _clock;
  final AppConfig _config;
  final MessageChanges _changes;
  final SettingsService _settings;

  final StreamController<ChatMessage> _incoming =
      StreamController<ChatMessage>.broadcast();

  /// Newly accepted inbound messages (duplicates are not emitted).
  Stream<ChatMessage> get incomingMessages => _incoming.stream;

  int get _nowMs => _clock.now().millisecondsSinceEpoch;

  // --- Outbound --------------------------------------------------------------

  Future<ChatMessage> sendText({
    required IdentityRecord recipient,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const ValidationException('Message is empty');
    }
    return _send(
      recipient: recipient,
      payloadType: MessagePayloadType.text,
      buildPayload:
          (id, createdAt, expiresAt, disappears, retentionExpiresAt) =>
              MessageFactory.buildText(
        messageIdHex: id,
        createdAtMs: createdAt,
        expiresAtMs: expiresAt,
        disappears: disappears,
        retentionExpiresAtMs: retentionExpiresAt,
        text: trimmed,
      ),
      text: trimmed,
    );
  }

  /// Validates and sends a PNG without altering its bytes.
  Future<ChatMessage> sendPng({
    required IdentityRecord recipient,
    required Uint8List bytes,
    required String filename,
  }) async {
    final validation = await PngValidator.validate(bytes, config: _config);
    return _send(
      recipient: recipient,
      payloadType: MessagePayloadType.png,
      buildPayload:
          (id, createdAt, expiresAt, disappears, retentionExpiresAt) =>
              MessageFactory.buildPng(
        messageIdHex: id,
        createdAtMs: createdAt,
        expiresAtMs: expiresAt,
        disappears: disappears,
        retentionExpiresAtMs: retentionExpiresAt,
        bytes: bytes,
        contentHashHex: validation.contentHashHex,
        width: validation.width,
        height: validation.height,
        filename: filename,
      ),
      imageBytes: bytes,
      imageHash: validation.contentHashHex,
      width: validation.width,
      height: validation.height,
      filename: filename,
    );
  }

  Future<ChatMessage> _send({
    required IdentityRecord recipient,
    required MessagePayloadType payloadType,
    required Map<String, Object?> Function(
      String id,
      int createdAt,
      int expiresAt,
      bool disappears,
      int? retentionExpiresAtMs,
    )
    buildPayload,
    String? text,
    Uint8List? imageBytes,
    String? imageHash,
    int? width,
    int? height,
    String? filename,
  }) async {
    final me = _identityHolder.requireIdentity;
    if (recipient.identityId == me.identityId) {
      throw const ValidationException('Cannot message your own identity');
    }
    await _remember(recipient);

    final createdAt = _nowMs;
    final expiresAt = createdAt + _config.messageTtl.inMilliseconds;
    final retentionState = await _settings.disappearingStateFor(
      recipient.identityId,
    );
    final applyingAcceptedChange = retentionState.incomingAccepted &&
        retentionState.lastAppliedRequestId ==
            retentionState.incomingRequestId;
    if (retentionState.outgoingCommitSent || applyingAcceptedChange) {
      throw const StateTransitionException(
        'Wait for the shared message-setting change to finish before sending',
      );
    }
    final disappears = await _settings.disappearingMessagesEnabledFor(
      recipient.identityId,
    );
    final requestedRetentionExpiry =
        createdAt + const Duration(hours: 24).inMilliseconds;
    final retentionExpiresAt = disappears ? requestedRetentionExpiry : null;
    final idHex = Ids.newMessageIdHex();

    final message = ChatMessage(
      id: idHex,
      senderId: me.identityId,
      recipientId: recipient.identityId,
      peerId: recipient.identityId,
      direction: MessageDirection.outgoing,
      status: MessageStatus.queued,
      payloadType: payloadType,
      createdAtMs: createdAt,
      expiresAtMs: expiresAt,
      disappears: disappears,
      retentionExpiresAtMs: retentionExpiresAt,
      text: text,
      imageBytes: imageBytes,
      imageContentHashHex: imageHash,
      imageWidth: width,
      imageHeight: height,
      imageFilename: filename,
    );
    final inserted = await _messages.insertIfAbsent(message);
    if (!inserted) {
      // Astronomically unlikely id collision, but never create a duplicate.
      throw const StorageException('Duplicate message id');
    }
    await _outbox.enqueue(
      sender: me,
      recipient: recipient,
      type: EnvelopeType.message,
      bundleId: hexToBytes(idHex),
      expiresAtMs: expiresAt,
      payload: buildPayload(
        idHex,
        createdAt,
        expiresAt,
        disappears,
        retentionExpiresAt,
      ),
    );
    _changes.notify();
    return message;
  }

  /// Re-enqueues outbound messages that have not been confirmed delivered.
  ///
  /// Retries reuse the same message/bundle id, so they can never create a
  /// duplicate logical message.
  Future<int> retryOutbound() async {
    final pending = await _messages.outboundWithStatus({
      MessageStatus.pending,
      MessageStatus.queued,
      MessageStatus.unconfirmed,
    });
    final now = _nowMs;
    var count = 0;
    for (final message in pending) {
      if (message.isExpiredAt(now)) continue;
      final peer = await _identities.find(message.recipientId);
      if (peer == null) continue;
      final me = _identityHolder.requireIdentity;
      final payload = _payloadFor(message);
      await _outbox.enqueue(
        sender: me,
        recipient: peer.record,
        type: EnvelopeType.message,
        bundleId: hexToBytes(message.id),
        expiresAtMs: message.expiresAtMs,
        payload: payload,
      );
      if (message.status != MessageStatus.queued) {
        await _messages.updateStatus(message.id, MessageStatus.queued);
      }
      count++;
    }
    if (count > 0) _changes.notify();
    return count;
  }

  // --- Inbound ---------------------------------------------------------------

  /// Validates, decrypts (already done by the codec) and stores a message.
  ///
  /// Always sends an authenticated delivery receipt for a message addressed to
  /// us, even on a duplicate, so a lost receipt can be recovered.
  Future<MessageInboundOutcome> handleIncoming(OpenedBundle opened) async {
    final me = _identityHolder.requireIdentity;
    final sender = opened.sender;
    if (sender.identityId == me.identityId) {
      return MessageInboundOutcome.ignored;
    }

    final payload = MessageFactory.parse(opened.payload);
    final now = _nowMs;

    if (now >= payload.expiresAtMs) return MessageInboundOutcome.expired;
    // A sender may not extend the TTL beyond our configured maximum.
    if (payload.expiresAtMs - payload.createdAtMs >
        _config.messageTtl.inMilliseconds) {
      return MessageInboundOutcome.invalid;
    }
    // The signed message id must match the routing bundle id.
    if (payload.messageIdHex.toLowerCase() !=
        bytesToHex(opened.bundleId).toLowerCase()) {
      return MessageInboundOutcome.invalid;
    }

    Uint8List? imageBytes;
    if (payload.isImage) {
      final raw = payload.imageBytes!;
      final PngValidationResult validation;
      try {
        validation = await PngValidator.validate(raw, config: _config);
      } on ValidationException {
        return MessageInboundOutcome.invalid;
      }
      if (validation.contentHashHex != payload.imageContentHashHex) {
        return MessageInboundOutcome.invalid;
      }
      if (validation.width != payload.imageWidth ||
          validation.height != payload.imageHeight) {
        return MessageInboundOutcome.invalid;
      }
      imageBytes = validation.byteLength == raw.length
          ? raw
          : Uint8List.fromList(raw);
    }

    final message = ChatMessage(
      id: payload.messageIdHex,
      senderId: sender.identityId,
      recipientId: me.identityId,
      peerId: sender.identityId,
      direction: MessageDirection.incoming,
      status: MessageStatus.received,
      payloadType: payload.kind,
      createdAtMs: payload.createdAtMs,
      expiresAtMs: payload.expiresAtMs,
      disappears: payload.disappears,
      retentionExpiresAtMs: payload.retentionExpiresAtMs,
      text: payload.text,
      imageBytes: imageBytes,
      imageContentHashHex: payload.imageContentHashHex,
      imageWidth: payload.imageWidth,
      imageHeight: payload.imageHeight,
      imageFilename: payload.imageFilename,
      receivedAtMs: now,
    );

    await _remember(sender);
    final inserted = await _messages.insertIfAbsent(message);
    // Always acknowledge: an authenticated receipt is idempotent.
    await _receipts.sendReceiptFor(message: message, recipient: sender);
    if (!inserted) return MessageInboundOutcome.duplicate;
    _incoming.add(message);
    _changes.notify();
    return MessageInboundOutcome.stored;
  }

  Future<void> markRead(String peerId) async {
    await _messages.markConversationRead(peerId, _nowMs);
    _changes.notify();
  }

  /// Marks an outgoing message as relayed at least once (not yet confirmed).
  Future<void> markRelayed(String messageIdHex) async {
    final message = await _messages.find(messageIdHex);
    if (message == null) return;
    if (message.direction != MessageDirection.outgoing) return;
    if (message.status == MessageStatus.queued ||
        message.status == MessageStatus.pending) {
      await _messages.updateStatus(messageIdHex, MessageStatus.unconfirmed);
      _changes.notify();
    }
  }

  Future<void> _remember(IdentityRecord record) async {
    final existing = await _identities.find(record.identityId);
    await _identities.upsert(
      KnownIdentity(
        record: record,
        isLocal: false,
        firstSeenMs: existing?.firstSeenMs ?? _nowMs,
        lastSeenMs: _nowMs,
        verifiedAtMs: existing?.verifiedAtMs,
      ),
    );
  }

  Map<String, Object?> _payloadFor(ChatMessage message) {
    if (message.payloadType == MessagePayloadType.text) {
      return MessageFactory.buildText(
        messageIdHex: message.id,
        createdAtMs: message.createdAtMs,
        expiresAtMs: message.expiresAtMs,
        disappears: message.disappears,
        retentionExpiresAtMs: message.retentionExpiresAtMs,
        text: message.text ?? '',
      );
    }
    return MessageFactory.buildPng(
      messageIdHex: message.id,
      createdAtMs: message.createdAtMs,
      expiresAtMs: message.expiresAtMs,
      disappears: message.disappears,
      retentionExpiresAtMs: message.retentionExpiresAtMs,
      bytes: message.imageBytes!,
      contentHashHex: message.imageContentHashHex!,
      width: message.imageWidth!,
      height: message.imageHeight!,
      filename: message.imageFilename ?? 'image.png',
    );
  }

  Future<void> dispose() async {
    await _incoming.close();
  }
}
