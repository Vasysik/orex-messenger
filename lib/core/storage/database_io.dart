import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqflite_cipher;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../config/orex_config.dart';
import 'database_security_policy.dart';

/// Нативный билдер БД.
///
/// Android/iOS/macOS открываются через sqflite_sqlcipher.
/// Windows/Linux используют SQLCipher из sqlcipher_flutter_libs через sqlite3
/// FFI. Если вместо SQLCipher подхватится обычный sqlite3, открытие падает.
Future<DatabaseApi> buildOrexDatabase() async {
  final dir = await getApplicationSupportDirectory();
  final useDesktopSqlCipher = Platform.isWindows || Platform.isLinux;
  final dbName = useDesktopSqlCipher ? 'orex-sqlcipher.sqlite' : 'orex.sqlite';
  final path = p.join(dir.path, dbName);

  // Генерируем или считываем единый 256-битный ключ из аппаратного Keychain/Keystore
  const secureStorage = FlutterSecureStorage();
  String? dbPassword = await secureStorage.read(key: 'orex_db_pass');

  if (dbPassword == null) {
    final random = Random.secure();
    final values = List<int>.generate(32, (i) => random.nextInt(256));
    dbPassword = base64Url.encode(values);
    await secureStorage.write(key: 'orex_db_pass', value: dbPassword);
  }
  final databasePassword = dbPassword;

  final Database db;
  // Пакет sqflite_sqlcipher официально поддерживает Android, iOS и macOS
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    db = await sqflite_cipher.openDatabase(
      path,
      password:
          dbPassword, // База данных на диске зашифрована по алгоритму AES-256
    );
  } else if (useDesktopSqlCipher) {
    OrexDatabaseSecurityPolicy.validateDesktopCache(
      environment: OrexConfig.environment,
      encryptedAtRest: true,
      allowInsecureDesktopCache: OrexConfig.allowInsecureDesktopCache,
      platformName: Platform.operatingSystem,
    );
    final factory = createDatabaseFactoryFfi(ffiInit: _initDesktopSqlCipher);
    db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        onConfigure: (database) =>
            _configureSqlCipherDatabase(database, databasePassword),
      ),
    );
  } else {
    OrexDatabaseSecurityPolicy.validateDesktopCache(
      environment: OrexConfig.environment,
      encryptedAtRest: false,
      allowInsecureDesktopCache: OrexConfig.allowInsecureDesktopCache,
      platformName: Platform.operatingSystem,
    );
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(path);
  }

  return MatrixSdkDatabase.init(
    'orex',
    database: db,
    fileStorageLocation: dir.uri,
  );
}

void _initDesktopSqlCipher() {
  if (Platform.isWindows) {
    sqlite_open.open.overrideFor(
      sqlite_open.OperatingSystem.windows,
      () => DynamicLibrary.open('sqlite3.dll'),
    );
  }

  // Force-load the library in the isolate used by sqflite_common_ffi. The
  // actual database open path verifies that this is SQLCipher, not plain SQLite.
  sqlite.sqlite3.openInMemory().dispose();
}

Future<void> _configureSqlCipherDatabase(
  Database database,
  String password,
) async {
  final cipherVersionRows = await database.rawQuery('PRAGMA cipher_version;');
  final cipherVersion = cipherVersionRows.isEmpty
      ? null
      : cipherVersionRows.first.values.first?.toString();
  if (cipherVersion == null || cipherVersion.isEmpty) {
    throw StateError(
      'SQLCipher is not available for ${Platform.operatingSystem}; refusing to '
      'open Matrix cache as plaintext.',
    );
  }

  await database.execute("PRAGMA key = '${_sqlQuote(password)}';");
  await database.rawQuery('SELECT count(*) FROM sqlite_master;');
}

String _sqlQuote(String value) => value.replaceAll("'", "''");
