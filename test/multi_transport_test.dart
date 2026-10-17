import 'dart:async';
import 'dart:typed_data';

import 'package:findit/core/errors/app_exception.dart';
import 'package:findit/crypto/identity_record.dart';
import 'package:findit/crypto/identity_service.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/domain/entities/peer_summary.dart';
import 'package:findit/transport/multi_transport.dart';
import 'package:findit/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// A connection that does nothing but carry its handle; enough to prove which
/// child [MultiTransport.connect] routed to.
class _FakeConnection implements TransportConnection {
  _FakeConnection(this.peerId);

  @override
  final String peerId;

  @override
  bool get isOpen => true;

  @override
  Stream<Uint8List> get bundles => const Stream<Uint8List>.empty();

  @override
  Stream<PeerSummary> get summaries => const Stream<PeerSummary>.empty();

  @override
  Stream<Object> get errors => const Stream<Object>.empty();

  @override
  Future<PeerHandshakeResult> handshake(PeerHandshakeRequest request) async =>
      throw UnimplementedError();

  @override
  Future<void> sendSummary(PeerSummary summary) async {}

  @override
  Future<void> sendBundles(List<Uint8List> bundles) async {}

  @override
  Future<void> close() async {}
}

class _FakeTransport implements Transport {
  _FakeTransport(
    this.localId, {
    String? id,
    String? name,
    TransportCapabilities capabilities = const TransportCapabilities(
      canDiscover: true,
      canConnect: true,
      supportsResumableTransfer: false,
      isSimulated: true,
      supportsBackground: false,
      description: 'Fake link.',
    ),
  })  : id = id ?? 'fake-$localId',
        name = name ?? 'Fake $localId',
        _capabilities = capabilities;

  @override
  final String localId;

  @override
  final String id;

  @override
  final String name;

  final TransportCapabilities _capabilities;

  /// Peers seeded before the composite is built.
  final List<TransportPeer> known = [];

  final StreamController<TransportPeer> _discovered =
      StreamController<TransportPeer>.broadcast();
  final StreamController<String> _lost = StreamController<String>.broadcast();
  final StreamController<TransportConnection> _incoming =
      StreamController<TransportConnection>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  final List<String> connectCalls = [];
  int startCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  int advertisementCalls = 0;

  Object? startFailure;
  Future<TransportConnection> Function(String handle)? onConnect;

  bool running = false;

  void emitPeer(TransportPeer peer) => _discovered.add(peer);
  void emitLost(String handle) => _lost.add(handle);
  void emitIncoming(TransportConnection connection) => _incoming.add(connection);
  void emitError(Object error) => _errors.add(error);

  @override
  String localIdFor(String peerId) => localId;

  @override
  TransportCapabilities get capabilities => _capabilities;

  @override
  bool get isRunning => running;

  @override
  List<TransportPeer> get knownPeers => List.unmodifiable(known);

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
    startCalls++;
    final failure = startFailure;
    if (failure != null) throw failure;
    running = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    running = false;
  }

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required IdentityRecord identity,
    required bool discoverable,
  }) async {
    advertisementCalls++;
  }

  @override
  Future<TransportConnection> connect(String peerId) async {
    connectCalls.add(peerId);
    final handler = onConnect;
    if (handler == null) {
      throw const TransportException('No route to peer');
    }
    return handler(peerId);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _discovered.close();
    await _lost.close();
    await _incoming.close();
    await _errors.close();
  }
}

TransportPeer _peer(String handle, {String? hint}) => TransportPeer(
      peerId: handle,
      discoveredAtMs: 0,
      displayNameHint: hint,
    );

