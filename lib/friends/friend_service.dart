import 'dart:async';
import 'dart:typed_data';

import '../core/config/app_config.dart';
import '../core/errors/app_exception.dart';
import '../core/protocol/envelope.dart';
import '../core/utils/clock.dart';
import '../core/utils/ids.dart';
import '../crypto/identity_holder.dart';
import '../crypto/identity_record.dart';
import '../domain/entities/friend.dart';
import '../domain/entities/friend_request.dart';
import '../domain/entities/known_identity.dart';
import '../domain/repositories/friend_repository.dart';
import '../domain/repositories/identity_repository.dart';
import '../messaging/bundle_outbox.dart';
import '../messaging/signed_bundle.dart';
import 'friend_protocol.dart';

/// Outcome of processing an inbound friend-protocol envelope.
enum FriendInboundOutcome {
  /// Envelope was irrelevant, blocked or otherwise deliberately dropped.
  ignored,

  /// An incoming request was stored and now awaits the user's decision.
  requestPending,

  /// An incoming request arrived while we also had an outgoing request, so the
  /// two were reconciled by accepting the incoming one.
  requestAutoAccepted,

  /// The same request (or a retry) had already been seen; state is unchanged.
  duplicate,

  /// Our outgoing request was accepted by the peer.
  accepted,

  /// Our accepted request was confirmed by the peer.
  confirmed,

  /// Our outgoing request was declined by the peer.
  declined,
}

/// The mutual-acceptance friend protocol.
///
/// Nothing here trusts a display name: every state transition is driven by an
/// authenticated, self-signed bundle and bound to a specific request id plus a
/// fingerprint of that request. Requests are idempotent (duplicate-safe) and
/// expire independently of the message TTL.
class FriendService {
  FriendService({
    required FriendRepository friends,
    required IdentityRepository identities,
    required BundleOutbox outbox,
    required IdentityHolder identityHolder,
    required Clock clock,
    required AppConfig config,
  }) : _friends = friends,
       _identities = identities,
       _outbox = outbox,
       _identityHolder = identityHolder,
       _clock = clock,
       _config = config;

  final FriendRepository _friends;
  final IdentityRepository _identities;
  final BundleOutbox _outbox;
  final IdentityHolder _identityHolder;
  final Clock _clock;
  final AppConfig _config;

  final StreamController<FriendRequestRecord> _incomingRequests =
      StreamController<FriendRequestRecord>.broadcast();
  final StreamController<FriendRecord> _friendshipChanges =
      StreamController<FriendRecord>.broadcast();

  /// Incoming requests that await a local decision.
  Stream<FriendRequestRecord> get incomingRequests => _incomingRequests.stream;

  /// Any friendship state change (accept/confirm/decline/block).
  Stream<FriendRecord> get friendshipChanges => _friendshipChanges.stream;

  int get _nowMs => _clock.now().millisecondsSinceEpoch;

  // --- Local actions ---------------------------------------------------------

  /// Remembers a scanned/known public identity.
  ///
  /// A QR scan is an explicit, out-of-band key exchange and therefore marks the
  /// identity as verified, but it does *not* create an accepted friendship.
  Future<KnownIdentity> rememberIdentity(
    IdentityRecord record, {
    required bool verified,
  }) async {
    if (!await record.verify()) {
      throw const CryptoException('Identity record failed verification');
    }
    if (verified) {
      return _identities.storeVerified(record, nowMs: _nowMs);
    }
    final existing = await _identities.find(record.identityId);
    final known = KnownIdentity(
      record: record,
      isLocal: false,
      firstSeenMs: existing?.firstSeenMs ?? _nowMs,
      lastSeenMs: _nowMs,
      verifiedAtMs: existing?.verifiedAtMs,
    );
    await _identities.upsert(known);
    return known;
  }

