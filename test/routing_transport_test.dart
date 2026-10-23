import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/crypto/identity_service.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/domain/entities/chat_message.dart';
import 'package:findit/transport/simulated_transport.dart';
import 'package:findit/transport/unsupported_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  group('Discovery and advertisement', () {
    late SimulatedNetwork network;
    late TestNode alice;
    late TestNode bob;

    setUp(() async {
      network = SimulatedNetwork();
      alice = await TestNode.create(network: network, autoConnect: false);
      bob = await TestNode.create(network: network, autoConnect: false);
      await alice.createIdentity('Alice');
      await bob.createIdentity('Bob');
      await alice.startRouting();
      await bob.startRouting();
    });

    tearDown(() async {
      await alice.dispose();
      await bob.dispose();
      await network.dispose();
    });

    test('advertises only a rotating handle and a display hint', () async {
      await waitFor(
        () => bob.transport.knownPeers.any(
          (peer) => peer.peerId == alice.localId,
        ),
        description: 'Bob discovers Alice',
      );
      final discovered = bob.transport.knownPeers.firstWhere(
        (peer) => peer.peerId == alice.localId,
      );

      expect(discovered.displayNameHint, 'Alice');
      // The permanent identity id is never used as a transport handle.
      expect(discovered.peerId, isNot(alice.id));
    });

    test(
      'handshake reveals identities and opens a session both ways',
      () async {
        await alice.connectTo(bob);
        await waitForAsync(
          () async =>
              bob.core.routingEngine.peers.length == 1 &&
              bob.core.routingEngine.peers.single.handshaken,
          description: 'Bob completes the handshake',
        );

        expect(alice.core.routingEngine.peers.single.identityId, bob.id);
        expect(bob.core.routingEngine.peers.single.identityId, alice.id);
        expect(alice.core.routingEngine.peers.single.displayName, 'Bob');
      },
    );

    test('labels the simulated transport honestly', () {
      expect(alice.transport.capabilities.isSimulated, isTrue);
      expect(alice.transport.capabilities.canDiscover, isTrue);
      expect(alice.transport.capabilities.canConnect, isTrue);
    });

    test('refuses to connect while the network is offline', () async {
      network.offline = true;
      await expectLater(
        alice.core.transport.connect(bob.localId),
        throwsA(isA<TransportException>()),
      );

      network.offline = false;
      final connection = await alice.core.transport.connect(bob.localId);
      expect(connection.isOpen, isTrue);
      await connection.close();
    });
  });

  group('Store-carry-forward', () {
    test(
      'a failed hand-off is not recorded and is retried to delivery',
      () async {
        final network = SimulatedNetwork();
        final alice = await TestNode.create(
          network: network,
          autoConnect: false,
          networkingEnabled: true,
        );
        final bob = await TestNode.create(
          network: network,
          autoConnect: false,
          networkingEnabled: true,
        );
        try {
          await alice.createIdentity('Alice');
          await bob.createIdentity('Bob');
          await markMutualFriends(alice, bob);
          await alice.startRouting();
          await bob.startRouting();

          final message = await alice.core.messageService.sendText(
            recipient: bob.identity!.record,
            text: 'retry me',
          );

          // Model a connection that drops the very next transfer.
          alice.transport.dropNextBundleSend = true;
          await alice.connectTo(bob);

          // A failed connection is not a successful forward: nothing is recorded
          // and the message stays queued.
          expect(await bob.core.messages.find(message.id), isNull);
          expect((await alice.storedBundle(message.id)).replicationCount, 0);
          expect(
            (await alice.core.messages.find(message.id))!.status,
            MessageStatus.queued,
          );

          // A retry reuses the exact same bundle id and now succeeds.
          await alice.core.routingEngine.flush();
          await waitForAsync(
            () async => (await bob.core.messages.find(message.id)) != null,
            description: 'Bob receives the retried bundle',
          );
          expect((await alice.storedBundle(message.id)).replicationCount, 1);
          expect((await bob.core.messages.find(message.id))!.text, 'retry me');
        } finally {
          await alice.dispose();
          await bob.dispose();
          await network.dispose();
        }
      },
    );

    test(
      'relays a message between two peers that never connect directly',
      () async {
        final network = SimulatedNetwork();
        final alice = await TestNode.create(
          network: network,
          autoConnect: false,
          networkingEnabled: true,
        );
        final relay = await TestNode.create(
          network: network,
          autoConnect: false,
          networkingEnabled: true,
        );
        final bob = await TestNode.create(
          network: network,
          autoConnect: false,
          networkingEnabled: true,
        );
        try {
          await alice.createIdentity('Alice');
          await relay.createIdentity('Relay');
          await bob.createIdentity('Bob');
          await markMutualFriends(alice, bob);
          await alice.startRouting();
          await relay.startRouting();
          await bob.startRouting();

          final message = await alice.core.messageService.sendText(
            recipient: bob.identity!.record,
            text: 'carried',
          );

          await alice.connectTo(relay);
          await waitForAsync(
            () async => relay.core.bundles.exists(message.id),
            description: 'the relay stores the bundle',
          );
          // Nothing has met Bob yet.
          expect(await bob.core.messages.find(message.id), isNull);

          await relay.connectTo(bob);
          await waitForAsync(
            () async => (await bob.core.messages.find(message.id)) != null,
            description: 'Bob receives the relayed message',
          );
          expect((await bob.core.messages.find(message.id))!.text, 'carried');
        } finally {
          await alice.dispose();
          await relay.dispose();
          await bob.dispose();
          await network.dispose();
        }
      },
    );

    test('honours the replication budget', () async {
      const config = AppConfig(replicationBudget: 1);
      final network = SimulatedNetwork();
      final alice = await TestNode.create(
        network: network,
        config: config,
        autoConnect: false,
        networkingEnabled: true,
      );
      final relay1 = await TestNode.create(
        network: network,
        config: config,
        autoConnect: false,
        networkingEnabled: true,
      );
      final relay2 = await TestNode.create(
        network: network,
        config: config,
        autoConnect: false,
        networkingEnabled: true,
      );
      try {
        await alice.createIdentity('Alice');
        await relay1.createIdentity('Relay 1');
        await relay2.createIdentity('Relay 2');
        await alice.startRouting();
        await relay1.startRouting();
        await relay2.startRouting();

        final peer = await IdentityService(
          secretStore: InMemorySecretStore(),
        ).generate(displayName: 'Bob');
        final message = await alice.core.messageService.sendText(
          recipient: peer.record,
          text: 'limited',
        );

        await alice.connectTo(relay1);
        await waitForAsync(
          () async => relay1.core.bundles.exists(message.id),
          description: 'the first relay stores the bundle',
        );
        expect((await alice.storedBundle(message.id)).replicationCount, 1);

        // The budget is already exhausted, so the second relay gets nothing.
        await alice.connectTo(relay2);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(await relay2.core.bundles.exists(message.id), isFalse);
        expect((await alice.storedBundle(message.id)).replicationCount, 1);
      } finally {
        await alice.dispose();
        await relay1.dispose();
        await relay2.dispose();
        await network.dispose();
      }
    });
  });

  group('Unsupported transport', () {
    test('never fakes connectivity', () async {
      final transport = UnsupportedWifiTransport();
      expect(transport.capabilities.canDiscover, isFalse);
      expect(transport.capabilities.isSimulated, isFalse);
      expect(transport.isRunning, isFalse);

      await expectLater(transport.start(), throwsA(isA<TransportException>()));
      await expectLater(
        transport.connect('some-peer'),
        throwsA(isA<TransportException>()),
      );

      // Advertisement is an honest no-op rather than a fake success.
      final peer = await IdentityService(
        secretStore: InMemorySecretStore(),
      ).generate(displayName: 'Nobody');
      await transport.updateAdvertisement(
        displayNameHint: 'Nobody',
        identity: peer.record,
        discoverable: true,
      );
      expect(transport.knownPeers, isEmpty);

      await transport.stop();
      await transport.dispose();
    });
  });
}
