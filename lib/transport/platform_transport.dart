import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';

import '../core/errors/app_exception.dart';
import '../crypto/identity_record.dart';
import '../domain/entities/peer_summary.dart';
import 'frame_stream.dart';
import 'peer_wire.dart';
import 'platform_transport_contract.dart';
import 'transport.dart';

/// The raw, undecoded channel surface used by [PlatformTransport].
///
/// The default [MethodChannelPlatformTransportGateway] talks to the native
/// plugin documented in `platform_transport_contract.dart`; tests inject a fake
/// so the whole Dart-side transport (discovery handling, connectivity, the
/// handshake/summary/bundle framing over real TCP sockets) can be exercised on
/// loopback without a device.
abstract class PlatformTransportGateway {
  /// Starts native discovery. [handle] is this endpoint's rotating, ephemeral
  /// handle; native advertises exactly this value so both peers compare the same
  /// pair when electing who dials. The identity id is never passed here.
  Future<Map<String, Object?>> start({
    required int dataPort,
    required String handle,
  });

  Future<void> stop();

  Future<void> updateAdvertisement({
    required String displayNameHint,
    required bool discoverable,
  });

  /// Asks native to bring up a datapath to [handle] and returns the peer's
  /// reachable `host`/`port`.
  Future<Map<String, Object?>> connect({required String handle});

  /// Native discovery / lifecycle events, as raw maps.
  Stream<Map<String, Object?>> get events;

  /// Whether the device's Wi-Fi radio is currently enabled.
  Future<bool> isWifiEnabled();

  /// Opens the system Wi-Fi settings panel and returns whether Wi-Fi is now on.
  Future<bool> requestWifiEnable();

  /// Whether required runtime permissions are granted.
  Future<bool> checkPermissions();

  /// Requests required runtime permissions.
  Future<bool> requestPermissions();

  /// Opens this app's system settings page, for when a permission was
  /// permanently denied and must be granted manually.
  Future<void> openAppSettings();

  /// Posts a local notification that a message addressed to this device
  /// arrived. Called only for an inbound message that decrypted to the local
  /// identity, so it can never notify someone else's message.
  Future<void> notifyMessage({required String title, required String body});

  /// Requests the OS notification permission (Android 13+). Returns whether
  /// notifications may be posted.
  Future<bool> requestNotificationPermission();

  /// Whether a Wi-Fi hotspot (SoftAP) is currently running. A running hotspot
  /// commonly blocks Wi-Fi Direct on the same radio.
  Future<bool> isHotspotEnabled();

  /// Opens the system hotspot/tethering settings so the user can turn it off.
  Future<void> openHotspotSettings();

  Future<void> dispose();
}

