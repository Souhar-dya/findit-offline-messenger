import 'dart:async';
import 'dart:typed_data';

import '../core/config/app_config.dart';
import '../core/errors/app_exception.dart';
import '../core/protocol/envelope.dart';
import '../core/settings/settings_service.dart';
import '../core/utils/bytes.dart';
import '../core/utils/clock.dart';
import '../crypto/identity_holder.dart';
import '../crypto/identity_record.dart';
import '../domain/entities/known_identity.dart';
import '../domain/entities/peer_summary.dart';
import '../domain/entities/stored_bundle.dart';
import '../domain/repositories/bundle_repository.dart';
import '../domain/repositories/identity_repository.dart';
import '../friends/friend_service.dart';
import '../messaging/bundle_outbox.dart';
import '../messaging/message_service.dart';
import '../messaging/receipt_service.dart';
import '../messaging/retention_service.dart';
import '../messaging/signed_bundle.dart';
import '../transport/transport.dart';

/// A peer we currently have an open transport session with.
class PeerSessionInfo {
  const PeerSessionInfo({
    required this.transportPeerId,
    required this.identityId,
    required this.displayName,
    required this.handshaken,
  });

  final String transportPeerId;
  final String? identityId;
  final String? displayName;
  final bool handshaken;
}

/// The store-carry-forward routing engine.
///
/// It is transport-independent: it only uses the [Transport] abstraction. There
/// is no central server and no fixed hop limit; forwarding is bounded by the
/// remaining message TTL and by replication / storage budgets.
class RoutingEngine {
  RoutingEngine({
    required Transport transport,
    required BundleCodec codec,
    required BundleRepository bundles,
    required BundleOutbox outbox,
    required MessageService messages,
    required FriendService friends,
    required ReceiptService receipts,
    required RetentionService retention,
    required IdentityRepository identities,
    required IdentityHolder identityHolder,
    required SettingsService settings,
    required Clock clock,
    required AppConfig config,
    this.autoConnect = true,
  }) : _transport = transport,
       _codec = codec,
       _bundles = bundles,
       _outbox = outbox,
       _messages = messages,
       _friends = friends,
       _receipts = receipts,
       _retention = retention,
       _identities = identities,
       _identityHolder = identityHolder,
       _settings = settings,
       _clock = clock,
       _config = config;

  final Transport _transport;
  final BundleCodec _codec;
  final BundleRepository _bundles;
  final BundleOutbox _outbox;
  final MessageService _messages;
  final FriendService _friends;
  final ReceiptService _receipts;
  final RetentionService _retention;
  final IdentityRepository _identities;
  final IdentityHolder _identityHolder;
  final SettingsService _settings;
  final Clock _clock;
  final AppConfig _config;

  /// Whether to automatically connect to discovered peers (used by the demo).
  final bool autoConnect;

  /// Serialized forwarding queue. Concurrent flush triggers (an enqueue event
  /// can arrive while a flush is running) are chained so they never interleave,
  /// and [stop] can await the tail before the database is closed.
  Future<void> _flushQueue = Future<void>.value();

  /// Serialized ingest queue, so received bundles are processed one at a time
  /// and [stop] can settle any in-flight handler.
  Future<void> _ingestQueue = Future<void>.value();

  final Map<String, _Session> _sessions = <String, _Session>{};
  final Set<String> _connecting = <String>{};
  final StreamController<List<PeerSessionInfo>> _peerChanges =
      StreamController<List<PeerSessionInfo>>.broadcast();

  StreamSubscription<TransportPeer>? _discoverySub;
  StreamSubscription<String>? _lostSub;
  StreamSubscription<String>? _blockedSub;
  StreamSubscription<TransportConnection>? _incomingSub;
  StreamSubscription<Object>? _errorSub;
  StreamSubscription<StoredBundle>? _enqueueSub;

  bool _started = false;
  Timer? _reconcileTimer;

  /// Snapshot of currently connected sessions, for the Nearby screen.
  List<PeerSessionInfo> get peers => [
    for (final session in _sessions.values)
      PeerSessionInfo(
        transportPeerId: session.connection.peerId,
        identityId: session.identityId,
        displayName: session.displayName,
        handshaken: session.identityId != null,
      ),
  ];

