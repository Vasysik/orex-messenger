import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'orex_avatar_cache_key.dart';

/// Persistent avatar cache shared by Flutter and the native Android layer.
///
/// On Android `getApplicationSupportDirectory()` maps to the app's files
/// directory, so Kotlin can read the same files from
/// `filesDir/orex_avatar_cache_v1` without a token or network request.
class OrexAvatarCache {
  const OrexAvatarCache._();

  static const String directoryName = 'orex_avatar_cache_v1';
  static const int _maxFileBytes = 8 * 1024 * 1024;
  static const int _maxCacheBytes = 64 * 1024 * 1024;

  static Future<Directory>? _directoryFuture;
  static Future<void>? _trimFuture;

  static String keyFor(Uri mxc) => orexAvatarCacheKey(mxc);

  static Future<Uint8List?> read(Uri mxc) async {
    if (mxc.scheme != 'mxc') return null;
    try {
      final file = await _fileFor(mxc);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.lengthInBytes > _maxFileBytes) {
        await _deleteQuietly(file);
        return null;
      }
      _touch(file);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Associates a Matrix room/user identity with an already cached avatar.
  /// One tiny file per identity avoids a shared JSON index and cross-isolate races.
  static Future<void> bindIdentity(String identity, Uri mxc) async {
    final normalized = identity.trim();
    if (normalized.isEmpty || mxc.scheme != 'mxc') return;
    final avatarKey = keyFor(mxc);
    try {
      final directory = await (_directoryFuture ??= _openDirectory());
      final binding = File(
        p.join(directory.path, 'binding_${orexStableCacheKey(normalized)}'),
      );
      final temporary = File(
        '${binding.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
      );
      await temporary.writeAsString(avatarKey, flush: true);
      if (await binding.exists()) await binding.delete();
      await temporary.rename(binding.path);
    } catch (_) {
      // Bindings only improve native presentation; cache failures are non-fatal.
    }
  }

  static Future<void> clearIdentity(String identity) async {
    final normalized = identity.trim();
    if (normalized.isEmpty) return;
    try {
      final directory = await (_directoryFuture ??= _openDirectory());
      await _deleteQuietly(
        File(
          p.join(
            directory.path,
            'binding_${orexStableCacheKey(normalized)}',
          ),
        ),
      );
    } catch (_) {
      // Stale presentation data is non-critical.
    }
  }

  static Future<bool> contains(Uri mxc) async {
    if (mxc.scheme != 'mxc') return false;
    try {
      return (await _fileFor(mxc)).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<String?> write(Uri mxc, Uint8List bytes) async {
    if (mxc.scheme != 'mxc' ||
        bytes.isEmpty ||
        bytes.lengthInBytes > _maxFileBytes) {
      return null;
    }
    try {
      final file = await _fileFor(mxc);
      if (await file.exists()) {
        _touch(file);
        return keyFor(mxc);
      }
      final temporary = File(
        '${file.path}.tmp.${DateTime.now().microsecondsSinceEpoch}',
      );
      await temporary.writeAsBytes(bytes, flush: true);
      try {
        await temporary.rename(file.path);
      } catch (_) {
        // Another isolate may have won the same immutable MXC write.
        await _deleteQuietly(temporary);
        if (!await file.exists()) rethrow;
      }
      _scheduleTrim();
      return keyFor(mxc);
    } catch (_) {
      return null;
    }
  }

  static Future<File> _fileFor(Uri mxc) async {
    final directory = await (_directoryFuture ??= _openDirectory());
    return File(p.join(directory.path, keyFor(mxc)));
  }

  static Future<Directory> _openDirectory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, directoryName));
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }

  static void _touch(File file) {
    file.setLastModified(DateTime.now()).then<void>(
      (_) {},
      onError: (_) {},
    );
  }

  static void _scheduleTrim() {
    if (_trimFuture != null) return;
    late final Future<void> task;
    task = _trim().whenComplete(() {
      if (identical(_trimFuture, task)) _trimFuture = null;
    });
    _trimFuture = task;
  }

  static Future<void> _trim() async {
    try {
      final directory = await (_directoryFuture ??= _openDirectory());
      final files = await directory
          .list(followLinks: false)
          .where(
            (entity) =>
                entity is File &&
                !entity.path.contains('.tmp.') &&
                !p.basename(entity.path).startsWith('binding_'),
          )
          .cast<File>()
          .toList();
      final entries = <({File file, int bytes, DateTime modified})>[];
      var totalBytes = 0;
      for (final file in files) {
        try {
          final stat = await file.stat();
          totalBytes += stat.size;
          entries.add((file: file, bytes: stat.size, modified: stat.modified));
        } catch (_) {
          // Ignore a file that disappeared during cleanup.
        }
      }
      if (totalBytes <= _maxCacheBytes) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (totalBytes <= _maxCacheBytes) break;
        await _deleteQuietly(entry.file);
        totalBytes -= entry.bytes;
      }
    } catch (_) {
      // Cache cleanup must never affect messenger startup or notifications.
    }
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort cache cleanup.
    }
  }
}
