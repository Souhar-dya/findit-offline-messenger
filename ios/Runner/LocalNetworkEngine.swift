import Foundation
import Network

/// What this device advertises: an opaque handle + an optional display hint.
struct Advertisement {
  let handle: String
  let displayNameHint: String?
  let ipv4: String?
  let dataPort: Int
}

/// The iOS connectivity fabric. Uses infrastructure Wi-Fi (an NWListener for
/// the Dart TCP data channel + Bonjour for discovery), which matches the "one
/// TCP endpoint per device" model the Dart side implements. MultipeerConnectivity
/// is the platform-native alternative but does not expose IP:port reachability,
/// so it cannot drive the shared Dart framing; it is documented here for
/// completeness and is out of scope for this scaffold.
///
/// IMPLEMENTATION STATUS — skeleton only. [start] fails honestly until the
/// NWListener/NetService lifecycle below is implemented and verified on a real
/// iPhone (a Mac + physical devices; iOS simulator cannot see local networks).
///
/// Privacy: Bonjour TXT records carry only the rotating handle, a display hint
/// and the data port. The identity id is never advertised.
class LocalNetworkEngine {
  let handle: String
  let fabric: String
  let localIPv4: String?

  private let onPeerFound: (String, String?, String?, Int, Int) -> Void
  private let onPeerLost: (String) -> Void
  private let onError: (String, String) -> Void

  init(
    host: String,
    onPeerFound: @escaping (String, String?, String?, Int, Int) -> Void,
    onPeerLost: @escaping (String) -> Void,
    onError: @escaping (String, String) -> Void
  ) {
    self.handle = Self.randomHandle()
    self.fabric = PlatformTransportChannel.fabricLocalNetwork
    self.localIPv4 = Self.localIPv4()
    self.onPeerFound = onPeerFound
    self.onPeerLost = onPeerLost
    self.onError = onError
  }

  func start() -> Bool {
    // TODO(device): implement and verify, then return true only when the whole
    // path (listener + Bonjour discovery) works.
    //
    //   1. NWListener on the Dart dataPort (passed via start()), bound to
    //      .any; NWParameters with passThroughEnable(true) so the tunnel does
    //      not encrypt what the app already encrypts end-to-end.
    //   2. Publish a Bonjour service "_findit._tcp" with TXT records
    //      { h = handle, p = dataPort, d = displayHint } via NetService, plus
    //      an NWListener service type.
    //   3. NWBrowser finding services below; each resolution yields host:port
    //      for events.onPeerFound(handle, hint, host, port, rssi).
    //   4. connect(handle): NWConnection to the discovered host:port, run the
    //      raw TCP handshake in Dart.
    //
    // iOS requires NSLocalNetworkUsageDescription and NSBonjourServices in
    // Info.plist (added); the user is prompted on first use. The IPv4 here is
    // the *local* Wi-Fi address used only for diagnostics until the listener
    // path is complete.
    onError(
      PlatformTransportChannel.errUnsupportedFeature,
      "Local-network discovery/connect is scaffold-only (see TODO in "
        + "LocalNetworkEngine)"
    )
    return false
  }

  func updateAdvertisement(_ advertisement: Advertisement) {
    // TODO(device): update the Bonjour TXT records (opaque handle + display
    // hint + dataPort), rotating `handle` per session.
  }

  func connect(
    handle: String,
    onResult: @escaping (String?, Int?, String?, String?) -> Void
  ) {
    // TODO(device): NWConnection to the peer's host:dataPort, then
    // onResult(host, dataPort, nil, nil). Never return a synthetic endpoint.
    onResult(
      nil,
      nil,
      PlatformTransportChannel.errConnectFailed,
      "Datapath formation is scaffold-only (see TODO in LocalNetworkEngine)"
    )
  }

  func stop() {
    // TODO(device): stop the NWListener, stop advertising, cancel browsers.
  }

  private static func randomHandle() -> String {
    let bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func localIPv4() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    defer { freeifaddrs(ifaddr) }
    var ptr = ifaddr
    while ptr != nil {
      let interface = ptr!.pointee
      let family = interface.ifa_addr.pointee.sa_family
      if family == UInt8(AF_INET) {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(
          interface.ifa_addr,
          socklen_t(interface.ifa_addr.pointee.sa_len),
          &host,
          socklen_t(host.count),
          nil,
          0,
          NI_NUMERICHOST
        )
        let name = String(cString: host)
        if name != "127.0.0.1" && String(cString: interface.ifa_name).hasPrefix("en") {
          address = name
        }
      }
      ptr = interface.ifa_next
    }
    return address
  }
}