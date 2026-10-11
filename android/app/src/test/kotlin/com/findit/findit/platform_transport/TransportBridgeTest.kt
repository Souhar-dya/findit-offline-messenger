package com.findit.findit.platform_transport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM tests for [TransportBridge] and [Handles]. These exercise the whole
 * request/response contract (start/stop/advertise/connect/capabilities and the
 * event payloads) with a fake [TransportEngine] — no Android framework, no
 * device, no radio. The Android fabric ([WifiP2pEngine]) is exercised on real
 * hardware only.
 */
class TransportBridgeTest {

    private class FakeEngine(
        override val handle: String = "handle-1",
        override val fabric: String = TransportContract.FABRIC_WIFI_P2P,
        private val startResult: Boolean = true,
    ) : TransportEngine {
        var startCalls = 0
        var stopCalls = 0
        var connectCalls = 0
        var lastAdvertisement: Advertisement? = null
        var lastConnectHandle: String? = null
        private var connectCallback: ((String?, Int?, String?, String?) -> Unit)? = null

        override fun start(): Boolean {
            startCalls++
            return startResult
        }

        override fun updateAdvertisement(advertisement: Advertisement) {
            lastAdvertisement = advertisement
        }

        override fun connect(
            handle: String,
            onResult: (String?, Int?, String?, String?) -> Unit,
        ) {
            connectCalls++
            lastConnectHandle = handle
            connectCallback = onResult
        }

        fun completeConnect(
            host: String?,
            port: Int?,
            code: String? = null,
            msg: String? = null,
        ) {
            connectCallback?.invoke(host, port, code, msg)
        }

        override fun stop() {
            stopCalls++
        }
    }

    private class Harness(
        val engine: FakeEngine = FakeEngine(),
        private val deviceName: String? = "test-device",
        private val localAddress: String? = "192.168.0.2",
    ) {
        val emitted = mutableListOf<Map<String, Any?>>()
        var events: EngineEvents? = null
        val bridge = TransportBridge(
            emit = { emitted.add(it) },
            createEngine = { created ->
                events = created
                engine
            },
            localAddress = { localAddress },
            now = { 1_000L },
            deviceName = { deviceName },
        )
    }

    @Test
    fun `start rejects a non-positive data port`() {
        val harness = Harness()
        val result = harness.bridge.handleStart(0, "local-handle")
        val failure = result as BridgeResult.Failure
        assertEquals(TransportContract.ERR_GENERIC, failure.code)
        assertEquals(0, harness.engine.startCalls)
    }

    @Test
    fun `start reports the fabric and device name`() {
        val harness = Harness()
        val result = harness.bridge.handleStart(9_000, "local-handle")
        val value = (result as BridgeResult.Success).value as Map<*, *>
        assertEquals(true, value[TransportContract.KEY_SUPPORTED])
        assertEquals(TransportContract.FABRIC_WIFI_P2P, value[TransportContract.KEY_FABRIC])
        assertEquals("test-device", value[TransportContract.KEY_DEVICE_NAME])
        assertEquals(1, harness.engine.startCalls)
    }

    @Test
    fun `start fails honestly when no fabric can run`() {
        val harness = Harness(FakeEngine(startResult = false))
        val result = harness.bridge.handleStart(9_000, "local-handle")
        val failure = result as BridgeResult.Failure
        assertEquals(TransportContract.ERR_UNSUPPORTED_FEATURE, failure.code)
    }

    @Test
    fun `a cached advertisement is published once the engine starts`() {
        val harness = Harness()
        harness.bridge.handleUpdateAdvertisement("Alice", true)
        // Nothing to advertise to before the engine exists.
        assertNull(harness.engine.lastAdvertisement)

        harness.bridge.handleStart(9_100, "local-handle")
        val advertisement = harness.engine.lastAdvertisement!!
        assertEquals("local-handle", advertisement.handle)
        assertEquals("Alice", advertisement.displayNameHint)
        assertEquals(9_100, advertisement.dataPort)
        assertEquals("192.168.0.2", advertisement.ipv4)
        assertEquals(true, advertisement.discoverable)
    }

    @Test
    fun `start advertises the handle Dart supplies, not the native one`() {
        val harness = Harness(FakeEngine(handle = "native-generated"))
        harness.bridge.handleStart(9_000, "rotating-local")
        // Both peers must compare the same pair of handles when electing who
        // dials, so the Dart-supplied handle wins over the native one.
        assertEquals("rotating-local", harness.engine.lastAdvertisement!!.handle)
    }

    @Test
    fun `start falls back to the engine handle when Dart sends none`() {
        val harness = Harness()
        harness.bridge.handleStart(9_000, null)
        assertEquals("handle-1", harness.engine.lastAdvertisement!!.handle)
    }

    @Test
    fun `updateAdvertisement hides the hint while not discoverable`() {
        val harness = Harness()
        harness.bridge.handleStart(9_100, "local-handle")
        harness.bridge.handleUpdateAdvertisement("Bob", false)
        val advertisement = harness.engine.lastAdvertisement!!
        assertNull(advertisement.displayNameHint)
        assertEquals(false, advertisement.discoverable)
        assertEquals("local-handle", advertisement.handle)
    }

