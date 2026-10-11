import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/cbor/canonical_cbor.dart';
import '../core/errors/app_exception.dart';
import '../core/protocol/envelope.dart';
import '../core/utils/clock.dart';
import '../crypto/identity_record.dart';
import '../crypto/identity_service.dart';
import '../crypto/message_crypto.dart';

/// A successfully decrypted and authenticated inner bundle.
class OpenedBundle {
  const OpenedBundle({
    required this.type,
    required this.sender,
    required this.payload,
    required this.bundleId,
    required this.expiresAtMs,
    required this.protocolVersion,
  });

  final EnvelopeType type;

  /// The verified public identity of the sender.
  final IdentityRecord sender;

  /// Type-specific payload map.
  final Map<String, Object?> payload;
  final Uint8List bundleId;
  final int expiresAtMs;
  final int protocolVersion;
}

/// Builds and opens signed + encrypted protocol bundles.
///
/// Layout of a bundle:
///
/// * Outer [Envelope] (relay-visible, unsigned): version, type, bundle id,
///   recipient id, expiry, and the AEAD output. Mutable routing data only.
/// * Inner canonical CBOR (signed, encrypted): `v`, `typ`, `rec` (sender's
///   signed identity record), `pl` (payload), `sig`.
///
/// The signature covers exactly the canonical encoding of `{v, typ, rec, pl}`.
/// Because the signed content is encrypted, relays cannot see who signed what.
class BundleCodec {
  BundleCodec({
    required MessageCrypto crypto,
    required Clock clock,
    this.protocolVersion = 1,
  }) : _crypto = crypto,
       _clock = clock;

  final MessageCrypto _crypto;
  final Clock _clock;
  final int protocolVersion;

  static const String _fieldVersion = 'v';
  static const String _fieldType = 'typ';
  static const String _fieldRecord = 'rec';
  static const String _fieldPayload = 'pl';
  static const String _fieldSignature = 'sig';

  /// Seals [payload] into a signed, encrypted envelope addressed to [recipient].
  Future<Uint8List> seal({
    required LocalIdentity sender,
    required IdentityRecord recipient,
    required EnvelopeType type,
    required Map<String, Object?> payload,
    required Uint8List bundleId,
    required int expiresAtMs,
  }) async {
    final unsigned = <String, Object?>{
      _fieldVersion: protocolVersion,
      _fieldType: type.wire,
      _fieldRecord: sender.record.toCbor(),
      _fieldPayload: payload,
    };
    final signature = await sender.sign(CanonicalCbor.encode(unsigned));
    final inner = <String, Object?>{...unsigned, _fieldSignature: signature};
    final plaintext = CanonicalCbor.encode(inner);
    final associatedData = Envelope.associatedDataFor(
      version: protocolVersion,
      type: type,
      bundleId: bundleId,
      recipientId: recipient.identityId,
      expiresAtMs: expiresAtMs,
    );
    final encrypted = await _crypto.encrypt(
      recipient: recipient,
      plaintext: plaintext,
      associatedData: associatedData,
    );
    final envelope = Envelope(
      version: protocolVersion,
      type: type,
      bundleId: bundleId,
      recipientId: recipient.identityId,
      expiresAtMs: expiresAtMs,
      cipherText: encrypted.cipherText,
      mac: encrypted.mac,
      nonce: encrypted.nonce,
      ephemeralPublicKey: encrypted.ephemeralPublicKey,
    );
    return envelope.encode();
  }

  /// Opens an envelope addressed to [recipient].
  ///
  /// Throws [ExpiredException] for expired envelopes, [CryptoException] for
  /// bad MACs or invalid signatures, and [ProtocolException] for malformed or
  /// non-canonical data. Never returns partially authenticated content.
  Future<OpenedBundle> open({
    required LocalIdentity recipient,
    required Envelope envelope,
  }) async {
    if (envelope.version != protocolVersion) {
      throw ProtocolException(
        'Unsupported envelope version ${envelope.version}',
      );
    }
    if (envelope.recipientId != recipient.identityId) {
      throw ProtocolException('Envelope is addressed to another identity');
    }
    final nowMs = _clock.now().millisecondsSinceEpoch;
    if (nowMs >= envelope.expiresAtMs) {
      throw const ExpiredException('Envelope has expired');
    }
    final plaintext = await _crypto.decrypt(
      recipient: recipient,
      payload: EncryptedPayload(
        ephemeralPublicKey: envelope.ephemeralPublicKey,
        nonce: envelope.nonce,
        cipherText: envelope.cipherText,
        mac: envelope.mac,
      ),
      associatedData: envelope.associatedData(),
    );
    final inner = CanonicalCbor.decode(plaintext);
    if ((inner[_fieldVersion] as int?) != protocolVersion) {
      throw const ProtocolException('Unsupported inner bundle version');
    }
    if (inner[_fieldType] != envelope.type.wire) {
      throw const ProtocolException('Inner type does not match envelope type');
    }
    final recordMap = inner[_fieldRecord];
    if (recordMap is! Map) {
      throw const ProtocolException(
        'Inner bundle is missing the sender record',
      );
    }
    final sender = IdentityRecord.fromCbor(recordMap.cast<String, Object?>());
    if (!await sender.verify()) {
      throw const CryptoException('Sender identity record failed verification');
    }
    final signature = inner[_fieldSignature];
    if (signature is! Uint8List || signature.length != 64) {
      throw const ProtocolException('Inner bundle signature is malformed');
    }
    final signedBytes = CanonicalCbor.encode({
      _fieldVersion: inner[_fieldVersion],
      _fieldType: inner[_fieldType],
      _fieldRecord: recordMap,
      _fieldPayload: inner[_fieldPayload],
    });
    final valid = await Ed25519().verify(
      signedBytes,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(
          sender.signingPublicKey,
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) {
      throw const CryptoException('Inner bundle signature is invalid');
    }
    final payload = inner[_fieldPayload];
    if (payload is! Map) {
      throw const ProtocolException('Inner bundle payload is malformed');
    }
    return OpenedBundle(
      type: envelope.type,
      sender: sender,
      payload: payload.cast<String, Object?>(),
      bundleId: envelope.bundleId,
      expiresAtMs: envelope.expiresAtMs,
      protocolVersion: protocolVersion,
    );
  }
}
