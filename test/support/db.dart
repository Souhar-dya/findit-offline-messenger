import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Initialises the FFI SQLite backend used by host-side (VM) tests.
///
/// The app itself uses the `sqflite` platform plugin; tests use
/// `sqflite_common_ffi` with an in-memory (or temporary) database so the exact
/// same repository and schema code can be exercised without a device.
bool _initialised = false;

void initTestDatabase() {
  if (_initialised) return;
  sqfliteFfiInit();
  _initialised = true;
}

/// A shared in-memory database factory for tests.
DatabaseFactory get testDatabaseFactory {
  initTestDatabase();
  return databaseFactoryFfi;
}
