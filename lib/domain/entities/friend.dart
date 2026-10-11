import '../../crypto/identity_record.dart';

/// Friendship lifecycle.
enum FriendStatus {
  /// We sent a request and are waiting for the peer's acceptance.
  pendingOutgoing('pending_outgoing'),

  /// The peer sent a request and we have not decided yet.
  pendingIncoming('pending_incoming'),

  /// Both sides accepted; the friendship is active.
  accepted('accepted'),

  /// We or the peer declined. The record is kept to avoid re-prompting.
  declined('declined'),

  /// Locally blocked; no protocol traffic is processed for this peer.
  blocked('blocked');

  const FriendStatus(this.wire);

  final String wire;

  static FriendStatus fromWire(String wire) {
    for (final value in FriendStatus.values) {
      if (value.wire == wire) return value;
    }
    throw ArgumentError('Unknown friend status: $wire');
  }
}

/// A stored contact.
///
/// Discovered identities are *not* friends. A [FriendRecord] is only created
/// after a mutual request/accept exchange or after the user explicitly adds a
/// scanned identity.
class FriendRecord {
  const FriendRecord({
    required this.peerId,
    required this.displayName,
    required this.status,
    required this.createdAtMs,
    this.verifiedAtMs,
    this.lastSeenAtMs,
    this.identityRecord,
  });

  final String peerId;
  final String displayName;
  final FriendStatus status;
  final int createdAtMs;

  /// When the key binding was confirmed (QR scan or authenticated acceptance).
  final int? verifiedAtMs;
  final int? lastSeenAtMs;

  /// The last verified public identity record for this peer, if known.
  final IdentityRecord? identityRecord;

  bool get isAccepted => status == FriendStatus.accepted;

  bool get isPending =>
      status == FriendStatus.pendingIncoming ||
      status == FriendStatus.pendingOutgoing;

  /// A contact is "verified" when we have cryptographically confirmed the key
  /// binding, as opposed to having merely discovered the identity.
  bool get isVerified => verifiedAtMs != null;

  FriendRecord copyWith({
    String? displayName,
    FriendStatus? status,
    int? verifiedAtMs,
    int? lastSeenAtMs,
    IdentityRecord? identityRecord,
  }) {
    return FriendRecord(
      peerId: peerId,
      displayName: displayName ?? this.displayName,
      status: status ?? this.status,
      createdAtMs: createdAtMs,
      verifiedAtMs: verifiedAtMs ?? this.verifiedAtMs,
      lastSeenAtMs: lastSeenAtMs ?? this.lastSeenAtMs,
      identityRecord: identityRecord ?? this.identityRecord,
    );
  }
}
