/// A tiny key/value store for local, non-secret preferences.
///
/// This holds things like whether the user accepted the terms and whether the
/// relay opt-in is enabled. It is deliberately separate from the identity /
/// message repositories, and it never stores secrets.
abstract class SettingsRepository {
  Future<String?> get(String key);

  Future<Map<String, String>> all();

  Future<void> put(String key, String value);

  Future<void> delete(String key);

  Future<void> clear();
}
