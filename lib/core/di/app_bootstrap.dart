import 'dart:io' show Platform;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../crypto/secret_store.dart';
import '../../transport/platform_transport.dart';
import '../../transport/simulated_transport.dart';
import '../../transport/transport.dart';
import '../../transport/unsupported_transport.dart';
import 'app_services.dart';
import 'core_services.dart';

/// Wires up the production object graph and loads any existing identity.
///
/// On Android the production transport is the native Wi-Fi Direct / Wi-Fi Aware
/// fabric exposed through the Kotlin platform channel. On iOS the native
/// transport is not yet implemented, so an honest [UnsupportedWifiTransport] is
/// used. A caller may always inject a different transport (e.g. the in-process
/// simulated one) for tests and demos.
class AppBootstrap {
  AppBootstrap._();

  static Future<AppServices> create({Transport? transport}) async {
    final supportDir = await getApplicationSupportDirectory();
    final databasePath = p.join(supportDir.path, 'findit.db');
    final demoDatabasePath = p.join(supportDir.path, 'findit_demo_peer.db');

    final network = SimulatedNetwork();
    final Transport effectiveTransport;
    if (transport != null) {
      effectiveTransport = transport;
    } else if (Platform.isAndroid) {
      effectiveTransport = PlatformTransport(
        gateway: MethodChannelPlatformTransportGateway(),
      );
    } else if (Platform.isIOS) {
      effectiveTransport = UnsupportedWifiTransport();
    } else {
      effectiveTransport = SimulatedTransport(network: network);
    }

    final core = await CoreServices.create(
      databaseFactory: databaseFactory,
      databasePath: databasePath,
      secretStore: FlutterSecureSecretStore(),
      transport: effectiveTransport,
    );

    final services = AppServices(
      core: core,
      simulatedNetwork: network,
      databaseFactory: databaseFactory,
      demoDatabasePath: demoDatabasePath,
    );
    await services.initialize();
    return services;
  }
}
