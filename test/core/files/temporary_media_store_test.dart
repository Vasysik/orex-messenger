import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/files/temporary_media_store_io.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('orex-media-store-test-');
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('writes unique sanitized files inside the managed directory', () async {
    final store = OrexTemporaryMediaStore(root: sandbox);
    final first = await store.write('../clip?.mp4', Uint8List.fromList([1, 2]));
    final second = await store.write('../clip?.mp4', Uint8List.fromList([3]));

    expect(p.isWithin(sandbox.path, first.path), isTrue);
    expect(p.basename(first.path), 'clip_.mp4');
    expect(p.basename(second.path), 'clip_ (2).mp4');
    expect(second.path, isNot(first.path));
    expect(await first.readAsBytes(), [1, 2]);
    expect(
      sandbox
          .listSync()
          .whereType<File>()
          .any(
            (file) => p.basename(file.path).startsWith('.orex-part-'),
          ),
      isFalse,
    );
  });

  test('removes stale files but retains fresh ones', () async {
    final now = DateTime(2026, 7, 23, 20);
    final stale = File(p.join(sandbox.path, 'stale.bin'));
    final fresh = File(p.join(sandbox.path, 'fresh.bin'));
    await stale.writeAsBytes([1]);
    await fresh.writeAsBytes([2]);
    await stale.setLastModified(now.subtract(const Duration(days: 2)));
    await fresh.setLastModified(now.subtract(const Duration(minutes: 5)));

    final store = OrexTemporaryMediaStore(root: sandbox, now: () => now);
    await store.cleanup();

    expect(await stale.exists(), isFalse);
    expect(await fresh.exists(), isTrue);
  });


  test('removes abandoned atomic-write files', () async {
    final now = DateTime(2026, 7, 23, 20);
    final partial = File(p.join(sandbox.path, '.orex-part-1-video.mp4'));
    await partial.writeAsBytes([1, 2, 3]);
    await partial.setLastModified(now.subtract(const Duration(hours: 1)));

    final store = OrexTemporaryMediaStore(root: sandbox, now: () => now);
    await store.cleanup();

    expect(await partial.exists(), isFalse);
  });

  test(
    'quota deletes old entries without touching recently opened files',
    () async {
      final now = DateTime(2026, 7, 23, 20);
      final old = File(p.join(sandbox.path, 'old.bin'));
      final recent = File(p.join(sandbox.path, 'recent.bin'));
      await old.writeAsBytes(List<int>.filled(8, 1));
      await recent.writeAsBytes(List<int>.filled(8, 2));
      await old.setLastModified(now.subtract(const Duration(hours: 3)));
      await recent.setLastModified(now.subtract(const Duration(minutes: 10)));

      final store = OrexTemporaryMediaStore(
        root: sandbox,
        now: () => now,
        maxTotalBytes: 10,
        maxAge: const Duration(days: 2),
        minimumAgeForQuota: const Duration(hours: 2),
      );
      await store.cleanup();

      expect(await old.exists(), isFalse);
      expect(await recent.exists(), isTrue);
    },
  );
}
