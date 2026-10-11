package com.findit.findit.platform_transport

/** Outcome of a transport method call, free of Flutter/Android types. */
sealed class BridgeResult {
    class Success(val value: Any?) : BridgeResult()
    class Failure(val code: String, val message: String) : BridgeResult()
    object NotImplemented : BridgeResult()
}

/**
 * All request/response logic of the platform transport, deliberately free of
 * Flutter and Android types so it can be unit tested on the JVM. The channel
 * is a thin adapter that maps channel calls onto this and forwards events.
 *
 * The engine is created lazily by [createEngine] the first time [handleStart]
 * runs. [emit] receives the raw event maps destined for the Dart event channel.
 */
class TransportBridge(
    private val emit: (Map<String, Any?>) -> Unit,
    private val createEngine: (EngineEvents) -> TransportEngine,
    private val localAddress: () -> String? = { null },
    private val now: () -> Long = { System.currentTimeMillis() },
    private val deviceName: () -> String? = { null },
) {
    private var engine: TransportEngine? = null
    private var dataPort: Int = 0
    private var advertisedHandle: String? = null
    private var displayNameHint: String? = null
    private var discoverable: Boolean = true

    /** Fabric of the currently running engine, or null when not started. */
    val fabric: String? get() = engine?.fabric

    fun handleStart(dataPortArg: Int, localHandle: String?): BridgeResult {
        dataPort = dataPortArg
        if (dataPort <= 0) {
            return BridgeResult.Failure(TransportContract.ERR_GENERIC, "dataPort must be > 0")
        }
        if (!localHandle.isNullOrEmpty()) {
            // Dart owns the advertised handle so both peers compare the same
            // pair when electing who dials (see RoutingEngine._shouldInitiate).
            advertisedHandle = localHandle
        }
        engine?.let { current ->
            return BridgeResult.Success(
                mapOf(
                    TransportContract.KEY_SUPPORTED to true,
                    TransportContract.KEY_FABRIC to current.fabric,
                    TransportContract.KEY_DEVICE_NAME to deviceName(),
                ),
            )
        }
        val candidate = createEngine(engineEvents())
        if (!candidate.start()) {
            // The engine reports a precise code/message through events first;
            // surface the same failure to Dart so the UI is honest.
            return BridgeResult.Failure(
                TransportContract.ERR_UNSUPPORTED_FEATURE,
                "Fabric ${candidate.fabric} is unavailable or scaffold-only",
            )
        }
        engine = candidate
        publishAdvertisement()
        return BridgeResult.Success(
            mapOf(
                TransportContract.KEY_SUPPORTED to true,
                TransportContract.KEY_FABRIC to candidate.fabric,
                TransportContract.KEY_DEVICE_NAME to deviceName(),
            ),
        )
    }

    fun handleStop(): BridgeResult {
        engine?.stop()
        engine = null
        return BridgeResult.Success(null)
    }

    fun handleUpdateAdvertisement(hint: String?, discoverableArg: Boolean): BridgeResult {
        displayNameHint = hint
        discoverable = discoverableArg
        publishAdvertisement()
        return BridgeResult.Success(null)
    }

    fun handleConnect(handle: String, onResult: (BridgeResult) -> Unit) {
        if (handle.isEmpty()) {
            onResult(BridgeResult.Failure(TransportContract.ERR_GENERIC, "handle missing"))
            return
        }
        val current = engine
        if (current == null) {
            onResult(BridgeResult.Failure(TransportContract.ERR_UNAVAILABLE, "Transport not started"))
            return
        }
        current.connect(handle) { host, port, code, msg ->
            when {
                !host.isNullOrEmpty() && port != null && port > 0 -> onResult(
                    BridgeResult.Success(
                        mapOf(
                            TransportContract.KEY_HOST to host,
                            TransportContract.KEY_PORT to port,
                        ),
                    ),
                )
                else -> onResult(
                    BridgeResult.Failure(
                        code ?: TransportContract.ERR_CONNECT_FAILED,
                        msg ?: "No datapath",
                    ),
                )
            }
        }
    }

    fun capabilities(): BridgeResult {
        val running = engine != null
        return BridgeResult.Success(
            mapOf(
                TransportContract.KEY_CAN_DISCOVER to running,
                TransportContract.KEY_CAN_CONNECT to running,
                TransportContract.KEY_RESUMABLE to false,
                TransportContract.KEY_BACKGROUND to false,
                TransportContract.KEY_DESCRIPTION to
                    "Native ${engine?.fabric ?: "unavailable"} transport. Requires both devices " +
                    "within Wi-Fi range and on the same direct group.",
            ),
        )
    }

    fun dispose() {
        engine?.stop()
        engine = null
    }

    private fun publishAdvertisement() {
        val current = engine ?: return
        current.updateAdvertisement(
            Advertisement(
                handle = advertisedHandle ?: current.handle,
                displayNameHint = if (discoverable) displayNameHint else null,
                ipv4 = localAddress(),
                dataPort = dataPort,
                discoverable = discoverable,
            ),
        )
    }

    private fun engineEvents(): EngineEvents = EngineEvents(
        onPeerFound = { handle, hint, host, port, rssi ->
            emit(
                mapOf(
                    TransportContract.EVENT to TransportContract.EVENT_PEER_FOUND,
                    TransportContract.KEY_HANDLE to handle,
                    TransportContract.KEY_DISPLAY_HINT to hint,
                    TransportContract.KEY_HOST to host,
                    TransportContract.KEY_DATA_PORT to port,
                    TransportContract.KEY_RSSI to rssi,
                    TransportContract.KEY_DISCOVERED_AT_MS to now(),
                ),
            )
        },
        onPeerLost = { handle ->
            emit(
                mapOf(
                    TransportContract.EVENT to TransportContract.EVENT_PEER_LOST,
                    TransportContract.KEY_HANDLE to handle,
                ),
            )
        },
        onError = { code, message ->
            emit(
                mapOf(
                    TransportContract.EVENT to TransportContract.EVENT_ERROR,
                    TransportContract.KEY_CODE to code,
                    TransportContract.KEY_MESSAGE to message,
                ),
            )
        },
    )
}
