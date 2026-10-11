import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../../crypto/secret_store.dart';
import '../../transport/simulated_transport.dart';
import '../../transport/transport.dart';
import 'app_services.dart';
import 'core_services.dart';

/// Wires up the production object graph and loads any existing identity.
///
/// By default the transport is the in-process simulated one, which keeps the
/// app fully runnable without a radio. When running on physical Android/iOS
/// hardware a caller may pass a real transport (e.g. a [PlatformTransport]
/// wired to the native Wi-Fi Direct / Wi-Fi Aware / local-network plugin). The
/// Nearby screen and README always label whatever transport is active honestly.
class AppBootstrap {
  AppBootstrap._();

  static Future<AppServices> create({Transport? transport}) async {
    final supportDir = await getApplicationSupportDirectory();
    final databasePath = p.join(supportDir.path, 'findit.db');
    final demoDatabasePath = p.join(supportDir.path, 'findit_demo_peer.db');

    final network = SimulatedNetwork();
    final effectiveTransport =
        transport ?? SimulatedTransport(network: network);

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
