import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import 'bytes.dart';

/// Length of a raw message / bundle identifier in bytes.
const int kMessageIdBytes = 16;

/// Length of an identity id, in hex characters (128 bits + `fid_` prefix).
const String kIdentityIdPrefix = 'fid_';

/// Identifier helpers.
///
/// Message IDs and bundle IDs are random byte strings with 128 bits of entropy.
/// UUIDs are used for friend-request IDs so they are human-logable and stable.
class Ids {
  Ids._();

  static const Uuid _uuid = Uuid();

  /// New RFC-4122 v4 UUID (used for friend request ids).
  static String newUuid() => _uuid.v4();

  /// New random 128-bit message id.
  static Uint8List newMessageId() => randomBytes(kMessageIdBytes);

  /// New random 128-bit bundle id.
  static Uint8List newBundleId() => randomBytes(kMessageIdBytes);

  /// Hex form of a new message id.
  static String newMessageIdHex() => bytesToHex(newMessageId());
}
