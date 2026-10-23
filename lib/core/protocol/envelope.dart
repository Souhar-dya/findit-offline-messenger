import 'dart:typed_data';

import '../cbor/canonical_cbor.dart';
import '../errors/app_exception.dart';

/// Envelope type tags carried in the outer (relay-visible) envelope and in the
/// signed inner bundle.
enum EnvelopeType {
  message('msg'),
  deliveryReceipt('receipt'),
  friendRequest('friend_request'),
  friendAccept('friend_accept'),
  friendConfirm('friend_confirm'),
  friendDecline('friend_decline'),
  retentionRequest('retention_request'),
  retentionResponse('retention_response'),
  retentionCommit('retention_commit'),
  retentionCommitAck('retention_commit_ack'),
  retentionActivate('retention_activate'),
  retentionActivateAck('retention_activate_ack');

  const EnvelopeType(this.wire);

  final String wire;

  static EnvelopeType fromWire(String wire) {
    for (final value in EnvelopeType.values) {
      if (value.wire == wire) return value;
    }
    throw ProtocolException('Unknown envelope type: $wire');
  }

  /// Whether this envelope carries a chat message payload.
  bool get isMessage => this == EnvelopeType.message;
}

/// The outer, relay-visible envelope.
///
/// Relays can read exactly these fields: protocol version, type, bundle id,
/// recipient identity id, expiry and the (encrypted) payload size. They cannot
/// read the sender identity, timestamps other than expiry, or the payload
/// contents. Mutable routing information is kept here, outside the immutable
/// signed content.
class Envelope {
  const Envelope({
    required this.version,
    required this.type,
    required this.bundleId,
    required this.recipientId,
    required this.expiresAtMs,
    required this.cipherText,
    required this.mac,
    required this.nonce,
    required this.ephemeralPublicKey,
    this.algorithm = 'AES-256-GCM',
    this.kdf = 'HKDF-SHA256',
  });

  final int version;
  final EnvelopeType type;

  /// Random (or deterministically derived) 128-bit bundle id used for dedup.
  final Uint8List bundleId;

  final String recipientId;
  final int expiresAtMs;

  final Uint8List cipherText;
  final Uint8List mac;
  final Uint8List nonce;
  final Uint8List ephemeralPublicKey;
  final String algorithm;
  final String kdf;

  /// Bytes that are authenticated as AEAD associated data (the immutable
  /// routing fields). Tampering with them breaks decryption.
  Uint8List associatedData() => associatedDataFor(
    version: version,
    type: type,
    bundleId: bundleId,
    recipientId: recipientId,
    expiresAtMs: expiresAtMs,
  );

  /// Computes the canonical AEAD associated data for the given routing fields.
  static Uint8List associatedDataFor({
    required int version,
    required EnvelopeType type,
    required Uint8List bundleId,
    required String recipientId,
    required int expiresAtMs,
  }) => CanonicalCbor.encode({
    'v': version,
    'typ': type.wire,
    'bid': bundleId,
    'to': recipientId,
    'exp': expiresAtMs,
  });

  /// Total serialized size of the envelope, used for quota accounting.
  int get approximateSizeBytes =>
      cipherText.length +
      mac.length +
      nonce.length +
      ephemeralPublicKey.length +
      128;

  Map<String, Object?> toCbor() => {
    'v': version,
    'typ': type.wire,
    'bid': bundleId,
    'to': recipientId,
    'exp': expiresAtMs,
    'alg': algorithm,
    'kdf': kdf,
    'epk': ephemeralPublicKey,
    'n': nonce,
    'ct': cipherText,
    'mac': mac,
  };

  Uint8List encode() => CanonicalCbor.encode(toCbor());

  static Envelope decode(List<int> bytes) {
    final map = CanonicalCbor.decode(bytes);
    return fromMap(map);
  }

  static Envelope fromMap(Map<String, Object?> map) {
    try {
      return Envelope(
        version: map['v'] as int,
        type: EnvelopeType.fromWire(map['typ'] as String),
        bundleId: map['bid'] as Uint8List,
        recipientId: map['to'] as String,
        expiresAtMs: map['exp'] as int,
        algorithm: map['alg'] as String,
        kdf: map['kdf'] as String,
        ephemeralPublicKey: map['epk'] as Uint8List,
        nonce: map['n'] as Uint8List,
        cipherText: map['ct'] as Uint8List,
        mac: map['mac'] as Uint8List,
      );
    } catch (error) {
      throw ProtocolException('Malformed envelope fields', cause: error);
    }
  }
}
