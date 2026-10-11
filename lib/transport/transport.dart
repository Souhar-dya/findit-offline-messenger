import 'dart:async';
import 'dart:typed_data';

import '../crypto/identity_record.dart';
import '../domain/entities/peer_summary.dart';

/// Static description of what a transport can do on this platform.
class TransportCapabilities {
  const TransportCapabilities({
    required this.canDiscover,
    required this.canConnect,
    required this.supportsResumableTransfer,
    required this.isSimulated,
    required this.supportsBackground,
    required this.description,
  });

  /// True when nearby peers can be discovered without knowing them in advance.
  final bool canDiscover;

  /// True when a connection can be opened to a specific peer handle.
  final bool canConnect;

  /// True when interrupted transfers can be resumed at the transport level.
  final bool supportsResumableTransfer;

  /// True only for in-process / loopback transports. The UI must label these.
  final bool isSimulated;

  /// Best-effort desktop/mobile background execution support.
  final bool supportsBackground;

  /// Human-readable explanation shown in the Nearby / Settings screens.
  final String description;

  static const TransportCapabilities unavailable = TransportCapabilities(
    canDiscover: false,
    canConnect: false,
    supportsResumableTransfer: false,
    isSimulated: false,
    supportsBackground: false,
    description:
        'No physical peer-to-peer Wi-Fi transport is available on '
        'this platform.',
  );
}

/// A peer advertised by a transport.
///
/// [peerId] is an ephemeral, rotating transport handle. A permanent identity id
/// is deliberately NOT part of an advertisement; it is only revealed after an
/// explicit connect + handshake.
class TransportPeer {
  const TransportPeer({
    required this.peerId,
    required this.discoveredAtMs,
    this.displayNameHint,
    this.rssi,
  });

  final String peerId;
  final int discoveredAtMs;

  /// Non-authoritative, possibly-empty display hint from the advertisement.
  final String? displayNameHint;
  final int? rssi;
}

/// Identity + capability exchange performed immediately after connecting.
class PeerHandshakeRequest {
  const PeerHandshakeRequest({
    required this.identity,
    required this.capabilities,
  });

  final IdentityRecord identity;
  final List<String> capabilities;
}

class PeerHandshakeResult {
  const PeerHandshakeResult({
    required this.identity,
    required this.capabilities,
  });

  final IdentityRecord identity;
  final List<String> capabilities;

  bool get supportsResumableTransfer =>
      capabilities.contains(TransportCapabilitiesKeys.resumableTransfer);
}

/// Well-known capability keys.
class TransportCapabilitiesKeys {
  TransportCapabilitiesKeys._();

  static const String resumableTransfer = 'resume';
  static const String cborEnvelopes = 'cbor-envelope-v1';
}

/// A live, authenticated-ish connection to a peer.
///
/// The transport does not know about messages or friendships; it only moves
/// opaque envelope bytes plus compact summaries.
abstract class TransportConnection {
  /// Ephemeral handle of the remote peer.
  String get peerId;

  /// True while the underlying channel is usable.
  bool get isOpen;

  /// Exchanges identity and capabilities. Must be called first.
  Future<PeerHandshakeResult> handshake(PeerHandshakeRequest request);

  /// Sends a compact peer summary (best-effort).
  Future<void> sendSummary(PeerSummary summary);

  /// Transfers complete envelope bundles.
  Future<void> sendBundles(List<Uint8List> bundles);

  /// Summaries received from the remote peer.
  Stream<PeerSummary> get summaries;

  /// Envelope bundles received from the remote peer.
  Stream<Uint8List> get bundles;

  /// Transport-level errors on this connection.
  Stream<Object> get errors;

  Future<void> close();
}

/// A replaceable discovery + transfer implementation.
abstract class Transport {
  /// Stable id of the transport implementation (e.g. `simulated`, `wifi-aware`).
  String get id;

  /// Human-readable name.
  String get name;

  /// Ephemeral, stable-for-this-session handle of the local endpoint. Used only
  /// for deterministic connect arbitration and diagnostics; it is never treated
  /// as an identity.
  String get localId;

  TransportCapabilities get capabilities;

  bool get isRunning;

  /// Peers currently considered reachable (snapshot, for seeding the UI).
  List<TransportPeer> get knownPeers;

  /// Peers that became visible.
  Stream<TransportPeer> get discoveredPeers;

  /// Handles of peers that are no longer visible.
  Stream<String> get lostPeers;

  /// Connections initiated by a remote peer.
  Stream<TransportConnection> get incomingConnections;

  /// Transport-level errors.
  Stream<Object> get errors;

  /// Starts discovery / advertisement. A non-simulated transport that cannot
  /// run on this platform must throw [TransportException] rather than pretend.
  Future<void> start();

  Future<void> stop();

  /// Publishes the advertisement used for discovery. Implementations should
  /// advertise only a rotating token and an optional display hint, never the
  /// permanent identity id.
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required IdentityRecord identity,
    required bool discoverable,
  });

  /// Opens a connection to [peerId], which must be a discovered handle.
  Future<TransportConnection> connect(String peerId);

  Future<void> dispose();
}
