import 'dart:collection';

import '../files/safe_filename.dart';

const int orexForwardedEventMaxBytes = 256 * 1024;
const int _forwardedTransformationReserveBytes = 128;

final class OrexForwardingException implements Exception {
  const OrexForwardingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Builds a new privacy-safe `m.room.message` content map for forwarding.
///
/// Media is forwarded by its existing Matrix content URI/encrypted descriptor;
/// file bytes are never downloaded into application memory. Room-specific
/// relations and mentions are removed so replies, edits and pings do not leak
/// into the destination room.
Map<String, dynamic> orexBuildForwardedContent(
  Map<String, dynamic> source,
) {
  final content = _BoundedJsonCopy(
    maxBytes:
        orexForwardedEventMaxBytes - _forwardedTransformationReserveBytes,
  ).copyMap(source);
  final relation = content['m.relates_to'];
  final isReply = relation is Map && relation['m.in_reply_to'] is Map;
  if (isReply) {
    final body = content['body'];
    if (body is String) content['body'] = _stripPlainReplyFallback(body);
    final formattedBody = content['formatted_body'];
    if (formattedBody is String) {
      content['formatted_body'] = _stripHtmlReplyFallback(formattedBody);
    }
  }

  content
    ..remove('m.relates_to')
    ..remove('m.new_content')
    ..remove('m.mentions');

  final msgType = content['msgtype'];
  if (msgType is! String || msgType.trim().isEmpty) {
    throw const OrexForwardingException(
      'Это сообщение нельзя безопасно переслать.',
    );
  }

  if (_mediaMessageTypes.contains(msgType)) {
    _normalizeMediaReference(content);

    final filename = content['filename'];
    if (filename is String) {
      content['filename'] = orexSafeFilename(filename);
    }
  }

  content['ru.orex.forwarded'] = true;
  return content;
}

/// Whether forwarding this content into an encrypted room would reuse a
/// plaintext media object. In that case Orex fails closed instead of silently
/// weakening the destination room's attachment privacy.
bool orexForwardedContentNeedsMediaReEncryption(
  Map<String, dynamic> content,
) {
  if (!_mediaMessageTypes.contains(content['msgtype'])) return false;

  final encryptedFile = content['file'];
  final encryptedUrl = encryptedFile is Map ? encryptedFile['url'] : null;
  if (!_isMxcUri(encryptedUrl) && _isMxcUri(content['url'])) return true;

  final info = content['info'];
  if (info is Map) {
    final thumbnailFile = info['thumbnail_file'];
    final encryptedThumbnailUrl = thumbnailFile is Map
        ? thumbnailFile['url']
        : null;
    if (!_isMxcUri(encryptedThumbnailUrl) &&
        _isMxcUri(info['thumbnail_url'])) {
      return true;
    }
  }

  return false;
}

void _normalizeMediaReference(Map<String, dynamic> content) {
  final plainUrl = content['url'];
  final encryptedFile = content['file'];
  final encryptedUrl = encryptedFile is Map ? encryptedFile['url'] : null;
  final hasEncryptedReference = _isMxcUri(encryptedUrl);
  final hasPlainReference = _isMxcUri(plainUrl);

  if (!hasEncryptedReference && !hasPlainReference) {
    throw const OrexForwardingException(
      'У медиафайла нет доступной Matrix-ссылки для пересылки.',
    );
  }

  if (hasEncryptedReference) {
    content.remove('url');
  } else {
    content.remove('file');
  }

  final info = content['info'];
  if (info is! Map) return;

  final normalizedInfo = Map<String, dynamic>.from(info);
  final thumbnailFile = normalizedInfo['thumbnail_file'];
  final encryptedThumbnailUrl = thumbnailFile is Map
      ? thumbnailFile['url']
      : null;
  if (_isMxcUri(encryptedThumbnailUrl)) {
    normalizedInfo.remove('thumbnail_url');
  } else if (_isMxcUri(normalizedInfo['thumbnail_url'])) {
    normalizedInfo.remove('thumbnail_file');
  } else {
    normalizedInfo
      ..remove('thumbnail_file')
      ..remove('thumbnail_url');
  }
  content['info'] = normalizedInfo;
}

final class _BoundedJsonCopy {
  _BoundedJsonCopy({required this.maxBytes});

