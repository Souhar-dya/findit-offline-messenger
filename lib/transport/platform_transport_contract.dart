/// The exact contract between the Dart transport layer and the native platform
/// transport. The Kotlin `PlatformTransportChannel.kt` and Swift
/// `PlatformTransportChannel.swift` implementations mirror every symbol in
/// here.
///
/// ## Design intent
///
/// All protocol logic stays in Dart and runs over an opaque TCP data channel;
/// native code only *establishes connectivity* and exchanges opaque
/// reachability information:
///
/// 1. Dart binds a TCP listen socket and reports its `dataPort` and rotating
///    `handle` via `start`.
/// 2. Native discovers nearby devices and advertises opaque
///    `{ handle, host, dataPort }` tuples. A `handle` is a rotating, ephemeral
///    token; only an optional display hint ever leaves the device. The
///    permanent identity id is NEVER passed to native code.
/// 3. `connect(handle)` asks native to bring up a datapath to the peer (a
///    Wi-Fi Direct group or Wi-Fi Aware datapath on Android, a local-network
///    path on iOS) and returns the peer's reachable `host`/`port`. Dart then
///    opens the TCP connection and performs the identity handshake, summary
///    exchange and bundle transfer itself using `frame_stream.dart`.
///
/// Errors are surfaced as `PlatformException`s carrying one of
/// [PlatformErrorCodes]; Dart maps them all to [TransportException]s and never
/// pretends connectivity exists.
library;

/// Method channel used for request/response calls; event channel for streams.
class PlatformChannelNames {
  PlatformChannelNames._();

  static const String channel = 'findit/transport';
  static const String events = 'findit/transport/events';
}

/// Request/response methods on the [PlatformChannelNames.channel] channel.
class PlatformMethodNames {
  PlatformMethodNames._();

  /// Starts discovery/advertisement. Arg: `{ dataPort, handle }` -> `{ supported,
  /// fabric, deviceName }`. `handle` is this endpoint's rotating, ephemeral
  /// handle: native must advertise exactly this value (and never the identity
  /// id) so both peers compare the same pair when electing who dials. Throws
  /// `unavailable` when no fabric can run.
  static const String start = 'start';

  /// Stops discovery and drops all datapaths. No args.
  static const String stop = 'stop';

  /// Publishes advertisement state. Arg: `{ displayNameHint, discoverable }`.
  /// Identity must NOT be passed through native code.
  static const String updateAdvertisement = 'updateAdvertisement';

  /// Brings up a datapath to a discovered handle. Arg: `{ handle }` ->
  /// `{ host, port }` (the peer's reachable data endpoint).
  static const String connect = 'connect';

  /// Static capability report. -> `{ canDiscover, canConnect,
  /// supportsResumableTransfer, supportsBackground, description }`.
  static const String capabilities = 'getCapabilities';

  /// Tears down the plugin. No args.
  static const String dispose = 'dispose';

  /// Checks whether Wi-Fi is enabled. -> `{ enabled: bool }`.
  static const String isWifiEnabled = 'isWifiEnabled';

  /// Requests the system Wi-Fi panel so the user can enable Wi-Fi.
  /// -> `{ enabled: bool }` (whether Wi-Fi is now on).
  static const String requestWifiEnable = 'requestWifiEnable';

  /// Checks whether required runtime permissions are granted.
  /// -> `{ granted: bool, missing: List<String> }`.
  static const String checkPermissions = 'checkPermissions';

  /// Requests the required runtime permissions.
  /// -> `{ granted: bool }`.
  static const String requestPermissions = 'requestPermissions';

  /// Opens this app's system settings page (e.g. after the user permanently
  /// denied a permission). No args.
  static const String openAppSettings = 'openAppSettings';
}

/// Event names carried on the [PlatformChannelNames.events] channel, each as a
/// map whose first key is [PlatformPayloadKeys.event].
class PlatformEventNames {
  PlatformEventNames._();

  /// `{ event:'peerFound', handle, displayNameHint?, host?, dataPort?, rssi?,
  /// discoveredAtMs? }`
  static const String peerFound = 'peerFound';

  /// `{ event:'peerLost', handle }`
  static const String peerLost = 'peerLost';

  /// `{ event:'peerReachable', handle, host, port }` - this device joined a
  /// group as the client, so the peer (the group owner) is reachable at
  /// `host`/`port`. The group owner cannot learn a client's address, so the
  /// client is always the side that dials.
  static const String peerReachable = 'peerReachable';

  /// `{ event:'error', code, message }` - a native-side failure.
  static const String error = 'error';
}

/// Well-known keys used in method arguments, results, and event payloads.
class PlatformPayloadKeys {
  PlatformPayloadKeys._();

  /// Type discriminator for event payloads (one of [PlatformEventNames]).
  static const String event = 'event';

  static const String handle = 'handle';
  static const String displayNameHint = 'displayNameHint';
  static const String discoverable = 'discoverable';
  static const String host = 'host';
  static const String dataPort = 'dataPort';
  static const String port = 'port';
  static const String rssi = 'rssi';
  static const String discoveredAtMs = 'discoveredAtMs';

  static const String supported = 'supported';
  static const String fabric = 'fabric';
  static const String deviceName = 'deviceName';

  static const String canDiscover = 'canDiscover';
  static const String canConnect = 'canConnect';
  static const String supportsResumableTransfer = 'supportsResumableTransfer';
  static const String supportsBackground = 'supportsBackground';
  static const String description = 'description';

  static const String code = 'code';
  static const String message = 'message';
}

/// `PlatformException.code` values emitted by the native side.
class PlatformErrorCodes {
  PlatformErrorCodes._();

  /// No network fabric is available (no Wi-Fi, no Wi-Fi Direct/Aware support).
  static const String unavailable = 'unavailable';

  /// The fabric exists but the requested capability is not supported here.
  static const String unsupportedFeature = 'unsupported_feature';

  /// A required OS permission was denied by the user or the OS.
  static const String permissionDenied = 'permission_denied';

  /// The datapath to the peer could not be established.
  static const String connectFailed = 'connect_failed';

  /// Any other native-side failure.
  static const String generic = 'transport_error';
}

/// Identifiers for the native fabric that is actually running.
class PlatformFabrics {
  PlatformFabrics._();

  /// Android Wi-Fi P2P (peer-to-peer) direct connections.
  static const String wifiDirect = 'wifi-p2p';

  /// Android Wi-Fi Aware (NAN) datapaths.
  static const String wifiAware = 'wifi-aware';

  /// iOS local-network connections over infrastructure Wi-Fi (Bonjour +
  /// NWListener); MultipeerConnectivity is the documented alternative.
  static const String localNetwork = 'local-network';
}
