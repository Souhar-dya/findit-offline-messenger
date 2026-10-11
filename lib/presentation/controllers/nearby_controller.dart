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

  Future<void> refresh() async {
    _knownPeers = _services.core.transport.knownPeers;
    _sessions = _services.core.routingEngine.peers;
    await refreshPlatformState();
    notifyListeners();
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
      _error = 'Could not start discovery: $error';
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

  void _onServicesChanged() => notifyListeners();

  @override
  void dispose() {
    _services.removeListener(_onServicesChanged);
    _discovered?.cancel();
    _lost?.cancel();
    _peers?.cancel();
    super.dispose();
  }
}
