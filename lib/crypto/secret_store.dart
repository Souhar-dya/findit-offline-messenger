import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Abstraction over platform-backed secret storage.
///
/// Only private key material is ever written here. Tests use
/// [InMemorySecretStore]; production uses [FlutterSecureSecretStore], which is
/// backed by the Android Keystore / iOS Keychain.
abstract class SecretStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<bool> containsKey(String key);
}

/// Secure storage backed by the operating system keychain / keystore.
///
/// Values written through this store are opaque strings; callers encode
/// structured data as base64 before persisting it so the plugin never has to
/// interpret the payload.
class FlutterSecureSecretStore implements SecretStore {
  FlutterSecureSecretStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<bool> containsKey(String key) => _storage.containsKey(key: key);
}

/// In-memory secret store, used by tests and by the non-mobile development
/// shell so the app can boot without a platform keychain.
class InMemorySecretStore implements SecretStore {
  InMemorySecretStore([Map<String, String>? seed]) : _values = {...?seed};

  final Map<String, String> _values;

  @override
  Future<bool> containsKey(String key) async => _values.containsKey(key);

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  /// Stored keys, for tests and diagnostics (values are NOT exposed).
  Iterable<String> get keys => _values.keys;

  /// Base64-encoded JSON helper shared by stores that persist structured data.
  static String encodeJson(Map<String, Object?> value) =>
      base64Encode(utf8.encode(jsonEncode(value)));

  static Map<String, Object?> decodeJson(String value) =>
      (jsonDecode(utf8.decode(base64Decode(value))) as Map)
          .cast<String, Object?>();
}
