package com.findit.findit.platform_transport

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import com.findit.findit.networking.NetworkingService
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
 * Runtime permissions: Wi-Fi Direct discovery needs a dangerous permission
 * (NEARBY_WIFI_DEVICES on Android 13+, ACCESS_FINE_LOCATION below). That request
 * MUST come from an Activity, so this class keeps a reference to the hosting
 * activity and surfaces the result back to Dart through [onRequestPermissionsResult].
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
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private var instance: PlatformTransportChannel? = null

        /** Request code for the runtime permission dialog. */
        private const val REQUEST_CODE_PERMISSIONS = 0xF1D1

        /**
         * Creates and installs the channel. Call from the Activity's
         * `configureFlutterEngine`.
         */
        fun install(activity: Activity, messenger: BinaryMessenger) {
            instance = PlatformTransportChannel(activity, messenger)
        }

        /**
         * Forwards the Activity permission result back to the pending Dart call.
         * Returns true when the result belonged to this plugin.
         */
        fun onRequestPermissionsResult(
            requestCode: Int,
            grantResults: IntArray,
        ): Boolean = instance?.handlePermissionResult(requestCode, grantResults) ?: false
    }

    private val appContext: Context = activity.applicationContext
    private val methodChannel = MethodChannel(messenger, TransportContract.CHANNEL)
    private val eventChannel = EventChannel(messenger, TransportContract.EVENTS_CHANNEL)

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var eventSink: EventChannel.EventSink? = null

    private val bridge = TransportBridge(
        emit = { event -> eventSink?.success(event) },
        createEngine = { events -> WifiP2pEngine(appContext, events) },
        localAddress = { localIpv4() },
        deviceName = { Build.MODEL },
        supportsBackground = { true },
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
                val outcome = bridge.handleStart(port, handle)
                // Keep the process alive in the background only while the radio
                // is actually running.
                if (outcome is BridgeResult.Success) {
                    NetworkingService.start(appContext)
                }
                result.respond(outcome)
            }

            TransportContract.METHOD_STOP -> {
                NetworkingService.stop(appContext)
                result.respond(bridge.handleStop())
            }

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
                NetworkingService.stop(appContext)
                bridge.dispose()
                methodChannel.setMethodCallHandler(null)
                eventChannel.setStreamHandler(null)
                instance = null
                result.success(null)
            }

            TransportContract.METHOD_IS_WIFI_ENABLED -> {
                val wifiManager =
                    appContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
                result.success(mapOf("enabled" to wifiManager.isWifiEnabled))
            }

            TransportContract.METHOD_REQUEST_WIFI_ENABLE -> {
                val intent = Intent(Settings.Panel.ACTION_WIFI)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                appContext.startActivity(intent)
                result.success(mapOf("enabled" to true))
            }

            TransportContract.METHOD_CHECK_PERMISSIONS -> {
                val missing = requiredPermissions().filter { !isGranted(it) }
                result.success(
                    mapOf("granted" to missing.isEmpty(), "missing" to missing),
                )
            }

            TransportContract.METHOD_REQUEST_PERMISSIONS -> {
                // Required permissions gate the app. POST_NOTIFICATIONS is only
                // for the background-service notification, so a denial must not
                // block networking.
                val toRequest = (requiredPermissions() + optionalPermissions())
                    .filter { !isGranted(it) }
                if (toRequest.isEmpty()) {
                    result.success(mapOf("granted" to true))
                    return
                }
                // Android only allows permission requests from an Activity.
                pendingPermissionResult?.error(
                    "permission_in_progress",
                    "A permission request is already in progress",
                    null,
                )
                pendingPermissionResult = result
                activity.requestPermissions(
                    toRequest.toTypedArray(),
                    REQUEST_CODE_PERMISSIONS,
                )
            }

            TransportContract.METHOD_OPEN_APP_SETTINGS -> {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", appContext.packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                appContext.startActivity(intent)
                result.success(null)
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

    private fun handlePermissionResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != REQUEST_CODE_PERMISSIONS) return false
        val result = pendingPermissionResult ?: return false
        pendingPermissionResult = null
        // Only the required set gates the app; an ignored notification prompt
        // must not be reported as a denied networking permission.
        val granted = requiredPermissions().all { isGranted(it) }
        result.success(mapOf("granted" to granted))
        return true
    }

    /** Dangerous permissions Wi-Fi Direct discovery needs on this OS version. */
    private fun requiredPermissions(): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return emptyList()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.NEARBY_WIFI_DEVICES)
        } else {
            listOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            )
        }
    }

    /** Nice-to-have permissions; not granted means a feature degrades, not fails. */
    private fun optionalPermissions(): List<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return emptyList()
        return listOf(Manifest.permission.POST_NOTIFICATIONS)
    }

    private fun isGranted(permission: String): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
            appContext.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

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
