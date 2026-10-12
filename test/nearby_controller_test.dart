import 'dart:async';
import 'dart:io';

import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/di/app_services.dart';
import 'package:findit/core/di/core_services.dart';
import 'package:findit/core/utils/clock.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/presentation/controllers/nearby_controller.dart';
import 'package:findit/transport/platform_transport.dart';
import 'package:findit/transport/platform_transport_contract.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/db.dart';

/// A minimal native-transport stand-in whose start can be made to fail, to
/// reproduce the "Wi-Fi is off" failure path without a radio.
class _FakeGateway implements PlatformTransportGateway {
  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  bool wifiEnabled = true;
  bool permissionsGranted = true;
  Object? startError;

  @override
  Future<Map<String, Object?>> start({
    required int dataPort,
    required String handle,
  }) async {
    final error = startError;
    if (error != null) throw error;
    return <String, Object?>{'fabric': PlatformFabrics.wifiDirect};
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required bool discoverable,
  }) async {}

  @override
  Future<Map<String, Object?>> connect({required String handle}) async =>
      <String, Object?>{'host': '127.0.0.1', 'port': 1};

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

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

  @override
  Future<void> dispose() async {}
}

class _Harness {
  _Harness(this.services, this.controller, this.gateway, this.directory);

  final AppServices services;
  final NearbyController controller;
  final _FakeGateway gateway;
  final Directory directory;

  Future<void> dispose() async {
    controller.dispose();
    await services.stopNetworking();
    services.dispose();
    try {
      directory.deleteSync(recursive: true);
    } catch (_) {
      // Best effort.
    }
  }
}

Future<_Harness> _harness() async {
  final directory = Directory.systemTemp.createTempSync('findit-nearby-');
  final gateway = _FakeGateway();
  final transport = PlatformTransport(gateway: gateway, localId: 'local');
  final core = await CoreServices.create(
    databaseFactory: testDatabaseFactory,
    databasePath: p.join(directory.path, 'nearby.db'),
    secretStore: InMemorySecretStore(),
    transport: transport,
    config: AppConfig.test,
    clock: FixedClock(DateTime.utc(2026, 1, 1, 12)),
  );
  await core.settings.load();
  final identity = await core.identityService.generate(displayName: 'Alice');
  core.identityHolder.set(identity);
  await core.settings.acceptConsent();
  await core.settings.setNetworkingEnabled(true);
  final services = AppServices(core: core);
  return _Harness(
    services,
    NearbyController(services),
    gateway,
    directory,
  );
}

void main() {
  group('NearbyController', () {
    test('reports Wi-Fi off with the actionable message', () async {
      final harness = await _harness();
      try {
        harness.gateway.wifiEnabled = false;
        await harness.controller.startTransport();

        expect(harness.controller.needsWifi, isTrue);
        expect(harness.controller.error, contains('Wi-Fi'));
        expect(harness.controller.isRunning, isFalse);
      } finally {
        await harness.dispose();
      }
    });

    test('clears a stale start failure once the transport is running', () async {
      final harness = await _harness();
      try {
        // A first attempt fails (the radio is warming up), recording the error
        // that used to stick on the Nearby banner forever.
        harness.gateway.startError = PlatformException(
          code: PlatformErrorCodes.unavailable,
          message: 'Wi-Fi is off',
        );
        await harness.controller.startTransport();
        expect(harness.controller.error, isNotNull);
        expect(harness.controller.isRunning, isFalse);

        // The radio is started from elsewhere (Profile switch / permission
        // gate), which never touches this controller's error field.
        harness.gateway.startError = null;
        await harness.services.startNetworking();
        expect(harness.services.core.routingEngine.isRunning, isTrue);

        await harness.controller.refresh();
        expect(harness.controller.error, isNull);
        expect(harness.controller.needsWifi, isFalse);
      } finally {
        await harness.dispose();
      }
    });
  });
}
