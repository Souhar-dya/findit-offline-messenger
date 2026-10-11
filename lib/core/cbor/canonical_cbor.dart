import 'dart:convert';
import 'dart:typed_data';

import 'package:cbor/cbor.dart';

import '../errors/app_exception.dart';
import '../utils/bytes.dart';

/// Canonical (deterministic) CBOR encoding and decoding for protocol objects.
///
/// Signatures must cover a byte string that is reproducible on both ends, so we
/// do not rely on the encoder's map iteration order. Instead every map is built
/// with keys sorted in canonical CBOR order (RFC 8949 §4.2.1: bytewise
/// lexicographic order of the deterministic encodings of the keys) and with
/// definite lengths.
///
/// The decoder re-encodes the decoded value and rejects any input that is not
/// already in canonical form. This prevents a malicious peer from producing two
/// different byte strings for the same logical object.
class CanonicalCbor {
  CanonicalCbor._();

  /// Encodes a `String`-keyed map as canonical CBOR bytes.
  static Uint8List encode(Map<String, Object?> map) {
    final value = _toCborValue(map);
    return Uint8List.fromList(cborEncode(value));
  }

  /// Decodes canonical CBOR bytes into a `String`-keyed map.
  ///
  /// Throws [ProtocolException] for malformed, non-map or non-canonical input.
  static Map<String, Object?> decode(
    List<int> bytes, {
    bool requireCanonical = true,
  }) {
    CborValue value;
    try {
      value = cborDecode(bytes);
    } catch (error) {
      throw ProtocolException('Malformed CBOR envelope', cause: error);
    }
    final object = _toDart(value);
    if (object is! Map) {
      throw const ProtocolException('CBOR envelope must be a map');
    }
    final map = <String, Object?>{};
    for (final entry in object.entries) {
      final key = entry.key;
      if (key is! String) {
        throw const ProtocolException('CBOR map keys must be strings');
      }
      map[key] = entry.value;
    }
    if (requireCanonical) {
      final reencoded = encode(map);
      if (!constantTimeEquals(reencoded, bytes)) {
        throw const ProtocolException('CBOR envelope is not canonical');
      }
    }
    return map;
  }

  /// Orders two string keys according to canonical CBOR rules.
  static int compareKeys(String a, String b) {
    final aBytes = utf8.encode(a);
    final bBytes = utf8.encode(b);
    if (aBytes.length != bBytes.length) {
      return aBytes.length - bBytes.length;
    }
    for (var i = 0; i < aBytes.length; i++) {
      if (aBytes[i] != bBytes[i]) return aBytes[i] - bBytes[i];
    }
    return 0;
  }

  static CborValue _toCborValue(Object? value) {
    if (value == null) return const CborNull();
    if (value is bool) return CborBool(value);
    if (value is int) return CborInt(BigInt.from(value));
    if (value is BigInt) return CborInt(value);
    if (value is String) return CborString(value);
    if (value is Uint8List) return CborBytes(value);
    if (value is List<int>) return CborBytes(value);
    if (value is List) {
      return CborList(
        value.map(_toCborValue).toList(growable: false),
        type: CborLengthType.definite,
      );
    }
    if (value is Map) {
      final keys = value.keys.map((k) => k as String).toList()
        ..sort(compareKeys);
      final entries = <MapEntry<CborValue, CborValue>>[
        for (final key in keys)
          MapEntry(CborString(key), _toCborValue(value[key])),
      ];
      return CborMap.fromEntries(entries, type: CborLengthType.definite);
    }
    throw ProtocolException('Unsupported CBOR value: ${value.runtimeType}');
  }

  static Object? _toDart(CborValue value) {
    if (value is CborNull) return null;
    if (value is CborBool) return value.value;
    if (value is CborSmallInt) return value.value;
    if (value is CborInt) return value.toInt();
    if (value is CborString) return value.toString();
    if (value is CborBytes) return Uint8List.fromList(value.bytes);
    if (value is CborList) {
      return value.map<Object?>(_toDart).toList(growable: false);
    }
    if (value is CborMap) {
      final map = <String, Object?>{};
      for (final entry in value.entries) {
        final key = _toDart(entry.key);
        if (key is! String) {
          throw const ProtocolException('CBOR map keys must be strings');
        }
        map[key] = _toDart(entry.value);
      }
      return map;
    }
    throw ProtocolException('Unsupported CBOR value: $value');
  }
}
