import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/voip_service.dart';

void main() {
  group('orexShouldResumePersistedCallAfterRing', () {
    test('continuing membership alone stays suppressed', () {
      expect(
        orexShouldResumePersistedCallAfterRing(
          hasFreshExplicitRing: false,
        ),
        isFalse,
      );
    });

    test('a fresh explicit ring starts a new incoming attempt', () {
      expect(
        orexShouldResumePersistedCallAfterRing(
          hasFreshExplicitRing: true,
        ),
        isTrue,
      );
    });
  });

  group('orexShouldMarkStartupCallAsSeen', () {
    test('suppresses only calls that already existed in the startup snapshot', () {
      expect(
        orexShouldMarkStartupCallAsSeen(
          existedAtStartup: true,
          hasFreshExplicitRing: false,
        ),
        isTrue,
      );
      expect(
        orexShouldMarkStartupCallAsSeen(
          existedAtStartup: false,
          hasFreshExplicitRing: false,
        ),
        isFalse,
      );
    });

    test('fresh explicit ring always bypasses startup suppression', () {
      expect(
        orexShouldMarkStartupCallAsSeen(
          existedAtStartup: true,
          hasFreshExplicitRing: true,
        ),
        isFalse,
      );
    });
  });
}
