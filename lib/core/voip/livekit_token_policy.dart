import 'dart:convert';

final class OrexLiveKitTokenPolicy {
  const OrexLiveKitTokenPolicy._();

  static Map<String, Object?> requestedGrants({
    required bool canPublishMedia,
    required bool listenOnly,
  }) {
    return {
      'can_subscribe': true,
      'can_publish': canPublishMedia,
      'listen_only': listenOnly,
    };
  }

  static void assertCompatibleWithRequestedGrants({
    required String jwt,
    required bool canPublishMedia,
  }) {
    if (canPublishMedia) return;

    final tokenCanPublish = canPublishFromJwt(jwt);
    if (tokenCanPublish == true) {
      throw StateError(
        'lk-jwt-service returned a publish-capable token for listen-only mode',
      );
    }
  }

  static bool? canPublishFromJwt(String jwt) {
    final parts = jwt.split('.');
    if (parts.length < 2) return null;

    final payload = _decodeJsonSegment(parts[1]);
    final videoGrant = payload?['video'];
    if (videoGrant is! Map) return null;

    final canPublish =
        _readBool(videoGrant['canPublish']) ??
        _readBool(videoGrant['can_publish']);
    final sources = videoGrant['canPublishSources'];
    if (sources is List && sources.isNotEmpty) return true;

    return canPublish;
  }

  static Map<String, Object?>? _decodeJsonSegment(String segment) {
    try {
      final normalized = base64Url.normalize(segment);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final json = jsonDecode(decoded);
      if (json is Map<String, Object?>) return json;
      if (json is Map) return json.cast<String, Object?>();
    } catch (_) {
      return null;
    }
    return null;
  }

  static bool? _readBool(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return null;
  }
}
