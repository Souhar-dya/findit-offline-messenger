import 'dart:convert';
import 'dart:typed_data';

import '../core/cbor/canonical_cbor.dart';
import '../core/errors/app_exception.dart';
import '../core/protocol/envelope.dart';
import '../core/utils/bytes.dart';
import '../core/utils/ids.dart';

/// Payload builders / validators for the four friend-protocol messages, plus
/// deterministic bundle-id derivation so retries reuse the same logical bundle.
class FriendProtocol {
  FriendProtocol._();

  static const int version = 1;

  /// Derives a stable bundle id for a protocol message so that retransmissions
  /// deduplicate at the routing layer and do not create new logical requests.
  static Future<Uint8List> deriveBundleId({
    required EnvelopeType type,
    required String requestId,
    required String fromId,
    required String toId,
  }) async {
    final digest = await sha256(
      utf8.encode('findit/friend/${type.wire}/$requestId/$fromId/$toId'),
    );
    return Uint8List.fromList(digest.sublist(0, kMessageIdBytes));
  }

  /// Fingerprint of a friend request, used to bind an acceptance to the exact
  /// request it answers.
  static Future<String> requestFingerprint({
    required String requestId,
    required String fromId,
    required String toId,
    required int createdAtMs,
    required int expiresAtMs,
    int protocolVersion = version,
  }) async {
    final bytes = CanonicalCbor.encode({
      'rid': requestId,
      'from': fromId,
      'to': toId,
      'iat': createdAtMs,
      'exp': expiresAtMs,
      'ver': protocolVersion,
    });
    return bytesToHex(await sha256(bytes));
  }

  static Map<String, Object?> buildRequestPayload({
    required String requestId,
    required String toId,
    required int createdAtMs,
    required int expiresAtMs,
    required String displayName,
  }) => {
    'rid': requestId,
    'to': toId,
    'iat': createdAtMs,
    'exp': expiresAtMs,
    'ver': version,
    'name': displayName,
  };

  static Map<String, Object?> buildResponsePayload({
    required String requestId,
    required String toId,
    required int createdAtMs,
    required int expiresAtMs,
    required String requestFingerprint,
    required EnvelopeType type,
  }) => {
    'rid': requestId,
    'to': toId,
    'iat': createdAtMs,
    'exp': expiresAtMs,
    'ver': version,
    'rfp': requestFingerprint,
    'kind': type.wire,
  };

  /// Validates a request payload and returns its fields.
  static FriendRequestPayload parseRequest(
    Map<String, Object?> payload, {
    required String recipientId,
  }) {
    try {
      final requestId = payload['rid'] as String;
      final to = payload['to'] as String;
      final createdAt = payload['iat'] as int;
      final expiresAt = payload['exp'] as int;
      final version = payload['ver'] as int;
      final name = payload['name'] as String;
      if (to != recipientId) {
        throw const ProtocolException('Friend request addressed elsewhere');
      }
      if (version != FriendProtocol.version) {
        throw const ProtocolException('Unsupported friend protocol version');
      }
      if (requestId.isEmpty || expiresAt <= createdAt) {
        throw const ProtocolException('Friend request has invalid fields');
      }
      return FriendRequestPayload(
        requestId: requestId,
        recipientId: to,
        createdAtMs: createdAt,
        expiresAtMs: expiresAt,
        displayName: name,
        protocolVersion: version,
      );
    } on ProtocolException {
      rethrow;
    } catch (error) {
      throw ProtocolException('Malformed friend request payload', cause: error);
    }
  }

  static FriendResponsePayload parseResponse(
    Map<String, Object?> payload, {
    required String recipientId,
    required EnvelopeType expected,
  }) {
    try {
      final requestId = payload['rid'] as String;
      final to = payload['to'] as String;
      final createdAt = payload['iat'] as int;
      final expiresAt = payload['exp'] as int;
      final version = payload['ver'] as int;
      final fingerprint = payload['rfp'] as String;
      final kind = payload['kind'] as String;
      if (kind != expected.wire) {
        throw const ProtocolException('Friend response kind mismatch');
      }
      if (to != recipientId) {
        throw const ProtocolException('Friend response addressed elsewhere');
      }
      if (version != FriendProtocol.version) {
        throw const ProtocolException('Unsupported friend protocol version');
      }
      return FriendResponsePayload(
        requestId: requestId,
        recipientId: to,
        createdAtMs: createdAt,
        expiresAtMs: expiresAt,
        requestFingerprint: fingerprint,
        protocolVersion: version,
        type: expected,
      );
    } on ProtocolException {
      rethrow;
    } catch (error) {
      throw ProtocolException(
        'Malformed friend response payload',
        cause: error,
      );
    }
  }
}

class FriendRequestPayload {
  const FriendRequestPayload({
    required this.requestId,
    required this.recipientId,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.displayName,
    required this.protocolVersion,
  });

  final String requestId;
  final String recipientId;
  final int createdAtMs;
  final int expiresAtMs;
  final String displayName;
  final int protocolVersion;
}

class FriendResponsePayload {
  const FriendResponsePayload({
    required this.requestId,
    required this.recipientId,
    required this.createdAtMs,
    required this.expiresAtMs,
    required this.requestFingerprint,
    required this.protocolVersion,
    required this.type,
  });

  final String requestId;
  final String recipientId;
  final int createdAtMs;
  final int expiresAtMs;
  final String requestFingerprint;
  final int protocolVersion;
  final EnvelopeType type;
}
