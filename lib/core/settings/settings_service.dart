import '../../domain/repositories/settings_repository.dart';
import '../legal/terms.dart';

/// Local, non-secret preferences that gate consent and networking.
///
/// This is intentionally pure Dart (no Flutter), because the routing engine
/// consults [networkingEnabled] on every send/receive decision. The in-memory
/// values are authoritative once [load] has run; writes persist straight
/// through.
class SettingsService {
  SettingsService({required SettingsRepository repository})
    : _repository = repository;

  /// Key holding the accepted [TermsDocument.version].
  static const String consentVersionKey = 'consent_version';

  /// Key holding the master networking flag (`'true'` / `'false'`).
  static const String networkingEnabledKey = 'networking_enabled';

  final SettingsRepository _repository;

  String? _consentVersion;
  bool _networkingEnabled = false;

  /// The version of the terms the user agreed to, or null if they have not.
  String? get acceptedConsentVersion => _consentVersion;

  /// True once the user has agreed to the current terms.
  bool get consentAccepted => _consentVersion == TermsDocument.version;

  /// The single master switch: whether this device uses the radio at all.
  ///
  /// Defaults to `false` (radio silent). While off, discovery never starts
  /// (the transport is not started), nothing is sent or received, and no
  /// bundles are carried for anyone. Turning it on starts discovery and lets
  /// your own messages be sent and received — the device may then also carry
  /// encrypted bundles addressed to others (relaying).
  bool get networkingEnabled => _networkingEnabled;

  /// Loads persisted preferences. Safe to call more than once.
  Future<void> load() async {
    final values = await _repository.all();
    _consentVersion = values[consentVersionKey];
    _networkingEnabled = values[networkingEnabledKey] == 'true';
  }

  /// Records agreement to the current terms.
  Future<void> acceptConsent() async {
    _consentVersion = TermsDocument.version;
    await _repository.put(consentVersionKey, TermsDocument.version);
  }

  /// Switches networking on or off.
  Future<void> setNetworkingEnabled(bool enabled) async {
    _networkingEnabled = enabled;
    await _repository.put(networkingEnabledKey, enabled ? 'true' : 'false');
  }

  /// Clears the in-memory flags without touching storage.
  ///
  /// Used after the local database has been wiped, so the terms are shown
  /// again and networking reverts to off.
  void clear() {
    _consentVersion = null;
    _networkingEnabled = false;
  }
}