  /// Sends a friend request to [peer], or reconciles if the peer already sent us
  /// one. Retries are safe: the user-visible logical action is idempotent.
  Future<FriendRecord> sendRequest({required IdentityRecord peer}) async {
    final me = _identityHolder.requireIdentity;
    if (peer.identityId == me.identityId) {
      throw const ValidationException('Cannot add your own identity');
    }
    if (await _friends.isBlocked(peer.identityId)) {
      throw const StateTransitionException('This contact is blocked');
    }
    await rememberIdentity(peer, verified: false);

    final existing = await _friends.findFriend(peer.identityId);
    if (existing != null && existing.isAccepted) {
      return existing;
    }

    final now = _nowMs;

    // Simultaneous-request reconciliation: the peer got here first, so accept
    // their request instead of creating a second logical request.
    final pending = await _friends.pendingRequestsBetween(
      me.identityId,
      peer.identityId,
    );
    final incoming = pending.where(
      (r) =>
          r.direction == FriendRequestDirection.incoming &&
          r.fromId == peer.identityId &&
          !r.isExpiredAt(now),
    );
    if (incoming.isNotEmpty) {
      await acceptRequest(incoming.first, peerRecord: peer);
      return (await _friends.findFriend(peer.identityId))!;
    }

    final requestId = Ids.newUuid();
    final expiresAt = now + _config.friendRequestTtl.inMilliseconds;
    final outgoing = FriendRequestRecord(
      requestId: requestId,
      fromId: me.identityId,
      toId: peer.identityId,
      direction: FriendRequestDirection.outgoing,
      state: FriendRequestState.pending,
      protocolVersion: FriendProtocol.version,
      createdAtMs: now,
      expiresAtMs: expiresAt,
    );
    await _friends.insertRequest(outgoing);

    final friend = FriendRecord(
      peerId: peer.identityId,
      displayName: peer.displayName,
      status: FriendStatus.pendingOutgoing,
      createdAtMs: existing?.createdAtMs ?? now,
      lastSeenAtMs: now,
    );
    await _friends.upsertFriend(friend);
    await _enqueueRequest(outgoing, peer);
    _friendshipChanges.add(friend);
    return friend;
  }

  /// Accepts an incoming request and notifies the requester.
  Future<FriendRecord> acceptRequest(
    FriendRequestRecord request, {
    IdentityRecord? peerRecord,
  }) async {
    if (request.direction != FriendRequestDirection.incoming) {
      throw const StateTransitionException(
        'Only incoming requests can be accepted',
      );
    }
    final now = _nowMs;
    if (request.isExpiredAt(now)) {
      await _friends.updateRequestState(
        request.requestId,
        FriendRequestState.expired,
      );
      throw const ExpiredException('This friend request has expired');
    }
    if (await _friends.isBlocked(request.fromId)) {
      throw const StateTransitionException('This contact is blocked');
    }

    final record =
        peerRecord ?? (await _identities.find(request.fromId))?.record;
    if (record == null) {
      throw const StateTransitionException('Unknown peer for this request');
    }
    await rememberIdentity(record, verified: true);
    await _friends.updateRequestState(
      request.requestId,
      FriendRequestState.accepted,
    );

    final friend = FriendRecord(
      peerId: request.fromId,
      displayName: record.displayName,
      status: FriendStatus.accepted,
      createdAtMs: request.createdAtMs,
      verifiedAtMs: now,
      lastSeenAtMs: now,
    );
    await _friends.upsertFriend(friend);
    await _enqueueResponse(
      request: request,
      recipient: record,
      type: EnvelopeType.friendAccept,
    );
    _friendshipChanges.add(friend);
    return friend;
  }

  /// Declines an incoming request.
  Future<void> declineRequest(
    FriendRequestRecord request, {
    IdentityRecord? peerRecord,
  }) async {
    final record =
        peerRecord ?? (await _identities.find(request.fromId))?.record;
    await _friends.updateRequestState(
      request.requestId,
      FriendRequestState.declined,
    );
    if (record != null) {
      final friend = FriendRecord(
        peerId: request.fromId,
        displayName: record.displayName,
        status: FriendStatus.declined,
        createdAtMs: request.createdAtMs,
        lastSeenAtMs: _nowMs,
      );
      await _friends.upsertFriend(friend);
      await _enqueueResponse(
        request: request,
        recipient: record,
        type: EnvelopeType.friendDecline,
      );
      _friendshipChanges.add(friend);
    }
  }

