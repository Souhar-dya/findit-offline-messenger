import 'dart:async';
import 'dart:io';

import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/di/core_services.dart';
import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/core/utils/clock.dart';
import 'package:findit/crypto/identity_record.dart';
import 'package:findit/crypto/identity_service.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/domain/entities/chat_message.dart';
import 'package:findit/domain/entities/friend.dart';
import 'package:findit/domain/entities/friend_request.dart';
import 'package:findit/domain/entities/peer_summary.dart';
import 'package:findit/transport/platform_transport.dart';
import 'package:findit/transport/platform_transport_contract.dart';
import 'package:findit/transport/transport.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/db.dart';

/// An identity record used by transport-level (non-routing) tests. The record
/// is deliberately NOT self-signed: verification only happens once the routing
/// engine ingests the handshake result, which these tests do not do.
IdentityRecord testRecord(String name, String id) => IdentityRecord(
  formatVersion: kIdentityFormatVersion,
  keyVersion: kIdentityKeyVersion,
  identityId: id,
  signingPublicKey: Uint8List(32),
  agreementPublicKey: Uint8List(32),
  displayName: name,
  signature: Uint8List(64),
);

/// Discovery "bus" shared by the fake gateways in a test: announcements made by
/// one endpoint are delivered to every other registered endpoint, mirroring a
/// Wi-Fi network where advertisements are visible to all listeners.
class _Hub {
  final Map<String, _FakeGateway> _gateways = <String, _FakeGateway>{};

  void register(_FakeGateway gateway) {
    _gateways[gateway.advertisedHandle ?? gateway.handle] = gateway;
  }

  _FakeGateway? lookup(String handle) => _gateways[handle];

  void announce(_FakeGateway self, String displayNameHint) {
    final port = self.dataPort;
    for (final other in [..._gateways.values]) {
      if (identical(other, self)) continue;
      other.emit(<String, Object?>{
        'event': PlatformEventNames.peerFound,
        'handle': self.advertisedHandle ?? self.handle,
        'displayNameHint': displayNameHint,
        'host': '127.0.0.1',
        'dataPort': port,
      });
    }
  }
}

/// A scripted [PlatformTransportGateway] that mimics the native plugin enough
/// to drive real TCP data channels: `start` records the data port,
/// `connect(handle)` resolves the peer's loopback endpoint, and discovery
/// events are injected by the test through [emit].
class _FakeGateway implements PlatformTransportGateway {
  _FakeGateway(this.handle, this.hub);

  final String handle;
  final _Hub hub;
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  int? dataPort;
  String? advertisedHandle;
  String? lastDisplayHint;
  bool? lastDiscoverable;
  Object? startError;
  bool connectFails = false;

  @override
  Future<bool> isWifiEnabled() async => wifiEnabled;

  @override
  Future<bool> requestWifiEnable() async {
    wifiEnabled = true;
    return wifiEnabled;
  }

  @override
  Future<bool> checkPermissions() async => permissionsGranted;

  @override
  Future<bool> requestPermissions() async {
    permissionsGranted = true;
    return permissionsGranted;
  }

  @override
  Future<void> openAppSettings() async {}

  bool wifiEnabled = true;
  bool permissionsGranted = true;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  void emit(Map<String, Object?> event) {
    if (!_events.isClosed) _events.add(event);
  }

  @override
  Future<Map<String, Object?>> start({
    required int dataPort,
    required String handle,
  }) async {
    if (startError != null) throw startError!;
    this.dataPort = dataPort;
    advertisedHandle = handle;
    hub.register(this);
    return <String, Object?>{'fabric': PlatformFabrics.wifiDirect};
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required bool discoverable,
  }) async {
    lastDisplayHint = displayNameHint;
    lastDiscoverable = discoverable;
    if (!discoverable) return;
    hub.announce(this, displayNameHint);
  }

  @override
  Future<Map<String, Object?>> connect({required String handle}) async {
    if (connectFails) {
      throw PlatformException(
        code: PlatformErrorCodes.connectFailed,
        message: 'no datapath',
      );
    }
    final other = hub.lookup(handle);
    if (other == null) {
      throw PlatformException(
        code: PlatformErrorCodes.connectFailed,
        message: 'peer gone',
      );
    }
    return <String, Object?>{'host': '127.0.0.1', 'port': other.dataPort};
  }

  @override
  Future<void> dispose() async {}
}

class _Node {
  _Node({
    required this.core,
    required this.transport,
    required this.dir,
    required this.identity,
  });

  final CoreServices core;
  final PlatformTransport transport;
  final Directory dir;
  final LocalIdentity identity;

  String get id => identity.identityId;

  Future<void> dispose() async {
    await core.dispose();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // Best effort; temporary directories are reaped by the OS.
    }
  }
}

