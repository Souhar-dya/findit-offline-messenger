import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/di/core_services.dart';
import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/core/utils/clock.dart';
import 'package:findit/crypto/identity_record.dart';
import 'package:findit/crypto/identity_service.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/domain/entities/peer_summary.dart';
import 'package:findit/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'support/db.dart';
import 'support/harness.dart' show waitFor;

/// A connection whose handshake always presents [record], whatever its
/// ephemeral handle is.
class _FakeConnection implements TransportConnection {
  _FakeConnection(this.peerId, this.record);

  @override
  final String peerId;
  final IdentityRecord record;
  bool _open = true;
  int closeCount = 0;

  final StreamController<Uint8List> _bundles =
      StreamController<Uint8List>();
  final StreamController<PeerSummary> _summaries =
      StreamController<PeerSummary>();
  final StreamController<Object> _errors = StreamController<Object>();

  @override
  bool get isOpen => _open;

  @override
  Stream<Uint8List> get bundles => _bundles.stream;

  @override
  Stream<PeerSummary> get summaries => _summaries.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<PeerHandshakeResult> handshake(PeerHandshakeRequest request) async =>
      PeerHandshakeResult(identity: record, capabilities: const []);

  @override
  Future<void> sendSummary(PeerSummary summary) async {}

  @override
  Future<void> sendBundles(List<Uint8List> bundles) async {}

  @override
  Future<void> close() async {
    closeCount++;
    if (!_open) return;
    _open = false;
    unawaited(_bundles.close());
    unawaited(_summaries.close());
    unawaited(_errors.close());
  }
}

/// A transport that lets a test push inbound connections with chosen handles,
/// modelling the same device reaching us over more than one socket.
class _FakeTransport implements Transport {
  _FakeTransport(this.localId);

  @override
  final String localId;

  @override
  String localIdFor(String peerId) => localId;

  final StreamController<TransportConnection> _incoming =
      StreamController<TransportConnection>.broadcast();
  final StreamController<TransportPeer> _discovered =
      StreamController<TransportPeer>.broadcast();
  final StreamController<String> _lost = StreamController<String>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  bool _running = false;

  void push(TransportConnection connection) => _incoming.add(connection);

  @override
  String get id => 'fake';

  @override
  String get name => 'Fake';

  @override
  TransportCapabilities get capabilities => const TransportCapabilities(
    canDiscover: true,
    canConnect: true,
    supportsResumableTransfer: false,
    isSimulated: true,
    supportsBackground: false,
    description: 'Fake transport for tests.',
  );

  @override
  bool get isRunning => _running;

  @override
  List<TransportPeer> get knownPeers => const [];

  @override
  Stream<TransportPeer> get discoveredPeers => _discovered.stream;

  @override
  Stream<String> get lostPeers => _lost.stream;

  @override
  Stream<TransportConnection> get incomingConnections => _incoming.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required IdentityRecord identity,
    required bool discoverable,
  }) async {}

  @override
  Future<TransportConnection> connect(String peerId) async =>
      throw const TransportException('Not used by this test');

  @override
  Future<void> dispose() async {
    await _incoming.close();
    await _discovered.close();
    await _lost.close();
    await _errors.close();
  }
}

void main() {
  test(
    'collapses two sockets that handshake to the same identity',
    () async {
      final directory = Directory.systemTemp.createTempSync('findit_dedupe');
      final transport = _FakeTransport('local-handle');
      final core = await CoreServices.create(
        databaseFactory: testDatabaseFactory,
        databasePath: p.join(directory.path, 'findit.db'),
        secretStore: InMemorySecretStore(),
        transport: transport,
        config: AppConfig.test,
        clock: FixedClock(DateTime.utc(2026, 1, 1)),
        autoConnect: false,
      );
      try {
        final local = await core.identityService.generate(
          displayName: 'Local',
        );
        core.identityHolder.set(local);
        await core.routingEngine.start();

        final peer = await IdentityService(
          secretStore: InMemorySecretStore(),
        ).generate(displayName: 'Peer');

        // The same person, first over an inbound socket keyed by ip:port (the
        // Wi-Fi Direct group-owner view) ...
        final first = _FakeConnection('192.168.49.2:5000', peer.record);
        transport.push(first);
        await waitFor(
          () => core.routingEngine.peers.length == 1,
          description: 'the first session to open',
        );

        // ... and again over a socket keyed by the rotating handle (the client
        // view). Keep the newly verified session and close the stale socket.
        final second = _FakeConnection('peer-handle', peer.record);
        transport.push(second);
        await waitFor(
          () => first.closeCount == 1,
          description: 'the stale socket to be closed',
        );

        expect(core.routingEngine.peers.length, 1);
        expect(core.routingEngine.peers.single.identityId, peer.identityId);
        expect(second.isOpen, isTrue);
      } finally {
        await core.dispose();
        try {
          directory.deleteSync(recursive: true);
        } catch (_) {
          // Best effort.
        }
      }
    },
  );
}
