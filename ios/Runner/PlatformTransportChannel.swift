import Flutter
import Foundation
import Network
import UIKit

/// Bridges Dart's `PlatformTransport` (`lib/transport/platform_transport.dart`)
/// to the native local-network fabric on iOS.
///
/// Wire contract: `lib/transport/platform_transport_contract.dart`,
/// `PlatformTransportChannel.kt` (Android) and this file must stay in sync.
///
/// Privacy: only a rotating handle, an optional display hint and a TCP dataPort
/// ever cross the channel. The permanent identity id is NEVER exposed to native
/// code.
///
/// IMPLEMENTATION STATUS — skeleton only. The channel plumbing is complete;
/// `LocalNetworkEngine` outlines the NWListener/Bonjour lifecycle with TODOs and
/// fails honestly until implemented, so Dart reports an unavailable transport
/// instead of fake connectivity.
class PlatformTransportChannel: NSObject, FlutterStreamHandler {
  // Channel names (mirror PlatformChannelNames).
  static let channelName = "findit/transport"
  static let eventsChannelName = "findit/transport/events"

  // Methods (mirror PlatformMethodNames).
  static let methodStart = "start"
  static let methodStop = "stop"
  static let methodUpdateAdvertisement = "updateAdvertisement"
  static let methodConnect = "connect"
  static let methodCapabilities = "getCapabilities"
  static let methodDispose = "dispose"

  // Events (mirror PlatformEventNames).
  static let eventPeerFound = "peerFound"
  static let eventPeerLost = "peerLost"
  static let eventError = "error"

  // Payload keys (mirror PlatformPayloadKeys).
  static let keyEvent = "event"
  static let keyHandle = "handle"
  static let keyDisplayNameHint = "displayNameHint"
  static let keyDiscoverable = "discoverable"
  static let keyHost = "host"
  static let keyDataPort = "dataPort"
  static let keyPort = "port"
  static let keyRssi = "rssi"
  static let keyDiscoveredAtMs = "discoveredAtMs"
  static let keySupported = "supported"
  static let keyFabric = "fabric"
  static let keyDeviceName = "deviceName"
  static let keyCanDiscover = "canDiscover"
  static let keyCanConnect = "canConnect"
  static let keyResumable = "supportsResumableTransfer"
  static let keyBackground = "supportsBackground"
  static let keyDescription = "description"
  static let keyCode = "code"
  static let keyMessage = "message"

  // Error codes (mirror PlatformErrorCodes).
  static let errUnavailable = "unavailable"
  static let errUnsupportedFeature = "unsupported_feature"
  static let errPermissionDenied = "permission_denied"
  static let errConnectFailed = "connect_failed"
  static let errGeneric = "transport_error"

  // Fabrics (mirror PlatformFabrics).
  static let fabricLocalNetwork = "local-network"

  static func register(messenger: FlutterBinaryMessenger) {
    _ = PlatformTransportChannel(messenger: messenger)
  }

  private let methodChannel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var eventSink: FlutterEventSink?
  private var engine: LocalNetworkEngine?
  private var dataPort: Int = 0
  /// The rotating handle Dart asked us to advertise (its localId). Both peers
  /// must compare the same pair of handles when electing who dials.
  private var advertisedHandle: String?
  private var displayNameHint: String?
  private var discoverable = true