Future<_Node> _startNode(String name, _FakeGateway fake) async {
  final transport = PlatformTransport(gateway: fake, localId: fake.handle);
  final dir = Directory.systemTemp.createTempSync('findit-platform-');
  final path = p.join(dir.path, '${name.toLowerCase()}.db');
  final core = await CoreServices.create(
    databaseFactory: testDatabaseFactory,
    databasePath: path,
    secretStore: InMemorySecretStore(),
    transport: transport,
    config: AppConfig.test,
    clock: FixedClock(DateTime.utc(2026, 1, 1, 12)),
  );
  final identity = await core.identityService.generate(displayName: name);
  core.identityHolder.set(identity);
  // These tests exercise end-to-end delivery, so switch networking on.
  await core.settings.setNetworkingEnabled(true);
  final node = _Node(
    core: core,
    transport: transport,
    dir: dir,
    identity: identity,
  );
  await core.routingEngine.start();
  return node;
}

Future<void> _waitForAsync(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 15),
  String description = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  group('PlatformTransport', () {
    test(
      'discovers peers through native events using only an opaque handle',
      () async {
        final hub = _Hub();
        final fakeA = _FakeGateway('aaaa', hub);
        final fakeB = _FakeGateway('bbbb', hub);
        final a = PlatformTransport(gateway: fakeA, localId: 'aaaa');
        final b = PlatformTransport(gateway: fakeB, localId: 'bbbb');
        addTearDown(() async {
          await a.dispose();
          await b.dispose();
        });
        await a.start();
        await b.start();

        // Advertisement state: the native layer receives only a rotating handle
        // (its own) and a display hint. The identity argument is never passed
        // across the channel.
        expect(fakeB.lastDisplayHint, isNull);
        await a.updateAdvertisement(
          displayNameHint: 'Alice',
          identity: testRecord('Alice', 'fid_alice'),
          discoverable: true,
        );
        expect(fakeA.lastDisplayHint, 'Alice');
        expect(fakeA.lastDiscoverable, isTrue);

        final found = a.discoveredPeers.first;
        // Discovery events travel Alice's own event channel (reported by her
        // native side about nearby devices).
        fakeA.emit(<String, Object?>{
          'event': PlatformEventNames.peerFound,
          'handle': 'bbbb',
          'displayNameHint': 'Bob',
          'host': '127.0.0.1',
          'dataPort': fakeB.dataPort ?? -1,
          'rssi': -55,
        });
        final peer = await found.timeout(const Duration(seconds: 5));
        expect(peer.peerId, 'bbbb');
        expect(peer.displayNameHint, 'Bob');
        expect(peer.rssi, -55);
        expect(a.knownPeers, hasLength(1));

        final lost = a.lostPeers.first;
        fakeA.emit(<String, Object?>{
          'event': PlatformEventNames.peerLost,
          'handle': 'bbbb',
        });
        expect(await lost.timeout(const Duration(seconds: 5)), 'bbbb');
        expect(a.knownPeers, isEmpty);
      },
    );

    test(
      'asks native to advertise its localId as the discoverable handle',
      () async {
        final hub = _Hub();
        // The fake's constructor handle stands in for a native-generated one;
        // `start` must override it with the transport's localId so that both
        // peers compare the same pair when electing who dials.
        final fake = _FakeGateway('native-generated', hub);
        final transport = PlatformTransport(
          gateway: fake,
          localId: 'rotating-local',
        );
        addTearDown(transport.dispose);

        await transport.start();
        expect(fake.advertisedHandle, 'rotating-local');
        expect(hub.lookup('rotating-local'), same(fake));
        expect(hub.lookup('native-generated'), isNull);
      },
    );

    test(
      'exchanges handshake, summaries and bundles over a real data channel',
      () async {
        final hub = _Hub();
        final fakeA = _FakeGateway('aaaa', hub);
        final fakeB = _FakeGateway('bbbb', hub);
        final a = PlatformTransport(gateway: fakeA, localId: 'aaaa');
        final b = PlatformTransport(gateway: fakeB, localId: 'bbbb');
        addTearDown(() async {
          await a.dispose();
          await b.dispose();
        });
        await a.start();
        await b.start();

        final incoming = b.incomingConnections.first;
        final connA = await a
            .connect('bbbb')
            .timeout(const Duration(seconds: 5));
        final connB = await incoming.timeout(const Duration(seconds: 5));

        final reqA = PeerHandshakeRequest(
          identity: testRecord('Alice', 'fid_alice'),
          capabilities: const [TransportCapabilitiesKeys.cborEnvelopes],
        );
        final reqB = PeerHandshakeRequest(
          identity: testRecord('Bob', 'fid_bob'),
          capabilities: const [TransportCapabilitiesKeys.cborEnvelopes],
        );
        final results = await Future.wait([
          connA.handshake(reqA).timeout(const Duration(seconds: 5)),
          connB.handshake(reqB).timeout(const Duration(seconds: 5)),
        ]);
        expect(results[0].identity.displayName, 'Bob');
        expect(results[1].identity.displayName, 'Alice');

        final summary = PeerSummary(
          identityId: 'fid_bob',
          generatedAtMs: 1234,
          entries: const [
            PeerSummaryEntry(bundleIdHex: 'aa', expiresAtMs: 999),
          ],
        );
        final receivedSummary = connB.summaries.first;
        await connA.sendSummary(summary);
        expect(
          (await receivedSummary.timeout(const Duration(seconds: 5))).bundleIds,
          {'aa'},
        );

        final payload = Uint8List.fromList(
          List<int>.generate(1800, (i) => i % 256),
        );
        final receivedBundle = connA.bundles.first;
        await connB.sendBundles([payload]);
        expect(
          await receivedBundle.timeout(const Duration(seconds: 5)),
          payload,
        );

        await connA.close();
        await connB.close();
        expect(connA.isOpen, isFalse);
        expect(connB.isOpen, isFalse);
      },
    );

    test('fails honestly when the native side is unavailable', () async {
      final fake = _FakeGateway('aaaa', _Hub())
        ..startError = PlatformException(
          code: PlatformErrorCodes.unavailable,
          message: 'no radio',
        );
      final transport = PlatformTransport(gateway: fake, localId: 'aaaa');
      addTearDown(() async {
        await transport.dispose();
      });
      expect(transport.capabilities.canDiscover, isFalse);
      expect(transport.capabilities.isSimulated, isFalse);
      await expectLater(transport.start(), throwsA(isA<TransportException>()));
      await expectLater(
        transport.connect('x'),
        throwsA(isA<TransportException>()),
      );
    });

    test('wraps a failed native connect into a TransportException', () async {
      final hub = _Hub();
      final fakeA = _FakeGateway('aaaa', hub)..connectFails = true;
      final a = PlatformTransport(gateway: fakeA, localId: 'aaaa');
      addTearDown(() async {
        await a.dispose();
      });
      await a.start();
      await expectLater(a.connect('bbbb'), throwsA(isA<TransportException>()));
    });

    test('fails when the peer datapath cannot be established', () async {
      final hub = _Hub();
      final fakeA = _FakeGateway('aaaa', hub);
      final a = PlatformTransport(gateway: fakeA, localId: 'aaaa');
      addTearDown(() async {
        await a.dispose();
      });
      await a.start();
      await expectLater(
        a.connect('nobody'),
        throwsA(isA<TransportException>()),
      );
    });

    test('routes a verified friend request and message end-to-end over the '
        'platform transport', () async {
      final hub = _Hub();
      final fakeA = _FakeGateway('aaaa', hub);
      final fakeB = _FakeGateway('bbbb', hub);
      final alice = await _startNode('Alice', fakeA);
      final bob = await _startNode('Bob', fakeB);
      addTearDown(() async {
        await alice.dispose();
        await bob.dispose();
      });

      // Discovery + deterministic arbitration ('aaaa' < 'bbbb') make Alice
      // the initiator; both sides converge on a handshaken session.
      await _waitForAsync(
        () async =>
            alice.core.routingEngine.peers.any(
              (p) => p.handshaken && p.identityId == bob.id,
            ) &&
            bob.core.routingEngine.peers.any(
              (p) => p.handshaken && p.identityId == alice.id,
            ),
        description: 'both nodes connected over the platform transport',
      );
      expect(fakeA.lastDisplayHint, 'Alice');
      expect(fakeA.lastDiscoverable, isTrue);
      expect(fakeB.dataPort, isNotNull);
      // The advertisement carried only a display hint: the gateway API has
      // no identity parameter, so no id ever reached the fake native layer.

      // Mutual acceptance over the wire.
      await alice.core.friendService.sendRequest(peer: bob.identity.record);
      await _waitForAsync(() async {
        final requests = await bob.core.friends.requestsForPeer(alice.id);
        return requests.any(
          (r) =>
              r.direction == FriendRequestDirection.incoming &&
              r.state == FriendRequestState.pending,
        );
      }, description: 'bob to record the incoming request');
      final incoming = (await bob.core.friends.requestsForPeer(
        alice.id,
      )).firstWhere((r) => r.direction == FriendRequestDirection.incoming);
      await bob.core.friendService.acceptRequest(
        incoming,
        peerRecord: alice.identity.record,
      );
      await _waitForAsync(() async {
        final friend = await alice.core.friends.findFriend(bob.id);
        return friend != null &&
            friend.status == FriendStatus.accepted &&
            friend.isVerified;
      }, description: 'alice to confirm the friendship');
      expect((await bob.core.friends.findFriend(alice.id))!.isVerified, isTrue);

      // A text message travels the same route and is confirmed with a
      // signed receipt.
      final message = await alice.core.messageService.sendText(
        recipient: bob.identity.record,
        text: 'hello over the wire',
      );
      await _waitForAsync(
        () async => (await bob.core.messages.find(message.id)) != null,
        description: 'bob to store the message',
      );
      await _waitForAsync(() async {
        final stored = await alice.core.messages.find(message.id);
        return stored != null &&
            stored.status == MessageStatus.delivered &&
            stored.deliveredAtMs != null;
      }, description: 'alice to confirm delivery with a signed receipt');
      final onBob = await bob.core.messages.find(message.id);
      expect(onBob!.text, 'hello over the wire');
    }, timeout: Timeout(const Duration(seconds: 60)));
  });
}
