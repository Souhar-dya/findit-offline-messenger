/// Base class for all expected, typed failures in the application.
sealed class AppException implements Exception {
  const AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

/// A malformed, truncated or non-canonical protocol structure.
class ProtocolException extends AppException {
  const ProtocolException(super.message, {super.cause});
}

/// A cryptographic failure: bad signature, bad MAC, key mismatch, etc.
class CryptoException extends AppException {
  const CryptoException(super.message, {super.cause});
}

/// A validation failure for user or protocol input.
class ValidationException extends AppException {
  const ValidationException(super.message, {super.cause});
}

/// A persistence-layer failure (SQLite, migrations, corruption).
class StorageException extends AppException {
  const StorageException(super.message, {super.cause});
}

/// A transport-layer failure or unsupported capability.
class TransportException extends AppException {
  const TransportException(super.message, {super.cause});
}

/// Raised when a resource quota (storage, replication, rate) is exhausted.
class QuotaExceededException extends AppException {
  const QuotaExceededException(super.message, {super.cause});
}

/// Raised when an operation is not permitted by the current protocol state.
class StateTransitionException extends AppException {
  const StateTransitionException(super.message, {super.cause});
}

/// Raised when a message or request has passed its immutable expiry.
class ExpiredException extends AppException {
  const ExpiredException(super.message, {super.cause});
}
