import 'dart:async';

import 'package:sqflite/sqflite.dart';

import '../core/config/app_config.dart';
import '../core/di/core_services.dart';
import '../core/utils/clock.dart';
import '../crypto/secret_store.dart';
import '../domain/entities/chat_message.dart';
import '../transport/simulated_transport.dart';

/// A second, fully independent FindIt instance running in-process.
///
/// It shares only the [SimulatedNetwork]; everything else (identity, database,
/// crypto, routing engine) is separate. This makes it a genuine peer: friend
/// requests, messages and receipts travel through the same transport
/// abstraction and the same protocol code as a real remote device would.
///
/// It is explicitly a *demo* peer. The UI labels it as simulated, and it never
/// implies a physical radio connection.
class SimulatedPeerAgent {
  SimulatedPeerAgent._({
    required this.core,
    required this.transport,
    required this.displayName,
  });

  final CoreServices core;
  final SimulatedTransport transport;
  final String displayName;

  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  bool autoReply = true;

  /// Starts a demo peer bound to [network].
  ///
  /// [databaseFactory] and [databasePath] must point at a database that can be
  /// safely reset; the agent starts from a clean slate every time.
  static Future<SimulatedPeerAgent> start({
    required SimulatedNetwork network,
    required DatabaseFactory databaseFactory,
    required String databasePath,
    String displayName = 'Demo peer',
    AppConfig config = AppConfig.production,
  }) async {
    final transport = SimulatedTransport(network: network);
    final core = await CoreServices.create(
      databaseFactory: databaseFactory,
      databasePath: databasePath,
      secretStore: InMemorySecretStore(),
      transport: transport,
      config: config,
      clock: const SystemClock(),
    );
    await core.database.deleteDatabase();
    await core.database.close();

    final identity = await core.identityService.generate(
      displayName: displayName,
    );
    core.identityHolder.set(identity);

    // The demo peer stands in for a remote device that already has networking
    // on, so it can answer friend requests and messages. The *local* user still
    // has to switch networking on themselves.
    await core.settings.setNetworkingEnabled(true);

    final agent = SimulatedPeerAgent._(
      core: core,
      transport: transport,
      displayName: displayName,
    );
    await core.routingEngine.start();

    agent._subscriptions.add(
      core.friendService.incomingRequests.listen((request) async {
        try {
          await core.friendService.acceptRequest(request);
        } catch (_) {
          // The request may have expired concurrently; nothing to do.
        }
      }),
    );
    agent._subscriptions.add(
      core.messageService.incomingMessages.listen(
        (ChatMessage message) => agent._onMessage(message),
      ),
    );
    return agent;
  }

  Future<void> _onMessage(ChatMessage message) async {
    if (!autoReply) return;
    final text = message.text;
    if (text == null || text.isEmpty) return;
    final peer = await core.identities.find(message.senderId);
    if (peer == null) return;
    try {
      await core.messageService.sendText(
        recipient: peer.record,
        text: 'Demo peer received: $text',
      );
    } catch (_) {
      // Ignore transient failures; the message stays queued for retry.
    }
  }

  Future<void> stop() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await core.dispose();
  }
}
