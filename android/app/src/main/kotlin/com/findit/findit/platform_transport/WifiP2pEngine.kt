package com.findit.findit.platform_transport

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.NetworkInfo
import android.net.wifi.WifiManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Looper
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
 * VERIFICATION: this compiles and passes Android lint, but exercising real
 * discovery/group formation requires two physical devices with Wi-Fi Direct
 * hardware in range — the emulator does not emulate the P2P radio. Treat the
 * on-device behavior as untested until validated on hardware.
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

    private var localService: WifiP2pDnsSdServiceInfo? = null

    // Per-session mapping from the handle a peer advertised to its device MAC.
    // Peers are addressed only by that advertised handle; the MAC is never
    // handed to Dart.
    private val addressByHandle = ConcurrentHashMap<String, String>()

    // What peers advertised to us (populated from DNS-SD).
    private val portByAddress = ConcurrentHashMap<String, Int>()
    private val hintByAddress = ConcurrentHashMap<String, String>()

    // The initiator's in-flight connect().
    private var pendingAddress: String? = null
    private var pendingResult: ((String?, Int?, String?, String?) -> Unit)? = null

    override fun start(): Boolean {
        val p2p = this.p2p
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT) || p2p == null) {
            events.onError(TransportContract.ERR_UNAVAILABLE, "This device does not support Wi-Fi Direct")
            return false
        }
        val wifi = context.getSystemService(WifiManager::class.java)
        if (wifi == null || !wifi.isWifiEnabled) {
            events.onError(TransportContract.ERR_UNAVAILABLE, "Wi-Fi is off")
            return false
        }
        val channel = p2p.initialize(
            context,
            Looper.getMainLooper(),
            WifiP2pManager.ChannelListener {
                running = false
                events.onError(TransportContract.ERR_UNAVAILABLE, "Wi-Fi Direct channel lost")
            },
        )
        if (channel == null) {
            events.onError(TransportContract.ERR_UNAVAILABLE, "Could not open a Wi-Fi Direct channel")
            return false
        }
        this.channel = channel
        running = true
        registerReceiver()
        configureServiceDiscovery(channel)
        p2p.discoverPeers(channel, actionListener("discoverPeers"))
        // The local advertisement is published once Dart sends an advertisement
        // carrying a valid dataPort (see updateAdvertisement).
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
        val address = addressByHandle[handle]
        if (address == null) {
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
            pendingAddress = address
            pendingResult = onResult
            val config = WifiP2pConfig().apply {
                deviceAddress = address
                // Prefer that the *invited* device becomes the group owner so the
                // address we read from WifiP2pInfo is the peer's IP.
                groupOwnerIntent = 0
            }
            p2p.connect(
                channel,
                config,
                object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        // Group formation continues via CONNECTION_CHANGED.
                    }

                    override fun onFailure(reason: Int) {
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
        running = false
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
                if (!instanceName.isNullOrEmpty()) rememberPeer(address, instanceName)
            },
            // TXT carries the peer handle ("h"), data port ("p") and hint ("d").
            WifiP2pManager.DnsSdTxtRecordListener { _, txt, device ->
                val address = device?.deviceAddress ?: return@DnsSdTxtRecordListener
                txt["p"]?.toIntOrNull()?.let { portByAddress[address] = it }
                txt["d"]?.let { hintByAddress[address] = it }
                val advertised = txt["h"]
                if (advertised.isNullOrEmpty()) return@DnsSdTxtRecordListener
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
    }

    private fun onConnectionChanged(intent: Intent) {
        @Suppress("DEPRECATION")
        val networkInfo =
            intent.getParcelableExtra(WifiP2pManager.EXTRA_NETWORK_INFO) as? NetworkInfo
        if (networkInfo?.isConnected != true) {
            resolvePending(
                null,
                null,
                TransportContract.ERR_CONNECT_FAILED,
                "Wi-Fi Direct group closed before a datapath was established",
            )
            return
        }
        val channel = this.channel ?: return
        p2p?.requestConnectionInfo(channel) { info -> onConnectionInfo(info) }
    }

    private fun onConnectionInfo(info: WifiP2pInfo) {
        val address = pendingAddress
        if (address == null || !info.groupFormed) return
        val port = portByAddress[address] ?: 0
        // We ask to be a client (groupOwnerIntent = 0), so the group owner is the
        // peer. If we still ended up as the owner we cannot learn the client's
        // IPv4 from WifiP2pInfo, so fail honestly rather than guess.
        val host = if (!info.isGroupOwner) info.groupOwnerAddress?.hostAddress else null
        if (host.isNullOrEmpty() || port <= 0) {
            resolvePending(
                null,
                null,
                TransportContract.ERR_CONNECT_FAILED,
                "Wi-Fi Direct group formed but the peer address was not resolvable",
            )
            return
        }
        resolvePending(host, port, null, null)
    }

    private fun resolvePending(host: String?, port: Int?, code: String?, msg: String?) {
        val callback = pendingResult
        pendingResult = null
        pendingAddress = null
        callback?.invoke(host, port, code, msg)
    }

    private fun actionListener(label: String) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() {}
        override fun onFailure(reason: Int) {
            events.onError(TransportContract.ERR_GENERIC, "Wi-Fi Direct $label failed ($reason)")
        }
    }

    private companion object {
        // A DNS-SD type understood by Wi-Fi Direct. The app-specific meaning is
        // carried in the instance name (the handle) and TXT records.
        const val SERVICE_TYPE = "_presence._tcp"
    }
}
