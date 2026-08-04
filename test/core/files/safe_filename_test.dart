import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/files/safe_filename.dart';

void main() {
  group('orexSafeFilename', () {
    test('drops path components and unsafe punctuation', () {
      expect(
        orexSafeFilename(r'../../folder\\bad:name?.mp4'),
        'bad_name_.mp4',
      );
    });

    test('uses fallback for traversal-only values', () {
      expect(orexSafeFilename('../..'), 'download.bin');
    });

    test('protects Windows reserved device names', () {
      expect(orexSafeFilename('CON.txt'), '_CON.txt');
      expect(orexSafeFilename('CON .txt'), '_CON .txt');
      expect(orexSafeFilename('lpt1'), '_lpt1');
    });

    test('keeps short limits safe for reserved names', () {
      expect(orexSafeFilename('CON', maxLength: 3), '_CO');
      expect(orexSafeFilename('anything', maxLength: 1), 'a');
    });

    test('keeps extension while limiting length', () {
      final value = orexSafeFilename('${'a' * 180}.video.mp4');
      expect(value.length, lessThanOrEqualTo(orexSafeFilenameMaxLength));
      expect(value, endsWith('.mp4'));
    });
  });
}
