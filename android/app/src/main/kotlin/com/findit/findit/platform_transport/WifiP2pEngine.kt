package com.findit.findit.platform_transport

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * Wi-Fi Direct (Wi-Fi P2P) connectivity fabric.
 *
 * Responsibilities (nothing else — all protocol stays in Dart over TCP):
 *  1. Discover nearby FindIt peers over Wi-Fi Direct DNS-SD.
 *  2. Advertise this device's opaque handle + Dart `dataPort` + display hint via
 *     Wi-Fi Direct DNS-SD ([WifiP2pDnsSdServiceInfo]) so a peer that discovers
 *     us learns where to connect.
 *  3. Bring up a group on `connect(handle)` and resolve the peer's reachable
 *     IPv4 + its advertised data port.
 *
 * Privacy: advertisements carry only the rotating handle Dart supplies, an
 * optional display hint and the data port. The permanent identity id is never
 * used. Wi-Fi Direct exposes the device MAC to the OS layer, but the MAC is
 * never forwarded to Dart — peers are addressed only by the handle they
 * advertise.
 *
 * The advertised handle comes from Dart (`start(handle = localId)`), not from
 * native, so both peers compare the same pair of handles when deciding who
 * dials (see RoutingEngine._shouldInitiate). Peers are reported only once their
 * advertised handle is known, so Dart never sees a handle the peer did not
 * choose.
 *
 * VERIFICATION: validated on two physical devices (Samsung SM-G990E and
 * Motorola Edge 60 Pro, Android 14/15): mutual discovery over DNS-SD, group
 * formation, the handshake and two-way text/image delivery with receipts all
 * work. The emulator cannot exercise this path — it does not emulate the P2P
 * radio — so re-validate on hardware after changing this file.
 */
