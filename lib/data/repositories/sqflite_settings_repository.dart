import 'package:sqflite/sqflite.dart';

import '../../domain/repositories/settings_repository.dart';
import '../db/app_database.dart';

/// SQLite-backed [SettingsRepository].
///
/// Preferences live in the same database as everything else, so "reset local
/// data" also clears consent and the relay opt-in (and therefore re-prompts).
class SqfliteSettingsRepository implements SettingsRepository {
  SqfliteSettingsRepository(this._database);

  final AppDatabase _database;

  @override
  Future<String?> get(String key) async {
    final db = await _database.database;
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  @override
  Future<Map<String, String>> all() async {
    final db = await _database.database;
    final rows = await db.query('settings', columns: ['key', 'value']);
    return <String, String>{
      for (final row in rows)
        row['key'] as String: row['value'] as String,
    };
  }

  @override
  Future<void> put(String key, String value) async {
    final db = await _database.database;
    await db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> delete(String key) async {
    final db = await _database.database;
    await db.delete('settings', where: 'key = ?', whereArgs: [key]);
  }

  @override
  Future<void> clear() async {
    final db = await _database.database;
    await db.delete('settings');
  }
}
