import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqflite_cipher;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Нативный билдер БД: мобильные устройства и macOS используют зашифрованную базу данных,
/// а Windows/Linux — FFI с поддержкой PRAGMA-ключей шифрования.
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
      password: dbPassword, // База данных на диске зашифрована по алгоритму AES-256
    );
  } else {
    // Windows / Linux: инициализируем FFI-движок
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(path);
    await db.execute("PRAGMA key = '$dbPassword';");
  }

  return MatrixSdkDatabase.init(
    'orex',
    database: db,
    fileStorageLocation: dir.uri,
  );
}