  /// Emits whenever the set of connected peers changes.
  Stream<List<PeerSessionInfo>> get peerChanges => _peerChanges.stream;

  bool get isRunning => _started;

  /// Starts discovery, advertisement and inbound handling.
  Future<void> start() async {
    if (_started) return;
    final identity = _identityHolder.requireIdentity;
    await _transport.updateAdvertisement(
      displayNameHint: identity.displayName,
      identity: identity.record,
      discoverable: true,
    );
    _discoverySub = _transport.discoveredPeers.listen(_onPeerDiscovered);
    _lostSub = _transport.lostPeers.listen(_onPeerLost);
    _blockedSub = _friends.blockedIdentityChanges.listen(_onIdentityBlocked);
    _incomingSub = _transport.incomingConnections.listen(_accept);
    _errorSub = _transport.errors.listen((_) {});
    _enqueueSub = _outbox.enqueued.listen((_) => flush());
    try {
      await _transport.start();
    } catch (_) {
      // A failed start (e.g. Wi-Fi turned off mid-launch) must not leave
      // half-wired listeners behind: a later retry would otherwise subscribe
      // again and handle every discovery twice.
      await _cancelSubscriptions();
      rethrow;
    }
    _started = true;
    _startReconcile();
    _emitPeers();
  }

  Future<void> stop() async {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    await _cancelSubscriptions();
    for (final session in [..._sessions.values]) {
      await session.dispose();
    }
    _sessions.clear();
    _connecting.clear();
    // Settle handler work that was already in flight. Ingest can spawn flushes,
    // so drain ingest first, then forwarding, before anything is closed.
    await _swallow(_ingestQueue);
    await _swallow(_flushQueue);
    if (_started) await _transport.stop();
    _started = false;
    _emitPeers();
  }

  Future<void> _cancelSubscriptions() async {
    await _discoverySub?.cancel();
    await _lostSub?.cancel();
    await _blockedSub?.cancel();
    await _incomingSub?.cancel();
    await _errorSub?.cancel();
    await _enqueueSub?.cancel();
    _discoverySub = null;
    _lostSub = null;
    _blockedSub = null;
    _incomingSub = null;
    _errorSub = null;
    _enqueueSub = null;
  }

  /// Retries dialing known peers that are not connected. A one-shot discovery
  /// event is not enough: a dial can fail (the peer was not listening yet, the
  /// group formed before both sides were ready) and without a retry the two
  /// devices would stay silently unconnected for the rest of the session. Keep
  /// the interval short so a peer that was discovered a moment too early is not
  /// stuck unconnected for long; concurrent dials to one handle are already
  /// guarded, so this cannot pile up.
  void _startReconcile() {
    _reconcileTimer ??= Timer.periodic(
      const Duration(seconds: 8),
      (_) => _reconcile(),
    );
  }

  Future<void> _reconcile() async {
    if (!_started || !_settings.networkingEnabled) return;
    for (final peer in _transport.knownPeers) {
      if (_sessions.containsKey(peer.peerId)) continue;
      if (_connecting.contains(peer.peerId)) continue;
      if (!_shouldInitiate(peer.peerId)) continue;
      unawaited(connectTo(peer.peerId));
    }
  }

  /// Opens a connection to a discovered peer handle.
  Future<void> connectTo(String transportPeerId) async {
    if (_connecting.contains(transportPeerId)) return;
    if (_sessions.containsKey(transportPeerId)) return;
    _connecting.add(transportPeerId);
    try {
      final connection = await _transport.connect(transportPeerId);
      await _runSession(connection, incoming: false);
    } on TransportException {
      // Peer disappeared; discovery will resurface it if it returns.
    } finally {
      _connecting.remove(transportPeerId);
    }
  }

  void _onPeerDiscovered(TransportPeer peer) {
    if (!autoConnect) return;
    if (!_shouldInitiate(peer.peerId)) return;
    unawaited(connectTo(peer.peerId));
  }

  void _onPeerLost(String transportPeerId) {
    _connecting.remove(transportPeerId);
    final session = _sessions.remove(transportPeerId);
    if (session == null) return;
    unawaited(session.dispose());
    _emitPeers();
  }

