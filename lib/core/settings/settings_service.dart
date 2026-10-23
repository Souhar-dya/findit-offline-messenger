import 'dart:convert';

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
  final Map<String, bool> _disappearingPreferences = <String, bool>{};

  /// Single-row persisted conversation state, so each local transition
  /// (including its pending handshake fields) is written atomically.
  Future<DisappearingPreferenceState> disappearingStateFor(
    String peerId,
  ) async {
    final value = await _repository.get(_disappearingKey(peerId));
    return _decodeDisappearingState(value);
  }

  Future<Map<String, DisappearingPreferenceState>> allDisappearingStates()
      async {
    const prefix = 'disappearing_messages:';
    final values = await _repository.all();
    final states = <String, DisappearingPreferenceState>{};
    for (final entry in values.entries) {
      if (entry.key.startsWith(prefix)) {
        states[entry.key.substring(prefix.length)] =
            _decodeDisappearingState(entry.value);
      }
    }
    return states;
  }

  DisappearingPreferenceState _decodeDisappearingState(String? value) {
    if (value == null) return const DisappearingPreferenceState();
    // Compatibility with the earlier local boolean preference format.
    if (value == 'true' || value == 'false') {
      return DisappearingPreferenceState(enabled: value == 'true');
    }
    try {
      return DisappearingPreferenceState.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
    } catch (_) {
      // A corrupt preference must not lock the conversation out. Restore the
      // safe default and replace it on the next update.
      return const DisappearingPreferenceState();
    }
  }

  Future<void> saveDisappearingState(
    String peerId,
    DisappearingPreferenceState state,
  ) async {
    _disappearingPreferences[peerId] = state.enabled;
    await _repository.put(_disappearingKey(peerId), jsonEncode(state.toJson()));
  }

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

  /// Whether messages with [peerId] disappear after 24 hours. New contacts
  /// default to disappearing messages being enabled.
  Future<bool> disappearingMessagesEnabledFor(String peerId) async {
    final cached = _disappearingPreferences[peerId];
    if (cached != null) return cached;
    final stored = await disappearingStateFor(peerId);
    final enabled = stored.enabled;
    _disappearingPreferences[peerId] = enabled;
    return enabled;
  }

  static String _disappearingKey(String peerId) =>
      'disappearing_messages:$peerId';

  /// Clears the in-memory flags without touching storage.
  ///
  /// Used after the local database has been wiped, so the terms are shown
  /// again and networking reverts to off.
  void clear() {
    _consentVersion = null;
    _networkingEnabled = false;
    _disappearingPreferences.clear();
  }
}

class DisappearingPreferenceState {
  const DisappearingPreferenceState({
    this.enabled = true,
    this.outgoingRequestId,
    this.outgoingEnabled,
    this.outgoingCommitSent = false,
    this.outgoingActivateSent = false,
    this.incomingRequestId,
    this.incomingEnabled,
    this.incomingAccepted = false,
    this.lastAppliedRequestId,
    this.lastRejectedRequestId,
  });

  final bool enabled;
  final String? outgoingRequestId;
  final bool? outgoingEnabled;
  final bool outgoingCommitSent;
  final bool outgoingActivateSent;
  final String? incomingRequestId;
  final bool? incomingEnabled;
  final bool incomingAccepted;
  final String? lastAppliedRequestId;
  final String? lastRejectedRequestId;

  DisappearingPreferenceState copyWith({
    bool? enabled,
    String? outgoingRequestId,
    bool? outgoingEnabled,
    bool? outgoingCommitSent,
    bool? outgoingActivateSent,
    String? incomingRequestId,
    bool? incomingEnabled,
    bool? incomingAccepted,
    String? lastAppliedRequestId,
    String? lastRejectedRequestId,
    bool clearOutgoing = false,
    bool clearIncoming = false,
  }) => DisappearingPreferenceState(
    enabled: enabled ?? this.enabled,
    outgoingRequestId: clearOutgoing
        ? null
        : outgoingRequestId ?? this.outgoingRequestId,
    outgoingEnabled: clearOutgoing
        ? null
        : outgoingEnabled ?? this.outgoingEnabled,
    outgoingCommitSent: clearOutgoing
        ? false
        : outgoingCommitSent ?? this.outgoingCommitSent,
    outgoingActivateSent: clearOutgoing
        ? false
        : outgoingActivateSent ?? this.outgoingActivateSent,
    incomingRequestId: clearIncoming
        ? null
        : incomingRequestId ?? this.incomingRequestId,
    incomingEnabled: clearIncoming
        ? null
        : incomingEnabled ?? this.incomingEnabled,
    incomingAccepted: clearIncoming
        ? false
        : incomingAccepted ?? this.incomingAccepted,
    lastAppliedRequestId: lastAppliedRequestId ?? this.lastAppliedRequestId,
    lastRejectedRequestId: lastRejectedRequestId ?? this.lastRejectedRequestId,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'outgoingRequestId': outgoingRequestId,
    'outgoingEnabled': outgoingEnabled,
    'outgoingCommitSent': outgoingCommitSent,
    'outgoingActivateSent': outgoingActivateSent,
    'incomingRequestId': incomingRequestId,
    'incomingEnabled': incomingEnabled,
    'incomingAccepted': incomingAccepted,
    'lastAppliedRequestId': lastAppliedRequestId,
    'lastRejectedRequestId': lastRejectedRequestId,
  };

  factory DisappearingPreferenceState.fromJson(Map<String, dynamic> json) =>
      DisappearingPreferenceState(
        enabled: json['enabled'] as bool? ?? true,
        outgoingRequestId: json['outgoingRequestId'] as String?,
        outgoingEnabled: json['outgoingEnabled'] as bool?,
        outgoingCommitSent: json['outgoingCommitSent'] as bool? ?? false,
        outgoingActivateSent: json['outgoingActivateSent'] as bool? ?? false,
        incomingRequestId: json['incomingRequestId'] as String?,
        incomingEnabled: json['incomingEnabled'] as bool?,
        incomingAccepted: json['incomingAccepted'] as bool? ?? false,
        lastAppliedRequestId: json['lastAppliedRequestId'] as String?,
        lastRejectedRequestId: json['lastRejectedRequestId'] as String?,
      );
}
