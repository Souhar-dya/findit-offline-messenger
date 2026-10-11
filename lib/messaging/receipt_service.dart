import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/cbor/canonical_cbor.dart';
import '../core/config/app_config.dart';
import '../core/errors/app_exception.dart';
import '../core/protocol/envelope.dart';
import '../core/utils/bytes.dart';
import '../core/utils/clock.dart';
import '../crypto/identity_holder.dart';
import '../crypto/identity_record.dart';
import '../domain/entities/chat_message.dart';
import '../domain/entities/delivery_receipt.dart';
import '../domain/entities/tombstone.dart';
import '../domain/repositories/bundle_repository.dart';
import '../domain/repositories/message_repository.dart';
import '../domain/repositories/receipt_repository.dart';
import '../messaging/bundle_outbox.dart';
import '../messaging/signed_bundle.dart';

/// Authenticated delivery receipts.
///
/// A receipt is signed by the identity that *accepted* the message (the
/// recipient) and addressed back to the original sender. Read receipts are
/// intentionally out of scope and are never sent here.
class ReceiptService {
  ReceiptService({
    required ReceiptRepository receipts,
    required MessageRepository messages,
    required BundleRepository bundles,
    required BundleOutbox outbox,
    required IdentityHolder identityHolder,
    required Clock clock,
    required AppConfig config,
  }) : _receipts = receipts,
       _messages = messages,
       _bundles = bundles,
       _outbox = outbox,
       _identityHolder = identityHolder,
       _clock = clock,
       _config = config;

  final ReceiptRepository _receipts;
  final MessageRepository _messages;
  final BundleRepository _bundles;
  final BundleOutbox _outbox;
  final IdentityHolder _identityHolder;
  final Clock _clock;
  final AppConfig _config;

  int get _nowMs => _clock.now().millisecondsSinceEpoch;

  /// Builds, stores and enqueues a receipt acknowledging that we accepted
  /// [message], which was sent by [recipient].
  Future<DeliveryReceipt> sendReceiptFor({
    required ChatMessage message,
    required IdentityRecord recipient,
  }) async {
    final me = _identityHolder.requireIdentity;
    if (message.recipientId != me.identityId) {
      throw const StateTransitionException(
        'Cannot receipt a message for another identity',
      );
    }
    final deliveredAt = _nowMs;
    final unsigned = <String, Object?>{
      'mid': message.id,
      'os': message.senderId,
      'dby': me.identityId,
      'at': deliveredAt,
      'v': _config.protocolVersion,
    };
    final signature = await me.sign(CanonicalCbor.encode(unsigned));
    final receipt = DeliveryReceipt(
      messageId: message.id,
      originalSenderId: message.senderId,
      deliveredById: me.identityId,
      deliveredAtMs: deliveredAt,
      signature: signature,
      protocolVersion: _config.protocolVersion,
    );
    final inserted = await _receipts.insertIfAbsent(receipt);
    if (!inserted) {
      // Already sent for this (message, recipient) pair: nothing to do.
      return receipt;
    }
    await _enqueue(receipt, recipient);
    await _receipts.markPropagated(message.id, me.identityId, deliveredAt);
    return receipt;
  }

  Future<void> _enqueue(
    DeliveryReceipt receipt,
    IdentityRecord recipient,
  ) async {
    final me = _identityHolder.requireIdentity;
    final bundleId = await _receiptBundleId(
      messageId: receipt.messageId,
      deliveredBy: receipt.deliveredById,
    );
    final expiresAt =
        receipt.deliveredAtMs + _config.deliveryReceiptTtl.inMilliseconds;
    await _outbox.enqueue(
      sender: me,
      recipient: recipient,
      type: EnvelopeType.deliveryReceipt,
      bundleId: bundleId,
      expiresAtMs: expiresAt,
      payload: {
        'mid': receipt.messageId,
        'os': receipt.originalSenderId,
        'dby': receipt.deliveredById,
        'at': receipt.deliveredAtMs,
        'v': receipt.protocolVersion,
        'sig': receipt.signature,
      },
    );
  }

  /// Deterministic bundle id so a retried receipt deduplicates.
  static Future<Uint8List> _receiptBundleId({
    required String messageId,
    required String deliveredBy,
  }) async {
    final digest = await sha256(
      utf8.encode('findit/receipt/$messageId/$deliveredBy'),
    );
    return Uint8List.fromList(digest.sublist(0, 16));
  }

