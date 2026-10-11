import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/errors/app_exception.dart';
import '../core/utils/bytes.dart';
import 'identity_record.dart';
import 'identity_service.dart';

/// The result of encrypting a payload for a recipient (ECIES style).
class EncryptedPayload {
  const EncryptedPayload({
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.cipherText,
    required this.mac,
  });

  final Uint8List ephemeralPublicKey;
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;
}

/// Authenticated encryption of message payloads for a known recipient.
///
/// Design (no custom cryptographic primitives):
///
/// 1. Generate a fresh ephemeral X25519 key pair for every envelope.
/// 2. ECDH between the ephemeral private key and the recipient's static X25519
///    key-agreement key.
/// 3. HKDF-SHA256 over the shared secret with `salt = ephemeralPub || recipientPub`
///    and a fixed info string, producing a 256-bit AES key.
/// 4. AES-256-GCM over the canonical inner bundle with the envelope's immutable
///    routing fields as associated data.
///
/// Because the shared secret is ephemeral-static, relays that only have the
/// outer envelope cannot decrypt it. Sender authentication is *not* provided by
/// this layer: it is provided by the Ed25519 signature inside the encrypted
/// bundle, so relays never see who signed what.
class MessageCrypto {
  MessageCrypto();

  static const String kdfInfo = 'findit/envelope/v1';

  final AesGcm _aead = AesGcm.with256bits();
  final X25519 _x25519 = X25519();

  Hkdf get _hkdf => Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  /// Encrypts [plaintext] for [recipient], binding [associatedData].
  Future<EncryptedPayload> encrypt({
    required IdentityRecord recipient,
    required Uint8List plaintext,
    required Uint8List associatedData,
  }) async {
    final ephemeral = await _x25519.newKeyPair();
    final ephemeralPublic = (await ephemeral.extractPublicKey()).bytes;
    final recipientPublic = SimplePublicKey(
      recipient.agreementPublicKey,
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: recipientPublic,
    );
    final key = await _deriveKey(
      shared: shared,
      salt: concatBytes([ephemeralPublic, recipient.agreementPublicKey]),
    );
    final box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      aad: associatedData,
    );
    return EncryptedPayload(
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublic),
      nonce: Uint8List.fromList(box.nonce),
      cipherText: Uint8List.fromList(box.cipherText),
      mac: Uint8List.fromList(box.mac.bytes),
    );
  }

  /// Decrypts [payload] addressed to the local [recipient].
  Future<Uint8List> decrypt({
    required LocalIdentity recipient,
    required EncryptedPayload payload,
    required Uint8List associatedData,
  }) async {
    final ephemeralPublic = SimplePublicKey(
      payload.ephemeralPublicKey,
      type: KeyPairType.x25519,
    );
    final shared = await _x25519.sharedSecretKey(
      keyPair: recipient.agreementKeyPair,
      remotePublicKey: ephemeralPublic,
    );
    final key = await _deriveKey(
      shared: shared,
      salt: concatBytes([
        payload.ephemeralPublicKey,
        recipient.record.agreementPublicKey,
      ]),
    );
    final box = SecretBox(
      payload.cipherText,
      nonce: payload.nonce,
      mac: Mac(payload.mac),
    );
    try {
      final clear = await _aead.decrypt(
        box,
        secretKey: key,
        aad: associatedData,
      );
      return Uint8List.fromList(clear);
    } catch (error) {
      throw CryptoException('Envelope authentication failed', cause: error);
    }
  }

  Future<SecretKey> _deriveKey({
    required SecretKey shared,
    required List<int> salt,
  }) {
    return _hkdf.deriveKey(
      secretKey: shared,
      nonce: salt,
      info: utf8.encode(kdfInfo),
    );
  }
}
