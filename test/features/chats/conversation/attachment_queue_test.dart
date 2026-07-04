import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/features/chats/conversation/attachment_queue.dart';

void main() {
  group('OrexAttachmentQueue', () {
    test('accepts exactly the configured maximum number of files', () {
      final queue = OrexAttachmentQueue(
        limits: const OrexAttachmentLimits(maxFiles: 10, maxFileBytes: 100),
      );

      final result = queue.addAll([
        for (var i = 0; i < 10; i++) _file('file-$i.txt', size: 1),
      ]);

      expect(result.accepted, hasLength(10));
      expect(result.rejectedCount, 0);
      expect(queue.files, hasLength(10));
    });

    test('rejects files after maxFiles without mutating accepted files', () {
      final queue = OrexAttachmentQueue(
        limits: const OrexAttachmentLimits(maxFiles: 2, maxFileBytes: 100),
      );

      final result = queue.addAll([
        _file('a.txt', size: 1),
        _file('b.txt', size: 1),
        _file('c.txt', size: 1),
      ]);

      expect(result.accepted.map((file) => file.name), ['a.txt', 'b.txt']);
      expect(result.rejectedCount, 1);
      expect(queue.files.map((file) => file.name), ['a.txt', 'b.txt']);
    });

    test('uses existing queued bytes when enforcing batch size', () {
      final queue = OrexAttachmentQueue(
        limits: const OrexAttachmentLimits(
          maxFiles: 10,
          maxFileBytes: 100,
          maxBatchBytes: 10,
        ),
      );

      queue.addAll([_file('existing.txt', size: 6)]);
      final result = queue.addAll([
        _file('fits.txt', size: 4),
        _file('too-much.txt', size: 1),
      ]);

      expect(result.accepted.single.name, 'fits.txt');
      expect(result.rejectedCount, 1);
      expect(queue.totalBytes, 10);
    });

    test('rejects oversized files and unloaded file bytes', () {
      final queue = OrexAttachmentQueue(
        limits: const OrexAttachmentLimits(maxFileBytes: 5),
      );

      final result = queue.addAll([
        _file('large.txt', size: 6),
        PlatformFile(name: 'missing-bytes.txt', size: 1),
        _file('ok.txt', size: 5),
      ]);

      expect(result.accepted.single.name, 'ok.txt');
      expect(result.rejectedCount, 2);
      expect(queue.files.single.name, 'ok.txt');
    });

    test('can preflight dropped files before reading them into memory', () {
      final queue = OrexAttachmentQueue(
        limits: const OrexAttachmentLimits(maxFiles: 2, maxFileBytes: 10),
      );

      expect(queue.canAcceptSize(fileBytes: 10), isTrue);
      expect(queue.canAcceptSize(fileBytes: 10, pendingCount: 2), isFalse);
      expect(queue.canAcceptSize(fileBytes: 11), isFalse);
    });
  });
}

PlatformFile _file(String name, {required int size}) {
  return PlatformFile(name: name, size: size, bytes: Uint8List(size));
}
