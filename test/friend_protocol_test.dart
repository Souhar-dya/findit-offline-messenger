import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/core/protocol/envelope.dart';
import 'package:findit/core/utils/bytes.dart';
import 'package:findit/core/utils/ids.dart';
import 'package:findit/crypto/identity_service.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/domain/entities/friend.dart';
import 'package:findit/domain/entities/friend_request.dart';
import 'package:findit/friends/friend_protocol.dart';
import 'package:findit/friends/friend_service.dart';
import 'package:findit/messaging/signed_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<FriendRequestRecord> outgoingRequest(
  TestNode node,
  TestNode peer,
) async {
  final requests = await node.core.friends.requestsForPeer(peer.id);
  return requests.firstWhere(
    (request) => request.direction == FriendRequestDirection.outgoing,
  );
}

Future<FriendRequestRecord> incomingRequest(
  TestNode node,
  TestNode peer,
) async {
  final requests = await node.core.friends.requestsForPeer(peer.id);
  return requests.firstWhere(
    (request) => request.direction == FriendRequestDirection.incoming,
  );
}

Future<OpenedBundle> deliverFriendBundle({
  required TestNode from,
  required TestNode to,
  required EnvelopeType type,
  required String requestId,
}) async {
  final hex = bytesToHex(
    await friendBundleId(
      type: type,
      requestId: requestId,
      fromId: from.id,
      toId: to.id,
    ),
  );
  final bundle = await from.storedBundle(hex);
  return to.open(bundle.bytes);
}