  /// Locally blocks or unblocks an identity. Blocked peers are dropped before
  /// any state is touched.
  Future<void> block(String identityId, {required bool blocked}) async {
    await _friends.setBlocked(identityId, blocked: blocked, nowMs: _nowMs);
    final friend = await _friends.findFriend(identityId);
    if (friend != null) _friendshipChanges.add(friend);
  }

  /// Re-enqueues still-pending outgoing requests. This never creates a new
  /// logical request: the deterministic bundle id is reused.
  Future<int> retryPendingRequests() async {
    var count = 0;
    for (final request in await _friends.allRequests()) {
      if (request.state != FriendRequestState.pending) continue;
      if (request.direction != FriendRequestDirection.outgoing) continue;
      if (request.isExpiredAt(_nowMs)) continue;
      final peer = await _identities.find(request.toId);
      if (peer == null) continue;
      await _enqueueRequest(request, peer.record);
      count++;
    }
    return count;
  }

  /// Expires stale pending requests. Returns the number affected.
  Future<int> expireRequests() => _friends.expireRequests(_nowMs);

  // --- Inbound handling ------------------------------------------------------

  /// Processes a decrypted, signed friend-protocol envelope.
  Future<FriendInboundOutcome> handleIncoming(OpenedBundle opened) async {
    final me = _identityHolder.requireIdentity;
    final senderId = opened.sender.identityId;
    if (senderId == me.identityId) return FriendInboundOutcome.ignored;
    if (await _friends.isBlocked(senderId)) return FriendInboundOutcome.ignored;

    switch (opened.type) {
      case EnvelopeType.friendRequest:
        return _handleRequest(opened);
      case EnvelopeType.friendAccept:
        return _handleAccept(opened);
      case EnvelopeType.friendConfirm:
        return _handleConfirm(opened);
      case EnvelopeType.friendDecline:
        return _handleDecline(opened);
      default:
        return FriendInboundOutcome.ignored;
    }
  }

  Future<FriendInboundOutcome> _handleRequest(OpenedBundle opened) async {
    final me = _identityHolder.requireIdentity;
    final payload = FriendProtocol.parseRequest(
      opened.payload,
      recipientId: me.identityId,
    );
    final now = _nowMs;
    if (now >= payload.expiresAtMs) return FriendInboundOutcome.ignored;

    final sender = opened.sender;
    await rememberIdentity(sender, verified: false);

    final existingRequest = await _friends.findRequest(payload.requestId);
    if (existingRequest != null) {
      // Duplicate of a request we already know about. If we had accepted it,
      // resend the acceptance so a lost response can still be recovered.
      if (existingRequest.state == FriendRequestState.accepted) {
        final peer = await _identities.find(sender.identityId);
        final record = peer?.record ?? sender;
        await _enqueueResponse(
          request: existingRequest,
          recipient: record,
          type: EnvelopeType.friendAccept,
        );
      }
      return FriendInboundOutcome.duplicate;
    }

    final friend = await _friends.findFriend(sender.identityId);
    if (friend != null && friend.isAccepted) {
      return FriendInboundOutcome.ignored;
    }

    final incoming = FriendRequestRecord(
      requestId: payload.requestId,
      fromId: sender.identityId,
      toId: me.identityId,
      direction: FriendRequestDirection.incoming,
      state: FriendRequestState.pending,
      protocolVersion: payload.protocolVersion,
      createdAtMs: payload.createdAtMs,
      expiresAtMs: payload.expiresAtMs,
      peerDisplayName: payload.displayName,
    );
    final inserted = await _friends.insertRequest(incoming);
    if (!inserted) return FriendInboundOutcome.duplicate;

    await _friends.upsertFriend(
      FriendRecord(
        peerId: sender.identityId,
        displayName: payload.displayName,
        status: FriendStatus.pendingIncoming,
        createdAtMs: payload.createdAtMs,
        lastSeenAtMs: now,
      ),
    );

    // Simultaneous requests => auto-reconcile by accepting the incoming one.
    final outgoing = await _friends.findPendingRequest(
      fromId: me.identityId,
      toId: sender.identityId,
    );
    if (outgoing != null) {
      await acceptRequest(incoming, peerRecord: sender);
      return FriendInboundOutcome.requestAutoAccepted;
    }

    _incomingRequests.add(incoming);
    return FriendInboundOutcome.requestPending;
  }

