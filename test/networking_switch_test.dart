import 'package:findit/domain/entities/chat_message.dart';
import 'package:findit/transport/simulated_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// The single master switch is enforced twice: at the [AppServices] level (the
/// radio is not started at all while off) and inside the routing engine (as a
/// second line of defence). These tests cover the routing-engine gates.
void main() {
  group('Networking switch', () {
    test('off: your own messages are not transferred, even direct', () async {
      final network = SimulatedNetwork();
      final alice = await TestNode.create(network: network, autoConnect: false);
      final bob = await TestNode.create(network: network, autoConnect: false);
      try {
        await alice.createIdentity('Alice');
        await bob.createIdentity('Bob');
        expect(alice.core.settings.networkingEnabled, isFalse);
        expect(bob.core.settings.networkingEnabled, isFalse);
        await alice.startRouting();
        await bob.startRouting();

        final message = await alice.core.messageService.sendText(
          recipient: bob.identity!.record,
          text: 'held until networking is on',
        );

        // Even a direct connection moves nothing while the switch is off.
        await alice.connectTo(bob);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(await bob.core.messages.find(message.id), isNull);
        expect((await alice.storedBundle(message.id)).replicationCount, 0);
        expect(
          (await alice.core.messages.find(message.id))!.status,
          MessageStatus.queued,
        );
      } finally {
        await alice.dispose();
        await bob.dispose();
        await network.dispose();
      }
    });

    test('off: a device never stores third-party bundles', () async {
      final network = SimulatedNetwork();
      final alice = await TestNode.create(
        network: network,
        autoConnect: false,
        networkingEnabled: true,
      );
      final relay = await TestNode.create(network: network, autoConnect: false);
      final bob = await TestNode.create(network: network, autoConnect: false);
      try {
        await alice.createIdentity('Alice');
        await relay.createIdentity('Relay');
        await bob.createIdentity('Bob');
        await alice.startRouting();
        await relay.startRouting();
        await bob.startRouting();

        final message = await alice.core.messageService.sendText(
          recipient: bob.identity!.record,
          text: 'not carried while the relay is off',
        );

        await alice.connectTo(relay);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(await relay.core.bundles.exists(message.id), isFalse);
        expect(await bob.core.messages.find(message.id), isNull);
      } finally {
        await alice.dispose();
        await relay.dispose();
        await bob.dispose();
        await network.dispose();
      }
    });

    test('on: your own messages transfer and third-party bundles are '
        'relayed', () async {
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
        expect(alice.core.settings.networkingEnabled, isTrue);
        await alice.startRouting();
        await relay.startRouting();
        await bob.startRouting();

        final message = await alice.core.messageService.sendText(
          recipient: bob.identity!.record,
          text: 'carried for someone else',
        );

        await alice.connectTo(relay);
        await waitForAsync(
          () async => relay.core.bundles.exists(message.id),
          description: 'the relay stores the bundle',
        );
        expect(await bob.core.messages.find(message.id), isNull);

        await relay.connectTo(bob);
        await waitForAsync(
          () async => (await bob.core.messages.find(message.id)) != null,
          description: 'Bob receives the relayed message',
        );
        expect(
          (await bob.core.messages.find(message.id))!.text,
          'carried for someone else',
        );
      } finally {
        await alice.dispose();
        await relay.dispose();
        await bob.dispose();
        await network.dispose();
      }
    });
  });
}
