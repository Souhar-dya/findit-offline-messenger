package com.findit.findit.platform_transport

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Thin adapter between the Flutter platform channels and [TransportBridge].
 *
 * All request/response and discovery logic lives in [TransportBridge] (pure JVM,
 * unit tested). This class only wires the channel plumbing and the Android
 * fabric ([WifiP2pEngine]).
 *
 * Wire contract: `lib/transport/platform_transport_contract.dart` (Dart),
 * this file (Android) and `PlatformTransportChannel.swift` (iOS) must stay in
 * sync; shared names live in [TransportContract].
 *
 * Privacy: only a rotating handle, an optional display hint and a TCP dataPort
 * ever cross the channel. The permanent identity id is NEVER exposed to native
 * code.
 */
class PlatformTransportChannel private constructor(
    context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        /** Registers the channel on [messenger]. Call from MainActivity. */
        fun register(context: Context, messenger: BinaryMessenger) {
            PlatformTransportChannel(context.applicationContext, messenger)
        }
    }

    private val appContext: Context = context.applicationContext
    private val methodChannel = MethodChannel(messenger, TransportContract.CHANNEL)
    private val eventChannel = EventChannel(messenger, TransportContract.EVENTS_CHANNEL)

    private var eventSink: EventChannel.EventSink? = null

    private val bridge = TransportBridge(
        emit = { payload -> eventSink?.success(payload) },
        createEngine = { events -> WifiP2pEngine(appContext, events) },
        localAddress = { localIpv4() },
        deviceName = { Build.MODEL },
    )

    init {
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            TransportContract.METHOD_START -> {
                val port = call.argument<Number>(TransportContract.KEY_DATA_PORT)?.toInt() ?: 0
                val handle = call.argument<String>(TransportContract.KEY_HANDLE)
                result.respond(bridge.handleStart(port, handle))
            }

            TransportContract.METHOD_STOP -> result.respond(bridge.handleStop())

            TransportContract.METHOD_UPDATE_ADVERTISEMENT -> {
                val hint = call.argument<String>(TransportContract.KEY_DISPLAY_HINT)
                val discoverable =
                    call.argument<Boolean>(TransportContract.KEY_DISCOVERABLE) ?: true
                result.respond(bridge.handleUpdateAdvertisement(hint, discoverable))
            }

            TransportContract.METHOD_CONNECT -> {
                val handle = call.argument<String>(TransportContract.KEY_HANDLE) ?: ""
                bridge.handleConnect(handle) { response -> result.respond(response) }
            }

            TransportContract.METHOD_CAPABILITIES -> result.respond(bridge.capabilities())

            TransportContract.METHOD_DISPOSE -> {
                bridge.dispose()
                methodChannel.setMethodCallHandler(null)
                eventChannel.setStreamHandler(null)
                result.success(null)
            }

            TransportContract.METHOD_IS_WIFI_ENABLED -> {
                val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                result.success(mapOf("enabled" to wifiManager.isWifiEnabled))
            }

            TransportContract.METHOD_REQUEST_WIFI_ENABLE -> {
                val intent = android.content.Intent(android.provider.Settings.Panel.ACTION_WIFI)
                intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                appContext.startActivity(intent)
                result.success(mapOf("enabled" to true))
            }

            TransportContract.METHOD_CHECK_PERMISSIONS -> {
                val missing = mutableListOf<String>()
                val locationPermission = if (android.os.Build.VERSION.SDK_INT >= 33) {
                    android.Manifest.permission.NEARBY_WIFI_DEVICES
                } else {
                    android.Manifest.permission.ACCESS_FINE_LOCATION
                }
                if (appContext.checkSelfPermission(locationPermission) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    missing.add(locationPermission)
                }
                result.success(mapOf("granted" to missing.isEmpty(), "missing" to missing))
            }

            TransportContract.METHOD_REQUEST_PERMISSIONS -> {
                val locationPermission = if (android.os.Build.VERSION.SDK_INT >= 33) {
                    android.Manifest.permission.NEARBY_WIFI_DEVICES
                } else {
                    android.Manifest.permission.ACCESS_FINE_LOCATION
                }
                val granted = appContext.checkSelfPermission(locationPermission) == android.content.pm.PackageManager.PERMISSION_GRANTED
                result.success(mapOf("granted" to granted))
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    private fun localIpv4(): String? {
        return try {
            NetworkInterface.getNetworkInterfaces()
                .toList()
                .asSequence()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList().asSequence() }
                .firstOrNull { address -> address is Inet4Address && !address.isLoopbackAddress }
                ?.hostAddress
        } catch (_: Exception) {
            null
        }
    }
}

private fun MethodChannel.Result.respond(result: BridgeResult) {
    when (result) {
        is BridgeResult.Success -> success(result.value)
        is BridgeResult.Failure -> error(result.code, result.message, null)
        BridgeResult.NotImplemented -> notImplemented()
    }
}
