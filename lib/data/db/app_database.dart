import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../../core/errors/app_exception.dart';

/// Owns the SQLite connection, schema and migrations.
///
/// The database is opened through an injectable [DatabaseFactory] so tests can
/// use `sqflite_common_ffi` while the app uses the platform plugin.
class AppDatabase {
  AppDatabase({required DatabaseFactory factory, required String path})
    : _factory = factory,
      _path = path;

  /// Current schema version. Increment and add a migration when changing it.
  static const int schemaVersion = 2;

  final DatabaseFactory _factory;
  final String _path;

  Database? _database;

  String get path => _path;

  Future<Database> get database async => _database ??= await _open();

  Future<void> close() async {
    final db = _database;
    _database = null;
    await db?.close();
  }

  /// Deletes the database file (used by "reset local data").
  Future<void> deleteDatabase() async {
    await close();
    await _factory.deleteDatabase(_path);
  }

  Future<Database> _open() async {
    try {
      return await _openInternal();
    } catch (error) {
      // Migration failure or corruption. Preserve the broken file for recovery
      // and start from a clean schema rather than crashing on launch.
      await _quarantine();
      try {
        return await _openInternal();
      } catch (retryError) {
        throw StorageException(
          'Unable to open the local database',
          cause: retryError,
        );
      }
    }
  }

