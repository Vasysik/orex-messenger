import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_attempt.dart';

void main() {
  final now = DateTime(2026, 7, 13, 20);

  test('accepts current and legacy control timestamps', () {
    expect(orexIsPlausibleCallControlTimestamp(null, now: now), isTrue);
    expect(
      orexIsPlausibleCallControlTimestamp(
        now.subtract(const Duration(minutes: 4)),
        now: now,
      ),
      isTrue,
    );
  });

  test('rejects stale and far-future control timestamps', () {
    expect(
      orexIsPlausibleCallControlTimestamp(
        now.subtract(const Duration(minutes: 6)),
        now: now,
      ),
      isFalse,
    );
    expect(
      orexIsPlausibleCallControlTimestamp(
        now.add(const Duration(minutes: 2)),
        now: now,
      ),
      isFalse,
    );
  });
}
