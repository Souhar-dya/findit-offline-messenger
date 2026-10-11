import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/cbor/canonical_cbor.dart';
import '../core/errors/app_exception.dart';
import 'identity_record.dart';
import 'secret_store.dart';

/// An identity with its in-memory private key pairs.
///
/// Private key material never leaves this object except into [SecretStore].
class LocalIdentity {
  const LocalIdentity({
    required this.record,
    required this.signingKeyPair,
    required this.agreementKeyPair,
  });

  final IdentityRecord record;
  final SimpleKeyPair signingKeyPair;
  final SimpleKeyPair agreementKeyPair;

  String get identityId => record.identityId;

  String get displayName => record.displayName;

  /// Signs arbitrary bytes with the identity's Ed25519 key.
  Future<Uint8List> sign(List<int> message) async {
    final signature = await Ed25519().sign(message, keyPair: signingKeyPair);
    return Uint8List.fromList(signature.bytes);
  }
}

/// Generates, persists and loads the local cryptographic identity.
///
/// The identity works fully offline. The seed material lives in [SecretStore];
/// the public [IdentityRecord] can be mirrored into the database for queries.
class IdentityService {
  IdentityService({required SecretStore secretStore})
    : _secretStore = secretStore;

  final SecretStore _secretStore;

  static const String storageKey = 'findit.identity.v1';
  static const int _privatePayloadVersion = 1;

  /// Creates and persists a brand new identity.
  Future<LocalIdentity> generate({required String displayName}) async {
    final signingKeyPair = await Ed25519().newKeyPair();
    final agreementKeyPair = await X25519().newKeyPair();
    final identity = await _build(
      displayName: displayName,
      signingKeyPair: signingKeyPair,
      agreementKeyPair: agreementKeyPair,
    );
    await _persist(identity);
    return identity;
  }

  /// Loads the persisted identity, or returns `null` if none exists.
  Future<LocalIdentity?> load() async {
    final encoded = await _secretStore.read(storageKey);
    if (encoded == null) return null;
    try {
      final map = CanonicalCbor.decode(base64Decode(encoded));
      final signingSeed = map['sd'] as Uint8List;
      final agreementSeed = map['ad'] as Uint8List;
      final name = map['name'] as String;
      final signingKeyPair = await Ed25519().newKeyPairFromSeed(signingSeed);
      final agreementKeyPair = await X25519().newKeyPairFromSeed(agreementSeed);
      final identity = await _build(
        displayName: name,
        signingKeyPair: signingKeyPair,
        agreementKeyPair: agreementKeyPair,
      );
      if (!await identity.record.verify()) {
        throw const CryptoException(
          'Stored identity record failed verification',
        );
      }
      return identity;
    } on AppException {
      rethrow;
    } catch (error) {
      throw StorageException('Failed to load local identity', cause: error);
    }
  }

  /// Whether an identity has already been created on this installation.
  Future<bool> hasIdentity() => _secretStore.containsKey(storageKey);

  /// Re-signs the identity record with a new display name.
  Future<LocalIdentity> rename(
    LocalIdentity current,
    String displayName,
  ) async {
    final renamed = LocalIdentity(
      record: await _signRecord(
        displayName: displayName,
        signingKeyPair: current.signingKeyPair,
        agreementKeyPair: current.agreementKeyPair,
      ),
      signingKeyPair: current.signingKeyPair,
      agreementKeyPair: current.agreementKeyPair,
    );
    await _persist(renamed);
    return renamed;
  }

  /// Permanently removes the identity (identity reset).
  Future<void> delete() => _secretStore.delete(storageKey);

  Future<LocalIdentity> _build({
    required String displayName,
    required SimpleKeyPair signingKeyPair,
    required SimpleKeyPair agreementKeyPair,
  }) async {
    final record = await _signRecord(
      displayName: displayName,
      signingKeyPair: signingKeyPair,
      agreementKeyPair: agreementKeyPair,
    );
    return LocalIdentity(
      record: record,
      signingKeyPair: signingKeyPair,
      agreementKeyPair: agreementKeyPair,
    );
  }

  Future<IdentityRecord> _signRecord({
    required String displayName,
    required SimpleKeyPair signingKeyPair,
    required SimpleKeyPair agreementKeyPair,
  }) async {
    final signingPublicKey = (await signingKeyPair.extractPublicKey()).bytes;
    final agreementPublicKey =
        (await agreementKeyPair.extractPublicKey()).bytes;
    final identityId = await IdentityRecord.deriveId(signingPublicKey);
    final unsigned = IdentityRecord(
      formatVersion: kIdentityFormatVersion,
      keyVersion: kIdentityKeyVersion,
      identityId: identityId,
      signingPublicKey: Uint8List.fromList(signingPublicKey),
      agreementPublicKey: Uint8List.fromList(agreementPublicKey),
      displayName: displayName,
      signature: Uint8List(0),
    );
    final signature = await Ed25519().sign(
      unsigned.signedBytes(),
      keyPair: signingKeyPair,
    );
    return IdentityRecord(
      formatVersion: unsigned.formatVersion,
      keyVersion: unsigned.keyVersion,
      identityId: unsigned.identityId,
      signingPublicKey: unsigned.signingPublicKey,
      agreementPublicKey: unsigned.agreementPublicKey,
      displayName: unsigned.displayName,
      signature: Uint8List.fromList(signature.bytes),
    );
  }

  Future<void> _persist(LocalIdentity identity) async {
    final signingSeed = await identity.signingKeyPair.extractPrivateKeyBytes();
    final agreementSeed = await identity.agreementKeyPair
        .extractPrivateKeyBytes();
    final payload = CanonicalCbor.encode({
      'v': _privatePayloadVersion,
      'sd': Uint8List.fromList(signingSeed),
      'ad': Uint8List.fromList(agreementSeed),
      'name': identity.record.displayName,
    });
    await _secretStore.write(storageKey, base64Encode(payload));
  }
}