void main() {
  late IdentityRecord identity;

  setUpAll(() async {
    final generated = await IdentityService(
      secretStore: InMemorySecretStore(),
    ).generate(displayName: 'Tester');
    identity = generated.record;
  });

  test('localId is the most preferred child and localIdFor routes per link',
      () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    expect(multi.localId, 'wifi-local');
    // Unknown handle falls back to the preferred link's handle...
    expect(multi.localIdFor('nobody'), 'wifi-local');

    // ...and a discovered handle reports the handle of the link that saw it.
    wifi.emitPeer(_peer('wifi-peer'));
    ble.emitPeer(_peer('ble-peer'));
    await Future<void>.delayed(Duration.zero);

    expect(multi.localIdFor('wifi-peer'), 'wifi-local');
    expect(multi.localIdFor('ble-peer'), 'ble-local');

    await multi.dispose();
  });

  test('connect routes a known handle to the child that discovered it',
      () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    ble.emitPeer(_peer('ble-peer'));
    ble.onConnect = (handle) async {
      expect(handle, 'ble-peer');
      return _FakeConnection(handle);
    };
    await Future<void>.delayed(Duration.zero);

    final connection = await multi.connect('ble-peer');
    expect(connection.peerId, 'ble-peer');
    expect(ble.connectCalls, ['ble-peer']);
    expect(wifi.connectCalls, isEmpty);

    await multi.dispose();
  });

  test('connect tries children in preference order for an unknown handle',
      () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    wifi.onConnect = (_) async => throw const TransportException('not on wifi');
    ble.onConnect = (handle) async => _FakeConnection(handle);

    final connection = await multi.connect('ghost');
    expect(connection.peerId, 'ghost');
    expect(wifi.connectCalls, ['ghost']);
    expect(ble.connectCalls, ['ghost']);

    await multi.dispose();
  });

  test('connect throws the first failure when every child fails', () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    wifi.onConnect = (_) async => throw const TransportException('wifi down');
    ble.onConnect = (_) async => throw const TransportException('ble down');

    await expectLater(
      multi.connect('ghost'),
      throwsA(isA<TransportException>()),
    );

    await multi.dispose();
  });

  test('discovery and loss are merged across children', () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    final discovered = <String>[];
    final lost = <String>[];
    final sub1 = multi.discoveredPeers.listen((p) => discovered.add(p.peerId));
    final sub2 = multi.lostPeers.listen(lost.add);

    wifi.emitPeer(_peer('a'));
    ble.emitPeer(_peer('b'));
    await Future<void>.delayed(Duration.zero);
    expect(multi.knownPeers.map((p) => p.peerId), containsAll(<String>['a', 'b']));

    wifi.emitLost('a');
    await Future<void>.delayed(Duration.zero);

    expect(discovered, ['a', 'b']);
    expect(lost, ['a']);
    expect(multi.knownPeers.map((p) => p.peerId), ['b']);
    // A lost handle is no longer owned by any link.
    expect(multi.localIdFor('a'), 'wifi-local');

    await sub1.cancel();
    await sub2.cancel();
    await multi.dispose();
  });

  test('incoming connections and errors fan in from every child', () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    final incoming = <String>[];
    final errors = <Object>[];
    final sub1 = multi.incomingConnections.listen((c) => incoming.add(c.peerId));
    final sub2 = multi.errors.listen(errors.add);

    ble.emitIncoming(_FakeConnection('in-from-ble'));
    wifi.emitError(const TransportException('wifi hiccup'));
    await Future<void>.delayed(Duration.zero);

    expect(incoming, ['in-from-ble']);
    expect(errors, hasLength(1));

    await sub1.cancel();
    await sub2.cancel();
    await multi.dispose();
  });

  test('capabilities are the union, simulated only when every child is',
      () async {
    final wifi = _FakeTransport(
      'wifi-local',
      name: 'Wi-Fi Direct',
      capabilities: const TransportCapabilities(
        canDiscover: true,
        canConnect: true,
        supportsResumableTransfer: true,
        isSimulated: false,
        supportsBackground: true,
        description: 'Wi-Fi Direct.',
      ),
    );
    final ble = _FakeTransport(
      'ble-local',
      name: 'Bluetooth LE',
      capabilities: const TransportCapabilities(
        canDiscover: true,
        canConnect: true,
        supportsResumableTransfer: false,
        isSimulated: false,
        supportsBackground: false,
        description: 'Bluetooth LE.',
      ),
    );
    final multi = MultiTransport([wifi, ble]);

    final caps = multi.capabilities;
    expect(caps.canDiscover, isTrue);
    expect(caps.canConnect, isTrue);
    expect(caps.supportsResumableTransfer, isTrue);
    expect(caps.supportsBackground, isTrue);
    expect(caps.isSimulated, isFalse);
    expect(caps.description, contains('Wi-Fi Direct'));
    expect(caps.description, contains('Bluetooth LE'));

    await multi.dispose();
  });

  test('start fans out and only throws when every child fails', () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    final errors = <Object>[];
    final sub = multi.errors.listen(errors.add);

    wifi.startFailure = const TransportException('no radio');
    await multi.start();
    await Future<void>.delayed(Duration.zero);

    expect(wifi.startCalls, 1);
    expect(ble.startCalls, 1);
    expect(ble.isRunning, isTrue);
    expect(errors, hasLength(1));

    await sub.cancel();
    await multi.dispose();
  });

  test('start rethrows when no child can start', () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    wifi.startFailure = const TransportException('no wifi radio');
    ble.startFailure = const TransportException('no ble radio');

    await expectLater(multi.start(), throwsA(isA<TransportException>()));

    await multi.dispose();
  });

  test('updateAdvertisement fans out to every child', () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    await multi.updateAdvertisement(
      displayNameHint: 'Tester',
      identity: identity,
      discoverable: true,
    );

    expect(wifi.advertisementCalls, 1);
    expect(ble.advertisementCalls, 1);

    await multi.dispose();
  });

  test('dispose stops the children and closes the merged streams', () async {
    final wifi = _FakeTransport('wifi-local');
    final ble = _FakeTransport('ble-local');
    final multi = MultiTransport([wifi, ble]);

    await multi.dispose();

    expect(wifi.disposeCalls, 1);
    expect(ble.disposeCalls, 1);
    // The merged streams are closed, so a later event must not escape.
    await expectLater(multi.discoveredPeers, emitsDone);
  });
}