    @Test
    fun `connect returns the host and port reported by the engine`() {
        val harness = Harness()
        harness.bridge.handleStart(9_100, "local-handle")
        var response: BridgeResult? = null
        harness.bridge.handleConnect("peer-1") { response = it }
        assertEquals("peer-1", harness.engine.lastConnectHandle)

        harness.engine.completeConnect("10.0.0.5", 4_321)
        val value = (response as BridgeResult.Success).value as Map<*, *>
        assertEquals("10.0.0.5", value[TransportContract.KEY_HOST])
        assertEquals(4_321, value[TransportContract.KEY_PORT])
    }

    @Test
    fun `connect maps an engine failure to connect_failed`() {
        val harness = Harness()
        harness.bridge.handleStart(9_100, "local-handle")
        var response: BridgeResult? = null
        harness.bridge.handleConnect("peer-1") { response = it }
        harness.engine.completeConnect(null, null)
        val failure = response as BridgeResult.Failure
        assertEquals(TransportContract.ERR_CONNECT_FAILED, failure.code)
    }

    @Test
    fun `connect before start is unavailable`() {
        val harness = Harness()
        var response: BridgeResult? = null
        harness.bridge.handleConnect("peer-1") { response = it }
        val failure = response as BridgeResult.Failure
        assertEquals(TransportContract.ERR_UNAVAILABLE, failure.code)
        assertEquals(0, harness.engine.connectCalls)
    }

    @Test
    fun `connect with an empty handle is a transport error`() {
        val harness = Harness()
        harness.bridge.handleStart(9_100, "local-handle")
        var response: BridgeResult? = null
        harness.bridge.handleConnect("") { response = it }
        val failure = response as BridgeResult.Failure
        assertEquals(TransportContract.ERR_GENERIC, failure.code)
        assertEquals(0, harness.engine.connectCalls)
    }

    @Test
    fun `capabilities track whether the transport is running`() {
        val harness = Harness()
        val before = (harness.bridge.capabilities() as BridgeResult.Success).value as Map<*, *>
        assertEquals(false, before[TransportContract.KEY_CAN_DISCOVER])
        assertEquals(false, before[TransportContract.KEY_CAN_CONNECT])
        assertEquals(false, before[TransportContract.KEY_RESUMABLE])

        harness.bridge.handleStart(9_100, "local-handle")
        val after = harness.bridge.capabilities() as BridgeResult.Success
        val value = after.value as Map<*, *>
        assertEquals(true, value[TransportContract.KEY_CAN_DISCOVER])
        assertEquals(true, value[TransportContract.KEY_CAN_CONNECT])
        assertEquals(true, (value[TransportContract.KEY_DESCRIPTION] as String).contains("wifi-p2p"))
        assertEquals(true, (before[TransportContract.KEY_DESCRIPTION] as String).contains("unavailable"))
    }

    @Test
    fun `peerFound events are forwarded as channel maps`() {
        val harness = Harness()
        harness.bridge.handleStart(9_100, "local-handle")
        harness.events!!.onPeerFound("peer-1", "Alice", null, 4_321, -42)

        val event = harness.emitted.last()
        assertEquals(TransportContract.EVENT_PEER_FOUND, event[TransportContract.EVENT])
        assertEquals("peer-1", event[TransportContract.KEY_HANDLE])
        assertEquals("Alice", event[TransportContract.KEY_DISPLAY_HINT])
        assertNull(event[TransportContract.KEY_HOST])
        assertEquals(4_321, event[TransportContract.KEY_DATA_PORT])
        assertEquals(-42, event[TransportContract.KEY_RSSI])
        assertEquals(1_000L, event[TransportContract.KEY_DISCOVERED_AT_MS])
    }

    @Test
    fun `peerLost and error events are forwarded as channel maps`() {
        val harness = Harness()
        harness.bridge.handleStart(9_100, "local-handle")
        harness.events!!.onPeerLost("peer-9")
        harness.events!!.onError(TransportContract.ERR_UNAVAILABLE, "nope")

        val lost = harness.emitted[harness.emitted.size - 2]
        assertEquals(TransportContract.EVENT_PEER_LOST, lost[TransportContract.EVENT])
        assertEquals("peer-9", lost[TransportContract.KEY_HANDLE])

        val error = harness.emitted.last()
        assertEquals(TransportContract.EVENT_ERROR, error[TransportContract.EVENT])
        assertEquals(TransportContract.ERR_UNAVAILABLE, error[TransportContract.KEY_CODE])
        assertEquals("nope", error[TransportContract.KEY_MESSAGE])
    }

    @Test
    fun `stop and dispose stop the engine`() {
        val harness = Harness()
        harness.bridge.handleStart(9_100, "local-handle")
        harness.bridge.handleStop()
        assertEquals(1, harness.engine.stopCalls)

        val capabilities = harness.bridge.capabilities() as BridgeResult.Success
        assertEquals(false, (capabilities.value as Map<*, *>)[TransportContract.KEY_CAN_DISCOVER])

        harness.bridge.handleStart(9_100, "local-handle")
        harness.bridge.dispose()
        assertEquals(2, harness.engine.stopCalls)
    }

    @Test
    fun `handles are unique lowercase hex tokens`() {
        val seen = mutableSetOf<String>()
        repeat(1_000) {
            val handle = Handles.next()
            assertEquals(16, handle.length)
            assertEquals(true, handle.all { it in "0123456789abcdef" })
            assertEquals(true, seen.add(handle))
        }
    }
}