void main() {
  late TestNode alice;
  late TestNode bob;

  setUp(() async {
    alice = await TestNode.create();
    bob = await TestNode.create();
    await alice.createIdentity('Alice');
    await bob.createIdentity('Bob');
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
  });

  group('Mutual acceptance', () {
    test(
      'completes request -> accept -> confirm into a verified friendship',
      () async {
        await alice.core.friendService.sendRequest(peer: bob.identity!.record);
        final request = await outgoingRequest(alice, bob);

        final incoming = await bob.core.friendService.handleIncoming(
          await deliverFriendBundle(
            from: alice,
            to: bob,
            type: EnvelopeType.friendRequest,
            requestId: request.requestId,
          ),
        );
        expect(incoming, FriendInboundOutcome.requestPending);

        final stored = await incomingRequest(bob, alice);
        expect(stored.state, FriendRequestState.pending);
        final pendingFriend = await bob.core.friends.findFriend(alice.id);
        expect(pendingFriend!.status, FriendStatus.pendingIncoming);

        await bob.core.friendService.acceptRequest(
          stored,
          peerRecord: alice.identity!.record,
        );

        final accepted = await alice.core.friendService.handleIncoming(
          await deliverFriendBundle(
            from: bob,
            to: alice,
            type: EnvelopeType.friendAccept,
            requestId: request.requestId,
          ),
        );
        expect(accepted, FriendInboundOutcome.accepted);

        final confirmed = await bob.core.friendService.handleIncoming(
          await deliverFriendBundle(
            from: alice,
            to: bob,
            type: EnvelopeType.friendConfirm,
            requestId: request.requestId,
          ),
        );
        expect(confirmed, FriendInboundOutcome.confirmed);

        final aliceFriend = await alice.core.friends.findFriend(bob.id);
        final bobFriend = await bob.core.friends.findFriend(alice.id);
        expect(aliceFriend!.status, FriendStatus.accepted);
        expect(bobFriend!.status, FriendStatus.accepted);
        expect(aliceFriend.isVerified, isTrue);
        expect(bobFriend.isVerified, isTrue);
      },
    );

    test(
      'declines an incoming request without creating a friendship',
      () async {
        await alice.core.friendService.sendRequest(peer: bob.identity!.record);
        final request = await outgoingRequest(alice, bob);
        await bob.core.friendService.handleIncoming(
          await deliverFriendBundle(
            from: alice,
            to: bob,
            type: EnvelopeType.friendRequest,
            requestId: request.requestId,
          ),
        );

        final stored = await incomingRequest(bob, alice);
        await bob.core.friendService.declineRequest(
          stored,
          peerRecord: alice.identity!.record,
        );
        expect(
          (await bob.core.friends.findFriend(alice.id))!.status,
          FriendStatus.declined,
        );

        final declined = await alice.core.friendService.handleIncoming(
          await deliverFriendBundle(
            from: bob,
            to: alice,
            type: EnvelopeType.friendDecline,
            requestId: request.requestId,
          ),
        );
        expect(declined, FriendInboundOutcome.declined);
        expect(
          (await alice.core.friends.findFriend(bob.id))!.status,
          FriendStatus.declined,
        );
        expect(
          (await alice.core.friends.findRequest(request.requestId))!.state,
          FriendRequestState.declined,
        );
      },
    );

    test('reconciles simultaneous requests into a single friendship', () async {
      await alice.core.friendService.sendRequest(peer: bob.identity!.record);
      await bob.core.friendService.sendRequest(peer: alice.identity!.record);
      final aliceRequest = await outgoingRequest(alice, bob);

      final outcome = await bob.core.friendService.handleIncoming(
        await deliverFriendBundle(
          from: alice,
          to: bob,
          type: EnvelopeType.friendRequest,
          requestId: aliceRequest.requestId,
        ),
      );
      expect(outcome, FriendInboundOutcome.requestAutoAccepted);

      final accepted = await alice.core.friendService.handleIncoming(
        await deliverFriendBundle(
          from: bob,
          to: alice,
          type: EnvelopeType.friendAccept,
          requestId: aliceRequest.requestId,
        ),
      );
      expect(accepted, FriendInboundOutcome.accepted);

      expect(
        (await alice.core.friends.findFriend(bob.id))!.status,
        FriendStatus.accepted,
      );
      expect(
        (await bob.core.friends.findFriend(alice.id))!.status,
        FriendStatus.accepted,
      );
    });
  });

  group('Idempotency and retries', () {
    test('ignores a duplicate request and keeps a single record', () async {
      await alice.core.friendService.sendRequest(peer: bob.identity!.record);
      final request = await outgoingRequest(alice, bob);

      final first = await bob.core.friendService.handleIncoming(
        await deliverFriendBundle(
          from: alice,
          to: bob,
          type: EnvelopeType.friendRequest,
          requestId: request.requestId,
        ),
      );
      expect(first, FriendInboundOutcome.requestPending);

      final second = await bob.core.friendService.handleIncoming(
        await deliverFriendBundle(
          from: alice,
          to: bob,
          type: EnvelopeType.friendRequest,
          requestId: request.requestId,
        ),
      );
      expect(second, FriendInboundOutcome.duplicate);

      final incomingCount = (await bob.core.friends.requestsForPeer(
        alice.id,
      )).where((r) => r.direction == FriendRequestDirection.incoming).length;
      expect(incomingCount, 1);
    });

    test(
      're-acknowledges a duplicate acceptance without a second relationship',
      () async {
        await alice.core.friendService.sendRequest(peer: bob.identity!.record);
        final request = await outgoingRequest(alice, bob);
        await bob.core.friendService.handleIncoming(
          await deliverFriendBundle(
            from: alice,
            to: bob,
            type: EnvelopeType.friendRequest,
            requestId: request.requestId,
          ),
        );
        final stored = await incomingRequest(bob, alice);
        await bob.core.friendService.acceptRequest(
          stored,
          peerRecord: alice.identity!.record,
        );

        final accept = await deliverFriendBundle(
          from: bob,
          to: alice,
          type: EnvelopeType.friendAccept,
          requestId: request.requestId,
        );
        expect(
          await alice.core.friendService.handleIncoming(accept),
          FriendInboundOutcome.accepted,
        );
        // Redelivery of the same acceptance is a duplicate, not a new friendship.
        expect(
          await alice.core.friendService.handleIncoming(accept),
          FriendInboundOutcome.duplicate,
        );
        expect((await alice.core.friends.allFriends()).length, 1);
      },
    );

    test(
      'retry re-enqueues the same logical bundle without duplicating it',
      () async {
        await alice.core.friendService.sendRequest(peer: bob.identity!.record);
        final request = await outgoingRequest(alice, bob);
        final hex = bytesToHex(
          await friendBundleId(
            type: EnvelopeType.friendRequest,
            requestId: request.requestId,
            fromId: alice.id,
            toId: bob.id,
          ),
        );
        expect(await alice.core.bundles.exists(hex), isTrue);
        final bytesBefore = await alice.core.bundles.totalBytes();

        expect(await alice.core.friendService.retryPendingRequests(), 1);

        expect(await alice.core.bundles.totalBytes(), bytesBefore);
        expect((await alice.core.friends.allRequests()).length, 1);
      },
    );

    test('only one pending request per pair is stored', () async {
      final now = alice.clock.now().millisecondsSinceEpoch;
      FriendRequestRecord make(String id) => FriendRequestRecord(
        requestId: id,
        fromId: bob.id,
        toId: alice.id,
        direction: FriendRequestDirection.incoming,
        state: FriendRequestState.pending,
        protocolVersion: 1,
        createdAtMs: now,
        expiresAtMs: now + 600000,
      );
      expect(
        await alice.core.friends.insertRequest(make(Ids.newUuid())),
        isTrue,
      );
      expect(
        await alice.core.friends.insertRequest(make(Ids.newUuid())),
        isFalse,
      );
    });
  });

  group('Expiry, blocking and validation', () {
    test('request TTL is independent of the message TTL', () async {
      final node = await TestNode.create(config: AppConfig.production);
      try {
        await node.createIdentity('Dave');
        final peer = await IdentityService(
          secretStore: InMemorySecretStore(),
        ).generate(displayName: 'Peer');
        await node.core.friendService.sendRequest(peer: peer.record);

        final request = (await node.core.friends.requestsForPeer(
          peer.identityId,
        )).single;
        expect(
          request.expiresAtMs - request.createdAtMs,
          AppConfig.production.friendRequestTtl.inMilliseconds,
        );
        expect(
          request.expiresAtMs - request.createdAtMs,
          isNot(AppConfig.production.messageTtl.inMilliseconds),
        );

        node.clock.advance(const Duration(days: 8));
        expect(await node.core.friendService.expireRequests(), 1);
        expect(
          (await node.core.friends.findRequest(request.requestId))!.state,
          FriendRequestState.expired,
        );
      } finally {
        await node.dispose();
      }
    });

    test('cannot accept an expired incoming request', () async {
      final now = alice.clock.now().millisecondsSinceEpoch;
      final request = FriendRequestRecord(
        requestId: Ids.newUuid(),
        fromId: bob.id,
        toId: alice.id,
        direction: FriendRequestDirection.incoming,
        state: FriendRequestState.pending,
        protocolVersion: 1,
        createdAtMs: now - 7200000,
        expiresAtMs: now - 3600000,
      );
      await alice.core.friends.insertRequest(request);

      expect(
        () => alice.core.friendService.acceptRequest(
          request,
          peerRecord: bob.identity!.record,
        ),
        throwsA(isA<ExpiredException>()),
      );
      expect(
        (await alice.core.friends.findRequest(request.requestId))!.state,
        FriendRequestState.expired,
      );
    });

    test('ignores protocol traffic from a blocked identity', () async {
      await bob.core.friendService.block(alice.id, blocked: true);
      await alice.core.friendService.sendRequest(peer: bob.identity!.record);
      final request = await outgoingRequest(alice, bob);

      final outcome = await bob.core.friendService.handleIncoming(
        await deliverFriendBundle(
          from: alice,
          to: bob,
          type: EnvelopeType.friendRequest,
          requestId: request.requestId,
        ),
      );
      expect(outcome, FriendInboundOutcome.ignored);
      expect(await bob.core.friends.findRequest(request.requestId), isNull);
    });

    test(
      'ignores an acceptance whose request fingerprint does not match',
      () async {
        await alice.core.friendService.sendRequest(peer: bob.identity!.record);
        final request = await outgoingRequest(alice, bob);
        final now = bob.clock.now().millisecondsSinceEpoch;
        final expiresAt = now + 3600000;
        final bundleId = await friendBundleId(
          type: EnvelopeType.friendAccept,
          requestId: request.requestId,
          fromId: bob.id,
          toId: alice.id,
        );
        final bytes = await bob.sealFor(
          recipient: alice,
          type: EnvelopeType.friendAccept,
          bundleId: bundleId,
          expiresAtMs: expiresAt,
          payload: FriendProtocol.buildResponsePayload(
            requestId: request.requestId,
            toId: alice.id,
            createdAtMs: now,
            expiresAtMs: expiresAt,
            requestFingerprint: 'deadbeef',
            type: EnvelopeType.friendAccept,
          ),
        );
        final outcome = await alice.core.friendService.handleIncoming(
          await alice.open(bytes),
        );
        expect(outcome, FriendInboundOutcome.ignored);
        expect(
          (await alice.core.friends.findRequest(request.requestId))!.state,
          FriendRequestState.pending,
        );
      },
    );

    test('rejects a request addressed to another identity', () async {
      final now = alice.clock.now().millisecondsSinceEpoch;
      final carol = await IdentityService(
        secretStore: InMemorySecretStore(),
      ).generate(displayName: 'Carol');
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.friendRequest,
        bundleId: randomBytes(16),
        payload: FriendProtocol.buildRequestPayload(
          requestId: Ids.newUuid(),
          toId: carol.identityId,
          createdAtMs: now,
          expiresAtMs: now + 3600000,
          displayName: 'Alice',
        ),
      );
      expect(
        () async =>
            bob.core.friendService.handleIncoming(await bob.open(bytes)),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('ignores a request that pretends to come from ourselves', () async {
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bytes = await alice.sealFor(
        recipient: alice,
        type: EnvelopeType.friendRequest,
        bundleId: randomBytes(16),
        payload: FriendProtocol.buildRequestPayload(
          requestId: Ids.newUuid(),
          toId: alice.id,
          createdAtMs: now,
          expiresAtMs: now + 3600000,
          displayName: 'Alice',
        ),
      );
      expect(
        await alice.core.friendService.handleIncoming(await alice.open(bytes)),
        FriendInboundOutcome.ignored,
      );
    });

    test('rejects an unsupported friend protocol version', () async {
      final now = alice.clock.now().millisecondsSinceEpoch;
      final bytes = await alice.sealFor(
        recipient: bob,
        type: EnvelopeType.friendRequest,
        bundleId: randomBytes(16),
        payload: {
          'rid': Ids.newUuid(),
          'to': bob.id,
          'iat': now,
          'exp': now + 3600000,
          'ver': 99,
          'name': 'Alice',
        },
      );
      expect(
        () async =>
            bob.core.friendService.handleIncoming(await bob.open(bytes)),
        throwsA(isA<ProtocolException>()),
      );
    });
  });

  group('Cancelling and removing', () {
    test('cancels a still-pending outgoing request', () async {
      await alice.core.friendService.sendRequest(peer: bob.identity!.record);
      final request = await outgoingRequest(alice, bob);
      expect(
        (await alice.core.friends.findFriend(bob.id))!.status,
        FriendStatus.pendingOutgoing,
      );

      await alice.core.friendService.cancelRequest(request);

      expect(await alice.core.friends.findRequest(request.requestId), isNull);
      // The contact entry that existed only for the pending request is gone.
      expect(await alice.core.friends.findFriend(bob.id), isNull);
    });

    test('refuses to cancel an incoming request', () async {
      await alice.core.friendService.sendRequest(peer: bob.identity!.record);
      final request = await outgoingRequest(alice, bob);
      await bob.core.friendService.handleIncoming(
        await deliverFriendBundle(
          from: alice,
          to: bob,
          type: EnvelopeType.friendRequest,
          requestId: request.requestId,
        ),
      );
      final incoming = await incomingRequest(bob, alice);
      expect(
        () => bob.core.friendService.cancelRequest(incoming),
        throwsA(isA<StateTransitionException>()),
      );
    });

    test('removes an accepted contact but keeps the identity', () async {
      await alice.core.friendService.sendRequest(peer: bob.identity!.record);
      final request = await outgoingRequest(alice, bob);
      await bob.core.friendService.handleIncoming(
        await deliverFriendBundle(
          from: alice,
          to: bob,
          type: EnvelopeType.friendRequest,
          requestId: request.requestId,
        ),
      );
      final incoming = await incomingRequest(bob, alice);
      await bob.core.friendService.acceptRequest(
        incoming,
        peerRecord: alice.identity!.record,
      );
      expect(
        (await bob.core.friends.findFriend(alice.id))!.status,
        FriendStatus.accepted,
      );

      await bob.core.friendService.removeFriend(alice.id);

      expect(await bob.core.friends.findFriend(alice.id), isNull);
      // The verified identity record survives so chat history stays readable.
      expect(await bob.core.identities.find(alice.id), isNotNull);
    });
  });
}
