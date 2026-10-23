import 'package:flutter/foundation.dart';

import '../../core/di/app_services.dart';

/// Backs the Profile / Settings screen: connection state, storage usage and the
/// single master networking switch.
class SettingsController extends ChangeNotifier {
  SettingsController(this._services);

  final AppServices _services;

  int _messageBytes = 0;
  int _bundleBytes = 0;
  bool _busy = false;
  String? _status;

  int get messageBytes => _messageBytes;
  int get bundleBytes => _bundleBytes;
  int get totalBytes => _messageBytes + _bundleBytes;
  int get quotaBytes => _services.config.defaultStorageQuotaBytes;
  bool get busy => _busy;
  String? get status => _status;

  double get quotaFraction {
    if (quotaBytes <= 0) return 0;
    return (totalBytes / quotaBytes).clamp(0.0, 1.0);
  }

  bool get isSimulated => _services.core.transport.capabilities.isSimulated;
  bool get canDiscover => _services.core.transport.capabilities.canDiscover;

  /// Whether this device uses the radio at all (the single master switch).
  bool get networkingEnabled => _services.networkingEnabled;

  Future<void> setNetworkingEnabled(bool value) async {
    _busy = true;
    notifyListeners();
    try {
      if (value && _services.requiresPlatformPermissions) {
        final granted = await _services.ensurePermissions();
        if (!granted) {
          _status =
              'Paxby needs the Nearby devices permission to use the radio. '
              'Grant it, then turn the switch on again.';
          return;
        }
      }
      await _services.setNetworkingEnabled(value);
      _status = value
          ? 'Paxby is on. This device can discover nearby peers, send and '
                'receive your messages, and may carry encrypted messages for '
                'others.'
          : 'Paxby is radio silent. Nothing is discovered, sent or received, '
                'and any stored third-party bundles were deleted.';
    } catch (error) {
      _status = 'Could not change networking: $error';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> refresh() async {
    _messageBytes = await _services.core.messages.totalPayloadBytes();
    _bundleBytes = await _services.core.bundles.totalBytes();
    notifyListeners();
  }
}