  Future<FriendInboundOutcome> _handleAccept(OpenedBundle opened) async {
    final me = _identityHolder.requireIdentity;
    final payload = FriendProtocol.parseResponse(
      opened.payload,
      recipientId: me.identityId,
      expected: EnvelopeType.friendAccept,
    );
    final request = await _friends.findRequest(payload.requestId);
    if (request == null) return FriendInboundOutcome.ignored;
    if (request.direction != FriendRequestDirection.outgoing) {
      return FriendInboundOutcome.ignored;
    }
    if (!await _fingerprintMatches(request, payload.requestFingerprint)) {
      return FriendInboundOutcome.ignored;
    }
    if (request.fromId != me.identityId ||
        request.toId != opened.sender.identityId) {
      return FriendInboundOutcome.ignored;
    }

    final now = _nowMs;
    if (request.isExpiredAt(now) &&
        request.state == FriendRequestState.pending) {
      await _friends.updateRequestState(
        request.requestId,
        FriendRequestState.expired,
      );
      return FriendInboundOutcome.ignored;
    }
    // Retry: an acceptance for an already-accepted request just triggers another
    // confirmation, never a second logical relationship.
    final alreadyAccepted = request.state == FriendRequestState.accepted;

    await rememberIdentity(opened.sender, verified: true);
    await _friends.updateRequestState(
      request.requestId,
      FriendRequestState.accepted,
    );
    final friend = FriendRecord(
      peerId: opened.sender.identityId,
      displayName: opened.sender.displayName,
      status: FriendStatus.accepted,
      createdAtMs: request.createdAtMs,
      verifiedAtMs: now,
      lastSeenAtMs: now,
    );
    await _friends.upsertFriend(friend);
    await _enqueueResponse(
      request: request,
      recipient: opened.sender,
      type: EnvelopeType.friendConfirm,
    );
    _friendshipChanges.add(friend);
    return alreadyAccepted
        ? FriendInboundOutcome.duplicate
        : FriendInboundOutcome.accepted;
  }

  Future<FriendInboundOutcome> _handleConfirm(OpenedBundle opened) async {
    final me = _identityHolder.requireIdentity;
    final payload = FriendProtocol.parseResponse(
      opened.payload,
      recipientId: me.identityId,
      expected: EnvelopeType.friendConfirm,
    );
    final request = await _friends.findRequest(payload.requestId);
    if (request == null) return FriendInboundOutcome.ignored;
    if (request.toId != me.identityId ||
        request.fromId != opened.sender.identityId) {
      return FriendInboundOutcome.ignored;
    }
    if (!await _fingerprintMatches(request, payload.requestFingerprint)) {
      return FriendInboundOutcome.ignored;
    }
    final now = _nowMs;
    await rememberIdentity(opened.sender, verified: true);
    await _friends.updateRequestState(
      request.requestId,
      FriendRequestState.confirmed,
    );
    final friend = FriendRecord(
      peerId: opened.sender.identityId,
      displayName: opened.sender.displayName,
      status: FriendStatus.accepted,
      createdAtMs: request.createdAtMs,
      verifiedAtMs: now,
      lastSeenAtMs: now,
    );
    await _friends.upsertFriend(friend);
    _friendshipChanges.add(friend);
    return FriendInboundOutcome.confirmed;
  }