  /// Processes a decrypted delivery receipt.
  ///
  /// Returns the referenced message when it is ours and was newly marked
  /// delivered, or `true`-equivalent through [ReceiptInboundResult].
  Future<ReceiptInboundResult> handleIncoming(OpenedBundle opened) async {
    final me = _identityHolder.requireIdentity;
    final payload = _parse(opened);
    if (payload.originalSenderId != me.identityId) {
      // Not addressed to us logically; ignore rather than trust.
      return ReceiptInboundResult.ignored;
    }
    if (opened.sender.identityId != payload.deliveredById) {
      return ReceiptInboundResult.ignored;
    }
    if (!await _verifySignature(payload, opened.sender)) {
      return ReceiptInboundResult.invalid;
    }

    final receipt = DeliveryReceipt(
      messageId: payload.messageId,
      originalSenderId: payload.originalSenderId,
      deliveredById: payload.deliveredById,
      deliveredAtMs: payload.deliveredAtMs,
      signature: payload.signature,
      protocolVersion: payload.protocolVersion,
    );
    final inserted = await _receipts.insertIfAbsent(receipt);
    if (!inserted) return ReceiptInboundResult.duplicate;

    final message = await _messages.find(payload.messageId);
    if (message == null || message.direction != MessageDirection.outgoing) {
      // The receipt arrived before (or without) the message; keep it for later.
      return ReceiptInboundResult.storedUnmatched;
    }
    if (message.status == MessageStatus.delivered) {
      return ReceiptInboundResult.duplicate;
    }
    await _messages.updateStatus(
      message.id,
      MessageStatus.delivered,
      deliveredAtMs: payload.deliveredAtMs,
    );
    await _bundles.addTombstone(
      MessageTombstone(
        bundleIdHex: message.id,
        reason: TombstoneReason.delivered,
        createdAtMs: _nowMs,
        expiresAtMs: _nowMs + _config.tombstoneRetention.inMilliseconds,
      ),
    );
    return ReceiptInboundResult.delivered;
  }

  /// Re-checks stored receipts against messages (handles receipts that arrive
  /// before their message, or a crash between the two writes).
  Future<int> reconcile() async {
    final me = _identityHolder.identity;
    if (me == null) return 0;
    var updated = 0;
    final pending = await _messages.outboundWithStatus({
      MessageStatus.pending,
      MessageStatus.queued,
      MessageStatus.unconfirmed,
    });
    for (final message in pending) {
      final receipts = await _receipts.receiptsForMessage(message.id);
      final valid = receipts.where((r) => r.originalSenderId == me.identityId);
      if (valid.isEmpty) continue;
      final latest = valid.reduce(
        (a, b) => a.deliveredAtMs >= b.deliveredAtMs ? a : b,
      );
      await _messages.updateStatus(
        message.id,
        MessageStatus.delivered,
        deliveredAtMs: latest.deliveredAtMs,
      );
      await _bundles.addTombstone(
        MessageTombstone(
          bundleIdHex: message.id,
          reason: TombstoneReason.delivered,
          createdAtMs: _nowMs,
          expiresAtMs: _nowMs + _config.tombstoneRetention.inMilliseconds,
        ),
      );
      updated++;
    }
    return updated;
  }

  Future<bool> _verifySignature(
    _ParsedReceipt receipt,
    IdentityRecord signer,
  ) async {
    final unsigned = <String, Object?>{
      'mid': receipt.messageId,
      'os': receipt.originalSenderId,
      'dby': receipt.deliveredById,
      'at': receipt.deliveredAtMs,
      'v': receipt.protocolVersion,
    };
    try {
      return await Ed25519().verify(
        CanonicalCbor.encode(unsigned),
        signature: Signature(
          receipt.signature,
          publicKey: SimplePublicKey(
            signer.signingPublicKey,
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } on AppException {
      rethrow;
    } catch (error) {
      throw CryptoException(
        'Receipt signature could not be verified',
        cause: error,
      );
    }
  }

  _ParsedReceipt _parse(OpenedBundle opened) {
    return _ParsedReceipt.fromPayload(opened.payload);
  }

  Future<void> dispose() async {}
}

/// Result of ingesting a delivery receipt.
enum ReceiptInboundResult {
  delivered,
  storedUnmatched,
  duplicate,
  invalid,
  ignored,
}

class _ParsedReceipt {
  const _ParsedReceipt({
    required this.messageId,
    required this.originalSenderId,
    required this.deliveredById,
    required this.deliveredAtMs,
    required this.signature,
    required this.protocolVersion,
  });

  final String messageId;
  final String originalSenderId;
  final String deliveredById;
  final int deliveredAtMs;
  final Uint8List signature;
  final int protocolVersion;

  factory _ParsedReceipt.fromPayload(Map<String, Object?> payload) {
    try {
      return _ParsedReceipt(
        messageId: payload['mid'] as String,
        originalSenderId: payload['os'] as String,
        deliveredById: payload['dby'] as String,
        deliveredAtMs: payload['at'] as int,
        signature: payload['sig'] as Uint8List,
        protocolVersion: payload['v'] as int,
      );
    } catch (error) {
      throw ProtocolException('Malformed delivery receipt', cause: error);
    }
  }
}
