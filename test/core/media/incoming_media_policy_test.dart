import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/media/incoming_media_policy.dart';

void main() {
  group('OrexIncomingMediaPolicy', () {
    test('reads attachment and thumbnail sizes from Matrix info', () {
      final content = <String, Object?>{
        'info': <String, Object?>{
          'size': 123,
          'thumbnail_info': <String, Object?>{'size': 45},
        },
      };

      expect(OrexIncomingMediaPolicy.attachmentSize(content), 123);
      expect(OrexIncomingMediaPolicy.thumbnailSize(content), 45);
    });

    test('unknown Web payloads are never auto-loaded', () {
      const content = <String, Object?>{};

      expect(
        OrexIncomingMediaPolicy.shouldAutoLoadThumbnail(content, isWeb: true),
        isFalse,
      );
      expect(
        OrexIncomingMediaPolicy.shouldAutoLoadImage(content, isWeb: true),
        isFalse,
      );
      expect(
        OrexIncomingMediaPolicy.shouldAutoLoadAudio(content, isWeb: true),
        isFalse,
      );
      expect(
        OrexIncomingMediaPolicy.manualDownloadBlockReason(
          content,
          isWeb: true,
        ),
        isNotNull,
      );
    });

    test('rejects oversized automatic media', () {
      final image = <String, Object?>{
        'info': <String, Object?>{
          'size': OrexIncomingMediaPolicy.webAutoImageBytes + 1,
        },
      };
      final audio = <String, Object?>{
        'info': <String, Object?>{
          'size': OrexIncomingMediaPolicy.webAutoAudioBytes + 1,
        },
      };

      expect(
        OrexIncomingMediaPolicy.shouldAutoLoadImage(image, isWeb: true),
        isFalse,
      );
      expect(
        OrexIncomingMediaPolicy.shouldAutoLoadAudio(audio, isWeb: true),
        isFalse,
      );
    });

    test('blocks oversized manual Web download', () {
      final content = <String, Object?>{
        'info': <String, Object?>{
          'size': OrexIncomingMediaPolicy.webManualDownloadBytes + 1,
        },
      };

      expect(
        OrexIncomingMediaPolicy.manualDownloadBlockReason(
          content,
          isWeb: true,
        ),
        contains('слишком большой'),
      );
    });
  });
}