  Future<Database> _openInternal() {
    return _factory.openDatabase(
      _path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
        onDowngrade: onDatabaseDowngradeDelete,
      ),
    );
  }

  Future<void> _quarantine() async {
    await close();
    if (_path == inMemoryDatabasePath) return;
    try {
      final file = File(_path);
      if (await file.exists()) {
        final backup =
            '$_path.corrupt-${DateTime.now().millisecondsSinceEpoch}';
        await file.rename(backup);
      }
    } catch (_) {
      // Best-effort; if we cannot preserve it we simply recreate.
    }
    try {
      await _factory.deleteDatabase(_path);
    } catch (_) {
      // Ignore: the open path will surface a real error if this fails.
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    final statements = _migrationsFrom(0, version);
    for (final statement in statements) {
      await db.execute(statement);
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    final statements = _migrationsFrom(oldVersion, newVersion);
    for (final statement in statements) {
      await db.execute(statement);
    }
  }

  /// Returns the ordered DDL statements to migrate from [from] to [to].
  ///
  /// Structured as a list of steps so future versions append steps rather than
  /// branching, and so migration failures surface deterministically.
  List<String> _migrationsFrom(int from, int to) {
    final statements = <String>[];
    if (from < 1) statements.addAll(_schemaV1);
    if (from < 2) statements.addAll(_schemaV2);
    return statements;
  }

  static const List<String> _schemaV1 = [
    '''
    CREATE TABLE identities (
      identity_id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      format_version INTEGER NOT NULL,
      key_version INTEGER NOT NULL,
      signing_public_key BLOB NOT NULL,
      agreement_public_key BLOB NOT NULL,
      signature BLOB NOT NULL,
      is_local INTEGER NOT NULL DEFAULT 0,
      first_seen_ms INTEGER NOT NULL,
      last_seen_ms INTEGER,
      verified_ms INTEGER
    )
    ''',
    '''
    CREATE TABLE friends (
      peer_id TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      status TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      verified_ms INTEGER,
      last_seen_ms INTEGER,
      FOREIGN KEY (peer_id) REFERENCES identities(identity_id) ON DELETE RESTRICT
    )
    ''',
    '''
    CREATE TABLE friend_requests (
      request_id TEXT PRIMARY KEY,
      from_id TEXT NOT NULL,
      to_id TEXT NOT NULL,
      direction TEXT NOT NULL,
      state TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      created_at_ms INTEGER NOT NULL,
      expires_at_ms INTEGER NOT NULL,
      peer_display_name TEXT
    )
    ''',
    '''
    CREATE UNIQUE INDEX idx_friend_requests_pending
      ON friend_requests(from_id, to_id)
      WHERE state = 'pending'
    ''',
    'CREATE INDEX idx_friend_requests_state ON friend_requests(state, expires_at_ms)',
    '''
    CREATE TABLE conversations (
      peer_id TEXT PRIMARY KEY,
      last_message_id TEXT,
      last_message_at_ms INTEGER,
      last_preview TEXT,
      updated_at_ms INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE messages (
      message_id TEXT PRIMARY KEY,
      bundle_id TEXT,
      conversation_id TEXT NOT NULL,
      sender_id TEXT NOT NULL,
      recipient_id TEXT NOT NULL,
      direction TEXT NOT NULL,
      status TEXT NOT NULL,
      payload_type TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      expires_at_ms INTEGER NOT NULL,
      received_at_ms INTEGER,
      delivered_at_ms INTEGER,
      read_at_ms INTEGER,
      text_content TEXT,
      image_bytes BLOB,
      image_hash TEXT,
      image_width INTEGER,
      image_height INTEGER,
      image_filename TEXT
    )
    ''',
    'CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at_ms DESC)',
    'CREATE INDEX idx_messages_status ON messages(status)',
    'CREATE INDEX idx_messages_expiry ON messages(expires_at_ms)',
    'CREATE INDEX idx_messages_bundle ON messages(bundle_id)',
    '''
    CREATE TABLE delivery_receipts (
      message_id TEXT NOT NULL,
      delivered_by_id TEXT NOT NULL,
      original_sender_id TEXT NOT NULL,
      delivered_at_ms INTEGER NOT NULL,
      signature BLOB NOT NULL,
      protocol_version INTEGER NOT NULL,
      received_at_ms INTEGER NOT NULL,
      propagated_at_ms INTEGER,
      PRIMARY KEY (message_id, delivered_by_id)
    )
    ''',
    'CREATE INDEX idx_receipts_propagate ON delivery_receipts(propagated_at_ms)',
    '''
    CREATE TABLE message_tombstones (
      bundle_id TEXT PRIMARY KEY,
      reason TEXT NOT NULL,
      created_at_ms INTEGER NOT NULL,
      expires_at_ms INTEGER NOT NULL
    )
    ''',
    'CREATE INDEX idx_tombstones_expiry ON message_tombstones(expires_at_ms)',
    '''
    CREATE TABLE bundles (
      bundle_id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      recipient_id TEXT NOT NULL,
      expires_at_ms INTEGER NOT NULL,
      stored_at_ms INTEGER NOT NULL,
      size_bytes INTEGER NOT NULL,
      payload BLOB NOT NULL,
      replication_count INTEGER NOT NULL DEFAULT 0,
      source_peer_id TEXT,
      last_forwarded_at_ms INTEGER
    )
    ''',
    'CREATE INDEX idx_bundles_expiry ON bundles(expires_at_ms)',
    'CREATE INDEX idx_bundles_recipient ON bundles(recipient_id, expires_at_ms)',
    '''
    CREATE TABLE bundle_forwards (
      bundle_id TEXT NOT NULL,
      peer_id TEXT NOT NULL,
      forwarded_at_ms INTEGER NOT NULL,
      PRIMARY KEY (bundle_id, peer_id),
      FOREIGN KEY (bundle_id) REFERENCES bundles(bundle_id) ON DELETE CASCADE
    )
    ''',
    '''
    CREATE TABLE pending_transfers (
      transfer_id TEXT PRIMARY KEY,
      peer_id TEXT NOT NULL,
      received_bytes INTEGER NOT NULL,
      total_bytes INTEGER NOT NULL,
      updated_at_ms INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE blocked_identities (
      identity_id TEXT PRIMARY KEY,
      blocked_at_ms INTEGER NOT NULL,
      reason TEXT
    )
    ''',
    '''
    CREATE TABLE rate_limits (
      bucket_key TEXT NOT NULL,
      window_start_ms INTEGER NOT NULL,
      count INTEGER NOT NULL,
      PRIMARY KEY (bucket_key, window_start_ms)
    )
    ''',
  ];

  /// v2: local, non-secret preferences (consent acceptance, relay opt-in).
  static const List<String> _schemaV2 = [
    '''
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
    ''',
  ];
}
