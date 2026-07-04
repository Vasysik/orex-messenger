import 'dart:collection';

import 'package:file_picker/file_picker.dart';

final class OrexAttachmentLimits {
  const OrexAttachmentLimits({
    this.maxFiles = 10,
    this.maxFileBytes = 50 * 1024 * 1024,
    this.maxBatchBytes = 100 * 1024 * 1024,
  });

  final int maxFiles;
  final int maxFileBytes;
  final int maxBatchBytes;
}

final class OrexAttachmentQueueResult {
  const OrexAttachmentQueueResult({
    required this.accepted,
    required this.rejectedCount,
  });

  final List<PlatformFile> accepted;
  final int rejectedCount;

  bool get hasAccepted => accepted.isNotEmpty;
  bool get hasRejected => rejectedCount > 0;
}

final class OrexAttachmentQueue {
  OrexAttachmentQueue({this.limits = const OrexAttachmentLimits()});

  final OrexAttachmentLimits limits;
  final List<PlatformFile> _files = [];

  UnmodifiableListView<PlatformFile> get files => UnmodifiableListView(_files);
  int get length => _files.length;
  int get totalBytes => _files.fold<int>(0, (sum, file) => sum + file.size);

  bool canAcceptSize({
    required int fileBytes,
    int pendingCount = 0,
    int pendingBytes = 0,
  }) {
    return _files.length + pendingCount < limits.maxFiles &&
        fileBytes <= limits.maxFileBytes &&
        totalBytes + pendingBytes + fileBytes <= limits.maxBatchBytes;
  }

  OrexAttachmentQueueResult addAll(Iterable<PlatformFile> candidates) {
    final accepted = <PlatformFile>[];
    var acceptedBytes = 0;
    var rejected = 0;

    for (final file in candidates) {
      if (file.bytes == null ||
          !canAcceptSize(
            fileBytes: file.size,
            pendingCount: accepted.length,
            pendingBytes: acceptedBytes,
          )) {
        rejected++;
        continue;
      }
      accepted.add(file);
      acceptedBytes += file.size;
    }

    _files.addAll(accepted);
    return OrexAttachmentQueueResult(
      accepted: List.unmodifiable(accepted),
      rejectedCount: rejected,
    );
  }

  List<PlatformFile> snapshot() => List<PlatformFile>.unmodifiable(_files);

  void removeAt(int index) {
    _files.removeAt(index);
  }

  void clear() {
    _files.clear();
  }
}
