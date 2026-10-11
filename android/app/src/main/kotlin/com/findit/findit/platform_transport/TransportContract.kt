package com.findit.findit.platform_transport

/**
 * Exact wire contract shared with Dart
 * (`lib/transport/platform_transport_contract.dart`) and the iOS
 * `PlatformTransportChannel.swift`. All three must stay in sync.
 *
 * Kept dependency-free (no Android/Flutter types) so the transport logic and
 * these names can be unit tested on the JVM.
 */
object TransportContract {
    // Channel names (mirror PlatformChannelNames).
    const val CHANNEL = "findit/transport"
    const val EVENTS_CHANNEL = "findit/transport/events"

    // Methods (mirror PlatformMethodNames).
    const val METHOD_START = "start"
    const val METHOD_STOP = "stop"
    const val METHOD_UPDATE_ADVERTISEMENT = "updateAdvertisement"
    const val METHOD_CONNECT = "connect"
    const val METHOD_CAPABILITIES = "getCapabilities"
    const val METHOD_DISPOSE = "dispose"
    const val METHOD_IS_WIFI_ENABLED = "isWifiEnabled"
    const val METHOD_REQUEST_WIFI_ENABLE = "requestWifiEnable"
    const val METHOD_CHECK_PERMISSIONS = "checkPermissions"
    const val METHOD_REQUEST_PERMISSIONS = "requestPermissions"

    // Event names (mirror PlatformEventNames).
    const val EVENT = "event"
    const val EVENT_PEER_FOUND = "peerFound"
    const val EVENT_PEER_LOST = "peerLost"
    const val EVENT_ERROR = "error"

    // Payload keys (mirror PlatformPayloadKeys).
    const val KEY_HANDLE = "handle"
    const val KEY_DISPLAY_HINT = "displayNameHint"
    const val KEY_DISCOVERABLE = "discoverable"
    const val KEY_HOST = "host"
    const val KEY_DATA_PORT = "dataPort"
    const val KEY_PORT = "port"
    const val KEY_RSSI = "rssi"
    const val KEY_DISCOVERED_AT_MS = "discoveredAtMs"
    const val KEY_SUPPORTED = "supported"
    const val KEY_FABRIC = "fabric"
    const val KEY_DEVICE_NAME = "deviceName"
    const val KEY_CAN_DISCOVER = "canDiscover"
    const val KEY_CAN_CONNECT = "canConnect"
    const val KEY_RESUMABLE = "supportsResumableTransfer"
    const val KEY_BACKGROUND = "supportsBackground"
    const val KEY_DESCRIPTION = "description"
    const val KEY_CODE = "code"
    const val KEY_MESSAGE = "message"

    // Error codes (mirror PlatformErrorCodes).
    const val ERR_UNAVAILABLE = "unavailable"
    const val ERR_UNSUPPORTED_FEATURE = "unsupported_feature"
    const val ERR_PERMISSION_DENIED = "permission_denied"
    const val ERR_CONNECT_FAILED = "connect_failed"
    const val ERR_GENERIC = "transport_error"

    // Fabrics (mirror PlatformFabrics).
    const val FABRIC_WIFI_P2P = "wifi-p2p"
    const val FABRIC_WIFI_AWARE = "wifi-aware"
    const val FABRIC_LOCAL_NETWORK = "local-network"
}
