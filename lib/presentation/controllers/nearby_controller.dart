import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/di/app_services.dart';
import '../../routing/routing_engine.dart';
import '../../transport/transport.dart';

/// Backs the Nearby screen: transport capability, discovered peers, live
/// sessions and the in-process demo peer.
class NearbyController extends ChangeNotifier {
  NearbyController(this._services) {
    final transport = _services.core.transport;
    _discovered = transport.discoveredPeers.listen((_) => refresh());
    _lost = transport.lostPeers.listen((_) => refresh());
    _peers = _services.core.routingEngine.peerChanges.listen((_) => refresh());
    _services.addListener(_onServicesChanged);
  }

  final AppServices _services;
  StreamSubscription<Object?>? _discovered;
  StreamSubscription<Object?>? _lost;
  StreamSubscription<Object?>? _peers;

  List<TransportPeer> _knownPeers = const [];
  List<PeerSessionInfo> _sessions = const [];
  bool _busy = false;
  bool _wasRunning = false;
  bool _disposed = false;
  String? _error;

  TransportCapabilities get capabilities =>
      _services.core.transport.capabilities;
  String get transportName => _services.core.transport.name;
  bool get isRunning => _services.core.routingEngine.isRunning;
  List<TransportPeer> get knownPeers => _knownPeers;
  List<PeerSessionInfo> get sessions => _sessions;
  bool get busy => _busy;
  String? get error => _error;
  bool get demoRunning => _services.isDemoRunning;
  bool get demoStarting => _services.isStartingDemo;
  String? get demoError => _services.demoError;
  bool get wifiEnabled => _wifiEnabled;
  bool get needsWifi => _needsWifi;
  bool get needsPermission => _needsPermission;

  bool _wifiEnabled = true;
  bool _needsWifi = false;
  bool _needsPermission = false;

  TransportPeer? peerFor(String peerId) {
    for (final peer in _knownPeers) {
      if (peer.peerId == peerId) return peer;
    }
    return null;
  }

  /// Discovered peers that do *not* already have a live session.
  ///
  /// A device we are already talking to must not be listed a second time under
  /// "Devices nearby": it belongs under "Connected" only. We match on the
  /// rotating handle when we have it (the client side of a Wi-Fi Direct group
  /// keys its session by handle) and, because the group owner only learns an
  /// inbound socket's ip:port, fall back to the advertised display hint, which
  /// is the same name the handshake later reports.
  List<TransportPeer> get peersInRange {
    final connectedHandles = <String>{
      for (final session in _sessions) session.transportPeerId,
    };
    final connectedNames = <String>{
      for (final session in _sessions)
        if (session.displayName != null && session.displayName!.isNotEmpty)
          session.displayName!.trim().toLowerCase(),
    };
    return [
      for (final peer in _knownPeers)
        if (!connectedHandles.contains(peer.peerId) &&
            !(peer.displayNameHint != null &&
                connectedNames.contains(
                  peer.displayNameHint!.trim().toLowerCase(),
                )))
          peer,
    ];
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _knownPeers = _services.core.transport.knownPeers;
    _sessions = _services.core.routingEngine.peers;
    await refreshPlatformState();
    // The await above can outlive the widget; never notify a disposed notifier.
    if (_disposed) return;
    _syncRunningState();
    notifyListeners();
  }

  /// Drops a stale start-up failure once the transport is actually running.
  ///
  /// The transport can be started from other screens (the permission gate, the
  /// Profile switch, identity creation), so a failure recorded here would
  /// otherwise leave a red "Wi-Fi is off" banner on Nearby even after the radio
  /// is up and peers are connected.
  void _syncRunningState() {
    final running = _services.core.routingEngine.isRunning;
    if (running && !_wasRunning) {
      _error = null;
      _needsWifi = false;
      _needsPermission = false;
    }
    _wasRunning = running;
  }

  /// Re-reads the radio + permission state without prompting the user.
  Future<void> refreshPlatformState() async {
    if (!_services.requiresPlatformPermissions) return;
    _wifiEnabled = await _services.isWifiEnabled();
  }

  /// Opens the system Wi-Fi panel so the user can turn Wi-Fi on.
  Future<void> enableWifi() async {
    if (!_services.requiresPlatformPermissions) return;
    _busy = true;
    notifyListeners();
    try {
      await _services.requestWifiEnable();
    } finally {
      _busy = false;
      await refresh();
    }
  }

  /// Opens this app's system settings page (permanently denied permission).
  Future<void> openAppSettings() => _services.openAppSettings();

  Future<void> startTransport() async {
    _busy = true;
    _error = null;
    _needsWifi = false;
    _needsPermission = false;
    notifyListeners();
    try {
      if (_services.requiresPlatformPermissions) {
        _wifiEnabled = await _services.isWifiEnabled();
        if (!_wifiEnabled) {
          _needsWifi = true;
          _error = 'Wi-Fi is off. Turn on Wi-Fi to discover nearby devices.';
          return;
        }
        if (!await _services.arePermissionsGranted()) {
          // Show the real system dialog, then continue only if it is granted.
          final granted = await _services.requestPermissions();
          if (!granted) {
            _needsPermission = true;
            _error =
                'FindIt needs the Nearby devices permission to find peers. '
                'Grant it, then tap Start again.';
            return;
          }
        }
      }
      await _services.startNetworking();
    } catch (error) {
      // The native side performs the authoritative Wi-Fi radio check, so a
      // failure here can mean the radio is off even though our pre-check read
      // as enabled. Re-read it so the "Turn on Wi-Fi" affordance appears.
      var message = 'Could not start discovery: $error';
      if (_services.requiresPlatformPermissions) {
        _wifiEnabled = await _services.isWifiEnabled();
        if (!_wifiEnabled) {
          _needsWifi = true;
          message = 'Wi-Fi is off. Turn on Wi-Fi to discover nearby devices.';
        }
      }
      _error = message;
    } finally {
      _busy = false;
      await refresh();
    }
  }

  Future<void> stopTransport() async {
    _busy = true;
    notifyListeners();
    try {
      await _services.stopNetworking();
    } finally {
      _busy = false;
      await refresh();
    }
  }

  Future<void> connect(String peerId) async {
    _error = null;
    notifyListeners();
    try {
      await _services.core.routingEngine.connectTo(peerId);
    } catch (error) {
      _error = 'Could not connect: $error';
    } finally {
      await refresh();
    }
  }

  Future<void> startDemoPeer() async {
    await _services.startDemoPeer();
    await refresh();
  }

  Future<void> stopDemoPeer() async {
    await _services.stopDemoPeer();
    await refresh();
  }

  void _onServicesChanged() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _services.removeListener(_onServicesChanged);
    _discovered?.cancel();
    _lost?.cancel();
    _peers?.cancel();
    super.dispose();
  }
}