  init(messenger: FlutterBinaryMessenger) {
    methodChannel = FlutterMethodChannel(
      name: PlatformTransportChannel.channelName,
      binaryMessenger: messenger
    )
    eventChannel = FlutterEventChannel(
      name: PlatformTransportChannel.eventsChannelName,
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler(handleMethodCall)
    eventChannel.setStreamHandler(self)
  }

  private func emit(_ payload: [String: Any]) {
    eventSink?(payload)
  }

  private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case PlatformTransportChannel.methodStart:
      guard let args = call.arguments as? [String: Any],
            let handle = args[PlatformTransportChannel.keyHandle] as? String,
            !handle.isEmpty,
            let port = (args[PlatformTransportChannel.keyDataPort] as? NSNumber)?.intValue,
            port > 0
      else {
        result(
          FlutterError(
            code: PlatformTransportChannel.errGeneric,
            message: "start requires a non-empty handle and a dataPort > 0",
            details: nil
          )
        )
        return
      }
      dataPort = port
      advertisedHandle = handle
      startEngine(result: result)

    case PlatformTransportChannel.methodStop:
      engine?.stop()
      result(nil)

    case PlatformTransportChannel.methodUpdateAdvertisement:
      if let args = call.arguments as? [String: Any] {
        displayNameHint = args[PlatformTransportChannel.keyDisplayNameHint] as? String
        discoverable = (args[PlatformTransportChannel.keyDiscoverable] as? Bool) ?? true
      }
      publishAdvertisement()
      result(nil)

    case PlatformTransportChannel.methodConnect:
      guard let handle = (call.arguments as? [String: Any])?[
        PlatformTransportChannel.keyHandle
      ] as? String, !handle.isEmpty else {
        result(
          FlutterError(
            code: PlatformTransportChannel.errGeneric,
            message: "handle missing",
            details: nil
          )
        )
        return
      }
      guard let current = engine else {
        result(
          FlutterError(
            code: PlatformTransportChannel.errUnavailable,
            message: "Transport not started",
            details: nil
          )
        )
        return
      }
      current.connect(handle: handle) { host, port, code, message in
        if let host = host, let port = port {
          result([PlatformTransportChannel.keyHost: host, PlatformTransportChannel.keyPort: port])
        } else {
          result(
            FlutterError(
              code: code ?? PlatformTransportChannel.errConnectFailed,
              message: message ?? "No datapath",
              details: nil
            )
          )
        }
      }

    case PlatformTransportChannel.methodCapabilities:
      let available = engine != nil
      result([
        PlatformTransportChannel.keyCanDiscover: available,
        PlatformTransportChannel.keyCanConnect: available,
        PlatformTransportChannel.keyResumable: false,
        PlatformTransportChannel.keyBackground: false,
        PlatformTransportChannel.keyDescription:
          "Native \(engine?.fabric ?? "unavailable") transport. This build ships "
          + "the platform channel seam; on-device connectivity is scaffold-only.",
      ])

    case PlatformTransportChannel.methodDispose:
      engine?.stop()
      engine = nil
      methodChannel.setMethodCallHandler(nil)
      eventChannel.setStreamHandler(nil)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startEngine(result: @escaping FlutterResult) {
    let candidate = LocalNetworkEngine(
      host: UIDevice.current.name,
      onPeerFound: { handle, hint, host, port, rssi in
        self.emit([
          PlatformTransportChannel.keyEvent: PlatformTransportChannel.eventPeerFound,
          PlatformTransportChannel.keyHandle: handle,
          PlatformTransportChannel.keyDisplayNameHint: hint ?? NSNull(),
          PlatformTransportChannel.keyHost: host ?? NSNull(),
          PlatformTransportChannel.keyDataPort: port,
          PlatformTransportChannel.keyRssi: rssi,
          PlatformTransportChannel.keyDiscoveredAtMs:
            Int(Date().timeIntervalSince1970 * 1000),
        ])
      },
      onPeerLost: { handle in
        self.emit([
          PlatformTransportChannel.keyEvent: PlatformTransportChannel.eventPeerLost,
          PlatformTransportChannel.keyHandle: handle,
        ])
      },
      onError: { code, message in
        self.emit([
          PlatformTransportChannel.keyEvent: PlatformTransportChannel.eventError,
          PlatformTransportChannel.keyCode: code,
          PlatformTransportChannel.keyMessage: message,
        ])
      }
    )
    guard candidate.start() else {
      result(
        FlutterError(
          code: PlatformTransportChannel.errUnsupportedFeature,
          message: "Fabric \(candidate.fabric) is unavailable or scaffold-only",
          details: nil
        )
      )
      return
    }
    engine = candidate
    publishAdvertisement()
    result([
      PlatformTransportChannel.keySupported: true,
      PlatformTransportChannel.keyFabric: candidate.fabric,
      PlatformTransportChannel.keyDeviceName: UIDevice.current.name,
    ])
  }

  private func publishAdvertisement() {
    guard let current = engine else { return }
    current.updateAdvertisement(
      Advertisement(
        handle: advertisedHandle ?? current.handle,
        displayNameHint: discoverable ? displayNameHint : nil,
        ipv4: current.localIPv4,
        dataPort: dataPort
      )
    )
  }

  // MARK: - FlutterStreamHandler

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}