/// [PlatformTransportGateway] backed by a `MethodChannel` + `EventChannel`.
class MethodChannelPlatformTransportGateway
    implements PlatformTransportGateway {
  MethodChannelPlatformTransportGateway({
    MethodChannel? channel,
    EventChannel? eventChannel,
  }) : _channel = channel ?? const MethodChannel(PlatformChannelNames.channel),
       _events =
           eventChannel ?? const EventChannel(PlatformChannelNames.events);

  final MethodChannel _channel;
  final EventChannel _events;

  @override
  Future<Map<String, Object?>> start({
    required int dataPort,
    required String handle,
  }) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      PlatformMethodNames.start,
      <String, Object?>{
        PlatformPayloadKeys.dataPort: dataPort,
        PlatformPayloadKeys.handle: handle,
      },
    );
    return _asStringMap(result);
  }

  @override
  Future<void> stop() async {
    await _channel.invokeMethod<void>(PlatformMethodNames.stop);
  }

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required bool discoverable,
  }) async {
    await _channel.invokeMethod<void>(
      PlatformMethodNames.updateAdvertisement,
      <String, Object?>{
        PlatformPayloadKeys.displayNameHint: displayNameHint,
        PlatformPayloadKeys.discoverable: discoverable,
      },
    );
  }

  @override
  Future<Map<String, Object?>> connect({required String handle}) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      PlatformMethodNames.connect,
      <String, Object?>{PlatformPayloadKeys.handle: handle},
    );
    return _asStringMap(result);
  }

  @override
  Stream<Map<String, Object?>> get events => _events
      .receiveBroadcastStream()
      .where((raw) => raw is Map)
      .map((raw) => _asStringMap(raw));

  @override
  Future<bool> isWifiEnabled() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      PlatformMethodNames.isWifiEnabled,
    );
    return (result?['enabled'] as bool?) ?? false;
  }

  @override
  Future<bool> requestWifiEnable() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      PlatformMethodNames.requestWifiEnable,
    );
    return (result?['enabled'] as bool?) ?? false;
  }

  @override
  Future<bool> checkPermissions() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      PlatformMethodNames.checkPermissions,
    );
    return (result?['granted'] as bool?) ?? false;
  }

  @override
  Future<bool> requestPermissions() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      PlatformMethodNames.requestPermissions,
    );
    return (result?['granted'] as bool?) ?? false;
  }

  @override
  Future<void> openAppSettings() async {
    await _channel.invokeMethod<void>(PlatformMethodNames.openAppSettings);
  }

  @override
  Future<void> notifyMessage({
    required String title,
    required String body,
  }) async {
    await _channel.invokeMethod<void>(PlatformMethodNames.notifyMessage, {
      PlatformPayloadKeys.title: title,
      PlatformPayloadKeys.body: body,
    });
  }

  @override
  Future<bool> requestNotificationPermission() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      PlatformMethodNames.requestNotificationPermission,
    );
    return (result?['granted'] as bool?) ?? false;
  }

  @override
  Future<bool> isHotspotEnabled() async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      PlatformMethodNames.isHotspotEnabled,
    );
    return (result?['enabled'] as bool?) ?? false;
  }

  @override
  Future<void> openHotspotSettings() async {
    await _channel.invokeMethod<void>(PlatformMethodNames.openHotspotSettings);
  }

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod<void>(PlatformMethodNames.dispose);
  }

  static Map<String, Object?> _asStringMap(Object? value) {
    if (value == null) return const <String, Object?>{};
    if (value is! Map) {
      throw const TransportException(
        'Platform transport returned non-map data',
      );
    }
    return <String, Object?>{
      for (final entry in value.entries) '${entry.key}': entry.value,
    };
  }
}

/// A [Transport] that bridges to the native platform transport plugin.
///
/// The native side (see `platform_transport_contract.dart`) only establishes
/// connectivity and reports opaque discovery + reachability data; every byte
/// of protocol (identity handshake, summaries, bundle transfer) travels here in
/// Dart over a plain TCP data channel.
///
/// When the native side is missing or reports an unsupported fabric,
/// [start] throws [TransportException] and all capabilities read as
/// unavailable. Connectivity is never faked.
class PlatformTransport implements Transport {
  PlatformTransport({
    required this.gateway,
    String? localId,
    this.connectTimeout = const Duration(seconds: 15),
    this.maxFrameBytes = 32 * 1024 * 1024,
  }) : localId = localId ?? _randomHandle();

  @override
  final String localId;

  final PlatformTransportGateway gateway;
  final Duration connectTimeout;
  final int maxFrameBytes;

  final StreamController<TransportPeer> _discovered =
      StreamController<TransportPeer>.broadcast();
  final StreamController<String> _lost = StreamController<String>.broadcast();
  final StreamController<TransportConnection> _incoming =
      StreamController<TransportConnection>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();

  final Map<String, _PeerEndpoint> _endpoints = <String, _PeerEndpoint>{};
  final Map<String, _PlatformConnection> _connections =
      <String, _PlatformConnection>{};

  /// Handles for which a client-side dial is currently in flight.
  final Set<String> _dialing = <String>{};

  ServerSocket? _server;
  StreamSubscription<Map<String, Object?>>? _eventSub;
  bool _running = false;
  bool _discoverable = false;
  bool _supportsBackground = false;
  String? _displayHint;
  String? _fabric;

  @override
  String get id => 'platform';

  @override
  String get name => 'Local Wi-Fi (native)';

  @override
  bool get isRunning => _running;

  @override
  List<TransportPeer> get knownPeers => [
    for (final endpoint in _endpoints.values)
      TransportPeer(
        peerId: endpoint.handle,
        discoveredAtMs: endpoint.discoveredAtMs,
        displayNameHint: endpoint.displayNameHint,
        rssi: endpoint.rssi,
      ),
  ];

  @override
  TransportCapabilities get capabilities {
    final fabric = _fabric;
    if (fabric == null) return TransportCapabilities.unavailable;
    return TransportCapabilities(
      canDiscover: true,
      canConnect: true,
      supportsResumableTransfer: false,
      isSimulated: false,
      supportsBackground: _supportsBackground,
      description:
          'Native Wi-Fi Direct transport. Both devices need Wi-Fi on, the '
          'Nearby devices permission granted, and must be within range.',
    );
  }

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
    if (_running) return;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    server.listen(_onAccepted, onError: (Object error) => _emitError(error));

