import 'dart:io';

import 'package:matrix/matrix.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Native: Android/iOS используют обычный sqflite, а desktop
/// (Windows/Linux/macOS) — sqflite_common_ffi.
Future<DatabaseApi> buildOrexDatabase() async {
  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'orex.sqlite');

  final Database db;
  if (Platform.isAndroid || Platform.isIOS) {
    db = await sqflite.openDatabase(path);
  } else {
    // Desktop: инициализируем FFI-движок sqlite3.
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(path);
  }

  return MatrixSdkDatabase.init(
    'orex',
    database: db,
    // Хранилище медиа-файлов рядом с БД (опционально).
    fileStorageLocation: dir.uri,
  );
}
