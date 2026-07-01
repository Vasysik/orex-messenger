// Кроссплатформенный билдер БД для Matrix SDK.
//
// Веб тянет IndexedDB-реализацию, нативные платформы — sqflite/ffi.
// Conditional import гарантирует, что веб-сборка НЕ подключает sqflite
// (иначе компиляция под web падает).
export 'database_io.dart' if (dart.library.js_interop) 'database_web.dart';
