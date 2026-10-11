import '../entities/friend.dart';
import '../entities/friend_request.dart';

/// Persistence for friendships, friend requests and blocks.
abstract class FriendRepository {
  Future<void> upsertFriend(FriendRecord friend);

  Future<FriendRecord?> findFriend(String peerId);

  Future<List<FriendRecord>> allFriends();

  Future<List<FriendRecord>> acceptedFriends();

  /// Atomic transition to accepted; returns the resulting record.
  Future<FriendRecord> acceptFriend(String peerId, int verifiedAtMs);

  Future<void> deleteFriend(String peerId);

  // --- Friend requests -------------------------------------------------------

  /// Inserts a request. Returns `false` if the request id already existed
  /// (idempotent insert).
  Future<bool> insertRequest(FriendRequestRecord request);

  Future<FriendRequestRecord?> findRequest(String requestId);

  /// Finds a still-pending request from [fromId] to [toId].
  Future<FriendRequestRecord?> findPendingRequest({
    required String fromId,
    required String toId,
  });

  /// Finds any pending request between the two identities, in either direction.
  Future<List<FriendRequestRecord>> pendingRequestsBetween(String a, String b);

  Future<List<FriendRequestRecord>> allRequests();

  Future<List<FriendRequestRecord>> requestsForPeer(String peerId);

  Future<void> updateRequestState(String requestId, FriendRequestState state);

  /// Expires pending requests past [nowMs]; returns the count affected.
  Future<int> expireRequests(int nowMs);

  // --- Blocking --------------------------------------------------------------

  Future<void> setBlocked(
    String identityId, {
    required bool blocked,
    required int nowMs,
  });

  Future<bool> isBlocked(String identityId);

  Future<List<String>> blockedIds();
}
