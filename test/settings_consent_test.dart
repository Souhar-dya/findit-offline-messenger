import 'dart:io';
import 'dart:typed_data';

import 'package:findit/core/di/app_services.dart';
import 'package:findit/core/legal/terms.dart';
import 'package:findit/core/protocol/envelope.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/domain/entities/stored_bundle.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('Consent settings', () {
    test('defaults to no consent and networking off', () async {
      final node = await TestNode.create();
      try {
        expect(node.core.settings.consentAccepted, isFalse);
        expect(node.core.settings.acceptedConsentVersion, isNull);
        expect(node.core.settings.networkingEnabled, isFalse);

        await node.core.settings.acceptConsent();
        expect(node.core.settings.consentAccepted, isTrue);
        expect(
          node.core.settings.acceptedConsentVersion,
          TermsDocument.version,
        );
      } finally {
        await node.dispose();
      }
    });

    test(
      'persists consent and the networking switch across a restart',
      () async {
        final directory = Directory.systemTemp.createTempSync(
          'findit-settings-',
        );
        final node = await TestNode.create(
          directory: directory,
          databaseName: 'settings',
          secretStore: InMemorySecretStore(),
          autoConnect: false,
        );
        await node.createIdentity('Alice');
        await node.core.settings.acceptConsent();
        await node.core.settings.setNetworkingEnabled(true);

        final reopened = await node.reopen();
        try {
          await reopened.core.settings.load();
          expect(reopened.core.settings.consentAccepted, isTrue);
          expect(reopened.core.settings.networkingEnabled, isTrue);
        } finally {
          await reopened.dispose();
        }
      },
    );

    test('clear() resets in-memory consent and networking', () async {
      final node = await TestNode.create();
      try {
        await node.core.settings.acceptConsent();
        await node.core.settings.setNetworkingEnabled(true);

        node.core.settings.clear();
        expect(node.core.settings.consentAccepted, isFalse);
        expect(node.core.settings.networkingEnabled, isFalse);
      } finally {
        await node.dispose();
      }
    });
  });

  group('Consent and the master switch', () {
    test(
      'stay radio silent until both consent and the switch are on',
      () async {
        final node = await TestNode.create(autoConnect: false);
        await node.createIdentity('Alice');
        final services = AppServices(core: node.core);
        try {
          expect(node.core.settings.consentAccepted, isFalse);

          // No consent -> no radio, even if the switch were on.
          await services.startNetworking();
          expect(node.core.routingEngine.isRunning, isFalse);

          // Consent alone is not enough: the switch is still off, so the radio
          // is not started.
          await services.acceptConsent();
          expect(node.core.settings.consentAccepted, isTrue);
          expect(node.core.routingEngine.isRunning, isFalse);

          // Switching networking on starts the radio.
          await services.setNetworkingEnabled(true);
          expect(node.core.routingEngine.isRunning, isTrue);

          // Switching it off again returns to radio silence.
          await services.setNetworkingEnabled(false);
          expect(node.core.routingEngine.isRunning, isFalse);
        } finally {
          await services.stopNetworking();
          await node.dispose();
        }
      },
    );
  });

  group('Networking switch orchestration', () {
    test('turning it off deletes third-party bundles but keeps own', () async {
      final node = await TestNode.create();
      await node.createIdentity('Relay');
      final services = AppServices(core: node.core);
      try {
        await services.setNetworkingEnabled(true);
        expect(services.networkingEnabled, isTrue);

        final now = node.clock.now().millisecondsSinceEpoch;
        Future<bool> insert(String hex, {String? source}) {
          return node.core.bundles.insertIfAbsent(
            StoredBundle(
              bundleIdHex: hex,
              type: EnvelopeType.message,
              recipientId: 'fid_someone',
              expiresAtMs: now + 600000,
              storedAtMs: now,
              sizeBytes: 4,
              bytes: Uint8List.fromList(const [1, 2, 3, 4]),
              replicationCount: 0,
              sourcePeerId: source,
            ),
          );
        }

        final own = List.filled(16, 'aa').join();
        final receivedA = List.filled(16, 'bb').join();
        final receivedB = List.filled(16, 'cc').join();
        await insert(own);
        await insert(receivedA, source: 'peer-handle');
        await insert(receivedB, source: 'peer-handle');

        await services.setNetworkingEnabled(false);
        expect(services.networkingEnabled, isFalse);

        expect(await node.core.bundles.exists(own), isTrue);
        expect(await node.core.bundles.exists(receivedA), isFalse);
        expect(await node.core.bundles.exists(receivedB), isFalse);
      } finally {
        await node.dispose();
      }
    });
  });
}
