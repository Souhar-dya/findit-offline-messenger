import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:sqflite/sqflite.dart';

import '../../demo/simulated_peer_agent.dart';
import '../../domain/entities/chat_message.dart';
import '../../transport/platform_transport.dart';
import '../../transport/simulated_transport.dart';
import '../config/app_config.dart';
import 'core_services.dart';

/// Owns the app-wide object graph plus the optional in-process demo peer.
///
/// It is provided to the widget tree with `provider`, so screens and
/// controllers never construct their own dependencies.
class AppServices extends ChangeNotifier with WidgetsBindingObserver {
  AppServices({
    required this.core,
    this.simulatedNetwork,
    this.databaseFactory,
    this.demoDatabasePath,
  }) {
    WidgetsBinding.instance.addObserver(this);
    // Announce inbound messages through the OS. The stream only carries
    // messages that decrypted to this device's own identity, so a notification
    // is never raised for a message addressed to anyone else.
    _incomingSub = core.messageService.incomingMessages.listen(
      _onIncomingMessage,
    );
  }

  final CoreServices core;

  /// Present only when the app is running over the simulated transport.
  final SimulatedNetwork? simulatedNetwork;
  final DatabaseFactory? databaseFactory;
  final String? demoDatabasePath;

  bool _isInForeground = true;

  SimulatedPeerAgent? _demoPeer;
  bool _startingDemo = false;
  String? _demoError;

  StreamSubscription<ChatMessage>? _incomingSub;

  bool get isDemoRunning => _demoPeer != null;
  bool get isStartingDemo => _startingDemo;
  bool get isInForeground => _isInForeground;
  String? get demoError => _demoError;
  AppConfig get config => core.config;

  /// Loads preferences and a persisted identity. The radio starts only when
  /// the user has accepted the terms *and* switched networking on — no data
  /// moves before consent, and nothing is discovered while the switch is off.
  Future<void> initialize() async {
    await core.settings.load();
    await refreshPermissions();
    final identity = await core.loadIdentity();
    if (identity != null &&
        core.settings.consentAccepted &&
        core.settings.networkingEnabled &&
        _permissionsGranted) {
      await ensureNetworkingStarted();
    }
  }

