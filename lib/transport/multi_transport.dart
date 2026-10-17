import 'dart:async';

import '../core/errors/app_exception.dart';
import '../crypto/identity_record.dart';
import 'transport.dart';

/// A transport that runs several links at once.
///
/// [MultiTransport] composes an ordered list of child transports. The order is
/// the preference: for a handle no child has claimed yet, the first child that
/// can open a connection wins. The intended order is
/// `[PlatformTransport (Wi-Fi Direct), BleTransport (BLE)]` — fast, image-capable
/// Wi-Fi Direct first, and the always-present, low-power BLE link second.
///
/// Discovery stays per child: each child discovers and advertises with its own
/// rotating handle. This class merges those views, and remembers which child
/// owns a handle so [connect] and [localIdFor] route the link back to where it
/// came from. Everything above the transport already works on opaque,
/// end-to-end-encrypted bundles, so a carried message does not care which child
/// moved it — which is what makes "reachable on Wi-Fi Direct now, on BLE later"
/// work.
class MultiTransport implements Transport {
  MultiTransport(this._children, {this.id = 'multi', this.name = 'Multi'}) {
    assert(_children.isNotEmpty, 'MultiTransport needs at least one child');
    for (final child in _children) {
      _subscriptions.add(
        child.discoveredPeers.listen((peer) => _onDiscovered(child, peer)),
      );
      _subscriptions.add(
        child.lostPeers.listen((handle) => _onLost(handle)),
      );
      _subscriptions.add(child.incomingConnections.listen(_incomingCtl.add));
      _subscriptions.add(child.errors.listen(_errorsCtl.add));
      for (final peer in child.knownPeers) {
        _owners[peer.peerId] = child;
        _known[peer.peerId] = peer;
      }
    }
  }

  /// Child transports, most preferred first.
  final List<Transport> _children;

  @override
  final String id;

  @override
  final String name;

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  final StreamController<TransportPeer> _discoveredCtl =
      StreamController<TransportPeer>.broadcast();
  final StreamController<String> _lostCtl = StreamController<String>.broadcast();
  final StreamController<TransportConnection> _incomingCtl =
      StreamController<TransportConnection>.broadcast();
  final StreamController<Object> _errorsCtl = StreamController<Object>.broadcast();

  /// Which child discovered a given handle.
  final Map<String, Transport> _owners = <String, Transport>{};

  final Map<String, TransportPeer> _known = <String, TransportPeer>{};

  void _onDiscovered(Transport child, TransportPeer peer) {
    _owners[peer.peerId] = child;
    _known[peer.peerId] = peer;
    _discoveredCtl.add(peer);
  }

  void _onLost(String handle) {
    _owners.remove(handle);
    _known.remove(handle);
    _lostCtl.add(handle);
  }

  @override
  String get localId => _children.first.localId;

  /// The local handle of the link that owns [peerId], so the routing engine's
  /// dial tie-break compares matching handles even when several radios are on.
  @override
  String localIdFor(String peerId) => _owners[peerId]?.localId ?? localId;

  @override
  TransportCapabilities get capabilities {
    final all = [for (final child in _children) child.capabilities];
    if (all.isEmpty) return TransportCapabilities.unavailable;
    return TransportCapabilities(
      canDiscover: all.any((c) => c.canDiscover),
      canConnect: all.any((c) => c.canConnect),
      supportsResumableTransfer: all.any((c) => c.supportsResumableTransfer),
      isSimulated: all.every((c) => c.isSimulated),
      supportsBackground: all.any((c) => c.supportsBackground),
      description: _children.length == 1
          ? all.single.description
          : 'Combined link: ${_children.map((c) => c.name).join(' + ')}.',
    );
  }

  @override
  bool get isRunning => _children.any((c) => c.isRunning);

  @override
  List<TransportPeer> get knownPeers => List.unmodifiable(_known.values);

  @override
  Stream<TransportPeer> get discoveredPeers => _discoveredCtl.stream;

  @override
  Stream<String> get lostPeers => _lostCtl.stream;

  @override
  Stream<TransportConnection> get incomingConnections => _incomingCtl.stream;

  @override
  Stream<Object> get errors => _errorsCtl.stream;

  @override
  Future<void> start() async {
    final failures = <Object>[];
    for (final child in _children) {
      try {
        await child.start();
      } catch (error) {
        failures.add(error);
      }
    }
    _throwIfAllFailed(failures);
    _reportFailures(failures);
  }

  @override
  Future<void> stop() async {
    for (final child in _children) {
      try {
        await child.stop();
      } catch (error) {
        _errorsCtl.add(error);
      }
    }
  }

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required IdentityRecord identity,
    required bool discoverable,
  }) async {
    final failures = <Object>[];
    for (final child in _children) {
      try {
        await child.updateAdvertisement(
          displayNameHint: displayNameHint,
          identity: identity,
          discoverable: discoverable,
        );
      } catch (error) {
        failures.add(error);
      }
    }
    _throwIfAllFailed(failures);
    _reportFailures(failures);
  }

  @override
  Future<TransportConnection> connect(String peerId) async {
    final owner = _owners[peerId];
    if (owner != null) return owner.connect(peerId);

    // The handle was not discovered on any child we track (for example it
    // appeared while we were busy). Try each child in preference order and keep
    // the first that answers.
    final failures = <Object>[];
    for (final child in _children) {
      try {
        return await child.connect(peerId);
      } catch (error) {
        failures.add(error);
      }
    }
    throw failures.isNotEmpty
        ? failures.first
        : const TransportException('No transport could reach this peer');
  }

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final child in _children) {
      try {
        await child.dispose();
      } catch (_) {
        // A child that cannot dispose must not keep the others alive.
      }
    }
    await _discoveredCtl.close();
    await _lostCtl.close();
    await _incomingCtl.close();
    await _errorsCtl.close();
  }

  /// Rethrows only when every child failed; otherwise reports the partial
  /// failures on [errors] so one dead radio never takes the whole app down.
  void _throwIfAllFailed(List<Object> failures) {
    if (failures.isNotEmpty && failures.length == _children.length) {
      throw failures.first;
    }
  }

  void _reportFailures(List<Object> failures) {
    for (final failure in failures) {
      _errorsCtl.add(failure);
    }
  }
}
