import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/matrix/matrix_service.dart';

void main() {
  group('MatrixVoicePermissionsService', () {
    test(
      'allows only explicitly listed users from voice permissions content',
      () {
        final content = {
          'users': {'@alice:orex': true, '@bob:orex': false},
        };

        expect(
          MatrixVoicePermissionsService.isUserAllowedByContent(
            content,
            '@alice:orex',
          ),
          isTrue,
        );
        expect(
          MatrixVoicePermissionsService.isUserAllowedByContent(
            content,
            '@bob:orex',
          ),
          isFalse,
        );
        expect(
          MatrixVoicePermissionsService.isUserAllowedByContent(
            content,
            '@carol:orex',
          ),
          isFalse,
        );
      },
    );

    test('treats missing or malformed content as denied', () {
      expect(
        MatrixVoicePermissionsService.isUserAllowedByContent(
          null,
          '@alice:orex',
        ),
        isFalse,
      );
      expect(
        MatrixVoicePermissionsService.isUserAllowedByContent({
          'users': ['@alice:orex'],
        }, '@alice:orex'),
        isFalse,
      );
    });
  });
}
