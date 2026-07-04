import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqflite_cipher;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/orex_config.dart';
import 'database_security_policy.dart';

/// Нативный билдер БД.
///
/// Android/iOS/macOS открываются через sqflite_sqlcipher и получают реальное
/// шифрование на диске. Windows/Linux сейчас используют обычный FFI SQLite,
/// поэтому локальная БД на этих платформах НЕ должна считаться зашифрованной,
/// пока проект не перейдёт на настоящую SQLCipher-сборку для desktop.
Future<DatabaseApi> buildOrexDatabase() async {
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'orex.sqlite');

  // Генерируем или считываем единый 256-битный ключ из аппаратного Keychain/Keystore
  const secureStorage = FlutterSecureStorage();
  String? dbPassword = await secureStorage.read(key: 'orex_db_pass');

  if (dbPassword == null) {
    final random = Random.secure();
    final values = List<int>.generate(32, (i) => random.nextInt(256));
    dbPassword = base64Url.encode(values);
    await secureStorage.write(key: 'orex_db_pass', value: dbPassword);
  }

  final Database db;
  // Пакет sqflite_sqlcipher официально поддерживает Android, iOS и macOS
  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    db = await sqflite_cipher.openDatabase(
      path,
      password:
          dbPassword, // База данных на диске зашифрована по алгоритму AES-256
    );
  } else {
    // Windows / Linux: обычный sqlite3 через FFI. Это НЕ SQLCipher.
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
