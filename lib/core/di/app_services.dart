import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../demo/simulated_peer_agent.dart';
import '../../transport/simulated_transport.dart';
import '../config/app_config.dart';
import 'core_services.dart';

/// Owns the app-wide object graph plus the optional in-process demo peer.
///
/// It is provided to the widget tree with `provider`, so screens and
/// controllers never construct their own dependencies.
class AppServices extends ChangeNotifier {
  AppServices({
    required this.core,
    this.simulatedNetwork,
    this.databaseFactory,
    this.demoDatabasePath,
  });

  final CoreServices core;

  /// Present only when the app is running over the simulated transport.
  final SimulatedNetwork? simulatedNetwork;
  final DatabaseFactory? databaseFactory;
  final String? demoDatabasePath;

  SimulatedPeerAgent? _demoPeer;
  bool _startingDemo = false;
  String? _demoError;

  bool get isDemoRunning => _demoPeer != null;
  bool get isStartingDemo => _startingDemo;
  String? get demoError => _demoError;
  AppConfig get config => core.config;

  /// Loads preferences and a persisted identity. The radio starts only when
  /// the user has accepted the terms *and* switched networking on — no data
  /// moves before consent, and nothing is discovered while the switch is off.
  Future<void> initialize() async {
    await core.settings.load();
    final identity = await core.loadIdentity();
    if (identity != null &&
        core.settings.consentAccepted &&
        core.settings.networkingEnabled) {
      await startNetworking();
    }
  }

  /// Records consent to the current terms, then starts networking if an
  /// identity already exists and the master switch is on.
  Future<void> acceptConsent() async {
    await core.settings.acceptConsent();
    if (core.identityHolder.hasIdentity) {
      await startNetworking();
    }
    notifyListeners();
  }

  /// The single master switch. Turning it on starts discovery and lets your
  /// own (and, optionally, other people's) messages move. Turning it off makes
  /// the device radio silent: the transport stops, sessions are closed and any
  /// third-party bundles it was carrying are deleted. Your own queued messages
  /// are kept and sent once networking is back on.
  Future<void> setNetworkingEnabled(bool enabled) async {
    await core.settings.setNetworkingEnabled(enabled);
    if (enabled) {
      await startNetworking();
    } else {
      // Radio silent also means the in-process demo peer stops.
      await stopDemoPeer();
      await stopNetworking();
      await core.bundles.deleteRelayedBundles();
    }
    notifyListeners();
  }

  /// Clears consent / networking state after the local database has been wiped,
  /// so the terms are shown again and networking reverts to off.
  void resetLocalPreferences() {
    core.settings.clear();
    notifyListeners();
  }

  /// True once the user has agreed to the current terms of use.
  bool get consentAccepted => core.settings.consentAccepted;

  /// Whether this device uses the radio at all. Off means radio silent (no
  /// discovery, no send/receive); on enables your own messages and relaying.
  bool get networkingEnabled => core.settings.networkingEnabled;

  /// Starts discovery, routing and periodic maintenance.
  ///
  /// Refuses to start until the terms are accepted *and* the master switch is
  /// on: this is the only place the radio is switched on.
  Future<void> startNetworking() async {
    if (!core.settings.consentAccepted) return;
    if (!core.settings.networkingEnabled) return; // radio silent
    if (!core.identityHolder.hasIdentity) return;
    if (!core.routingEngine.isRunning) {
      await core.routingEngine.start();
    }
    core.maintenance.start();
  }

  Future<void> stopNetworking() async {
    core.maintenance.stop();
    if (core.routingEngine.isRunning) {
      await core.routingEngine.stop();
    }
  }

  /// Runs one maintenance pass and returns a human-readable summary.
  Future<String> runMaintenance() async {
    final report = await core.maintenance.runOnce();
    return '${report.messagesExpired} messages expired, '
        '${report.bundlesExpired} bundles reclaimed, '
        '${report.requestsExpired} requests expired, '
        '${report.receiptsPruned} receipts pruned.';
  }

  /// Starts the in-process demo peer on the simulated network, if available.
  Future<void> startDemoPeer() async {
    if (_demoPeer != null || _startingDemo) return;
    final network = simulatedNetwork;
    final factory = databaseFactory;
    final path = demoDatabasePath;
    if (network == null || factory == null || path == null) {
      _demoError =
          'The demo peer is only available on the simulated transport.';
      notifyListeners();
      return;
    }
    _startingDemo = true;
    _demoError = null;
    notifyListeners();
    try {
      _demoPeer = await SimulatedPeerAgent.start(
        network: network,
        databaseFactory: factory,
        databasePath: path,
        config: core.config,
      );
    } catch (error) {
      _demoError = 'Could not start the demo peer: $error';
    } finally {
      _startingDemo = false;
      notifyListeners();
    }
  }

  Future<void> stopDemoPeer() async {
    final peer = _demoPeer;
    _demoPeer = null;
    notifyListeners();
    await peer?.stop();
  }

  @override
  void dispose() {
    unawaited(_demoPeer?.stop());
    unawaited(core.dispose());
    super.dispose();
  }
}