  void _onIdentityBlocked(String identityId) {
    final blockedSessions = _sessions.values
        .where((session) => session.identityId == identityId)
        .toList();
    for (final session in blockedSessions) {
      _sessions.remove(session.connection.peerId);
      unawaited(session.dispose());
    }
    if (blockedSessions.isNotEmpty) _emitPeers();
  }

  /// Deterministic tie-break so two peers never both initiate a connection to
  /// each other. This only orders ephemeral transport handles; it has no
  /// security meaning. [Transport.localIdFor] keeps it correct when one side
  /// runs several radios at once.
  bool _shouldInitiate(String peerHandle) =>
      _transport.localIdFor(peerHandle).compareTo(peerHandle) < 0;

  void _accept(TransportConnection connection) {
    unawaited(_runSession(connection, incoming: true));
  }

  Future<void> _runSession(
    TransportConnection connection, {
    required bool incoming,
  }) async {
    if (_sessions.containsKey(connection.peerId)) {
      // A second connection for a handle we already hold (a repeated dial). Close
      // it instead of leaking a socket that nothing would ever read from.
      await connection.close();
      return;
    }
    final session = _Session(connection);
    _sessions[connection.peerId] = session;

    session.bundleSub = connection.bundles.listen(
      (bytes) => _enqueueIngest(bytes, session),
      onError: (_) {},
      onDone: () => _dropSession(session),
    );
    session.summarySub = connection.summaries.listen((summary) {
      session.peerSummaries = summary.bundleIds;
    }, onError: (_) {});
    session.errorSub = connection.errors.listen((_) {});
    _emitPeers();

    try {
      final identity = _identityHolder.requireIdentity;
      final result = await connection
          .handshake(
            PeerHandshakeRequest(
              identity: identity.record,
              capabilities: const [
                TransportCapabilitiesKeys.cborEnvelopes,
                TransportCapabilitiesKeys.resumableTransfer,
              ],
            ),
          )
          .timeout(const Duration(seconds: 10));
      if (!await result.identity.verify()) {
        throw const CryptoException(
          'Peer presented an invalid identity record',
        );
      }
      if (await _friends.isBlocked(result.identity.identityId)) {
        throw const StateTransitionException('This peer is blocked');
      }
      session.identityId = result.identity.identityId;
      session.displayName = result.identity.displayName;
      // One peer, one session. The same device can be reached over two sockets:
      // the Wi-Fi Direct group owner keys an inbound socket by ip:port while the
      // client keys its outbound socket by the rotating handle, and a
      // re-discovery can dial again while a session is still live. The completed
      // handshake proves both sockets are the same person, so keep the session we
      // already had and drop the spare: "Connected" must never list a peer twice.
      final existing = _otherSessionWithIdentity(session, result.identity.identityId);
      if (existing != null) {
        // A restarted app advertises a fresh transport handle while an old TCP
        // session can remain half-open. Prefer the session that just completed
        // a valid handshake, and close the old one so the same identity cannot
        // stay represented by two transport connections.
        _sessions.remove(existing.connection.peerId);
        await existing.dispose();
      }
      await _rememberPeer(result.identity);
      await connection.sendSummary(await _buildSummary());
      await _forwardTo(session);
      _emitPeers();
    } catch (_) {
      await session.dispose();
      _sessions.remove(connection.peerId);
      _emitPeers();
    }
  }

  Future<void> _rememberPeer(IdentityRecord record) async {
    final existing = await _identities.find(record.identityId);
    final verifiedAt = existing?.verifiedAtMs;
    await _identities.upsert(
      KnownIdentity(
        record: record,
        isLocal: false,
        firstSeenMs:
            existing?.firstSeenMs ?? _clock.now().millisecondsSinceEpoch,
        lastSeenMs: _clock.now().millisecondsSinceEpoch,
        verifiedAtMs: verifiedAt,
      ),
    );
  }

  /// Forwards every eligible queued bundle to every open session.
  ///
  /// Triggers are serialized through [_flushQueue] so a flush never runs
  /// concurrently with itself and the result can be awaited during shutdown.
  Future<void> flush() {
    final run = _swallow(_flushQueue).then((_) => _flushNow());
    _flushQueue = _swallow(run);
    return run;
  }

  Future<void> _flushNow() async {
    for (final session in [..._sessions.values]) {
      await _forwardTo(session);
    }
  }

