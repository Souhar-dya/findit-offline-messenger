package com.findit.findit

import com.findit.findit.platform_transport.PlatformTransportChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Registers the Dart <-> native transport channel. The app keeps using
        // the simulated transport by default; the native fabric is opt-in.
        // Android uses Wi-Fi Direct (implemented, but not yet hardware-verified);
        // Wi-Fi Aware is still a stub. See README, "Native radio status".
        PlatformTransportChannel.register(
            applicationContext,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }
}