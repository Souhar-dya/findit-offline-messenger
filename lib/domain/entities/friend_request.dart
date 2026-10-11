/// Direction of a friend request relative to the local user.
enum FriendRequestDirection { incoming, outgoing }

/// Lifecycle of a friend request.
enum FriendRequestState {
  pending('pending'),
  accepted('accepted'),
  confirmed('confirmed'),
  declined('declined'),
  expired('expired');

  const FriendRequestState(this.wire);

  final String wire;

  static FriendRequestState fromWire(String wire) {
    for (final value in FriendRequestState.values) {
      if (value.wire == wire) return value;
    }
    throw ArgumentError('Unknown friend request state: $wire');
  }
}

/// A friend request as stored locally.
class FriendRequestRecord {
  const FriendRequestRecord({
    required this.requestId,
    required this.fromId,
    required this.toId,
    required this.direction,
    required this.state,
    required this.protocolVersion,
    required this.createdAtMs,
    required this.expiresAtMs,
    this.peerDisplayName,
    this.senderIdentityId,
  });

  /// Unique, stable protocol request id (UUID v4).
  final String requestId;
  final String fromId;
  final String toId;
  final FriendRequestDirection direction;
  final FriendRequestState state;
  final int protocolVersion;
  final int createdAtMs;
  final int expiresAtMs;

  /// The display name advertised with the request (non-unique, informational).
  final String? peerDisplayName;

  /// The identity id of the party that signed the request, if available.
  final String? senderIdentityId;

  FriendRequestRecord copyWith({
    FriendRequestState? state,
    String? peerDisplayName,
    String? senderIdentityId,
  }) {
    return FriendRequestRecord(
      requestId: requestId,
      fromId: fromId,
      toId: toId,
      direction: direction,
      state: state ?? this.state,
      protocolVersion: protocolVersion,
      createdAtMs: createdAtMs,
      expiresAtMs: expiresAtMs,
      peerDisplayName: peerDisplayName ?? this.peerDisplayName,
      senderIdentityId: senderIdentityId ?? this.senderIdentityId,
    );
  }

  bool isExpiredAt(int nowMs) => nowMs >= expiresAtMs;
}
