import 'package:matrix/matrix.dart';

/// Web: Matrix SDK сам использует IndexedDB (window.indexedDB),
/// никакого sqflite не требуется.
Future<DatabaseApi> buildOrexDatabase() async {
  return MatrixSdkDatabase.init('orex');
}