@SuppressLint("MissingPermission", "DEPRECATION")
class WifiP2pEngine(
    private val context: Context,
    private val events: EngineEvents,
) : TransportEngine {

    override val handle: String = Handles.next()
    override val fabric: String = TransportContract.FABRIC_WIFI_P2P

    private val p2p: WifiP2pManager? =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager

    private var channel: WifiP2pManager.Channel? = null
    private var receiver: BroadcastReceiver? = null
    private var running = false

    // Fails a connect() whose Wi-Fi Direct group never forms.
    private var connectTimeoutTask: Runnable? = null

    private var localService: WifiP2pDnsSdServiceInfo? = null

    // Per-session mapping from the handle a peer advertised to its device MAC.
    // Peers are addressed only by that advertised handle; the MAC is never
    // handed to Dart.
    private val addressByHandle = ConcurrentHashMap<String, String>()

    // What peers advertised to us (populated from DNS-SD).
    private val portByAddress = ConcurrentHashMap<String, Int>()
    private val hintByAddress = ConcurrentHashMap<String, String>()

    // Reverse of [addressByHandle]: the handle a peer advertised, by device MAC.
    // Needed when this device is invited into a group: WifiP2pGroup only reports
    // the owner's MAC address, not the handle it advertised.
    private val handleByAddress = ConcurrentHashMap<String, String>()

    // The initiator's in-flight connect().
    private var pendingAddress: String? = null
    private var pendingResult: ((String?, Int?, String?, String?) -> Unit)? = null

    override fun start(): Boolean {
        val p2p = this.p2p
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT) || p2p == null) {
            Log.e(TAG, "start: this device does not support Wi-Fi Direct")
            events.onError(TransportContract.ERR_UNAVAILABLE, "This device does not support Wi-Fi Direct")
            return false
        }
        val wifi = context.getSystemService(WifiManager::class.java)
        if (wifi == null || !wifi.isWifiEnabled) {
            Log.e(TAG, "start: Wi-Fi is off")
            events.onError(TransportContract.ERR_UNAVAILABLE, "Wi-Fi is off")
            return false
        }
        Log.d(TAG, "start: opening Wi-Fi Direct channel")
        val channel = p2p.initialize(
            context,
            Looper.getMainLooper(),
            WifiP2pManager.ChannelListener {
                running = false
                Log.e(TAG, "start: Wi-Fi Direct channel lost")
                events.onError(TransportContract.ERR_UNAVAILABLE, "Wi-Fi Direct channel lost")
            },
        )
        if (channel == null) {
            Log.e(TAG, "start: could not open a Wi-Fi Direct channel")
            events.onError(TransportContract.ERR_UNAVAILABLE, "Could not open a Wi-Fi Direct channel")
            return false
        }
        this.channel = channel
        running = true
        registerReceiver()
        // A group left behind by a previous run (a crash, a force-stop, a swipe
        // away) blocks discovery and would strand this device as a group owner
        // that nobody dials. Drop it before starting over.
        p2p.requestConnectionInfo(channel) { info ->
            if (info.groupFormed) {
                Log.d(TAG, "start: removing a leftover Wi-Fi Direct group")
                p2p.removeGroup(channel, actionListener("removeLeftoverGroup"))
            }
        }
        configureServiceDiscovery(channel)
        p2p.discoverPeers(channel, actionListener("discoverPeers"))
        startRediscovery()
        // The local advertisement is published once Dart sends an advertisement
        // carrying a valid dataPort (see updateAdvertisement).
        Log.d(TAG, "start: discovery is running")
        return true
    }

    override fun updateAdvertisement(advertisement: Advertisement) {
        val channel = this.channel ?: return
        val p2p = this.p2p ?: return

        // Re-publish the local DNS-SD service with the current handle/port/hint.
        localService?.let { service ->
            p2p.removeLocalService(channel, service, actionListener("removeLocalService"))
        }
        localService = null
        if (!advertisement.discoverable || advertisement.dataPort <= 0) return

        val advertised = advertisement.handle.ifEmpty { handle }
        val txt = mutableMapOf(
            "h" to advertised,
            "p" to advertisement.dataPort.toString(),
        )
        advertisement.displayNameHint?.let { txt["d"] = it }
        Log.d(TAG, "advertise: handle=$advertised port=${advertisement.dataPort} hint=${advertisement.displayNameHint}")
        val service = WifiP2pDnsSdServiceInfo.newInstance(advertised, SERVICE_TYPE, txt)
        localService = service
        p2p.addLocalService(channel, service, actionListener("addLocalService"))
    }

    override fun connect(
        handle: String,
        onResult: (host: String?, port: Int?, code: String?, msg: String?) -> Unit,
    ) {
        val p2p = this.p2p
        val channel = this.channel
        if (!running || p2p == null || channel == null) {
            onResult(null, null, TransportContract.ERR_CONNECT_FAILED, "Transport is not running")
            return
        }
        Log.d(TAG, "connect: peer=$handle")
        val address = addressByHandle[handle]
        if (address == null) {
            Log.e(TAG, "connect: unknown peer handle $handle")
            onResult(null, null, TransportContract.ERR_CONNECT_FAILED, "Unknown peer handle")
            return
        }
        val port = portByAddress[address] ?: 0
        if (port <= 0) {
            onResult(
                null,
                null,
                TransportContract.ERR_CONNECT_FAILED,
                "Peer did not advertise a reachable data port",
            )
            return
        }
        p2p.requestConnectionInfo(channel) { info ->
            val owner = info.groupOwnerAddress?.hostAddress
            if (info.groupFormed && !info.isGroupOwner && !owner.isNullOrEmpty()) {
                // Already in a group we do not own; the group owner is the peer.
                onResult(owner, port, null, null)
                return@requestConnectionInfo
            }
            if (info.groupFormed && info.isGroupOwner) {
                // We already own a group. Re-running connect() would tear the
                // existing group down, and only a client can dial, so there is
                // nothing to initiate: the peer reaches us.
                onResult(
                    null,
                    null,
                    TransportContract.ERR_CONNECT_FAILED,
                    "This device already owns the Wi-Fi Direct group; the peer dials us",
                )
                return@requestConnectionInfo
            }
            pendingAddress = address
            pendingResult = onResult
            val config = WifiP2pConfig().apply {
                deviceAddress = address
                // A hint only: negotiation may still elect this device as the
                // group owner, which is fine because the client is always the
                // side that dials (see onConnectionInfo).
                groupOwnerIntent = 0
            }
            p2p.connect(
                channel,
                config,
                object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        Log.d(TAG, "connect: p2p.connect() accepted; waiting for group formation")
                        // Group formation continues via CONNECTION_CHANGED. Guard
                        // it so a peer that never joins cannot hang connect().
                        scheduleConnectTimeout()
                    }

                    override fun onFailure(reason: Int) {
                        Log.e(TAG, "connect: p2p.connect() failed reason=$reason")
                        resolvePending(
                            null,
                            null,
                            TransportContract.ERR_CONNECT_FAILED,
                            "Wi-Fi Direct connect failed ($reason)",
                        )
                    }
                },
            )
        }
    }

    override fun stop() {
        Log.d(TAG, "stop: discovery shutting down")
        running = false
        stopRediscovery()
        resolvePending(null, null, TransportContract.ERR_CONNECT_FAILED, "Transport stopped")

        receiver?.let { r -> runCatching { context.unregisterReceiver(r) } }
        receiver = null

        val channel = this.channel
        val p2p = this.p2p
        if (channel != null && p2p != null) {
            localService?.let { service ->
                runCatching { p2p.removeLocalService(channel, service, null) }
            }
            runCatching { p2p.clearLocalServices(channel, null) }
            runCatching { p2p.cancelConnect(channel, null) }
            runCatching { p2p.removeGroup(channel, null) }
        }
        localService = null
        addressByHandle.clear()
        portByAddress.clear()
        hintByAddress.clear()
        handleByAddress.clear()
    }

    // --- discovery + group formation -----------------------------------------

    private fun registerReceiver() {
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                        val state = intent.getIntExtra(
                            WifiP2pManager.EXTRA_WIFI_STATE,
                            WifiP2pManager.WIFI_P2P_STATE_DISABLED,
                        )
                        if (state != WifiP2pManager.WIFI_P2P_STATE_ENABLED && running) {
                            events.onError(TransportContract.ERR_UNAVAILABLE, "Wi-Fi Direct was disabled")
                        }
                    }

                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION ->
                        onConnectionChanged(intent)
                }
            }
        }
        receiver = r
        context.registerReceiver(r, filter)
    }

    private fun configureServiceDiscovery(channel: WifiP2pManager.Channel) {
        val p2p = this.p2p ?: return
        p2p.setDnsSdResponseListeners(
            channel,
            // Service available: remember the advertised handle (the instance
            // name). The richer TXT record below carries the port + hint and is
            // what actually announces the peer.
            WifiP2pManager.DnsSdServiceResponseListener { instanceName, _, device ->
                val address = device?.deviceAddress ?: return@DnsSdServiceResponseListener
                if (!instanceName.isNullOrEmpty()) {
                    rememberPeer(address, normalizeHandle(instanceName))
                }
            },
            // TXT carries the peer handle ("h"), data port ("p") and hint ("d").
            WifiP2pManager.DnsSdTxtRecordListener { _, txt, device ->
                val address = device?.deviceAddress ?: return@DnsSdTxtRecordListener
                txt["p"]?.toIntOrNull()?.let { portByAddress[address] = it }
                txt["d"]?.let { hintByAddress[address] = it }
                val advertised = txt["h"]?.let { normalizeHandle(it) }?.takeIf { it.isNotEmpty() }
                Log.d(TAG, "DNS-SD TXT: h=${txt["h"]} p=${txt["p"]} d=${txt["d"]}")
                if (advertised == null) return@DnsSdTxtRecordListener
                rememberPeer(address, advertised)
                events.onPeerFound(
                    advertised,
                    hintByAddress[address],
                    null,
                    portByAddress[address] ?: 0,
                    0,
                )
            },
        )
        p2p.addServiceRequest(
            channel,
            WifiP2pDnsSdServiceRequest.newInstance(),
            actionListener("addServiceRequest"),
        )
        p2p.discoverServices(channel, actionListener("discoverServices"))
    }

    private fun rememberPeer(address: String, advertised: String) {
        addressByHandle[advertised] = address
        handleByAddress[address] = advertised
    }

    /**
     * Base64 padding does not survive the DNS-SD TXT round-trip, so it must not
     * survive the instance-name one either. Without this the same peer is
     * remembered under two handles ("abc=" and "abc"), which opens two sessions
     * to one device and makes the deterministic dial tie-break compare
     * different strings on the two devices.
     */
    private fun normalizeHandle(advertised: String): String = advertised.trimEnd('=')

    private fun onConnectionChanged(intent: Intent) {
        // Do NOT read EXTRA_NETWORK_INFO: it is deprecated and returns null on
        // Android 10+, which used to make this bail out and leave connect()
        // hanging forever. Always ask the manager for the authoritative state.
        val channel = this.channel ?: return
        val p2p = this.p2p ?: return
        Log.d(TAG, "WIFI_P2P_CONNECTION_CHANGED_ACTION -> requestConnectionInfo")
        p2p.requestConnectionInfo(channel) { info -> onConnectionInfo(info) }
    }

    private fun onConnectionInfo(info: WifiP2pInfo) {
        Log.d(
            TAG,
            "onConnectionInfo: groupFormed=${info.groupFormed} " +
                "isGroupOwner=${info.isGroupOwner} " +
                "owner=${info.groupOwnerAddress?.hostAddress} " +
                "pending=$pendingAddress",
        )
        if (!info.groupFormed) {
            // A group that is still forming reports groupFormed=false, and the
            // formed state only arrives in a later broadcast. Treating that as
            // "the group closed" failed connect() the instant it was requested,
            // so the datapath was only ever rescued by the client-dial path.
            // Wait instead: connect() has its own timeout for a peer that never
            // shows up.
            Log.d(TAG, "onConnectionInfo: no group yet (pending=${pendingAddress != null})")
            return
        }
        val p2p = this.p2p
        val channel = this.channel
        if (p2p == null || channel == null) return

        // Only the *client* of a Wi-Fi Direct group can learn the other side's
        // IPv4 address (WifiP2pInfo.groupOwnerAddress). A group owner cannot
        // discover a client's address through the public API, so the client is
        // always the side that dials and the owner always waits for the inbound
        // connection. That keeps the datapath deterministic no matter which side
        // requested the group (negotiation does not always honour
        // groupOwnerIntent).
        if (info.isGroupOwner) {
            if (pendingResult != null) {
                resolvePending(
                    null,
                    null,
                    TransportContract.ERR_CONNECT_FAILED,
                    "Wi-Fi Direct group formed with this device as the group owner; " +
                        "the peer dials us",
                )
            }
            return
        }

        val host = info.groupOwnerAddress?.hostAddress
        if (host.isNullOrEmpty()) {
            resolvePending(
                null,
                null,
                TransportContract.ERR_CONNECT_FAILED,
                "Wi-Fi Direct group formed but the owner address was not resolvable",
            )
            return
        }

        val requested = pendingAddress
        if (requested != null) {
            // We asked to connect and ended up as the client: dial the owner we
            // invited, using the port it advertised.
            val port = portByAddress[requested] ?: 0
            if (port <= 0) {
                resolvePending(
                    null,
                    null,
                    TransportContract.ERR_CONNECT_FAILED,
                    "Wi-Fi Direct group formed but the peer's data port is unknown",
                )
                return
            }
            resolvePending(host, port, null, null)
            return
        }

        // We were invited into the group. The owner is only known by MAC address
        // from WifiP2pInfo, so look up the handle it advertised and hand the
        // reachable endpoint to Dart, which opens the datapath.
        p2p.requestGroupInfo(channel) { group ->
            val ownerMac = group?.owner?.deviceAddress
            val port = ownerMac?.let { portByAddress[it] } ?: 0
            val handle = ownerMac?.let { handleByAddress[it] }
            if (port <= 0 || handle.isNullOrEmpty()) {
                Log.e(TAG, "join: owner unknown (mac=$ownerMac port=$port)")
                events.onError(
                    TransportContract.ERR_GENERIC,
                    "Wi-Fi Direct group formed but the peer's data port is unknown",
                )
                return@requestGroupInfo
            }
            Log.d(TAG, "join: dial owner handle=$handle host=$host port=$port")
            events.onPeerReachable(handle, host, port)
        }
    }

    private fun resolvePending(host: String?, port: Int?, code: String?, msg: String?) {
        cancelConnectTimeout()
        val callback = pendingResult
        pendingResult = null
        pendingAddress = null
        callback?.invoke(host, port, code, msg)
    }

    /** Fails a connect() whose group never formed, so it cannot hang forever. */
    private fun scheduleConnectTimeout() {
        cancelConnectTimeout()
        val task = Runnable {
            connectTimeoutTask = null
            if (pendingResult != null) {
                Log.e(TAG, "connect: timed out waiting for Wi-Fi Direct group formation")
                resolvePending(
                    null,
                    null,
                    TransportContract.ERR_CONNECT_FAILED,
                    "Wi-Fi Direct group formation timed out",
                )
            }
        }
        connectTimeoutTask = task
        mainHandler.postDelayed(task, CONNECT_TIMEOUT_MS)
    }

    private fun cancelConnectTimeout() {
        connectTimeoutTask?.let { mainHandler.removeCallbacks(it) }
        connectTimeoutTask = null
    }

    private fun actionListener(label: String) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() {
            Log.d(TAG, "action $label: success")
        }

        override fun onFailure(reason: Int) {
            Log.e(TAG, "action $label: failed ($reason)")
            events.onError(TransportContract.ERR_GENERIC, "Wi-Fi Direct $label failed ($reason)")
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val rediscover = object : Runnable {
        override fun run() {
            val p2p = this@WifiP2pEngine.p2p ?: return
            val channel = this@WifiP2pEngine.channel ?: return
            if (!running) return
            Log.d(TAG, "rediscover: discoverPeers + discoverServices")
            p2p.discoverPeers(channel, actionListener("rediscoverPeers"))
            p2p.discoverServices(channel, actionListener("rediscoverServices"))
            mainHandler.postDelayed(this, REDISCOVER_INTERVAL_MS)
        }
    }

    private fun startRediscovery() {
        mainHandler.removeCallbacks(rediscover)
        mainHandler.postDelayed(rediscover, REDISCOVER_INTERVAL_MS)
    }

    private fun stopRediscovery() {
        mainHandler.removeCallbacks(rediscover)
    }

    private companion object {
        // A DNS-SD type understood by Wi-Fi Direct. The app-specific meaning is
        // carried in the instance name (the handle) and TXT records.
        const val SERVICE_TYPE = "_presence._tcp"
        const val TAG = "FindIt/Transport"

        /** Android stops Wi-Fi Direct discovery after a while, so re-issue it. */
        const val REDISCOVER_INTERVAL_MS = 30_000L

        /** How long to wait for a requested Wi-Fi Direct group to form. */
        const val CONNECT_TIMEOUT_MS = 20_000L
    }
}
