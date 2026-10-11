import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const String _hexAlphabet = '0123456789abcdef';

/// Encodes [bytes] as a lowercase (or uppercase) hex string.
String bytesToHex(List<int> bytes, {bool upperCase = false}) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(_hexAlphabet[(byte >> 4) & 0x0f]);
    buffer.write(_hexAlphabet[byte & 0x0f]);
  }
  final value = buffer.toString();
  return upperCase ? value.toUpperCase() : value;
}

/// Decodes a hex string into bytes. Throws [FormatException] on bad input.
Uint8List hexToBytes(String hex) {
  final cleaned = hex.trim();
  if (cleaned.length.isOdd) {
    throw FormatException('Hex string must have an even length', hex);
  }
  final out = Uint8List(cleaned.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(cleaned.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      throw FormatException('Invalid hex character', hex);
    }
    out[i] = byte;
  }
  return out;
}

/// Constant-time byte comparison for MACs and signatures.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

final Random _secureRandom = Random.secure();

/// Cryptographically secure random bytes.
///
/// The `cryptography` package provides secure random generation, but we keep a
/// thin wrapper so that the traffic of a single platform RNG is easy to audit.
Uint8List randomBytes(int length) {
  if (length <= 0) return Uint8List(0);
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = _secureRandom.nextInt(256);
  }
  return out;
}

/// Concatenates several byte lists into a single [Uint8List].
Uint8List concatBytes(List<List<int>> parts) {
  var total = 0;
  for (final part in parts) {
    total += part.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}

/// SHA-256 digest of [data].
Future<Uint8List> sha256(List<int> data) async {
  final hash = await Sha256().hash(data);
  return Uint8List.fromList(hash.bytes);
}

/// Synchronously copies a list into a fixed-length [Uint8List].
Uint8List asUint8List(List<int> data) =>
    data is Uint8List ? data : Uint8List.fromList(data);