  final int maxBytes;
  final Set<Object> _activeContainers = HashSet<Object>.identity();
  int _usedBytes = 0;

  Map<String, dynamic> copyMap(Map<String, dynamic> source) =>
      _copyValue(source, 0) as Map<String, dynamic>;

  Object? _copyValue(Object? value, int depth) {
    if (depth > 64) {
      throw const OrexForwardingException(
        'Сообщение имеет слишком сложную структуру для пересылки.',
      );
    }
    if (value == null) {
      _consume(4);
      return null;
    }
    if (value is bool) {
      _consume(value ? 4 : 5);
      return value;
    }
    if (value is String) {
      _consume(_jsonStringByteLength(value));
      return value;
    }
    if (value is num) {
      if (value is double && !value.isFinite) {
        throw const OrexForwardingException(
          'Сообщение имеет неподдерживаемый формат.',
        );
      }
      _consume(value.toString().length);
      return value;
    }
    if (value is List) {
      _enter(value);
      try {
        _consume(2 + value.length);
        return <Object?>[
          for (final item in value) _copyValue(item, depth + 1),
        ];
      } finally {
        _activeContainers.remove(value);
      }
    }
    if (value is Map) {
      _enter(value);
      try {
        _consume(2 + value.length);
        final result = <String, dynamic>{};
        for (final entry in value.entries) {
          final key = entry.key;
          if (key is! String) {
            throw const OrexForwardingException(
              'Сообщение имеет неподдерживаемый формат.',
            );
          }
          _consume(_jsonStringByteLength(key) + 1);
          result[key] = _copyValue(entry.value, depth + 1);
        }
        return result;
      } finally {
        _activeContainers.remove(value);
      }
    }

    throw const OrexForwardingException(
      'Сообщение имеет неподдерживаемый формат.',
    );
  }

  void _enter(Object value) {
    if (!_activeContainers.add(value)) {
      throw const OrexForwardingException(
        'Сообщение имеет циклическую структуру.',
      );
    }
  }

  void _consume(int bytes) {
    _usedBytes += bytes;
    if (_usedBytes > maxBytes) {
      throw const OrexForwardingException(
        'Служебные данные сообщения слишком велики для безопасной пересылки.',
      );
    }
  }
}

int _jsonStringByteLength(String value) {
  var length = 2; // Opening and closing quotes.
  for (final rune in value.runes) {
    if (rune == 0x22 || rune == 0x5C) {
      length += 2;
    } else if (rune <= 0x1F) {
      length += switch (rune) {
        0x08 || 0x09 || 0x0A || 0x0C || 0x0D => 2,
        _ => 6,
      };
    } else if (rune <= 0x7F) {
      length += 1;
    } else if (rune <= 0x7FF) {
      length += 2;
    } else if (rune <= 0xFFFF) {
      length += 3;
    } else {
      length += 4;
    }
  }
  return length;
}

String _stripPlainReplyFallback(String body) {
  final separator = body.indexOf('\n\n');
  if (separator <= 0) return body;
  final quoted = body.substring(0, separator).split('\n');
  if (quoted.isEmpty || quoted.any((line) => !line.startsWith('>'))) {
    return body;
  }
  return body.substring(separator + 2);
}

String _stripHtmlReplyFallback(String body) => body.replaceFirst(
  RegExp(
    r'^\s*<mx-reply>[\s\S]*?</mx-reply>\s*',
    caseSensitive: false,
  ),
  '',
);

bool _isMxcUri(Object? value) {
  if (value is! String) return false;
  final uri = Uri.tryParse(value);
  return uri != null && uri.scheme == 'mxc' && uri.host.isNotEmpty;
}

const Set<String> _mediaMessageTypes = <String>{
  'm.image',
  'm.video',
  'm.audio',
  'm.file',
};
