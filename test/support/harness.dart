import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:findit/core/config/app_config.dart';
import 'package:findit/core/di/core_services.dart';
import 'package:findit/core/protocol/envelope.dart';
import 'package:findit/core/utils/clock.dart';
import 'package:findit/crypto/identity_service.dart';
import 'package:findit/crypto/secret_store.dart';
import 'package:findit/domain/entities/friend.dart';
import 'package:findit/domain/entities/known_identity.dart';
import 'package:findit/domain/entities/stored_bundle.dart';
import 'package:findit/messaging/signed_bundle.dart';
import 'package:findit/transport/simulated_transport.dart';
import 'package:path/path.dart' as p;

import 'db.dart';

/// A self-contained FindIt instance for tests.
///
/// It owns a temporary SQLite database, an [InMemorySecretStore], a
/// [FixedClock] and a [SimulatedTransport] on a [SimulatedNetwork]. This is the
/// exact production object graph (see [CoreServices.create]); only the storage
/// backend and the transport implementation are substituted for test doubles.
class TestNode {
  TestNode._({
    required this.core,
    required this.network,
    required this.transport,
    required this.clock,
    required this.secretStore,
    required this.config,
    required this.directory,
    required this.databasePath,
    required this.localId,
    required this.autoConnect,
    required this.networkingEnabled,
  });

  final CoreServices core;
  final SimulatedNetwork network;
  final SimulatedTransport transport;
  final FixedClock clock;
  final InMemorySecretStore secretStore;
  final AppConfig config;
  final Directory directory;
  final String databasePath;
  final String localId;
  final bool autoConnect;
  final bool networkingEnabled;

  LocalIdentity? identity;

  /// Identity id of the local identity. Throws before [createIdentity].
  String get id {
    final value = identity;
    if (value == null) {
      throw StateError('No identity was created for this node');
    }
    return value.identityId;
  }

  static Future<TestNode> create({
    SimulatedNetwork? network,
    AppConfig config = AppConfig.test,
    DateTime? start,
    bool autoConnect = true,
    bool networkingEnabled = false,
    String? localId,
    InMemorySecretStore? secretStore,
    Directory? directory,
    String databaseName = 'findit',
  }) async {
    final store = secretStore ?? InMemorySecretStore();
    final net = network ?? SimulatedNetwork();
    final simulated = SimulatedTransport(network: net, localId: localId);
    final resolvedClock = FixedClock(start ?? DateTime.utc(2026, 1, 1, 12));
    final dir =
        directory ?? Directory.systemTemp.createTempSync('findit-test-');
    final path = p.join(dir.path, '$databaseName.db');
    final core = await CoreServices.create(
      databaseFactory: testDatabaseFactory,
      databasePath: path,
      secretStore: store,
      transport: simulated,
      config: config,
      clock: resolvedClock,
      autoConnect: autoConnect,
    );
    await core.settings.load();
    if (networkingEnabled) {
      await core.settings.setNetworkingEnabled(true);
    }
    return TestNode._(
      core: core,
      network: net,
      transport: simulated,
      clock: resolvedClock,
      secretStore: store,
      config: config,
      directory: dir,
      databasePath: path,
      localId: simulated.localId,
      autoConnect: autoConnect,
      networkingEnabled: networkingEnabled,
    );
  }

  Future<LocalIdentity> createIdentity([
    String displayName = 'Test user',
  ]) async {
    final created = await core.identityService.generate(
      displayName: displayName,
    );
    core.identityHolder.set(created);
    identity = created;
    final now = clock.now().millisecondsSinceEpoch;
    await core.identities.upsert(
      KnownIdentity(
        record: created.record,
        isLocal: true,
        firstSeenMs: now,
        lastSeenMs: now,
        verifiedAtMs: now,
      ),
    );
    return created;
  }

  Future<void> startRouting() => core.routingEngine.start();

