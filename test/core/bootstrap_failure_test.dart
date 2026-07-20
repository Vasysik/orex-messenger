import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/bootstrap_failure.dart';

void main() {
  group('OrexStartupFailure', () {
    test('exposes a stable support code without the original exception', () {
      const failure = OrexStartupFailure(OrexStartupStage.crypto);

      expect(failure.code, 'STARTUP_CRYPTO');
      expect(failure.userMessage, contains('шифрования'));
      expect(failure.toString(), 'STARTUP_CRYPTO');
    });

    test('gives every startup stage a non-empty unique code', () {
      final codes = OrexStartupStage.values.map((stage) => stage.code);

      expect(codes, everyElement(isNotEmpty));
      expect(codes.toSet(), hasLength(OrexStartupStage.values.length));
    });
  });
}
