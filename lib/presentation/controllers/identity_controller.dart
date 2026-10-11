import 'package:flutter/foundation.dart';

import '../../core/di/app_services.dart';
import '../../core/errors/app_exception.dart';
import '../../crypto/identity_record.dart';
import '../../crypto/identity_service.dart';
import '../../domain/entities/known_identity.dart';

/// Owns onboarding, the active identity, QR export and identity reset.
class IdentityController extends ChangeNotifier {
  IdentityController(this._services);

  final AppServices _services;

  LocalIdentity? _identity;
  bool _busy = false;
  String? _error;
  String? _status;

  LocalIdentity? get identity => _identity;
  bool get hasIdentity => _identity != null;
  bool get busy => _busy;
  String? get error => _error;
  String? get status => _status;

  String get displayName => _identity?.displayName ?? '';
  String get identityId => _identity?.identityId ?? '';

  Future<void> load() async {
    _identity = await _services.core.identityService.load();
    if (_identity != null) {
      _services.core.identityHolder.set(_identity!);
    }
    notifyListeners();
  }

  /// Seeds the controller from an already-loaded identity without notifying.
  void syncFromHolder() {
    _identity = _services.core.identityHolder.identity;
  }

  Future<bool> create(String displayName) async {
    final name = displayName.trim();
    if (name.isEmpty) {
      _error = 'Please enter a display name.';
      notifyListeners();
      return false;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final identity = await _services.core.identityService.generate(
        displayName: name,
      );
      _identity = identity;
      _services.core.identityHolder.set(identity);
      final now = _services.core.clock.now().millisecondsSinceEpoch;
      await _services.core.identities.upsert(
        KnownIdentity(
          record: identity.record,
          isLocal: true,
          firstSeenMs: now,
          lastSeenMs: now,
          verifiedAtMs: now,
        ),
      );
      await _services.startNetworking();
      _status = 'Identity created. Only the public record leaves this device.';
      return true;
    } on AppException catch (error) {
      _error = error.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> rename(String displayName) async {
    final current = _identity;
    final name = displayName.trim();
    if (current == null || name.isEmpty) {
      _error = 'Please enter a display name.';
      notifyListeners();
      return false;
    }
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final renamed = await _services.core.identityService.rename(
        current,
        name,
      );
      _identity = renamed;
      _services.core.identityHolder.set(renamed);
      final now = _services.core.clock.now().millisecondsSinceEpoch;
      await _services.core.identities.upsert(
        KnownIdentity(
          record: renamed.record,
          isLocal: true,
          firstSeenMs: now,
          lastSeenMs: now,
          verifiedAtMs: now,
        ),
      );
      await _services.core.transport.updateAdvertisement(
        displayNameHint: renamed.displayName,
        identity: renamed.record,
        discoverable: true,
      );
      _status = 'Display name updated.';
      return true;
    } on AppException catch (error) {
      _error = error.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Wipes the identity and all local data. Irreversible.
  Future<void> reset() async {
    _busy = true;
    notifyListeners();
    try {
      await _services.stopNetworking();
      await _services.stopDemoPeer();
      await _services.core.identityService.delete();
      await _services.core.database.deleteDatabase();
      _identity = null;
      _services.core.identityHolder.clear();
      // Consent and the relay opt-in live in the (now deleted) database, so
      // clear the in-memory copy too and re-prompt for the terms.
      _services.resetLocalPreferences();
      _status = 'Local identity and data removed.';
    } on AppException catch (error) {
      _error = error.message;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// QR payload (public information only).
  String? get qrData => _identity?.record.toQrData();

  /// Re-verifies a scanned record before it is stored.
  Future<IdentityRecord> verifyScannedRecord(String data) async {
    final record = IdentityRecord.parseQrData(data);
    if (!await record.verify()) {
      throw const CryptoException('The scanned identity failed verification');
    }
    return record;
  }

  void clearMessages() {
    _error = null;
    _status = null;
    notifyListeners();
  }
}
