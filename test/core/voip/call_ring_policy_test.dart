import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_ring_policy.dart';

void main() {
  group('orexShouldPresentExplicitRing', () {
    final now = DateTime.utc(2026, 7, 13, 20);

    test('accepts a recent ring while membership is still propagating', () {
      expect(
        orexShouldPresentExplicitRing(
          roomHasActiveCall: false,
          eventAge: const Duration(seconds: 5),
        ),
        isTrue,
      );
    });

    test('accepts a ring backed by active MatrixRTC membership', () {
      expect(
        orexShouldPresentExplicitRing(
          roomHasActiveCall: true,
          eventAge: now.difference(now.subtract(const Duration(minutes: 2))),
        ),
        isTrue,
      );
    });

    test('rejects a delayed ring after the call membership disappeared', () {
      expect(
        orexShouldPresentExplicitRing(
          roomHasActiveCall: false,
          eventAge: const Duration(seconds: 13),
        ),
        isFalse,
      );
    });

    test('rejects future timestamps without active membership', () {
      expect(
        orexShouldPresentExplicitRing(
          roomHasActiveCall: false,
          eventAge: const Duration(seconds: -1),
        ),
        isFalse,
      );
    });
  });

  group('orexParseWakeCancellationAction', () {
    test('allows only ringing-surface cleanup actions', () {
      expect(
        orexParseWakeCancellationAction('handled'),
        OrexWakeCancellationAction.handled,
      );
      expect(
        orexParseWakeCancellationAction('ended'),
        OrexWakeCancellationAction.ended,
      );
    });

    test('does not accept plaintext authoritative dispositions', () {
      for (final action in <String>['accepted', 'rejected', 'busy']) {
        expect(orexParseWakeCancellationAction(action), isNull);
      }
    });
  });
}
