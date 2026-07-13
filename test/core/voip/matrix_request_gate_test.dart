import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/matrix_request_gate.dart';

void main() {
  group('orexMatrixRateLimitInfo', () {
    test('reads Matrix JSON-shaped errors', () {
      final info = orexMatrixRateLimitInfo({
        'errcode': 'M_LIMIT_EXCEEDED',
        'retry_after_ms': 4287,
      });

      expect(info.isRateLimited, isTrue);
      expect(info.retryAfter, const Duration(milliseconds: 4287));
    });

    test('reads retry_after_ms retained in exception text', () {
      final info = orexMatrixRateLimitInfo(
        Exception('M_LIMIT_EXCEEDED retry_after_ms: 2821'),
      );

      expect(info.isRateLimited, isTrue);
      expect(info.retryAfter, const Duration(milliseconds: 2821));
    });
  });

  group('OrexMatrixRequestGate', () {
    test('coalesces duplicate in-flight semantic writes', () async {
      final gate = OrexMatrixRequestGate(minimumSpacing: Duration.zero);
      final operationCompleter = Completer<int>();
      var calls = 0;

      Future<int> operation() {
        calls++;
        return operationCompleter.future;
      }

      final first = gate.run<int>(
        operationName: 'ring',
        coalesceKey: 'ring:room',
        operation: operation,
      );
      final second = gate.run<int>(
        operationName: 'ring',
        coalesceKey: 'ring:room',
        operation: operation,
      );

      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      operationCompleter.complete(7);
      expect(await first, 7);
      expect(await second, 7);
    });

    test('retries a rate-limited write using bounded server backoff', () async {
      final gate = OrexMatrixRequestGate(
        minimumSpacing: Duration.zero,
        maximumRetryDelay: const Duration(milliseconds: 1),
      );
      var calls = 0;

      final result = await gate.run<String>(
        operationName: 'membership',
        maxAttempts: 2,
        operation: () async {
          calls++;
          if (calls == 1) {
            throw const _RateLimitedError();
          }
          return 'ok';
        },
      );

      expect(result, 'ok');
      expect(calls, 2);
    });

    test('does not replay an unknown write failure', () async {
      final gate = OrexMatrixRequestGate(minimumSpacing: Duration.zero);
      var calls = 0;

      await expectLater(
        gate.run<void>(
          operationName: 'membership',
          maxAttempts: 3,
          operation: () async {
            calls++;
            throw StateError('transport failed after write');
          },
        ),
        throwsStateError,
      );

      expect(calls, 1);
    });
  });
}

final class _RateLimitedError implements Exception {
  const _RateLimitedError();

  String get errcode => 'M_LIMIT_EXCEEDED';
  int get retryAfterMs => 1;

  @override
  String toString() => 'M_LIMIT_EXCEEDED';
}
