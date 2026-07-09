final class OrexIncomingMediaPolicy {
  const OrexIncomingMediaPolicy._();

  static const int webAutoThumbnailBytes = 4 * 1024 * 1024;
  static const int nativeAutoThumbnailBytes = 8 * 1024 * 1024;
  static const int webAutoImageBytes = 8 * 1024 * 1024;
  static const int nativeAutoImageBytes = 20 * 1024 * 1024;
  static const int webAutoAudioBytes = 12 * 1024 * 1024;
  static const int nativeAutoAudioBytes = 24 * 1024 * 1024;
  static const int webManualDownloadBytes = 50 * 1024 * 1024;
  static const int nativeManualDownloadBytes = 200 * 1024 * 1024;
  static const int webDecryptedCacheBytes = 32 * 1024 * 1024;
  static const int nativeDecryptedCacheBytes = 96 * 1024 * 1024;

  static int decryptedCacheLimit({required bool isWeb}) =>
      isWeb ? webDecryptedCacheBytes : nativeDecryptedCacheBytes;

  static int? attachmentSize(Map<String, Object?> content) {
    final info = _objectMap(content['info']);
    return _positiveInt(info?['size']) ?? _positiveInt(content['size']);
  }

  static int? thumbnailSize(Map<String, Object?> content) {
    final info = _objectMap(content['info']);
    final thumbnailInfo = _objectMap(info?['thumbnail_info']);
    return _positiveInt(thumbnailInfo?['size']);
  }

  static bool shouldAutoLoadThumbnail(
    Map<String, Object?> content, {
    required bool isWeb,
  }) {
    final size = thumbnailSize(content);
    if (size == null) return false;
    final limit = isWeb ? webAutoThumbnailBytes : nativeAutoThumbnailBytes;
    return size <= limit;
  }

  static bool shouldAutoLoadImage(
    Map<String, Object?> content, {
    required bool isWeb,
  }) {
    final size = attachmentSize(content);
    if (size == null) return false;
    final limit = isWeb ? webAutoImageBytes : nativeAutoImageBytes;
    return size <= limit;
  }

  static bool shouldAutoLoadAudio(
    Map<String, Object?> content, {
    required bool isWeb,
  }) {
    final size = attachmentSize(content);
    if (size == null) return false;
    final limit = isWeb ? webAutoAudioBytes : nativeAutoAudioBytes;
    return size <= limit;
  }

  static String? manualDownloadBlockReason(
    Map<String, Object?> content, {
    required bool isWeb,
  }) {
    final size = attachmentSize(content);
    if (size == null) {
      return isWeb
          ? 'Размер файла неизвестен. В Web загрузка заблокирована для защиты памяти вкладки.'
          : null;
    }
    final limit = isWeb ? webManualDownloadBytes : nativeManualDownloadBytes;
    if (size <= limit) return null;
    return 'Файл слишком большой для безопасной загрузки целиком в память '
        '(${_formatBytes(size)} > ${_formatBytes(limit)}).';
  }

  static Map<String, Object?>? _objectMap(Object? value) {
    if (value is! Map) return null;
    return value.map((key, value) => MapEntry(key.toString(), value));
  }

  static int? _positiveInt(Object? value) {
    if (value is! num) return null;
    final parsed = value.toInt();
    return parsed >= 0 ? parsed : null;
  }

  static String _formatBytes(int bytes) {
    final mib = bytes / (1024 * 1024);
    return '${mib.toStringAsFixed(mib >= 10 ? 0 : 1)} МБ';
  }
}
