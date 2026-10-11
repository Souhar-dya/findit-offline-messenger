import 'dart:async';
import 'dart:typed_data';

import '../core/config/app_config.dart';
import '../core/protocol/envelope.dart';
import '../core/utils/clock.dart';
import '../crypto/identity_record.dart';
import '../crypto/identity_service.dart';
import '../domain/entities/stored_bundle.dart';
import '../domain/repositories/bundle_repository.dart';
import 'signed_bundle.dart';

/// Seals protocol messages and persists them in the store-carry-forward queue.
///
/// Nothing is "sent" by this class; it only enqueues. The forwarding engine
/// delivers queued bundles opportunistically, and retries are exactly the same
/// bytes/bundle id, so they remain idempotent.
class BundleOutbox {
  BundleOutbox({
    required BundleCodec codec,
    required BundleRepository bundles,
    required Clock clock,
    required AppConfig config,
  }) : _codec = codec,
       _bundles = bundles,
       _clock = clock,
       _config = config;

  final BundleCodec _codec;
  final BundleRepository _bundles;
  final Clock _clock;
  final AppConfig _config;

  final StreamController<StoredBundle> _enqueued =
      StreamController<StoredBundle>.broadcast();

  /// Emits locally enqueued bundles so the routing engine can forward them.
  Stream<StoredBundle> get enqueued => _enqueued.stream;

  /// Seals [payload] and stores it as a forwardable bundle. Returns the bytes.
  Future<Uint8List> enqueue({
    required LocalIdentity sender,
    required IdentityRecord recipient,
    required EnvelopeType type,
    required Map<String, Object?> payload,
    required Uint8List bundleId,
    required int expiresAtMs,
    String? sourcePeerId,
  }) async {
    final bytes = await _codec.seal(
      sender: sender,
      recipient: recipient,
      type: type,
      payload: payload,
      bundleId: bundleId,
      expiresAtMs: expiresAtMs,
    );
    final stored = StoredBundle(
      bundleIdHex: _hex(bundleId),
      type: type,
      recipientId: recipient.identityId,
      expiresAtMs: expiresAtMs,
      storedAtMs: _clock.now().millisecondsSinceEpoch,
      sizeBytes: bytes.length,
      bytes: bytes,
      replicationCount: 0,
      sourcePeerId: sourcePeerId,
    );
    final inserted = await _bundles.insertIfAbsent(stored);
    if (inserted && !_enqueued.isClosed) _enqueued.add(stored);
    return bytes;
  }

  /// Stores a bundle that was received from a peer so it can be relayed on.
  Future<bool> storeReceived({
    required Uint8List bundleId,
    required EnvelopeType type,
    required String recipientId,
    required int expiresAtMs,
    required Uint8List bytes,
    String? sourcePeerId,
  }) {
    return _bundles.insertIfAbsent(
      StoredBundle(
        bundleIdHex: _hex(bundleId),
        type: type,
        recipientId: recipientId,
        expiresAtMs: expiresAtMs,
        storedAtMs: _clock.now().millisecondsSinceEpoch,
        sizeBytes: bytes.length,
        bytes: bytes,
        replicationCount: 0,
        sourcePeerId: sourcePeerId,
      ),
    );
  }

  /// The configured maximum number of peers a bundle may be replicated to.
  int get replicationBudget => _config.replicationBudget;

  Future<void> dispose() async {
    await _enqueued.close();
  }

  String _hex(Uint8List bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