  /// Records consent to the current terms, then starts networking if an
  /// identity already exists and the master switch is on.
  Future<void> acceptConsent() async {
    await core.settings.acceptConsent();
    if (core.identityHolder.hasIdentity) {
      await ensureNetworkingStarted();
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
      await ensureNetworkingStarted();
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
    // Ask (once) for the notification permission so inbound messages can be
    // announced. A denial only means quiet arrivals; it never blocks this.
    await ensureNotificationPermission();
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

  /// Re-arms discovery when the app should be listening but is not.
  ///
  /// The first [startNetworking] attempt can fail because the app was launched
  /// while Wi-Fi was off, which leaves nothing discovering once the radio comes
  /// back. Safe to call repeatedly: it only acts while the user has consented,
  /// the master switch is on and the engine is stopped.
  Future<void> ensureNetworkingStarted() async {
    if (core.routingEngine.isRunning) return;
    // Do not start Wi-Fi Direct unless Wi-Fi is on and the hotspot is off.
    // The root gate guides the user to the relevant system settings panel.
    if (requiresPlatformPermissions) {
      final wifiEnabled = await isWifiEnabled();
      final hotspotEnabled = await isHotspotEnabled();
      if (!wifiEnabled || hotspotEnabled) return;
    }
    try {
      await startNetworking();
    } catch (_) {
      // The radio can still be mid-transition; a later Wi-Fi check retries.
    }
  }

  /// The native platform transport, when this build has one (Android). Returns
  /// null for the simulated/unsupported transports, which need no OS
  /// permissions or Wi-Fi checks.
  PlatformTransport? get platformTransport {
    final transport = core.transport;
    return transport is PlatformTransport ? transport : null;
  }

  /// True when the running transport is the native one and therefore depends on
  /// OS runtime permissions + the Wi-Fi radio.
  bool get requiresPlatformPermissions => platformTransport != null;

  Future<bool> isWifiEnabled() async =>
      await platformTransport?.gateway.isWifiEnabled() ?? true;

  Future<bool> requestWifiEnable() async =>
      await platformTransport?.gateway.requestWifiEnable() ?? true;

  /// Whether a Wi-Fi hotspot is running on this device. Only meaningful for the
  /// native transport; the simulated one reports false.
  Future<bool> isHotspotEnabled() async =>
      await platformTransport?.gateway.isHotspotEnabled() ?? false;

  /// Opens the system hotspot/tethering settings.
  Future<void> openHotspotSettings() async {
    await platformTransport?.gateway.openHotspotSettings();
  }

  bool _notificationPermissionRequested = false;

  /// Asks the OS for the notification permission at most once per app run.
  /// Safe and silent when not running the native transport.
  Future<void> ensureNotificationPermission() async {
    if (_notificationPermissionRequested) return;
    _notificationPermissionRequested = true;
    final transport = platformTransport;
    if (transport == null) return;
    try {
      await transport.gateway.requestNotificationPermission();
    } catch (_) {
      // Optional: a denial only means quiet arrivals.
    }
  }

  /// Posts a local notification for an accepted inbound message.
  ///
  /// The [MessageService.incomingMessages] stream only emits messages that
  /// decrypted for this identity, so a notification is never raised for a
  /// message addressed to anyone else.
  void _onIncomingMessage(ChatMessage message) {
    final transport = platformTransport;
    if (transport == null) return;
    unawaited(_notifyIncoming(transport, message));
  }

  Future<void> _notifyIncoming(
    PlatformTransport transport,
    ChatMessage message,
  ) async {
    try {
      if (_isInForeground) return;
      final sender = await core.identities.find(message.senderId);
      final name = sender?.record.displayName ?? 'Someone nearby';
      final body = message.payloadType == MessagePayloadType.png
          ? 'Photo'
          : (message.text ?? 'New message');
      await transport.gateway.notifyMessage(
        title: 'New message from $name',
        body: body,
      );
    } catch (_) {
      // A missing notification must never affect message delivery.
    }
  }

  Future<bool> arePermissionsGranted() async =>
      await platformTransport?.gateway.checkPermissions() ?? true;

  /// Shows the system permission dialog. Returns whether it was granted.
  Future<bool> requestPermissions() async =>
      await platformTransport?.gateway.requestPermissions() ?? true;

  /// Opens this app's system settings page (for permanently denied permissions).
  Future<void> openAppSettings() async {
    await platformTransport?.gateway.openAppSettings();
  }

  bool _permissionsGranted = true;

  /// Whether the OS permissions the native transport needs are granted.
  bool get permissionsGranted => _permissionsGranted;

  /// Re-reads permission state without prompting. Notifies listeners.
  Future<void> refreshPermissions() async {
    _permissionsGranted = requiresPlatformPermissions
        ? await arePermissionsGranted()
        : true;
    notifyListeners();
  }

  /// Prompts for the required permissions when missing and returns the result.
  Future<bool> ensurePermissions() async {
    await refreshPermissions();
    if (_permissionsGranted) return true;
    _permissionsGranted = await requestPermissions();
    notifyListeners();
    return _permissionsGranted;
  }

  /// Called by the UI after the permission dialog is granted, so a pending
  /// networking start can proceed.
  Future<void> onPermissionsGranted() async {
    _permissionsGranted = true;
    notifyListeners();
    if (consentAccepted &&
        networkingEnabled &&
        core.identityHolder.hasIdentity) {
      await ensureNetworkingStarted();
    }
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _isInForeground;
    _isInForeground = state == AppLifecycleState.resumed;
    if (wasForeground != _isInForeground) notifyListeners();
    super.didChangeAppLifecycleState(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_incomingSub?.cancel());
    unawaited(_demoPeer?.stop());
    unawaited(core.dispose());
    super.dispose();
  }
}
