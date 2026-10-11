import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/errors/app_exception.dart';
import '../crypto/identity_record.dart';
import '../domain/entities/peer_summary.dart';
import 'transport.dart';

/// An in-process bus that connects [SimulatedTransport] endpoints.
///
/// This is *not* a radio. It exists so the full protocol (discovery, handshake,
/// summaries, bundle transfer) can be exercised on one machine, in tests, and
/// in the built-in demo peer. The code path is identical to a real transport,
/// which is what makes the abstraction meaningful.
class SimulatedNetwork {
  SimulatedNetwork({this.name = 'simulated'});

  final String name;
  final Map<String, SimulatedTransport> _endpoints =
      <String, SimulatedTransport>{};
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// When true, no new connections can be established (models "offline").
  bool offline = false;

  Iterable<SimulatedTransport> get endpoints => _endpoints.values;

  Stream<void> get changes => _changes.stream;

  SimulatedTransport? find(String localId) => _endpoints[localId];

  void _register(SimulatedTransport transport) {
    _endpoints[transport.localId] = transport;
    _notify();
  }

  void _unregister(String localId) {
    if (_endpoints.remove(localId) != null) _notify();
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  Future<void> dispose() async {
    for (final endpoint in [..._endpoints.values]) {
      await endpoint.dispose();
    }
    _endpoints.clear();
    await _changes.close();
  }
}

/// A [Transport] backed by [SimulatedNetwork].
class SimulatedTransport implements Transport {
  SimulatedTransport({
    required this.network,
    String? localId,
    this.exchangeDelay = Duration.zero,
  }) : localId = localId ?? _randomHandle();

  final SimulatedNetwork network;

  @override
  final String localId;

  /// Optional artificial latency applied to every transfer, to make races in
  /// the routing layer observable in tests.
  final Duration exchangeDelay;

  @override
  String get id => 'simulated';

  @override
  String get name => 'Simulated (in-process)';

  @override
  TransportCapabilities get capabilities => TransportCapabilities(
    canDiscover: true,
    canConnect: true,
    supportsResumableTransfer: true,
    isSimulated: true,
    supportsBackground: false,
    description:
        'In-process loopback transport. No radio, Wi-Fi or Bluetooth is '
        'used. For development, tests and the built-in demo peer only.',
  );

  @override
  bool get isRunning => _running;

  @override
  List<TransportPeer> get knownPeers => _known.values.toList(growable: false);

  @override
  Stream<TransportPeer> get discoveredPeers => _discovered.stream;

  @override
  Stream<String> get lostPeers => _lost.stream;

  @override
  Stream<TransportConnection> get incomingConnections => _incoming.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  final StreamController<TransportPeer> _discovered =
      StreamController<TransportPeer>.broadcast();
  final StreamController<String> _lost = StreamController<String>.broadcast();
  final StreamController<TransportConnection> _incoming =
      StreamController<TransportConnection>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  final Map<String, TransportPeer> _known = <String, TransportPeer>{};
  final Map<String, _SimulatedConnection> _connections =
      <String, _SimulatedConnection>{};

  StreamSubscription<void>? _networkSub;
  bool _running = false;
  bool _discoverable = false;
  String? _displayHint;

  /// When set, the next outbound bundle transfer throws, modelling a connection
  /// that fails mid-session. The bundle must NOT be recorded as forwarded.
  bool dropNextBundleSend = false;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    network._register(this);
    _networkSub = network.changes.listen((_) => _refreshDiscovery());
    _refreshDiscovery();
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _networkSub?.cancel();
    _networkSub = null;
    for (final connection in [..._connections.values]) {
      await connection.close();
    }
    _connections.clear();
    network._unregister(localId);
    final gone = _known.keys.toList();
    _known.clear();
    for (final peerId in gone) {
      if (!_lost.isClosed) _lost.add(peerId);
    }
  }

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required IdentityRecord identity,
    required bool discoverable,
  }) async {
    _displayHint = displayNameHint;
    _discoverable = discoverable;
    // Deliberately ignore [identity]: advertisements must not leak the
    // permanent identity id. Only the rotating handle and a display hint are
    // published.
    network._notify();
    _refreshDiscovery();
  }

  @override
  Future<TransportConnection> connect(String peerId) async {
    if (!_running) {
      throw const TransportException('Transport is not running');
    }
    if (network.offline) {
      throw const TransportException('Network is offline');
    }
    final peer = network.find(peerId);
    if (peer == null || !peer._running) {
      throw const TransportException('Peer is not reachable');
    }
    final existing = _connections[peerId];
    if (existing != null && existing.isOpen) return existing;

    final local = _SimulatedConnection(peerId, this);
    final remote = _SimulatedConnection(localId, peer);
    local._remote = remote;
    remote._remote = local;
    _connections[peerId] = local;
    peer._connections[localId] = remote;
    if (!peer._incoming.isClosed) peer._incoming.add(remote);
    return local;
  }

  void _refreshDiscovery() {
    if (!_running) return;
    final reachable = <String, SimulatedTransport>{};
    for (final endpoint in network.endpoints) {
      if (identical(endpoint, this)) continue;
      if (!endpoint._running || !endpoint._discoverable) continue;
      reachable[endpoint.localId] = endpoint;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final entry in reachable.entries) {
      if (_known.containsKey(entry.key)) continue;
      final peer = TransportPeer(
        peerId: entry.key,
        discoveredAtMs: now,
        displayNameHint: entry.value._displayHint,
      );
      _known[entry.key] = peer;
      if (!_discovered.isClosed) _discovered.add(peer);
    }
    final lost = _known.keys.where((id) => !reachable.containsKey(id)).toList();
    for (final peerId in lost) {
      _known.remove(peerId);
      final connection = _connections.remove(peerId);
      if (connection != null) unawaited(connection.close());
      if (!_lost.isClosed) _lost.add(peerId);
    }
  }

  Future<void> _handleRemoteClose(String peerId) async {
    final connection = _connections.remove(peerId);
    await connection?.disposeLocal();
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _discovered.close();
    await _lost.close();
    await _incoming.close();
    await _errors.close();
  }

  static String _randomHandle() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }
}

