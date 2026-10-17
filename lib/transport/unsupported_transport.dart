import 'dart:async';
import 'dart:math';

import '../core/errors/app_exception.dart';
import '../crypto/identity_record.dart';
import 'transport.dart';

/// An honest transport placeholder for platforms where no cross-platform
/// peer-to-peer Wi-Fi transport exists.
///
/// It never fakes connectivity: discovery, connection and advertisement all
/// throw [TransportException] with a clear explanation, and
/// [TransportCapabilities.unavailable] advertises `canDiscover = false`.
///
/// Background: Android offers Wi-Fi Aware (NAN) while iOS offers
/// MultipeerConnectivity / Wi-Fi Aware only on newer hardware. There is no
/// single Flutter plugin that implements both with the same semantics, and
/// Bluetooth is explicitly out of scope. Rather than pretend, the app surfaces
/// this limitation and keeps the store-carry-forward core fully usable through
/// the simulated transport.
class UnsupportedWifiTransport implements Transport {
  UnsupportedWifiTransport() : localId = _randomHandle();

  @override
  final String localId;

  @override
  String localIdFor(String peerId) => localId;

  @override
  String get id => 'wifi-p2p-unavailable';

  @override
  String get name => 'Peer-to-peer Wi-Fi (unavailable)';

  @override
  TransportCapabilities get capabilities => TransportCapabilities.unavailable;

  @override
  bool get isRunning => false;

  @override
  List<TransportPeer> get knownPeers => const [];

  @override
  Stream<TransportPeer> get discoveredPeers => const Stream.empty();

  @override
  Stream<String> get lostPeers => const Stream.empty();

  @override
  Stream<TransportConnection> get incomingConnections => const Stream.empty();

  @override
  Stream<Object> get errors => const Stream.empty();

  @override
  Future<void> start() async {
    throw const TransportException(
      'No physical peer-to-peer Wi-Fi transport is available on this platform. '
      'Live relaying between real devices is not implemented; use the '
      'simulated transport or a future Wi-Fi Aware / MultipeerConnectivity '
      'plugin.',
    );
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required IdentityRecord identity,
    required bool discoverable,
  }) async {
    // Nothing to advertise without a radio; intentionally a no-op rather than
    // a failure so the UI can still show the capability state.
  }

  @override
  Future<TransportConnection> connect(String peerId) async {
    throw const TransportException(
      'Cannot connect: no physical peer-to-peer Wi-Fi transport is available.',
    );
  }

  @override
  Future<void> dispose() async {}

  static String _randomHandle() {
    final random = Random.secure();
    return List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
