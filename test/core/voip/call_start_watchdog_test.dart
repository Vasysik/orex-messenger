import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_start_watchdog.dart';

void main() {
  test('fails a stuck backend stage instead of leaving call UI pending', () async {
    final backend = Completer<void>();

    await expectLater(
      orexRunCallStage<void>(
        stage: 'matrixrtc-signaling',
        timeout: const Duration(milliseconds: 10),
        operation: () => backend.future,
      ),
      throwsA(
        isA<OrexCallStageTimeout>().having(
          (error) => error.stage,
          'stage',
          'matrixrtc-signaling',
        ),
      ),
    );

    // A late backend response must remain harmless to the caller that already
    // timed out and moved into cleanup.
    backend.complete();
    await backend.future;
  });

  test('returns the real backend result before the deadline', () async {
    final result = await orexRunCallStage<int>(
      stage: 'livekit-media',
      timeout: const Duration(seconds: 1),
      operation: () async => 42,
    );

    expect(result, 42);
  });
}
