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
 *  1. Discover nearby Paxby peers over Wi-Fi Direct DNS-SD.
 *  2. Advertise this device's opaque handle + Dart `dataPort` + display hint via
 *     Wi-Fi Direct DNS-SD ([WifiP2pDnsSdServiceInfo]) so a peer that discovers
 *     us learns where to connect.
 *  3. Join or extend a Wi-Fi Direct group on `connect(handle)` and resolve the
 *     reachable group-owner IPv4 + its advertised data port.
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

    // Whether a DNS-SD service request is registered for the current channel.
    // Registering twice returns BUSY, so add it once and re-add only if lost.
    private var serviceRequestAdded = false

    // Per-session mapping from the handle a peer advertised to its device MAC.
    // Peers are addressed only by that advertised handle; the MAC is never
    // handed to Dart.
    private val addressByHandle = ConcurrentHashMap<String, String>()

    // What each advertised handle told us (populated from DNS-SD).
    //
    // These are keyed by the advertised *handle*, never by the device MAC: one
    // device can have more than one DNS-SD service registered at once (for
    // example a service left behind by an earlier run). Keying by MAC let the
    // second service's port overwrite the first's, so every handle dialed the
    // last-seen port — a wrong port, hence "Connection refused", and the peer
    // never connected until the stale service happened to disappear.
    private val portByHandle = ConcurrentHashMap<String, Int>()
    private val hintByHandle = ConcurrentHashMap<String, String>()

    // The session-start time each handle advertised (TXT "t"), used to pick the
    // newest service when one device is advertising several. 0 when absent.
    private val timeByHandle = ConcurrentHashMap<String, Long>()

    // Reverse of [addressByHandle]: the handle a peer advertised, by device MAC.
    // Needed when this device is invited into a group: WifiP2pGroup only reports
    // the owner's MAC address, not the handle it advertised.
    private val handleByAddress = ConcurrentHashMap<String, String>()

    // The initiator's in-flight connect(): the handle being dialed and its MAC.
    private var pendingHandle: String? = null
    private var pendingAddress: String? = null
    private var pendingResult: ((String?, Int?, String?, String?) -> Unit)? = null

    // When this device was first seen owning a Wi-Fi Direct group with no
    // clients. Used to give a peer that is still joining a grace period before
    // the leftover group is torn down. 0 means "not currently owner".
    private var ownedGroupSinceMs: Long = 0L

    // Stamped once per engine (i.e. once per app run) and advertised as the TXT
    // "t" key. When an old run leaves its DNS-SD service registered, a discoverer
    // uses "t" to tell this run's service (larger t) from the stale one.
    private val sessionStartMs: Long = System.currentTimeMillis()

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
        // that nobody dials. Drop it before starting over, then begin discovery,
        // so the (asynchronous) group teardown cannot race the discovery request.
        p2p.requestConnectionInfo(channel) { info ->
            if (!running) return@requestConnectionInfo
            if (info.groupFormed) {
                Log.d(TAG, "start: removing a leftover Wi-Fi Direct group")
                p2p.removeGroup(
                    channel,
                    object : WifiP2pManager.ActionListener {
                        override fun onSuccess() = beginDiscovery()
                        override fun onFailure(reason: Int) {
                            Log.e(TAG, "start: removeLeftoverGroup failed ($reason)")
                            beginDiscovery()
                        }
                    },
                )
            } else {
                beginDiscovery()
            }
        }
        // The local advertisement is published once Dart sends an advertisement
        // carrying a valid dataPort (see updateAdvertisement).
        Log.d(TAG, "start: opening discovery")
        return true
    }

    private fun beginDiscovery() {
        val channel = this.channel ?: return
        if (!running) return
        configureServiceDiscovery(channel)
        startRediscovery()
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
            // Session-start stamp; lets a discoverer prefer this run's advert
            // over one an earlier run left registered.
            "t" to sessionStartMs.toString(),
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
        val port = portByHandle[handle] ?: 0
        if (port <= 0) {
            Log.e(TAG, "connect: peer $handle has no advertised data port")
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
                // A Wi-Fi Direct client can only use its current group's owner
                // as the TCP relay. The requested peer may be another client,
                // so the owner's address must use the owner's advertised port.
                resolveOwnerEndpoint(
                    host = owner,
                    onResolved = { _, ownerPort -> onResult(owner, ownerPort, null, null) },
                    onFailure = { message ->
                        onResult(null, null, TransportContract.ERR_CONNECT_FAILED, message)
                    },
                )
                return@requestConnectionInfo
            }
            if (info.groupFormed && info.isGroupOwner) {
                // We own a group. Invite new peers into it so one Paxby group
                // can carry traffic for several nearby devices. A group with
                // *no* clients is a leftover (the peer
                // that formed it left, or negotiation made us owner and the peer
                // never joined); it would otherwise block every future connect,
                // so clear it and start over. Give a peer that is still joining
                // a short grace period first, so a fresh group is never torn
                // down mid-join.
                val now = System.currentTimeMillis()
                if (ownedGroupSinceMs == 0L) ownedGroupSinceMs = now
                p2p.requestGroupInfo(channel) { group ->
                    val clients = group?.clientList
                    if (clients.isNullOrEmpty() && now - ownedGroupSinceMs >= STALE_GROUP_GRACE_MS) {
                        Log.d(TAG, "connect: owned group has no clients; clearing it and re-initiating")
                        p2p.removeGroup(
                            channel,
                            object : WifiP2pManager.ActionListener {
                                override fun onSuccess() {
                                    ownedGroupSinceMs = 0L
                                    mainHandler.postDelayed(
                                        { initiateGroup(handle, address, onResult) },
                                        GROUP_RESET_DELAY_MS,
                                    )
                                }

                                override fun onFailure(reason: Int) {
                                    Log.e(TAG, "connect: could not clear stale group ($reason)")
                                    onResult(
                                        null,
                                        null,
                                        TransportContract.ERR_CONNECT_FAILED,
                                        "Could not clear the stale Wi-Fi Direct group ($reason)",
                                    )
                                }
                            },
                        )
                    } else if (clients.orEmpty().any {
                            it.deviceAddress.equals(address, ignoreCase = true)
                        }
                    ) {
                        Log.d(TAG, "connect: peer $handle is already a client in this group")
                        onResult(
                            null,
                            null,
                            TransportContract.ERR_CONNECT_FAILED,
                            "Peer is already connected through this Wi-Fi Direct group",
                        )
                    } else {
                        Log.d(
                            TAG,
                            "connect: invite another peer into our group (${clients?.size ?: 0} current client(s))",
                        )
                        initiateGroup(handle, address, onResult)
                    }
                }
                return@requestConnectionInfo
            }
            ownedGroupSinceMs = 0L
            initiateGroup(handle, address, onResult)
        }
    }

    /**
     * Requests a new Wi-Fi Direct group with [handle]. Split out so a stale
     * group can be torn down and the exact same request re-issued.
     */
    private fun initiateGroup(
        handle: String,
        address: String,
        onResult: (host: String?, port: Int?, code: String?, msg: String?) -> Unit,
    ) {
        if (!running) {
            onResult(null, null, TransportContract.ERR_CONNECT_FAILED, "Transport is not running")
            return
        }
        val p2p = this.p2p ?: run {
            onResult(null, null, TransportContract.ERR_CONNECT_FAILED, "Transport is not running")
            return
        }
        val channel = this.channel ?: run {
            onResult(null, null, TransportContract.ERR_CONNECT_FAILED, "Transport is not running")
            return
        }
        pendingHandle = handle
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
            runCatching { p2p.clearServiceRequests(channel, null) }
            runCatching { p2p.cancelConnect(channel, null) }
            runCatching { p2p.removeGroup(channel, null) }
        }
        serviceRequestAdded = false
        localService = null
        ownedGroupSinceMs = 0L
        addressByHandle.clear()
        portByHandle.clear()
        hintByHandle.clear()
        timeByHandle.clear()
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
            // The service record's instance name mirrors the handle, but the TXT
            // record below is authoritative (it also carries the port and hint),
            // so there is nothing to do here beyond logging.
            WifiP2pManager.DnsSdServiceResponseListener { instanceName, _, _ ->
                if (!instanceName.isNullOrEmpty()) {
                    Log.d(TAG, "DNS-SD service: $instanceName")
                }
            },
            // TXT carries the peer handle ("h"), data port ("p"), hint ("d") and
            // session-start time ("t").
            WifiP2pManager.DnsSdTxtRecordListener { _, txt, device ->
                val address = device?.deviceAddress ?: return@DnsSdTxtRecordListener
                val advertised = txt["h"]?.let { normalizeHandle(it) }?.takeIf { it.isNotEmpty() }
                    ?: return@DnsSdTxtRecordListener
                val port = txt["p"]?.toIntOrNull() ?: 0
                val hint = txt["d"]
                val seenAt = txt["t"]?.toLongOrNull() ?: 0L
                Log.d(TAG, "DNS-SD TXT: h=${txt["h"]} p=${txt["p"]} d=${txt["d"]} t=${txt["t"]}")
                onServiceAdvertised(address, advertised, port, hint, seenAt)
            },
        )
        ensureServiceRequest(p2p, channel)
        p2p.discoverServices(channel, actionListener("discoverServices"))
    }

    /**
     * Registers the DNS-SD service request exactly once for this channel.
     *
     * Peers are found only through their advertised service, so this request (and
     * `discoverServices`) is the whole discovery path. Registering it twice
     * returns BUSY, which is treated as "already registered".
     */
    private fun ensureServiceRequest(p2p: WifiP2pManager, channel: WifiP2pManager.Channel) {
        if (serviceRequestAdded) return
        p2p.addServiceRequest(
            channel,
            WifiP2pDnsSdServiceRequest.newInstance(),
            object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    serviceRequestAdded = true
                    Log.d(TAG, "action addServiceRequest: success")
                }

                override fun onFailure(reason: Int) {
                    if (reason == WifiP2pManager.BUSY) {
                        // A request is already registered for this channel.
                        serviceRequestAdded = true
                    }
                    Log.e(TAG, "action addServiceRequest: failed ($reason)")
                }
            },
        )
    }

    /**
     * Handles one advertised DNS-SD service.
     *
     * A single device can have several Paxby services registered at once: a
     * Wi-Fi Direct service registration survives its app being killed, so an
     * earlier run's advert lingers and Android keeps returning it. Treating each
     * service as its own peer showed the same phone twice and made the app dial a
     * dead port. Here one MAC is one peer: the newest service (largest TXT "t")
     * wins, any service it supersedes is reported lost so Dart drops the row, and
     * each remaining handle keeps its own port.
     */
    private fun onServiceAdvertised(
        address: String,
        advertised: String,
        port: Int,
        hint: String?,
        timeMs: Long,
    ) {
        addressByHandle[advertised] = address
        portByHandle[advertised] = port
        if (hint != null) hintByHandle[advertised] = hint
        timeByHandle[advertised] = timeMs

        val current = handleByAddress[address]
        if (current == null) {
            handleByAddress[address] = advertised
            events.onPeerFound(advertised, hint, null, port, 0)
            return
        }
        if (current == advertised) {
            events.onPeerFound(advertised, hint, null, port, 0)
            return
        }

        // A second service on the same device. Keep the newer session (larger
        // "t"); ignore an older leftover rather than showing the device twice.
        val currentTime = timeByHandle[current] ?: 0L
        if (timeMs > currentTime) {
            handleByAddress[address] = advertised
            forgetHandle(current)
            events.onPeerFound(advertised, hint, null, port, 0)
        } else {
            Log.d(TAG, "DNS-SD: ignoring stale service h=$advertised (current=$current)")
        }
    }

    /** Drops a superseded handle's state and tells Dart it is gone. */
    private fun forgetHandle(advertised: String) {
        addressByHandle.remove(advertised)
        portByHandle.remove(advertised)
        hintByHandle.remove(advertised)
        timeByHandle.remove(advertised)
        events.onPeerLost(advertised)
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
            val requestedAddress = pendingAddress
            if (pendingResult != null && requestedAddress != null) {
                // The group owner cannot dial a client: wait until Android
                // reports that the invited client joined, then let its socket
                // arrive through the normal server listener. Keeping the
                // request pending also prevents a second invitation from
                // overwriting this one while the first peer is joining.
                p2p.requestGroupInfo(channel) { group ->
                    val joined = group?.clientList.orEmpty().any {
                        it.deviceAddress.equals(requestedAddress, ignoreCase = true)
                    }
                    if (joined) {
                        resolvePending(
                            null,
                            null,
                            TransportContract.ERR_CONNECT_FAILED,
                            "Peer joined this Wi-Fi Direct group and will connect to its owner",
                        )
                    } else {
                        Log.d(TAG, "onConnectionInfo: waiting for invited client to join")
                    }
                }
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

        val requested = pendingHandle
        if (requested != null) {
            // We asked to connect and ended up as the client: dial the owner we
            // invited, using the port the handle we dialed advertised.
            val port = portByHandle[requested] ?: 0
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
        // reachable endpoint to Dart, which opens the datapath. The owner's
        // service may not have been discovered before the group formed, so keep
        // retrying (nudging discovery each time) instead of giving up.
        resolveOwnerAndDial(host)
    }

    /**
     * Maps the group owner's MAC to the handle/port it advertised, then hands
     * the endpoint to Dart. Retries a few times because the group can form
     * before the owner's DNS-SD advert has been discovered.
     */
    private fun resolveOwnerAndDial(host: String, attemptsLeft: Int = JOIN_MAPPING_RETRIES) {
        resolveOwnerEndpoint(
            host = host,
            attemptsLeft = attemptsLeft,
            onResolved = { handle, port ->
                Log.d(TAG, "join: dial owner handle=$handle host=$host port=$port")
                events.onPeerReachable(handle, host, port)
            },
            onFailure = { message -> events.onError(TransportContract.ERR_GENERIC, message) },
        )
    }

    /** Resolves a group's owner endpoint, retrying until DNS-SD maps its MAC. */
    private fun resolveOwnerEndpoint(
        host: String,
        attemptsLeft: Int = JOIN_MAPPING_RETRIES,
        onResolved: (handle: String, port: Int) -> Unit,
        onFailure: (String) -> Unit,
    ) {
        val p2p = this.p2p
        val channel = this.channel
        if (p2p == null || channel == null) {
            onFailure("Wi-Fi Direct is not available")
            return
        }
        p2p.requestGroupInfo(channel) { group ->
            val ownerMac = group?.owner?.deviceAddress
            val handle = ownerMac?.let { mac ->
                handleByAddress.entries.firstOrNull { (address, _) ->
                    address.equals(mac, ignoreCase = true)
                }?.value
            }
            val port = handle?.let { portByHandle[it] } ?: 0
            if (port > 0 && !handle.isNullOrEmpty()) {
                onResolved(handle, port)
                return@requestGroupInfo
            }
            if (attemptsLeft <= 0) {
                Log.e(TAG, "join: owner unknown (mac=$ownerMac port=$port) after retries")
                onFailure("Wi-Fi Direct group formed but the owner's data port is unknown")
                return@requestGroupInfo
            }
            Log.d(
                TAG,
                "join: owner mac=$ownerMac not mapped yet; retrying (${attemptsLeft - 1} left)",
            )
            ensureServiceRequest(p2p, channel)
            p2p.discoverServices(channel, actionListener("joinMapping"))
            mainHandler.postDelayed(
                {
                    if (running) {
                        resolveOwnerEndpoint(
                            host = host,
                            attemptsLeft = attemptsLeft - 1,
                            onResolved = onResolved,
                            onFailure = onFailure,
                        )
                    }
                },
                JOIN_MAPPING_RETRY_MS,
            )
        }
    }

    private fun resolvePending(host: String?, port: Int?, code: String?, msg: String?) {
        cancelConnectTimeout()
        val callback = pendingResult
        pendingResult = null
        pendingHandle = null
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
            // Re-issue DNS-SD service discovery only. Android allows just one
            // discovery mode at a time, and raw peer discovery (discoverPeers)
            // cancels service discovery — which used to leave the first minutes
            // after launch finding nothing. Peers come from their advertised
            // service, so service discovery is all we need.
            ensureServiceRequest(p2p, channel)
            Log.d(TAG, "rediscover: discoverServices")
            p2p.discoverServices(channel, actionListener("rediscoverServices"))
            mainHandler.postDelayed(this, REDISCOVER_INTERVAL_MS)
        }
    }

    private fun startRediscovery() {
        mainHandler.removeCallbacks(rediscover)
        // Fire twice soon after start: the first discoverServices can be
        // rejected/ignored while the stack settles; a tiny follow-up usually
        // catches peers that advertise in that window.
        mainHandler.postDelayed(rediscover, PRIME_DISCOVERY_DELAY_MS)
        mainHandler.postDelayed(rediscover, PRIME_DISCOVERY_DELAY_MS2)
    }

    private fun stopRediscovery() {
        mainHandler.removeCallbacks(rediscover)
    }

    private companion object {
        // A DNS-SD type understood by Wi-Fi Direct. The app-specific meaning is
        // carried in the instance name (the handle) and TXT records.
        const val SERVICE_TYPE = "_presence._tcp"
        const val TAG = "Paxby/Transport"

        /**
         * Re-issue service discovery this often.
         *
         * Android's Wi-Fi Direct find is a one-shot scan with no "services
         * changed" callback, so a peer that advertises just after a scan ends is
         * invisible until the next one. A rejected call (the scan is still
         * running) is harmless, so a short interval just restarts the scan the
         * moment it lapses and bounds how long a newly-arrived peer stays hidden.
         */
        const val REDISCOVER_INTERVAL_MS = 5_000L

        /**
         * First re-issue, a moment after start.
         *
         * The very first `discoverServices` after start is sometimes ignored (the
         * Wi-Fi Direct stack is still settling, or a leftover group was just torn
         * down), and then nothing scans until the first periodic tick — which is
         * what made an app that had just launched sit on "Searching…" for half a
         * minute. Priming shortly after start removes that wait.
         */
        const val PRIME_DISCOVERY_DELAY_MS = 800L
        const val PRIME_DISCOVERY_DELAY_MS2 = 1_400L

        /** How long to wait for a requested Wi-Fi Direct group to form. */
        const val CONNECT_TIMEOUT_MS = 15_000L

        /**
         * Wait after removing a stale, client-less group before re-requesting a
         * new one. The stack needs a moment to actually drop the group, and
         * connect() while it is still going away fails.
         */
        const val GROUP_RESET_DELAY_MS = 700L

        /**
         * How long an owned, client-less group must persist before it is treated
         * as a leftover. Prevents tearing down a group while a peer is still
         * joining it.
         */
        const val STALE_GROUP_GRACE_MS = 6_000L

        /**
         * How many times to re-check whether the group owner's MAC maps to a
         * handle/port while acting as the group client. The group can form
         * before the owner's service is discovered, and dialing without a port
         * is impossible.
         */
        const val JOIN_MAPPING_RETRIES = 8
        const val JOIN_MAPPING_RETRY_MS = 700L
    }
}
