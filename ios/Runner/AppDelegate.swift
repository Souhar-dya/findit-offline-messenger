import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Registers the Dart <-> native transport channel (local-network fabric).
    // The app keeps using the simulated transport by default; the native
    // fabric is opt-in and scaffold-only right now (see README).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PlatformTransportChannel") {
      PlatformTransportChannel.register(messenger: registrar.messenger())
    }
  }
}