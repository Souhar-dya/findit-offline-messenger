/// Central, immutable application configuration.
///
/// Every tunable protocol / resource value lives here so that tests can use a
/// compact deterministic configuration while production uses the documented
/// defaults from the specification.
class AppConfig {
  const AppConfig({
    this.protocolVersion = 1,
    this.messageTtl = const Duration(hours: 24),
    this.friendRequestTtl = const Duration(days: 7),
    this.deliveryReceiptTtl = const Duration(hours: 48),
    this.tombstoneRetention = const Duration(days: 30),
    this.receiptRetention = const Duration(days: 30),
    this.protocolMessageRetention = const Duration(days: 14),
    this.defaultStorageQuotaBytes = 256 * 1024 * 1024,
    this.maxImageBytes = 12 * 1024 * 1024,
    this.maxEnvelopeBytes = 16 * 1024 * 1024,
    this.maxImagePixels = 64 * 1024 * 1024,
    this.maxImageDimension = 12000,
    this.replicationBudget = 8,
    this.perPeerForwardBudget = 1,
    this.maxFriendsPerRequestBatch = 32,
    this.maxFriendRequestsPerHour = 30,
    this.maxInboundBundlesPerMinute = 240,
    this.maxTombstones = 20000,
    this.maxPendingTransfers = 500,
  }) : assert(replicationBudget > 0),
       assert(maxImageBytes > 0);

  /// Wire protocol format version for envelopes and identity records.
  final int protocolVersion;

  /// Ordinary message time-to-live, measured from original creation.
  final Duration messageTtl;

  /// Friend request expiry (kept separate from the message TTL).
  final Duration friendRequestTtl;

  /// How long a delivery receipt is retained and forwarded.
  final Duration deliveryReceiptTtl;

  /// How long delivered/expired tombstones are retained to prevent replay.
  final Duration tombstoneRetention;

  /// How long received delivery receipts are retained in the database.
  final Duration receiptRetention;

  /// Retention for friend-protocol envelopes kept for retries.
  final Duration protocolMessageRetention;

  /// Default local storage quota for message + payload data.
  final int defaultStorageQuotaBytes;

  /// Hard upper bound for a single PNG attachment.
  final int maxImageBytes;

  /// Hard upper bound for a single wire envelope (defensive).
  final int maxEnvelopeBytes;

  /// Maximum decoded pixel count accepted for a PNG (decompression bomb guard).
  final int maxImagePixels;

  /// Maximum accepted width or height of a PNG.
  final int maxImageDimension;

  /// Maximum number of peers a bundle is replicated to.
  final int replicationBudget;

  /// How many times a bundle may be handed to the same peer.
  final int perPeerForwardBudget;

  /// Maximum size of a single friend-request batch.
  final int maxFriendsPerRequestBatch;

  /// Inbound rate limit for friend requests, per peer, per hour.
  final int maxFriendRequestsPerHour;

  /// Inbound rate limit for bundles overall, per minute.
  final int maxInboundBundlesPerMinute;

  /// Upper bound on retained tombstone rows.
  final int maxTombstones;

  /// Upper bound on simultaneously tracked incomplete transfers.
  final int maxPendingTransfers;

  static const AppConfig production = AppConfig();

  /// A small, fast configuration used in unit tests.
  static const AppConfig test = AppConfig(
    messageTtl: Duration(minutes: 30),
    friendRequestTtl: Duration(hours: 2),
    deliveryReceiptTtl: Duration(minutes: 30),
    tombstoneRetention: Duration(days: 1),
    receiptRetention: Duration(days: 1),
    defaultStorageQuotaBytes: 4 * 1024 * 1024,
    maxImageBytes: 512 * 1024,
    maxEnvelopeBytes: 1024 * 1024,
    maxImagePixels: 4 * 1024 * 1024,
    maxImageDimension: 4096,
  );
}
