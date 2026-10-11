import '../../crypto/identity_record.dart';

/// How a nearby peer was discovered. A discovery event never creates a
/// friendship on its own.
enum DiscoverySource {
  simulated('simulated'),
  wifiAware('wifi_aware'),
  wifiDirect('wifi_direct'),
  manual('manual');

  const DiscoverySource(this.wire);

  final String wire;
}

/// A peer currently visible over a transport.
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.transportPeerId,
    required this.identityRecord,
    required this.source,
    required this.discoveredAtMs,
    this.rssi,
    this.isFriend = false,
    this.isReachable = true,
  });

  /// Ephemeral, transport-local handle. Never used as a stable identity.
  final String transportPeerId;

  /// The advertised public identity (untrusted until verified).
  final IdentityRecord identityRecord;

  final DiscoverySource source;
  final int discoveredAtMs;
  final int? rssi;
  final bool isFriend;
  final bool isReachable;

  String get identityId => identityRecord.identityId;

  String get displayName => identityRecord.displayName;
}
