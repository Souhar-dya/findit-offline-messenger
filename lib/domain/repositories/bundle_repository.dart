import '../entities/stored_bundle.dart';
import '../entities/tombstone.dart';

/// The store-carry-forward queue plus tombstones and incomplete transfers.
abstract class BundleRepository {
  /// Atomically inserts a bundle. Returns `false` when the bundle id already
  /// exists (deduplication).
  Future<bool> insertIfAbsent(StoredBundle bundle);

  Future<StoredBundle?> find(String bundleIdHex);

  Future<bool> exists(String bundleIdHex);

  /// Bundles eligible for forwarding: not expired, not tombstoned, still under
  /// the replication budget, and not yet seen by [peerId].
  Future<List<StoredBundle>> claimForwardable({
    required int nowMs,
    required int replicationBudget,
    String? peerId,
    int limit = 50,
  });

  /// Records a successful forwarding hand-off. A failed attempt must NOT call
  /// this.
  Future<void> recordForwarded(
    String bundleIdHex,
    String peerId,
    int nowMs, {
    required int replicationBudget,
  });

  Future<void> delete(String bundleIdHex);

  /// Deletes bundles this device is carrying for others — i.e. bundles that
  /// were received from a peer rather than originated here. Used when relaying
  /// is switched off so the device stops holding third-party data. Returns the
  /// number of bundles removed.
  Future<int> deleteRelayedBundles();

  Future<int> totalBytes();

  /// Deletes expired bundles and writes tombstones for them. Returns count.
  Future<int> expireBundles(int nowMs, int tombstoneExpiresAtMs);

  // --- Tombstones ------------------------------------------------------------

  Future<void> addTombstone(MessageTombstone tombstone);

  Future<bool> hasTombstone(String bundleIdHex);

  Future<void> pruneTombstones(int nowMs, {required int maxCount});

  // --- Incomplete transfers --------------------------------------------------

  /// Records an in-progress transfer chunk set so a restart can resume or
  /// discard it. Partial transfers are never promoted to complete messages.
  Future<void> upsertPendingTransfer({
    required String transferId,
    required String peerId,
    required int receivedBytes,
    required int totalBytes,
    required int updatedAtMs,
  });

  Future<void> deletePendingTransfer(String transferId);

  Future<int> countPendingTransfers();
}
