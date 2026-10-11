import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/cbor/canonical_cbor.dart';
import '../core/errors/app_exception.dart';
import '../core/utils/bytes.dart';
import '../core/utils/ids.dart';

/// Wire format version of the identity record.
const int kIdentityFormatVersion = 1;

/// Version of the key material in the record. Bumping this signals a key
/// rotation or algorithm change and lets old records be rejected explicitly.
const int kIdentityKeyVersion = 1;

/// A public identity record.
///
/// It contains only public information: the identity id, the Ed25519 signing
/// key, the X25519 key-agreement key, the display name and a self-signature.
/// Private keys are never part of this structure and are never exported.
class IdentityRecord {
  const IdentityRecord({
    required this.formatVersion,
    required this.keyVersion,
    required this.identityId,
    required this.signingPublicKey,
    required this.agreementPublicKey,
    required this.displayName,
    required this.signature,
  });

  final int formatVersion;
  final int keyVersion;
  final String identityId;
  final Uint8List signingPublicKey;
  final Uint8List agreementPublicKey;
  final String displayName;
  final Uint8List signature;

  /// Derives a stable identity id from the Ed25519 public key.
  static Future<String> deriveId(List<int> signingPublicKey) async {
    final digest = await sha256(signingPublicKey);
    return '$kIdentityIdPrefix${bytesToHex(digest.sublist(0, 16))}';
  }

  /// The exact fields covered by [signature], canonical-encoded.
  Map<String, Object?> unsignedMap() => {
    'v': formatVersion,
    'kv': keyVersion,
    'id': identityId,
    'ik': signingPublicKey,
    'ak': agreementPublicKey,
    'name': displayName,
  };

  Uint8List signedBytes() => CanonicalCbor.encode(unsignedMap());

  Map<String, Object?> toCbor() => {...unsignedMap(), 'sig': signature};

  Uint8List encode() => CanonicalCbor.encode(toCbor());

  /// True when the id is correctly bound to the signing key.
  Future<bool> isIdBound() async {
    final expected = await deriveId(signingPublicKey);
    return expected == identityId;
  }

  /// Verifies the self-signature and the id/key binding.
  Future<bool> verify() async {
    if (formatVersion != kIdentityFormatVersion) return false;
    if (signingPublicKey.length != 32 || agreementPublicKey.length != 32) {
      return false;
    }
    if (signature.length != 64) return false;
    if (!await isIdBound()) return false;
    return Ed25519().verify(
      signedBytes(),
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(signingPublicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  /// Base64url payload placed in a QR code. Contains public data only.
  String toQrData() => base64Url.encode(encode());

  /// Parses QR data produced by [toQrData]. Accepts an optional `findit://`
  /// scheme prefix for robustness.
  static IdentityRecord parseQrData(String data) {
    var payload = data.trim();
    const scheme = 'findit://';
    if (payload.toLowerCase().startsWith(scheme)) {
      payload = payload.substring(scheme.length);
    }
    Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base64Url.decode(payload));
    } catch (error) {
      throw ProtocolException('QR payload is not valid base64', cause: error);
    }
    return fromCbor(CanonicalCbor.decode(bytes));
  }

  static IdentityRecord fromCbor(Map<String, Object?> map) {
    try {
      return IdentityRecord(
        formatVersion: map['v'] as int,
        keyVersion: map['kv'] as int,
        identityId: map['id'] as String,
        signingPublicKey: asUint8List(map['ik'] as List<int>),
        agreementPublicKey: asUint8List(map['ak'] as List<int>),
        displayName: map['name'] as String,
        signature: asUint8List(map['sig'] as List<int>),
      );
    } catch (error) {
      throw ProtocolException('Malformed identity record', cause: error);
    }
  }

  /// Parses and fully verifies a record from CBOR bytes.
  static Future<IdentityRecord> parseAndVerify(List<int> bytes) async {
    final record = fromCbor(CanonicalCbor.decode(bytes));
    if (!await record.verify()) {
      throw const CryptoException('Identity record signature is invalid');
    }
    return record;
  }

  @override
  String toString() =>
      'IdentityRecord($identityId, name="$displayName", v$formatVersion/kv$keyVersion)';
}
