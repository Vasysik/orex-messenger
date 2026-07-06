import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/config/app_version.dart';

void main() {
  group('OrexAppVersion.displayBuildNumberFromPlatform', () {
    test('keeps ordinary build numbers unchanged', () {
      expect(OrexAppVersion.displayBuildNumberFromPlatform('5'), '5');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('42'), '42');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('999'), '999');
    });

    test('normalizes Flutter split-per-ABI version codes', () {
      expect(OrexAppVersion.displayBuildNumberFromPlatform('1005'), '5');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('2005'), '5');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('3005'), '5');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('4005'), '5');
    });

    test('keeps zero, malformed and unrelated large codes unchanged', () {
      expect(OrexAppVersion.displayBuildNumberFromPlatform('0'), '0');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('2000'), '2000');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('9005'), '9005');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('10005'), '10005');
      expect(OrexAppVersion.displayBuildNumberFromPlatform('custom'), 'custom');
      expect(OrexAppVersion.displayBuildNumberFromPlatform(' 5 '), '5');
    });
  });
}
