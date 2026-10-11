import '../../crypto/identity_record.dart';

/// A public identity record the device knows about, plus local metadata.
///
/// This is how the app distinguishes *discovered* identities (unverified
/// records) from *verified* contacts.
class KnownIdentity {
  const KnownIdentity({
    required this.record,
    required this.isLocal,
    required this.firstSeenMs,
    this.lastSeenMs,
    this.verifiedAtMs,
  });

  final IdentityRecord record;
  final bool isLocal;
  final int firstSeenMs;
  final int? lastSeenMs;

  /// Set when the key binding was confirmed (QR scan or mutual acceptance).
  final int? verifiedAtMs;

  String get identityId => record.identityId;

  bool get isVerified => verifiedAtMs != null;

  KnownIdentity copyWith({int? lastSeenMs, int? verifiedAtMs, bool? isLocal}) {
    return KnownIdentity(
      record: record,
      isLocal: isLocal ?? this.isLocal,
      firstSeenMs: firstSeenMs,
      lastSeenMs: lastSeenMs ?? this.lastSeenMs,
      verifiedAtMs: verifiedAtMs ?? this.verifiedAtMs,
    );
  }
}
