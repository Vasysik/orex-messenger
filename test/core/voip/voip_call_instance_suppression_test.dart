import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/voip_service.dart';

void main() {
  group('orexIsNewCallInstanceAfterPersistedLeave', () {
    test('keeps suppressing the same continuing call membership', () {
      expect(
        orexIsNewCallInstanceAfterPersistedLeave(
          previousMemberships: {'alice-device-call-membership'},
          currentMemberships: {'alice-device-call-membership'},
          hasFreshRing: false,
        ),
        isFalse,
      );
    });

    test('accepts a genuinely new membership instance', () {
      expect(
        orexIsNewCallInstanceAfterPersistedLeave(
          previousMemberships: {'old-membership'},
          currentMemberships: {'new-membership'},
          hasFreshRing: false,
        ),
        isTrue,
      );
    });

    test('fresh explicit ring starts a new call without a cached baseline', () {
      expect(
        orexIsNewCallInstanceAfterPersistedLeave(
          previousMemberships: const <String>{},
          currentMemberships: const <String>{},
          hasFreshRing: true,
        ),
        isTrue,
      );
    });

    test('empty baseline alone never resurrects a continuing call', () {
      expect(
        orexIsNewCallInstanceAfterPersistedLeave(
          previousMemberships: const <String>{},
          currentMemberships: {'same-remote-call'},
          hasFreshRing: false,
        ),
        isFalse,
      );
    });
  });

  group('orexIsFreshRingAfterLeave', () {
    final leftAt = DateTime.utc(2026, 7, 10, 12);

    test('accepts only a ring newer than the local leave disposition', () {
      expect(
        orexIsFreshRingAfterLeave(
          ringAt: leftAt.add(const Duration(milliseconds: 1)),
          leftAt: leftAt,
        ),
        isTrue,
      );
      expect(
        orexIsFreshRingAfterLeave(ringAt: leftAt, leftAt: leftAt),
        isFalse,
      );
      expect(
        orexIsFreshRingAfterLeave(
          ringAt: leftAt.subtract(const Duration(seconds: 1)),
          leftAt: leftAt,
        ),
        isFalse,
      );
      expect(
        orexIsFreshRingAfterLeave(ringAt: null, leftAt: leftAt),
        isFalse,
      );
    });
  });

  group('orexShouldMarkStartupCallAsSeen', () {
    test('suppresses only calls that existed in the startup snapshot', () {
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

    test('fresh explicit ring bypasses startup suppression', () {
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
