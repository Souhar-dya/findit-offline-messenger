package com.findit.findit

import com.findit.findit.platform_transport.PlatformTransportChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // The native Wi-Fi Direct transport owns the "Nearby" feature. It needs
        // runtime permissions, so the channel is installed with this Activity.
        PlatformTransportChannel.install(
            this,
            flutterEngine.dartExecutor.binaryMessenger,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // Forward the dialog result to the pending Dart permission request.
        PlatformTransportChannel.onRequestPermissionsResult(requestCode, grantResults)
    }
}
