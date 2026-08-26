import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'safe_filename.dart';

const String _partialPrefix = '.orex-part-';

/// Managed storage for files handed to external native applications.
///
/// Files are written atomically into a dedicated temporary directory. Old
/// entries are removed by age and, for sufficiently old files, by a soft size
/// quota. Recent files are retained so a system media player has time to open
/// and continue reading them after the external application is launched.
final class OrexTemporaryMediaStore {
  OrexTemporaryMediaStore({
    required this.root,
    this.maxAge = const Duration(hours: 24),
    this.maxTotalBytes = 512 * 1024 * 1024,
    this.minimumAgeForQuota = const Duration(hours: 2),
    this.partialFileMaxAge = const Duration(minutes: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Directory root;
  final Duration maxAge;
  final int maxTotalBytes;
  final Duration minimumAgeForQuota;
  final Duration partialFileMaxAge;
  final DateTime Function() _now;

  Future<File> write(String filename, Uint8List bytes) async {
    await _ensureRoot();
    await _cleanupQuietly();

    final safeName = orexSafeFilename(filename);
    final target = await _availableTarget(safeName);
    final partial = File(
      p.join(
        root.path,
        '$_partialPrefix${_now().microsecondsSinceEpoch}-${p.basename(target.path)}',
      ),
    );

    _assertInsideRoot(target.path);
    _assertInsideRoot(partial.path);

    late final File completed;
    try {
      await partial.writeAsBytes(bytes, flush: true);
      completed = await partial.rename(target.path);
    } catch (_) {
      await _deleteQuietly(partial);
      rethrow;
    }

    await _cleanupQuietly();
    return completed;
  }

  Future<File> _availableTarget(String safeName) async {
    for (var attempt = 0; attempt < 1000; attempt++) {
      final candidateName = attempt == 0
          ? safeName
          : _filenameWithCollisionSuffix(safeName, attempt + 1);
      final candidate = File(p.join(root.path, candidateName));
      _assertInsideRoot(candidate.path);
      final type = await FileSystemEntity.type(
        candidate.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return candidate;
    }

    final fallback = orexSafeFilename(
      '${_now().microsecondsSinceEpoch}-$safeName',
    );
    final candidate = File(p.join(root.path, fallback));
    _assertInsideRoot(candidate.path);
    return candidate;
  }

  String _filenameWithCollisionSuffix(String safeName, int number) {
    var extension = p.extension(safeName);
    final rawBase = p.basenameWithoutExtension(safeName);
    final base = rawBase.isEmpty ? 'file' : rawBase;
    final suffix = ' ($number)';
    if (extension.length + suffix.length >= orexSafeFilenameMaxLength) {
      extension = '';
    }
    final maxBase = orexSafeFilenameMaxLength - extension.length - suffix.length;
    final trimmedBase = base.length > maxBase
        ? base.substring(0, maxBase)
        : base;
    return '$trimmedBase$suffix$extension';
  }

  Future<void> _cleanupQuietly() async {
    try {
      await cleanup();
    } catch (_) {
      // Cleanup is best effort and must not discard a completed download.
    }
  }

  Future<void> cleanup() async {
    await _ensureRoot();
    final now = _now();
    final retained = <_TemporaryMediaEntry>[];

    await for (final entity in root.list(followLinks: false)) {
      if (entity is Link) {
        await _deleteEntityQuietly(entity);
        continue;
      }
      if (entity is! File) continue;

      _assertInsideRoot(entity.path);
      try {
        final stat = await entity.stat();
        final age = _nonNegativeAge(now, stat.modified);
        final isPartial = p.basename(entity.path).startsWith(_partialPrefix);
        if ((isPartial && age >= partialFileMaxAge) || age >= maxAge) {
          await _deleteQuietly(entity);
          continue;
        }
        if (!isPartial) {
          retained.add(
            _TemporaryMediaEntry(
              file: entity,
              bytes: stat.size,
              modified: stat.modified,
            ),
          );
        }
      } on FileSystemException {
        // Another cleanup/write may have removed the entry already.
      }
    }

    var totalBytes = retained.fold<int>(0, (sum, item) => sum + item.bytes);
    if (totalBytes <= maxTotalBytes) return;

    retained.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in retained) {
      if (totalBytes <= maxTotalBytes) break;
      if (_nonNegativeAge(now, entry.modified) < minimumAgeForQuota) continue;
      if (await _deleteQuietly(entry.file)) totalBytes -= entry.bytes;
    }
  }

  Duration _nonNegativeAge(DateTime now, DateTime modified) {
    final age = now.difference(modified);
    return age.isNegative ? Duration.zero : age;
  }

  Future<void> _ensureRoot() async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(root.path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(root.path).delete();
    }
    await root.create(recursive: true);
  }

  void _assertInsideRoot(String candidate) {
    final normalizedRoot = p.normalize(p.absolute(root.path));
    final normalizedCandidate = p.normalize(p.absolute(candidate));
    if (!p.isWithin(normalizedRoot, normalizedCandidate)) {
      throw FileSystemException(
        'Temporary media path escaped its managed directory',
        candidate,
      );
    }
  }

  Future<bool> _deleteQuietly(File file) => _deleteEntityQuietly(file);

  Future<bool> _deleteEntityQuietly(FileSystemEntity entity) async {
    try {
      final type = await FileSystemEntity.type(
        entity.path,
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return true;
      await entity.delete();
      return true;
    } on FileSystemException {
      // Best-effort cleanup. The next startup/open retries it.
      return false;
    }
  }
}

final class _TemporaryMediaEntry {
  const _TemporaryMediaEntry({
    required this.file,
    required this.bytes,
    required this.modified,
  });

  final File file;
  final int bytes;
  final DateTime modified;
}
