import 'identity_service.dart';

/// A tiny mutable holder for the currently active [LocalIdentity].
///
/// Services and controllers read the identity through this holder instead of
/// capturing it once, so onboarding, rename and identity reset are all
/// reflected everywhere without rebuilding the dependency graph.
class IdentityHolder {
  LocalIdentity? _identity;

  LocalIdentity? get identity => _identity;

  bool get hasIdentity => _identity != null;

  void set(LocalIdentity identity) {
    _identity = identity;
  }

  void clear() {
    _identity = null;
  }

  /// The active identity, or a [StateError] when called before onboarding.
  LocalIdentity get requireIdentity {
    final identity = _identity;
    if (identity == null) {
      throw StateError('No local identity is available yet');
    }
    return identity;
  }
}
