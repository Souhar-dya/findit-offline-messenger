/// Reason a tombstone exists.
enum TombstoneReason {
  delivered('delivered'),
  expired('expired'),
  declined('declined'),
  blocked('blocked');

  const TombstoneReason(this.wire);

  final String wire;

  static TombstoneReason fromWire(String wire) {
    for (final value in TombstoneReason.values) {
      if (value.wire == wire) return value;
    }
    throw ArgumentError('Unknown tombstone reason: $wire');
  }
}

/// A bounded record that prevents a stale copy of a message from being
/// reintroduced after the original was delivered or expired.
class MessageTombstone {
  const MessageTombstone({
    required this.bundleIdHex,
    required this.reason,
    required this.createdAtMs,
    required this.expiresAtMs,
  });

  final String bundleIdHex;
  final TombstoneReason reason;
  final int createdAtMs;

  /// When the tombstone itself may be forgotten.
  final int expiresAtMs;
}
