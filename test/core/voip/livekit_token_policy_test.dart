import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/livekit_token_policy.dart';

void main() {
  group('OrexLiveKitTokenPolicy', () {
    test('reads canPublish from LiveKit JWT video grant', () {
      final jwt = _jwt({
        'video': {'roomJoin': true, 'canPublish': true},
      });

      expect(OrexLiveKitTokenPolicy.canPublishFromJwt(jwt), isTrue);
    });

    test('treats non-empty canPublishSources as publish capability', () {
      final jwt = _jwt({
        'video': {
          'roomJoin': true,
          'canPublish': false,
          'canPublishSources': ['microphone'],
        },
      });

      expect(OrexLiveKitTokenPolicy.canPublishFromJwt(jwt), isTrue);
    });
  });
}

String _jwt(Map<String, Object?> payload) {
  final header = _segment({'alg': 'none', 'typ': 'JWT'});
  return '$header.${_segment(payload)}.';
}

String _segment(Map<String, Object?> json) {
  final bytes = utf8.encode(jsonEncode(json));
  return base64Url.encode(bytes).replaceAll('=', '');
}
