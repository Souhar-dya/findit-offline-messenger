import 'dart:async';

import '../domain/repositories/bundle_repository.dart';
import '../domain/repositories/message_repository.dart';
import '../domain/repositories/receipt_repository.dart';
import '../friends/friend_service.dart';
import '../messaging/message_changes.dart';
import '../messaging/message_service.dart';
import '../messaging/receipt_service.dart';
import 'config/app_config.dart';
import 'utils/clock.dart';

/// Summary of one maintenance pass.
class MaintenanceReport {
  const MaintenanceReport({
    required this.messagesExpired,
    required this.messagesEvicted,
    required this.bundlesExpired,
    required this.requestsExpired,
    required this.receiptsPruned,
    required this.receiptsReconciled,
  });

  final int messagesExpired;

  /// Messages dropped, oldest first, to get back under the storage quota.
  final int messagesEvicted;
  final int bundlesExpired;
  final int requestsExpired;
  final int receiptsPruned;
  final int receiptsReconciled;
}

/// Best-effort lazy cleanup.
///
/// Expiry is enforced at read/ingest time as well; this only reclaims bytes and
/// bounds tombstones/receipts so storage does not grow without limit.
class MaintenanceService {
  MaintenanceService({
    required MessageRepository messages,
    required BundleRepository bundles,
    required ReceiptRepository receipts,
    required FriendService friends,
    required MessageService messageService,
    required ReceiptService receiptService,
    required MessageChanges changes,
    required Clock clock,
    required AppConfig config,
  }) : _messages = messages,
       _bundles = bundles,
       _receipts = receipts,
       _friends = friends,
       _messageService = messageService,
       _receiptService = receiptService,
       _changes = changes,
       _clock = clock,
       _config = config;

  final MessageRepository _messages;
  final BundleRepository _bundles;
  final ReceiptRepository _receipts;
  final FriendService _friends;
  final MessageService _messageService;
  final ReceiptService _receiptService;
  final MessageChanges _changes;
  final Clock _clock;
  final AppConfig _config;

  Timer? _timer;

  Future<MaintenanceReport> runOnce() async {
    final now = _clock.now().millisecondsSinceEpoch;
    final tombstoneExpiry = now + _config.tombstoneRetention.inMilliseconds;

    final ttlExpired = await _messages.expireMessages(
      now,
      tombstoneExpiresAtMs: tombstoneExpiry,
    );
    final disappeared = await _messages.deleteDisappearingMessages(
      now,
      tombstoneExpiresAtMs: tombstoneExpiry,
    );
    final bundlesExpired = await _bundles.expireBundles(now, tombstoneExpiry);
    await _bundles.pruneTombstones(now, maxCount: _config.maxTombstones);

    // Keep the whole store bounded: if it is over quota, drop the oldest
    // messages first (first in, first out). Only the message store is
    // reclaimed here; bundles already have their own quota.
    final bundleBytes = await _bundles.totalBytes();
    final messageBudget = _config.defaultStorageQuotaBytes - bundleBytes;
    final messagesEvicted = await _messages.evictOldest(
      messageBudget < 0 ? 0 : messageBudget,
    );
    if (messagesEvicted > 0 || disappeared > 0) _changes.notify();

    final requestsExpired = await _friends.expireRequests();
    final receiptsPruned = await _receipts.prune(
      now - _config.receiptRetention.inMilliseconds,
    );

    // Recover state after a crash or an out-of-order receipt.
    await _friends.retryPendingRequests();
    await _messageService.retryOutbound();
    final reconciled = await _receiptService.reconcile();

    return MaintenanceReport(
      messagesExpired: ttlExpired + disappeared,
      messagesEvicted: messagesEvicted,
      bundlesExpired: bundlesExpired,
      requestsExpired: requestsExpired,
      receiptsPruned: receiptsPruned,
      receiptsReconciled: reconciled,
    );
  }

  /// Starts a periodic cleanup. Safe to call once.
  void start({Duration interval = const Duration(minutes: 5)}) {
    _timer?.cancel();
    unawaited(runOnce());
    _timer = Timer.periodic(interval, (_) {
      unawaited(runOnce());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
