package com.findit.findit.platform_transport

import java.security.SecureRandom

/** Callbacks the engine uses to push events toward Dart (via the bridge). */
class EngineEvents(
    val onPeerFound: (handle: String, displayNameHint: String?, host: String?, dataPort: Int, rssi: Int) -> Unit,
    val onPeerLost: (handle: String) -> Unit,
    val onError: (code: String, message: String) -> Unit,
)

/** What this device advertises: an opaque handle + an optional display hint. */
class Advertisement(
    val handle: String,
    val displayNameHint: String?,
    val ipv4: String?,
    val dataPort: Int,
    val discoverable: Boolean,
)

/** Connectivity fabric interface; implemented by Wi-Fi P2P and Wi-Fi Aware. */
interface TransportEngine {
    /** Rotating, ephemeral handle used in advertisements. Never a real id. */
    val handle: String

    /** One of [TransportContract.FABRIC_WIFI_P2P] etc. */
    val fabric: String

    /**
     * Starts discovery + advertisement. Returns false (and reports a precise
     * code/message through [EngineEvents.onError]) when this fabric cannot run.
     * The channel must NEVER fall through to a fake "connected" state.
     */
    fun start(): Boolean

    /** Publishes the current advertisement state. */
    fun updateAdvertisement(advertisement: Advertisement)

    /**
     * Brings up a datapath to the peer advertising [handle]. On success calls
     * onResult(host, port, null, null); otherwise onResult(null, null, code,
     * msg). Never synthesizes an endpoint it did not actually establish.
     */
    fun connect(handle: String, onResult: (host: String?, port: Int?, code: String?, msg: String?) -> Unit)

    fun stop()
}

/**
 * Rotating opaque handle generator. Hex (lowercase) so it is pure JVM code
 * that unit tests can exercise without Android stubs, and so it is URL/DB safe.
 */
object Handles {
    private val random = SecureRandom()
    private const val HEX = "0123456789abcdef"

    /** 8 random bytes rendered as 16 lowercase hex characters. */
    fun next(): String {
        val bytes = ByteArray(8)
        random.nextBytes(bytes)
        val out = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            out.append(HEX[v ushr 4]).append(HEX[v and 0x0F])
        }
        return out.toString()
    }
}