  /// Runs [future] and swallows its error so queue runners never poison the
  /// chain; the error is still delivered to the caller of the successive
  /// future returned by [flush].
  Future<void> _swallow(Future<void> future) async {
    try {
      await future;
    } catch (_) {
      // Errors surface to the caller of the enclosing operation; the queue
      // itself must stay healthy so the next trigger runs.
    }
  }

  Future<void> _forwardTo(_Session session) async {
    try {
      final identityId = session.identityId;
      if (identityId == null || !session.connection.isOpen) return;
      // Radio silent: while networking is off nothing is handed to anyone, not
      // even bundles this device originated.
      if (!_settings.networkingEnabled) return;
      final now = _clock.now().millisecondsSinceEpoch;
      final candidates = await _bundles.claimForwardable(
        nowMs: now,
        replicationBudget: _config.replicationBudget,
        peerId: identityId,
        limit: 32,
      );
      final toSend = <StoredBundle>[];
      for (final bundle in candidates) {
        if (bundle.sourcePeerId == identityId) continue;
        if (session.peerSummaries.contains(bundle.bundleIdHex)) continue;
        toSend.add(bundle);
      }
      if (toSend.isEmpty) return;
      try {
        await session.connection.sendBundles(
          toSend.map((b) => b.bytes).toList(),
        );
      } on TransportException {
        // The hand-off failed. Do NOT record a forward: a failed connection is
        // not a successful forward, so the bundle stays queued for a retry.
        return;
      } catch (_) {
        // Any other transport-level failure is treated the same way.
        return;
      }
      for (final bundle in toSend) {
        try {
          await _bundles.recordForwarded(
            bundle.bundleIdHex,
            identityId,
            now,
            replicationBudget: _config.replicationBudget,
          );
          if (bundle.type == EnvelopeType.message) {
            await _messages.markRelayed(bundle.bundleIdHex);
          }
        } catch (_) {
          // Best-effort bookkeeping: the bytes already left this node. If the
          // write fails (e.g. shutdown mid-flight) the bundle is still queued
          // and redelivery is idempotent for the receiver.
        }
      }
    } catch (_) {
      // A storage failure must not crash forwarding; the bundle stays queued
      // for the next flush.
    }
  }

  /// Queues [bytes] for processing on the serialized ingest queue.
  void _enqueueIngest(Uint8List bytes, _Session session) {
    final run = _swallow(_ingestQueue).then((_) => _ingest(bytes, session));
    _ingestQueue = _swallow(run);
  }

  /// Handles one received bundle. This is a fire-and-forget path: every failure
  /// is dropped silently (never surfaced as content), so the queue runner can
  /// never throw.
  Future<void> _ingest(Uint8List bytes, _Session session) async {
    try {
      if (bytes.length > _config.maxEnvelopeBytes) return;
      final me = _identityHolder.identity;
      if (me == null) return;
      // Radio silent: while networking is off this device accepts nothing — not
      // even messages addressed to it.
      if (!_settings.networkingEnabled) return;
      final connectedIdentity = session.identityId;
      if (connectedIdentity != null &&
          await _friends.isBlocked(connectedIdentity)) {
        return;
      }

      final Envelope envelope;
      try {
        envelope = Envelope.decode(bytes);
      } catch (_) {
        return; // Malformed bytes are dropped, never surfaced as content.
      }
      final now = _clock.now().millisecondsSinceEpoch;
      if (now >= envelope.expiresAtMs) return;

      final bundleIdHex = bytesToHex(envelope.bundleId);
      if (await _bundles.hasTombstone(bundleIdHex)) return;

      if (envelope.recipientId == me.identityId) {
        // Addressed to us: decrypt + dispatch. It is not stored for relaying.
      try {
        final opened = await _codec.open(recipient: me, envelope: envelope);
        if ((opened.type == EnvelopeType.message ||
                opened.type == EnvelopeType.deliveryReceipt ||
                opened.type == EnvelopeType.retentionRequest ||
                opened.type == EnvelopeType.retentionResponse ||
                opened.type == EnvelopeType.retentionCommit ||
                opened.type == EnvelopeType.retentionCommitAck ||
                opened.type == EnvelopeType.retentionActivate ||
                opened.type == EnvelopeType.retentionActivateAck) &&
            !await _friends.canExchangeMessages(opened.sender.identityId)) {
          return;
        }
        await _dispatch(opened);
        } on ExpiredException {
          return;
        } on AppException {
          return;
        } catch (_) {
          return;
        }
        return;
      }

      // Elsewhere-bound: store-carry-forward, subject to the storage quota.
      if (await _withinQuota(bytes.length)) {
        await _outbox.storeReceived(
          bundleId: envelope.bundleId,
          type: envelope.type,
          recipientId: envelope.recipientId,
          expiresAtMs: envelope.expiresAtMs,
          bytes: bytes,
          sourcePeerId: session.identityId ?? session.connection.peerId,
        );
        unawaited(flush());
      }
    } catch (_) {
      // A storage failure (e.g. shutdown while the database is closing) drops
      // this bundle; it is never marked complete or delivered.
    }
  }