/// One end of an in-process connection. The remote end is another
/// [_SimulatedConnection] whose stream controllers receive our frames.
class _SimulatedConnection implements TransportConnection {
  _SimulatedConnection(this.peerId, this._local);

  @override
  final String peerId;

  final SimulatedTransport _local;

  _SimulatedConnection? _remote;
  bool _open = true;

  final StreamController<Uint8List> _bundles = StreamController<Uint8List>();
  final StreamController<PeerSummary> _summaries =
      StreamController<PeerSummary>();
  final StreamController<Object> _errors = StreamController<Object>();

  PeerHandshakeRequest? _pendingRemoteRequest;
  Completer<PeerHandshakeRequest>? _remoteCompleter;

  @override
  Stream<Uint8List> get bundles => _bundles.stream;

  @override
  Stream<PeerSummary> get summaries => _summaries.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  bool get isOpen => _open && (_remote?._open ?? false);

  @override
  Future<PeerHandshakeResult> handshake(PeerHandshakeRequest request) async {
    _ensureOpen();
    final completer = Completer<PeerHandshakeRequest>();
    _remoteCompleter = completer;
    final already = _pendingRemoteRequest;
    _pendingRemoteRequest = null;
    if (already != null) {
      completer.complete(already);
    }
    _remote?._receiveHandshake(request);
    final remote = await completer.future.timeout(const Duration(seconds: 15));
    return PeerHandshakeResult(
      identity: remote.identity,
      capabilities: remote.capabilities,
    );
  }

  void _receiveHandshake(PeerHandshakeRequest request) {
    final completer = _remoteCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(request);
      _remoteCompleter = null;
    } else {
      _pendingRemoteRequest = request;
    }
  }

  @override
  Future<void> sendSummary(PeerSummary summary) async {
    _ensureOpen();
    final remote = _remote;
    if (remote == null || remote._summaries.isClosed) return;
    await _delay();
    remote._summaries.add(summary);
  }

  @override
  Future<void> sendBundles(List<Uint8List> bundles) async {
    _ensureOpen();
    if (_local.dropNextBundleSend) {
      _local.dropNextBundleSend = false;
      throw const TransportException('Simulated transfer failure');
    }
    final remote = _remote;
    if (remote == null) {
      throw const TransportException('Connection is closed');
    }
    await _delay();
    for (final bytes in bundles) {
      if (remote._bundles.isClosed) {
        throw const TransportException('Connection closed during transfer');
      }
      remote._bundles.add(bytes);
    }
  }

  Future<void> _delay() async {
    if (_local.exchangeDelay > Duration.zero) {
      await Future<void>.delayed(_local.exchangeDelay);
    }
  }

  void _ensureOpen() {
    if (!_open) throw const TransportException('Connection is closed');
    if (_remote == null || !_remote!._open) {
      throw const TransportException('Connection is closed');
    }
  }

  /// Adds an error to this side's error stream (used by tests / fault injection).
  void injectError(Object error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    final remote = _remote;
    if (remote != null) {
      remote._open = false;
      await remote._local._handleRemoteClose(remote.peerId);
      await remote.disposeLocal();
    }
    await _local._handleRemoteClose(peerId);
    await disposeLocal();
  }

  /// Closes the internal message streams and marks the connection closed.
  ///
  /// These are single-subscription controllers: their `close()` future only
  /// completes once a listener consumes the `done` event, which may never
  /// happen (e.g. a raw `connect()` whose session was never started). The
  /// futures are deliberately not awaited; `isClosed` flips synchronously,
  /// which is what senders check.
  Future<void> disposeLocal() async {
    _open = false;
    unawaited(_bundles.close());
    unawaited(_summaries.close());
    unawaited(_errors.close());
  }
}
