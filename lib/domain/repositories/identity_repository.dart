import '../../crypto/identity_record.dart';
import '../entities/known_identity.dart';

/// Persistence for public identity records (local + peers).
abstract class IdentityRepository {
  /// Inserts or updates a known identity. Never overwrites a local identity.
  Future<void> upsert(KnownIdentity identity);

  Future<KnownIdentity?> find(String identityId);

  Future<KnownIdentity?> localIdentity();

  Future<List<KnownIdentity>> allKnown();

  Future<List<KnownIdentity>> verifiedIdentities();

  /// Records that an identity was observed at [nowMs].
  Future<void> touch(String identityId, int nowMs);

  /// Marks an identity's key binding as verified.
  Future<void> markVerified(String identityId, int nowMs);

  Future<void> delete(String identityId);

  /// Whether any durable state references this identity. Used to avoid
  /// deleting identity records that friendships or pending messages depend on.
  Future<bool> isReferenced(String identityId);

  /// Convenience: store a public record that has already been verified.
  Future<KnownIdentity> storeVerified(
    IdentityRecord record, {
    required int nowMs,
    bool isLocal = false,
  });
}
