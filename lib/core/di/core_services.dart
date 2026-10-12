import 'package:sqflite/sqflite.dart';

import '../../crypto/identity_holder.dart';
import '../../crypto/identity_service.dart';
import '../../crypto/message_crypto.dart';
import '../../crypto/secret_store.dart';
import '../../data/db/app_database.dart';
import '../../data/repositories/sqflite_bundle_repository.dart';
import '../../data/repositories/sqflite_friend_repository.dart';
import '../../data/repositories/sqflite_identity_repository.dart';
import '../../data/repositories/sqflite_message_repository.dart';
import '../../data/repositories/sqflite_receipt_repository.dart';
import '../../data/repositories/sqflite_settings_repository.dart';
import '../../domain/entities/known_identity.dart';
import '../../domain/repositories/bundle_repository.dart';
import '../../domain/repositories/friend_repository.dart';
import '../../domain/repositories/identity_repository.dart';
import '../../domain/repositories/message_repository.dart';
import '../../domain/repositories/receipt_repository.dart';
import '../../friends/friend_service.dart';
import '../../messaging/bundle_outbox.dart';
import '../../messaging/message_changes.dart';
import '../../messaging/message_service.dart';
import '../../messaging/receipt_service.dart';
import '../../messaging/signed_bundle.dart';
import '../../routing/routing_engine.dart';
import '../../transport/transport.dart';
import '../config/app_config.dart';
import '../maintenance_service.dart';
import '../settings/settings_service.dart';
import '../utils/clock.dart';

/// The Flutter-free core of the application: storage, cryptography, protocol
/// services, the routing engine and the transport.
///
/// Keeping this free of any Flutter widget dependency means it can be built in
/// plain Dart tests, and a second instance can run as the in-process demo peer.
class CoreServices {
  CoreServices({
    required this.config,
    required this.clock,
    required this.database,
    required this.identityService,
    required this.identityHolder,
    required this.identities,
    required this.friends,
    required this.messages,
    required this.bundles,
    required this.receipts,
    required this.settings,
    required this.codec,
    required this.outbox,
    required this.messageChanges,
    required this.friendService,
    required this.receiptService,
    required this.messageService,
    required this.routingEngine,
    required this.maintenance,
    required this.transport,
  });

  final AppConfig config;
  final Clock clock;
  final AppDatabase database;

  final IdentityService identityService;
  final IdentityHolder identityHolder;

  final IdentityRepository identities;
  final FriendRepository friends;
  final MessageRepository messages;
  final BundleRepository bundles;
  final ReceiptRepository receipts;

  /// Local, non-secret preferences (consent acceptance, relay opt-in).
  final SettingsService settings;

  final BundleCodec codec;
  final BundleOutbox outbox;

  /// Coarse "messages changed" signal so chat screens refresh immediately.
  final MessageChanges messageChanges;

  final FriendService friendService;
  final ReceiptService receiptService;
  final MessageService messageService;

  final RoutingEngine routingEngine;
  final MaintenanceService maintenance;
  final Transport transport;

  /// Builds the whole object graph. Nothing is started yet: call
  /// [RoutingEngine.start] once an identity exists.
  static Future<CoreServices> create({
    required DatabaseFactory databaseFactory,
    required String databasePath,
    required SecretStore secretStore,
    required Transport transport,
    AppConfig config = AppConfig.production,
    Clock clock = const SystemClock(),
    bool autoConnect = true,
  }) async {
    final database = AppDatabase(factory: databaseFactory, path: databasePath);
    final identities = SqfliteIdentityRepository(database);
    final friends = SqfliteFriendRepository(database);
    final messages = SqfliteMessageRepository(database);
    final bundles = SqfliteBundleRepository(database);
    final receipts = SqfliteReceiptRepository(database);
    final settings = SettingsService(
      repository: SqfliteSettingsRepository(database),
    );

    final identityService = IdentityService(secretStore: secretStore);
    final identityHolder = IdentityHolder();
    final codec = BundleCodec(
      crypto: MessageCrypto(),
      clock: clock,
      protocolVersion: config.protocolVersion,
    );
    final outbox = BundleOutbox(
      codec: codec,
      bundles: bundles,
      clock: clock,
      config: config,
    );
    final messageChanges = MessageChanges();
    final friendService = FriendService(
      friends: friends,
      identities: identities,
      outbox: outbox,
      identityHolder: identityHolder,
      clock: clock,
      config: config,
    );
    final receiptService = ReceiptService(
      receipts: receipts,
      messages: messages,
      bundles: bundles,
      outbox: outbox,
      identityHolder: identityHolder,
      clock: clock,
      config: config,
      changes: messageChanges,
    );
    final messageService = MessageService(
      messages: messages,
      identities: identities,
      outbox: outbox,
      receipts: receiptService,
      identityHolder: identityHolder,
      clock: clock,
      config: config,
      changes: messageChanges,
    );
    final routingEngine = RoutingEngine(
      transport: transport,
      codec: codec,
      bundles: bundles,
      outbox: outbox,
      messages: messageService,
      friends: friendService,
      receipts: receiptService,
      identities: identities,
      identityHolder: identityHolder,
      settings: settings,
      clock: clock,
      config: config,
      autoConnect: autoConnect,
    );
    final maintenance = MaintenanceService(
      messages: messages,
      bundles: bundles,
      receipts: receipts,
      friends: friendService,
      messageService: messageService,
      receiptService: receiptService,
      clock: clock,
      config: config,
    );

    return CoreServices(
      config: config,
      clock: clock,
      database: database,
      identityService: identityService,
      identityHolder: identityHolder,
      identities: identities,
      friends: friends,
      messages: messages,
      bundles: bundles,
      receipts: receipts,
      settings: settings,
      codec: codec,
      outbox: outbox,
      messageChanges: messageChanges,
      friendService: friendService,
      receiptService: receiptService,
      messageService: messageService,
      routingEngine: routingEngine,
      maintenance: maintenance,
      transport: transport,
    );
  }

  /// Loads an existing identity into the holder. Returns it, or null.
  Future<LocalIdentity?> loadIdentity() async {
    final identity = await identityService.load();
    if (identity != null) {
      identityHolder.set(identity);
      final now = clock.now().millisecondsSinceEpoch;
      await identities.upsert(
        KnownIdentity(
          record: identity.record,
          isLocal: true,
          firstSeenMs: now,
          lastSeenMs: now,
          verifiedAtMs: now,
        ),
      );
    }
    return identity;
  }

  Future<void> dispose() async {
    maintenance.stop();
    await routingEngine.dispose();
    await transport.dispose();
    await messageService.dispose();
    await friendService.dispose();
    await outbox.dispose();
    await messageChanges.dispose();
    await database.close();
  }
}
