package com.findit.findit.platform_transport

import android.content.Context
import android.net.wifi.aware.WifiAwareManager
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * Wi-Fi Aware (NAN) fabric, API 26+.
 *
 * IMPLEMENTATION STATUS — skeleton only. The channel plumbing is complete but
 * the Aware lifecycle below is outlined with TODOs and must be implemented and
 * verified on physical hardware. Until then [start] fails honestly.
 *
 * Privacy: discovery-only publications must not require the distance/location
 * permission flag; `NEARBY_WIFI_DEVICES` with `neverForLocation` is the target
 * posture on Android 13+ (see AndroidManifest.xml).
 */
@RequiresApi(Build.VERSION_CODES.O)
class WifiAwareEngine(
    private val context: Context,
    private val events: EngineEvents,
) : TransportEngine {

    override val handle: String = Handles.next()
    override val fabric: String = TransportContract.FABRIC_WIFI_AWARE

    // This class is only instantiated on API 26+ (the channel checks
    // availability first), so the class-level @RequiresApi covers the manager.
    private val aware: WifiAwareManager? =
        context.getSystemService(WifiAwareManager::class.java)

    override fun start(): Boolean {
        val aware = aware ?: return false
        if (!aware.isAvailable) {
            events.onError(
                TransportContract.ERR_UNAVAILABLE,
                "Wi-Fi Aware is not available on this device",
            )
            return false
        }

        // TODO(device): complete the Aware lifecycle, then return true only when
        // the whole path (subscribe/publish + datapath + address) works.
        //
        //   1. aware.attach(executor, AttachCallback) -> WifiAwareSession.
        //   2. Publish only an opaque handle (service name noise is fine) and
        //      the display hint; never the identity id.
        //   3. Subscribers: onServiceDiscovered -> WifiAwareDiscoverySession,
        //      requestDataPath(WifiAwareNetworkSpecifier) -> NetworkRequest ->
        //      ConnectivityManager gives a Network whose addresses resolve via
        //      Network.getNetworkHandle()/getLinkProperties(); advertise the
        //      IPv6-aware endpoint for the Dart TCP listener.
        //   4. Resolve onResult(host, dataPort, null, null) only once the
        //      datapath is real.
        //
        // Wi-Fi Aware datapaths are typically IPv6-only; the Dart framing runs
        // over TCP, so an IPv6 mapped socket is required. Verify on hardware.
        events.onError(
            TransportContract.ERR_UNSUPPORTED_FEATURE,
            "Wi-Fi Aware discovery/datapath is scaffold-only (see TODO in " +
                "WifiAwareEngine)",
        )
        return false
    }

    override fun updateAdvertisement(advertisement: Advertisement) {
        // TODO(device): refresh the published service info (opaque handle +
        // display hint) on the active WifiAwareSession, rotating `handle`.
    }

    override fun connect(
        handle: String,
        onResult: (host: String?, port: Int?, code: String?, msg: String?) -> Unit,
    ) {
        // TODO(device): request a data path to the discovered session and
        // resolve the peer's reachable address + Dart dataPort.
        onResult(
            null,
            null,
            TransportContract.ERR_CONNECT_FAILED,
            "Datapath formation is scaffold-only (see TODO in WifiAwareEngine)",
        )
    }

    override fun stop() {
        // TODO(device): close the WifiAwareSession and unpublish.
    }
}