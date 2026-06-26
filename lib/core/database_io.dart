import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sqflite_cipher;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Нативный билдер БД: Android/iOS используют sqflite_sqlcipher с шифрованием,
/// а desktop (Windows/Linux/macOS) — sqflite_common_ffi.
Future<DatabaseApi> buildOrexDatabase() async {
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'orex.sqlite');

  final Database db;
  if (Platform.isAndroid || Platform.isIOS) {
    const secureStorage = FlutterSecureStorage();
    String? dbPassword = await secureStorage.read(key: 'orex_db_pass');
    
    if (dbPassword == null) {
      // Генерируем надежный 256-битный ключ (32 байта)
      final random = Random.secure();
      final values = List<int>.generate(32, (i) => random.nextInt(256));
      dbPassword = base64Url.encode(values);
      await secureStorage.write(key: 'orex_db_pass', value: dbPassword);
    }

    db = await sqflite_cipher.openDatabase(
      path,
      password: dbPassword, // База данных полностью зашифрована на диске по алгоритму AES
    );
  } else {
    // Desktop: инициализируем FFI-движок sqlite3.
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(path);
  }

  return MatrixSdkDatabase.init(
    'orex',
    database: db,
    fileStorageLocation: dir.uri,
  );
}
