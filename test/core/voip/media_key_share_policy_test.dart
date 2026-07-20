import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/orex_livekit_backend.dart';
import 'package:orex_messenger/core/voip/voip_service.dart';

void main() {
  group('late-join media key sharing', () {
    test('shares the current local key with a newly observed participant', () {
      expect(
        orexPendingMediaKeyShareTargets(
          remoteParticipantIds: const ['alice:phone', 'bob:phone'],
          sharedParticipantIds: {'alice:phone'},
        ),
        {'bob:phone'},
      );
    });

    test(
      'does not rotate again when every active device already has the key',
      () {
        expect(
          orexPendingMediaKeyShareTargets(
            remoteParticipantIds: const ['alice:phone'],
            sharedParticipantIds: {'alice:phone'},
          ),
          isEmpty,
        );
      },
    );

    test('deduplicates repeated membership observations', () {
      expect(
        orexPendingMediaKeyShareTargets(
          remoteParticipantIds: const [
            'alice:phone',
            'alice:phone',
            'bob:desktop',
          ],
          sharedParticipantIds: <String>{},
        ),
        {'alice:phone', 'bob:desktop'},
      );
    });

    test('re-shares with every active device after local key rotation', () {
      expect(
        orexPendingMediaKeyShareTargets(
          remoteParticipantIds: const ['alice:phone', 'bob:desktop'],
          sharedParticipantIds: {'alice:phone', 'bob:desktop'},
          sharedLocalKeyRevision: 3,
          currentLocalKeyRevision: 4,
        ),
        {'alice:phone', 'bob:desktop'},
      );
    });

    test('replays the current key to a forced active device', () {
      expect(
        orexPendingMediaKeyShareTargets(
          remoteParticipantIds: const ['alice:phone', 'bob:desktop'],
          sharedParticipantIds: {'alice:phone', 'bob:desktop'},
          forceReplayParticipantIds: const ['alice:phone'],
        ),
        {'alice:phone'},
      );
    });

    test('never replays a key to a device that already left', () {
      expect(
        orexPendingMediaKeyShareTargets(
          remoteParticipantIds: const ['alice:phone'],
          sharedParticipantIds: {'alice:phone'},
          forceReplayParticipantIds: const ['bob:desktop'],
        ),
        isEmpty,
      );
    });

    test('keeps a same-device mobile rejoin in leave rotation recipients', () {
      expect(
        orexMediaKeyRecipientIdsAfterLeaveDebounce(const [
          'alice:phone',
          'bob:desktop',
        ]),
        contains('alice:phone'),
      );
    });
  });

  group('media key call epoch', () {
    test('accepts the active sender membership', () {
      expect(
        orexMediaKeySenderEpochMatches(
          claimedEpoch: 'membership-2',
          activeMembershipId: 'membership-2',
        ),
        isTrue,
      );
    });

    test('rejects a delayed key from an older call in the same room', () {
      expect(
        orexMediaKeySenderEpochMatches(
          claimedEpoch: 'membership-1',
          activeMembershipId: 'membership-2',
        ),
        isFalse,
      );
    });

    test(
      'keeps compatibility with MatrixRTC clients without the extension',
      () {
        expect(
          orexMediaKeySenderEpochMatches(
            claimedEpoch: null,
            activeMembershipId: 'membership-2',
          ),
          isTrue,
        );
      },
    );
  });
}