  Future<FriendInboundOutcome> _handleDecline(OpenedBundle opened) async {
    final me = _identityHolder.requireIdentity;
    final payload = FriendProtocol.parseResponse(
      opened.payload,
      recipientId: me.identityId,
      expected: EnvelopeType.friendDecline,
    );
    final request = await _friends.findRequest(payload.requestId);
    if (request == null) return FriendInboundOutcome.ignored;
    if (request.direction != FriendRequestDirection.outgoing) {
      return FriendInboundOutcome.ignored;
    }
    if (!await _fingerprintMatches(request, payload.requestFingerprint)) {
      return FriendInboundOutcome.ignored;
    }
    await _friends.updateRequestState(
      request.requestId,
      FriendRequestState.declined,
    );
    final friend = FriendRecord(
      peerId: opened.sender.identityId,
      displayName: opened.sender.displayName,
      status: FriendStatus.declined,
      createdAtMs: request.createdAtMs,
      lastSeenAtMs: _nowMs,
    );
    await _friends.upsertFriend(friend);
    _friendshipChanges.add(friend);
    return FriendInboundOutcome.declined;
  }

  Future<bool> _fingerprintMatches(
    FriendRequestRecord request,
    String fingerprint,
  ) async {
    final expected = await FriendProtocol.requestFingerprint(
      requestId: request.requestId,
      fromId: request.fromId,
      toId: request.toId,
      createdAtMs: request.createdAtMs,
      expiresAtMs: request.expiresAtMs,
      protocolVersion: request.protocolVersion,
    );
    return expected == fingerprint;
  }

  Future<void> _enqueueRequest(
    FriendRequestRecord request,
    IdentityRecord peer,
  ) async {
    final me = _identityHolder.requireIdentity;
    final bundleId = await FriendProtocol.deriveBundleId(
      type: EnvelopeType.friendRequest,
      requestId: request.requestId,
      fromId: me.identityId,
      toId: peer.identityId,
    );
    await _outbox.enqueue(
      sender: me,
      recipient: peer,
      type: EnvelopeType.friendRequest,
      bundleId: bundleId,
      expiresAtMs: request.expiresAtMs,
      payload: FriendProtocol.buildRequestPayload(
        requestId: request.requestId,
        toId: peer.identityId,
        createdAtMs: request.createdAtMs,
        expiresAtMs: request.expiresAtMs,
        displayName: me.displayName,
      ),
    );
  }

  Future<void> _enqueueResponse({
    required FriendRequestRecord request,
    required IdentityRecord recipient,
    required EnvelopeType type,
  }) async {
    final me = _identityHolder.requireIdentity;
    final fingerprint = await FriendProtocol.requestFingerprint(
      requestId: request.requestId,
      fromId: request.fromId,
      toId: request.toId,
      createdAtMs: request.createdAtMs,
      expiresAtMs: request.expiresAtMs,
      protocolVersion: request.protocolVersion,
    );
    final now = _nowMs;
    final expiresAt = now + _config.friendRequestTtl.inMilliseconds;
    final bundleId = await FriendProtocol.deriveBundleId(
      type: type,
      requestId: request.requestId,
      fromId: me.identityId,
      toId: recipient.identityId,
    );
    await _outbox.enqueue(
      sender: me,
      recipient: recipient,
      type: type,
      bundleId: bundleId,
      expiresAtMs: expiresAt,
      payload: FriendProtocol.buildResponsePayload(
        requestId: request.requestId,
        toId: recipient.identityId,
        createdAtMs: now,
        expiresAtMs: expiresAt,
        requestFingerprint: fingerprint,
        type: type,
      ),
    );
  }

  Future<void> dispose() async {
    await _incomingRequests.close();
    await _friendshipChanges.close();
  }
}

/// Exposed for tests: a bundle id used for a friend request.
Future<Uint8List> friendBundleId({
  required EnvelopeType type,
  required String requestId,
  required String fromId,
  required String toId,
}) => FriendProtocol.deriveBundleId(
  type: type,
  requestId: requestId,
  fromId: fromId,
  toId: toId,
);
