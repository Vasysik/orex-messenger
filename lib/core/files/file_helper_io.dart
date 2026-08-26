import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:open_app_file/open_app_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'temporary_media_store_io.dart';

class FileHelper {
  static Future<OrexTemporaryMediaStore>? _storeFuture;
  static Future<void> _operationTail = Future<void>.value();

  static Future<void> saveAndOpenFile(String filename, Uint8List bytes) async {
    final file = await _serialize(() async {
      final store = await _store();
      return store.write(filename, bytes);
    });

    try {
      final result = await OpenAppFile.open(file.path);
      if (result.type != ResultType.done) {
        throw FileSystemException(result.message, file.path);
      }
    } catch (_) {
      try {
        await file.delete();
      } on FileSystemException {
        // Best effort: the managed cleanup retries on the next launch/open.
      }
      rethrow;
    }
  }

  static Future<void> cleanupTemporaryFiles() async {
    try {
      await _serialize(() async {
        final store = await _store();
        await store.cleanup();
      });
    } catch (_) {
      // Temporary cleanup must never prevent application startup.
    }
  }

  static Future<OrexTemporaryMediaStore> _store() async {
    final existing = _storeFuture;
    if (existing != null) return existing;

    final created = _createStore();
    _storeFuture = created;
    try {
      return await created;
    } catch (_) {
      if (identical(_storeFuture, created)) _storeFuture = null;
      rethrow;
    }
  }

  static Future<OrexTemporaryMediaStore> _createStore() async {
    final temp = await getTemporaryDirectory();
    return OrexTemporaryMediaStore(
      root: Directory(p.join(temp.path, 'orex_media')),
    );
  }

  static Future<T> _serialize<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    final previous = _operationTail;
    _operationTail = () async {
      try {
        await previous;
      } catch (_) {
        // A failed operation must not block the managed queue.
      }
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }();
    return completer.future;
  }
}