    Map<String, Object?> result;
    try {
      result = await gateway.start(dataPort: server.port, handle: localId);
    } catch (error) {
      await _closeServer();
      throw TransportException(
        'Native transport is unavailable: $error',
        cause: error,
      );
    }
    final fabric = result[PlatformPayloadKeys.fabric] as String?;
    if (fabric == null || fabric.isEmpty) {
      await _closeServer();
      throw const TransportException(
        'Native transport did not report a usable fabric',
      );
    }
    _fabric = fabric;
    _supportsBackground =
        result[PlatformPayloadKeys.supportsBackground] as bool? ?? false;
    _running = true;
    _eventSub = gateway.events.listen(
      _onPlatformEvent,
      onError: (Object error) => _emitError(error),
    );
    // Re-publish the advertisement that routing issued before start() ran.
    if (_displayHint != null) {
      try {
        await gateway.updateAdvertisement(
          displayNameHint: _displayHint!,
          discoverable: _discoverable,
        );
      } catch (error) {
        _emitError(
          TransportException('Failed to publish advertisement', cause: error),
        );
      }
    }
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _eventSub?.cancel();
    _eventSub = null;
    for (final connection in [..._connections.values]) {
      await connection.close();
    }
    _connections.clear();
    final gone = _endpoints.keys.toList();
    _endpoints.clear();
    for (final handle in gone) {
      if (!_lost.isClosed) _lost.add(handle);
    }
    await _closeServer();
    await gateway.stop();
  }

  @override
  Future<void> updateAdvertisement({
    required String displayNameHint,
    required IdentityRecord identity,
    required bool discoverable,
  }) async {
    // [identity] is deliberately ignored: the native layer never learns the
    // permanent identity id. Advertisements carry only a rotating handle and
    // an optional display hint.
    _displayHint = displayNameHint;
    _discoverable = discoverable;
    if (!_running) return;
    await gateway.updateAdvertisement(
      displayNameHint: displayNameHint,
      discoverable: discoverable,
    );
  }

  @override
  Future<TransportConnection> connect(String peerId) async {
    if (!_running) {
      throw const TransportException('Transport is not running');
    }
    final existing = _connections[peerId];
    if (existing != null && existing.isOpen) return existing;

    Map<String, Object?> endpoint;
    try {
      endpoint = await gateway.connect(handle: peerId);
    } catch (error) {
      throw TransportException(
        'Native connect failed for $peerId',
        cause: error,
      );
    }
    final host = endpoint[PlatformPayloadKeys.host] as String?;
    final port = endpoint[PlatformPayloadKeys.port] as int?;
    if (host == null || host.isEmpty || port == null || port <= 0) {
      throw const TransportException(
        'Native transport returned no reachable endpoint for the peer',
      );
    }
    final socket = await Socket.connect(host, port, timeout: connectTimeout);
    return _makeConnection(socket, peerId);
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _discovered.close();
    await _lost.close();
    await _incoming.close();
    await _errors.close();
    await gateway.dispose();
  }

  void _onAccepted(Socket socket) {
    if (!_running) {
      socket.destroy();
      return;
    }
    final peerId = '${socket.remoteAddress.address}:${socket.remotePort}';
    final connection = _makeConnection(socket, peerId);
    if (!_incoming.isClosed) _incoming.add(connection);
  }

  _PlatformConnection _makeConnection(Socket socket, String peerId) {
    final connection = _PlatformConnection(
      socket,
      peerId,
      maxFrameBytes: maxFrameBytes,
    );
    connection.onClosed = () => _handleConnectionClosed(peerId);
    _connections[peerId] = connection;
    return connection;
  }

  void _handleConnectionClosed(String peerId) {
    _connections.remove(peerId);
  }

  void _onPlatformEvent(Map<String, Object?> event) {
    final type = event[PlatformPayloadKeys.event] as String?;
    switch (type) {
      case PlatformEventNames.peerFound:
        _handlePeerFound(event);
      case PlatformEventNames.peerLost:
        _handlePeerLost(event);
      case PlatformEventNames.peerReachable:
        _handlePeerReachable(event);
      case PlatformEventNames.error:
        _emitError(
          TransportException(
            event[PlatformPayloadKeys.message] as String? ??
                'Native transport reported an error',
          ),
        );
      default:
        _emitError(TransportException('Unknown native event: $type'));
    }
  }

  void _handlePeerFound(Map<String, Object?> event) {
    final handle = event[PlatformPayloadKeys.handle] as String?;
    if (handle == null || handle.isEmpty) return;
    final displayHint = event[PlatformPayloadKeys.displayNameHint] as String?;
    final rssi = event[PlatformPayloadKeys.rssi] as int?;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = _endpoints[handle];
    final discoveredAtMs = existing?.discoveredAtMs ?? now;
    _endpoints[handle] = _PeerEndpoint(
      handle: handle,
      discoveredAtMs: discoveredAtMs,
      displayNameHint: displayHint,
      rssi: rssi,
    );
    if (existing == null && !_discovered.isClosed) {
      _discovered.add(
        TransportPeer(
          peerId: handle,
          discoveredAtMs: discoveredAtMs,
          displayNameHint: displayHint,
          rssi: rssi,
        ),
      );
    }
  }

  void _handlePeerLost(Map<String, Object?> event) {
    final handle = event[PlatformPayloadKeys.handle] as String?;
    if (handle == null) return;
    if (_endpoints.remove(handle) == null) return;
    if (!_lost.isClosed) _lost.add(handle);
  }

  /// Native reports that this device joined a Wi-Fi Direct group as the client
  /// and the peer (the group owner) is reachable. Only the client can learn the
  /// owner's address, so the client always opens the datapath.
  void _handlePeerReachable(Map<String, Object?> event) {
    final handle = event[PlatformPayloadKeys.handle] as String?;
    final host = event[PlatformPayloadKeys.host] as String?;
    final port = event[PlatformPayloadKeys.port] as int?;
    if (handle == null || handle.isEmpty) return;
    if (host == null || host.isEmpty || port == null || port <= 0) return;
    if (!_running) return;
    final existing = _connections[handle];
    if (existing != null && existing.isOpen) return;
    if (!_dialing.add(handle)) return;
    unawaited(_dialReachable(handle, host, port));
  }

  Future<void> _dialReachable(String handle, String host, int port) async {
    try {
      final socket = await Socket.connect(host, port, timeout: connectTimeout);
      if (!_running) {
        socket.destroy();
        return;
      }
      final connection = _makeConnection(socket, handle);
      if (!_incoming.isClosed) _incoming.add(connection);
    } catch (_) {
      // The peer is gone or not listening yet. Discovery surfaces it again, and
      // the routing engine keeps retrying while the peer is known.
    } finally {
      _dialing.remove(handle);
    }
  }

  void _emitError(Object error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  Future<void> _closeServer() async {
    final server = _server;
    _server = null;
    if (server != null) {
      try {
        await server.close();
      } catch (_) {
        // Best-effort shutdown.
      }
    }
  }

  static String _randomHandle() {
    final random = Random.secure();
    final bytes = List<int>.generate(8, (_) => random.nextInt(256));
    // Deliberately unpadded. The handle travels to the peer twice: once as the
    // DNS-SD instance name and once as the "h" TXT value, and Android strips
    // base64 padding from TXT values but not from instance names. Padding would
    // therefore make the same peer look like two different devices (two
    // sessions, a duplicate "Connected" row) and break the deterministic
    // tie-break that decides which side dials.
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}

class _PeerEndpoint {
  const _PeerEndpoint({
    required this.handle,
    required this.discoveredAtMs,
    this.displayNameHint,
    this.rssi,
  });

  final String handle;
  final int discoveredAtMs;
  final String? displayNameHint;
  final int? rssi;
}

/// One end of a live platform transport connection: a TCP socket framed with
/// [FrameStream] plus the post-connect protocol implemented in Dart.
class _PlatformConnection implements TransportConnection {
  _PlatformConnection(this._socket, this.peerId, {required int maxFrameBytes}) {
    _frameStream = FrameStream(_socket, maxFrameBytes: maxFrameBytes);
    _frameSub = _frameStream.frames.listen(
      _onFrame,
      onError: (Object error) => _onTransportError(error),
      onDone: _onRemoteClosed,
    );
    _errorSub = _frameStream.errors.listen(_onTransportError);
  }

  final Socket _socket;

  @override
  final String peerId;

  late final FrameStream _frameStream;
  late final StreamSubscription<InboundFrame> _frameSub;
  late final StreamSubscription<Object> _errorSub;

  final StreamController<Uint8List> _bundles = StreamController<Uint8List>();
  final StreamController<PeerSummary> _summaries =
      StreamController<PeerSummary>();
  final StreamController<Object> _errors = StreamController<Object>();

  final List<PeerHandshakeRequest> _handshakeBuffer = <PeerHandshakeRequest>[];
  final List<Completer<PeerHandshakeRequest>> _handshakeWaiters =
      <Completer<PeerHandshakeRequest>>[];

  bool _open = true;
  void Function()? onClosed;

  @override
  Stream<Uint8List> get bundles => _bundles.stream;

  @override
  Stream<PeerSummary> get summaries => _summaries.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  bool get isOpen => _open && _frameStream.isOpen;

  @override
  Future<PeerHandshakeResult> handshake(PeerHandshakeRequest request) async {
    _ensureOpen();
    try {
      await _frameStream.send(
        frameTypeHandshake,
        encodeHandshakePayload(request),
      );
    } catch (error) {
      throw TransportException('Handshake send failed', cause: error);
    }
    final remote = await _awaitHandshake();
    return PeerHandshakeResult(
      identity: remote.identity,
      capabilities: remote.capabilities,
    );
  }

  @override
  Future<void> sendSummary(PeerSummary summary) async {
    _ensureOpen();
    try {
      await _frameStream.send(frameTypeSummary, encodeSummaryPayload(summary));
    } catch (error) {
      throw TransportException('Summary send failed', cause: error);
    }
  }

  @override
  Future<void> sendBundles(List<Uint8List> bundles) async {
    _ensureOpen();
    try {
      for (final bytes in bundles) {
        await _frameStream.send(frameTypeBundle, bytes);
      }
    } catch (error) {
      throw TransportException('Bundle transfer failed', cause: error);
    }
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _failWaiters();
    await _frameSub.cancel();
    await _errorSub.cancel();
    unawaited(_bundles.close());
    unawaited(_summaries.close());
    unawaited(_errors.close());
    await _frameStream.close();
  }

  void _onFrame(InboundFrame frame) {
    if (!_open) return;
    try {
      switch (frame.type) {
        case frameTypeHandshake:
          _onHandshake(decodeHandshakePayload(frame.payload));
          break;
        case frameTypeSummary:
          if (!_summaries.isClosed) {
            _summaries.add(decodeSummaryPayload(frame.payload));
          }
          break;
        case frameTypeBundle:
          if (!_bundles.isClosed) _bundles.add(frame.payload);
          break;
        default:
          _fail(TransportException('Unknown frame type ${frame.type}'));
      }
    } catch (_) {
      // A decode failure is a transport-level error, never surfaced as content.
      _fail(const TransportException('Malformed frame payload'));
    }
  }

  void _onHandshake(PeerHandshakeRequest request) {
    if (_handshakeWaiters.isNotEmpty) {
      final waiter = _handshakeWaiters.removeAt(0);
      if (!waiter.isCompleted) waiter.complete(request);
    } else {
      _handshakeBuffer.add(request);
    }
  }

  Future<PeerHandshakeRequest> _awaitHandshake() {
    if (_handshakeBuffer.isNotEmpty) {
      return Future<PeerHandshakeRequest>.value(_handshakeBuffer.removeAt(0));
    }
    if (!_open) {
      return Future<PeerHandshakeRequest>.error(
        const TransportException('Connection closed before handshake'),
      );
    }
    final completer = Completer<PeerHandshakeRequest>();
    _handshakeWaiters.add(completer);
    return completer.future;
  }

  void _onRemoteClosed() {
    if (!_open) return;
    _open = false;
    _failWaiters();
    unawaited(_bundles.close());
    unawaited(_summaries.close());
    unawaited(_errors.close());
    onClosed?.call();
  }

  void _onTransportError(Object error) {
    if (!_errors.isClosed) _errors.add(error);
  }

  void _fail(Object error) {
    _onTransportError(error);
    unawaited(close());
  }

  void _failWaiters() {
    for (final waiter in _handshakeWaiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(const TransportException('Connection closed'));
      }
    }
    _handshakeWaiters.clear();
  }

  void _ensureOpen() {
    if (!_open || !_frameStream.isOpen) {
      throw const TransportException('Connection is closed');
    }
  }
}