  Future<void> connectTo(TestNode other) =>
      core.routingEngine.connectTo(other.transport.localId);

  /// Seals a protocol bundle from this node to [recipient].
  Future<Uint8List> sealFor({
    required TestNode recipient,
    required EnvelopeType type,
    required Map<String, Object?> payload,
    required Uint8List bundleId,
    int? expiresAtMs,
    int? createdAtMs,
  }) {
    final created = createdAtMs ?? clock.now().millisecondsSinceEpoch;
    return core.codec.seal(
      sender: identity!,
      recipient: recipient.identity!.record,
      type: type,
      payload: payload,
      bundleId: bundleId,
      expiresAtMs: expiresAtMs ?? created + config.messageTtl.inMilliseconds,
    );
  }

  /// Opens bundle [bytes] addressed to this node.
  Future<OpenedBundle> open(Uint8List bytes) =>
      core.codec.open(recipient: identity!, envelope: Envelope.decode(bytes));

  /// Loads a stored bundle from this node's forwarding queue.
  Future<StoredBundle> storedBundle(String bundleIdHex) async {
    final bundle = await core.bundles.find(bundleIdHex);
    if (bundle == null) {
      throw StateError('No stored bundle $bundleIdHex on this node');
    }
    return bundle;
  }

  /// Number of known identities on this node.
  Future<int> knownIdentityCount() async =>
      (await core.identities.allKnown()).length;

  Future<void> dispose({bool deleteDirectory = true}) async {
    await core.dispose();
    if (deleteDirectory) {
      try {
        directory.deleteSync(recursive: true);
      } catch (_) {
        // Best effort; temporary directories are reaped by the OS.
      }
    }
  }

  /// Simulates an app restart: closes the core, keeps the database file and the
  /// secret store, and opens a fresh core over the same persisted state.
  Future<TestNode> reopen() async {
    await core.dispose();
    return TestNode.create(
      config: config,
      autoConnect: autoConnect,
      networkingEnabled: networkingEnabled,
      localId: localId,
      secretStore: secretStore,
      directory: directory,
      databaseName: p.basenameWithoutExtension(databasePath),
      start: clock.now(),
    );
  }
}

/// Marks the two test identities as mutually accepted contacts without
/// exercising the friend-request protocol. Use this only when a test is about
/// message routing rather than friend onboarding.
Future<void> markMutualFriends(TestNode first, TestNode second) async {
  final now = first.clock.now().millisecondsSinceEpoch;
  await first.core.friendService.rememberIdentity(
    second.identity!.record,
    verified: true,
  );
  await second.core.friendService.rememberIdentity(
    first.identity!.record,
    verified: true,
  );
  await first.core.friends.upsertFriend(
    FriendRecord(
      peerId: second.id,
      displayName: second.identity!.displayName,
      status: FriendStatus.accepted,
      createdAtMs: now,
      verifiedAtMs: now,
      identityRecord: second.identity!.record,
    ),
  );
  await second.core.friends.upsertFriend(
    FriendRecord(
      peerId: first.id,
      displayName: first.identity!.displayName,
      status: FriendStatus.accepted,
      createdAtMs: now,
      verifiedAtMs: now,
      identityRecord: first.identity!.record,
    ),
  );
}

/// Returns the first forwardable bundle of [type] currently stored on [node].
Future<StoredBundle> firstBundleOfType(TestNode node, EnvelopeType type) async {
  final bundles = await node.core.bundles.claimForwardable(
    nowMs: node.clock.now().millisecondsSinceEpoch,
    replicationBudget: node.config.replicationBudget,
    limit: 200,
  );
  return bundles.firstWhere((bundle) => bundle.type == type);
}

/// Polls [predicate] until it returns true or [timeout] elapses.
Future<void> waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String description = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Polls an asynchronous [predicate] until it returns true or [timeout] elapses.
Future<void> waitForAsync(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String description = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Timed out waiting for $description');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
