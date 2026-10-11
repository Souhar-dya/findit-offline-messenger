import 'dart:typed_data';

import '../../core/protocol/envelope.dart';

/// A store-carry-forward item: an accepted, signed, encrypted envelope plus the
/// routing metadata the local device needs to forward it.
class StoredBundle {
  const StoredBundle({
    required this.bundleIdHex,
    required this.type,
    required this.recipientId,
    required this.expiresAtMs,
    required this.storedAtMs,
    required this.sizeBytes,
    required this.bytes,
    required this.replicationCount,
    this.sourcePeerId,
    this.lastForwardedAtMs,
    this.forwardedPeerIds = const <String>{},
  });

  /// Hex bundle id (also the primary key in SQLite).
  final String bundleIdHex;
  final EnvelopeType type;

  /// Who the bundle is addressed to (routing only; not necessarily a friend).
  final String recipientId;
  final int expiresAtMs;
  final int storedAtMs;
  final int sizeBytes;

  /// The exact serialized envelope bytes.
  final Uint8List bytes;

  /// How many distinct peers we have already handed this bundle to.
  final int replicationCount;

  /// Peer we received this bundle from, if any (avoid immediate echo).
  final String? sourcePeerId;
  final int? lastForwardedAtMs;

  /// Peers already given a copy, so we do not re-send the same bundle.
  final Set<String> forwardedPeerIds;

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;

  StoredBundle copyWith({
    int? replicationCount,
    int? lastForwardedAtMs,
    Set<String>? forwardedPeerIds,
  }) {
    return StoredBundle(
      bundleIdHex: bundleIdHex,
      type: type,
      recipientId: recipientId,
      expiresAtMs: expiresAtMs,
      storedAtMs: storedAtMs,
      sizeBytes: sizeBytes,
      bytes: bytes,
      replicationCount: replicationCount ?? this.replicationCount,
      sourcePeerId: sourcePeerId,
      lastForwardedAtMs: lastForwardedAtMs ?? this.lastForwardedAtMs,
      forwardedPeerIds: forwardedPeerIds ?? this.forwardedPeerIds,
    );
  }
}
