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
      expect(orexIsFreshRingAfterLeave(ringAt: null, leftAt: leftAt), isFalse);
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

  group('exact call-attempt promotion', () {
    test('promotes only a current tokenless attempt', () {
      expect(
        orexShouldPromoteLegacyCallInstance(
          hasCurrentCall: true,
          expectedRingEventId: null,
          receivedRingEventId: r'$ring-A',
        ),
        isTrue,
      );
      expect(
        orexShouldPromoteLegacyCallInstance(
          hasCurrentCall: false,
          expectedRingEventId: null,
          receivedRingEventId: r'$ring-A',
        ),
        isFalse,
      );
      expect(
        orexShouldPromoteLegacyCallInstance(
          hasCurrentCall: true,
          expectedRingEventId: r'$ring-A',
          receivedRingEventId: r'$ring-B',
        ),
        isFalse,
      );
    });

    test('accepts first strong disposition but rejects stale exact ids', () {
      expect(
        orexShouldApplyCallDisposition(
          hasCurrentCall: true,
          expectedRingEventId: null,
          receivedRingEventId: r'$ring-A',
        ),
        isTrue,
      );
      expect(
        orexShouldApplyCallDisposition(
          hasCurrentCall: true,
          expectedRingEventId: r'$ring-A',
          receivedRingEventId: r'$ring-B',
        ),
        isFalse,
      );
      expect(
        orexShouldApplyCallDisposition(
          hasCurrentCall: true,
          expectedRingEventId: r'$ring-A',
          receivedRingEventId: null,
        ),
        isFalse,
      );
      expect(
        orexShouldApplyCallDisposition(
          hasCurrentCall: false,
          expectedRingEventId: null,
          receivedRingEventId: r'$ring-A',
        ),
        isTrue,
      );
    });

    test('stored legacy tombstone uses event ordering', () {
      final handledAt = DateTime.utc(2026, 7, 13, 10);
      expect(
        orexShouldPromoteStoredLegacyCallInstance(
          exactAttemptAt: handledAt,
          legacyDispositionAt: handledAt,
        ),
        isTrue,
      );
      expect(
        orexShouldPromoteStoredLegacyCallInstance(
          exactAttemptAt: handledAt.subtract(const Duration(seconds: 1)),
          legacyDispositionAt: handledAt,
        ),
        isTrue,
      );
      expect(
        orexShouldPromoteStoredLegacyCallInstance(
          exactAttemptAt: handledAt.add(const Duration(milliseconds: 1)),
          legacyDispositionAt: handledAt,
        ),
        isFalse,
      );
      expect(
        orexShouldPromoteStoredLegacyCallInstance(
          exactAttemptAt: null,
          legacyDispositionAt: handledAt,
        ),
        isFalse,
      );
      expect(
        orexShouldPromoteStoredLegacyCallInstance(
          exactAttemptAt: handledAt,
          legacyDispositionAt: null,
        ),
        isFalse,
      );
    });

    test('out-of-order exact control tombstones only the future attempt', () {
      expect(
        orexShouldRecordOutOfOrderExactTombstone(
          currentRingEventId: r'$ring-A',
          receivedRingEventId: r'$ring-B',
        ),
        isTrue,
      );
      expect(
        orexShouldRecordOutOfOrderExactTombstone(
          currentRingEventId: r'$ring-A',
          receivedRingEventId: r'$ring-A',
        ),
        isFalse,
      );
      expect(
        orexShouldRecordOutOfOrderExactTombstone(
          currentRingEventId: null,
          receivedRingEventId: r'$ring-B',
        ),
        isFalse,
      );
    });
  });

  group('shown incoming ordering', () {
    final shownAt = DateTime.utc(2026, 7, 13, 10);

    test('only a newer different exact ring supersedes the current UI', () {
      expect(
        orexShouldSupersedeShownIncomingCall(
          shownRingEventId: r'$ring-A',
          shownAt: shownAt,
          candidateRingEventId: r'$ring-B',
          candidateAt: shownAt.add(const Duration(milliseconds: 1)),
        ),
        isTrue,
      );
      expect(
        orexShouldSupersedeShownIncomingCall(
          shownRingEventId: r'$ring-A',
          shownAt: shownAt,
          candidateRingEventId: r'$ring-B',
          candidateAt: shownAt,
        ),
        isFalse,
      );
      expect(
        orexShouldSupersedeShownIncomingCall(
          shownRingEventId: r'$ring-A',
          shownAt: shownAt,
          candidateRingEventId: r'$ring-A',
          candidateAt: shownAt.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
      expect(
        orexShouldSupersedeShownIncomingCall(
          shownRingEventId: null,
          shownAt: shownAt,
          candidateRingEventId: r'$ring-A',
          candidateAt: shownAt.add(const Duration(seconds: 1)),
        ),
        isFalse,
      );
    });
  });
}