  Future<bool> _withinQuota(int incomingBytes) async {
    var total = await _bundles.totalBytes();
    if (total + incomingBytes > _config.defaultStorageQuotaBytes) {
      await _bundles.expireBundles(
        _clock.now().millisecondsSinceEpoch,
        _clock.now().millisecondsSinceEpoch +
            _config.tombstoneRetention.inMilliseconds,
      );
      total = await _bundles.totalBytes();
    }
    return total + incomingBytes <= _config.defaultStorageQuotaBytes;
  }

  Future<void> _dispatch(OpenedBundle opened) async {
    switch (opened.type) {
      case EnvelopeType.message:
        await _messages.handleIncoming(opened);
      case EnvelopeType.deliveryReceipt:
        await _receipts.handleIncoming(opened);
      case EnvelopeType.friendRequest:
      case EnvelopeType.friendAccept:
      case EnvelopeType.friendConfirm:
      case EnvelopeType.friendDecline:
        await _friends.handleIncoming(opened);
      case EnvelopeType.retentionRequest:
      case EnvelopeType.retentionResponse:
      case EnvelopeType.retentionCommit:
      case EnvelopeType.retentionCommitAck:
      case EnvelopeType.retentionActivate:
      case EnvelopeType.retentionActivateAck:
        await _retention.handleIncoming(opened);
    }
  }

  Future<PeerSummary> _buildSummary() async {
    final me = _identityHolder.requireIdentity;
    final now = _clock.now().millisecondsSinceEpoch;
    // Radio silent: while networking is off this device advertises nothing and
    // asks for nothing, so no bundle ever moves through it.
    if (!_settings.networkingEnabled) {
      return PeerSummary(
        identityId: me.identityId,
        generatedAtMs: now,
        entries: const <PeerSummaryEntry>[],
      );
    }
    final forwardable = await _bundles.claimForwardable(
      nowMs: now,
      replicationBudget: _config.replicationBudget,
      limit: 64,
    );
    return PeerSummary(
      identityId: me.identityId,
      generatedAtMs: now,
      entries: [
        for (final bundle in forwardable)
          PeerSummaryEntry(
            bundleIdHex: bundle.bundleIdHex,
            expiresAtMs: bundle.expiresAtMs,
          ),
      ],
    );
  }

  void _emitPeers() {
    if (!_peerChanges.isClosed) _peerChanges.add(peers);
  }

  void _dropSession(_Session session) {
    if (_sessions.remove(session.connection.peerId) != null) {
      _emitPeers();
    }
  }

  /// Another live session that has already proven the same permanent identity as
  /// [session]. Used to replace stale sockets after a peer restarts.
  _Session? _otherSessionWithIdentity(_Session session, String identityId) {
    for (final other in _sessions.values) {
      if (identical(other, session)) continue;
      if (other.identityId == identityId && other.connection.isOpen) return other;
    }
    return null;
  }

  Future<void> dispose() async {
    await stop();
    await _peerChanges.close();
  }
}

class _Session {
  _Session(this.connection);

  final TransportConnection connection;
  String? identityId;
  String? displayName;
  Set<String> peerSummaries = const {};
  StreamSubscription<Uint8List>? bundleSub;
  StreamSubscription<PeerSummary>? summarySub;
  StreamSubscription<Object>? errorSub;

  Future<void> dispose() async {
    await bundleSub?.cancel();
    await summarySub?.cancel();
    await errorSub?.cancel();
    await connection.close();
  }
}
