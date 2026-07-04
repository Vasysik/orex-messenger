import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/voice_state_repository.dart';

void main() {
  group('OrexVoiceStateRepository', () {
    test('reads Matrix content when state is not cached', () {
      final repo = _repo(
        localUserId: '@me:orex',
        remote: {
          '@alice:orex': {'hand_raised': true, 'speaker_muted': false},
        },
      );

      final state = repo.stateForUser('@alice:orex');

      expect(state.handRaised, isTrue);
      expect(state.speakerMuted, isFalse);
    });

    test('updates and publishes local state payload', () async {
      final writes = <String, Map<String, Object?>>{};
      final repo = _repo(localUserId: '@me:orex', writes: writes);

      final changed = await repo.updateAndPublishLocal(
        (state) => state.copyWith(handRaised: true, reaction: 'ok'),
      );

      expect(changed, isTrue);
      expect(writes['@me:orex'], {
        'hand_raised': true,
        'speaker_muted': false,
        'reaction': 'ok',
      });
    });

    test('does not mutate or publish without a local user', () async {
      var called = false;
      final repo = OrexVoiceStateRepository(
        localUserIdProvider: () => null,
        readContent: (_) => null,
        writeContent: (_, _) async => called = true,
      );

      expect(
        repo.updateLocal((state) => state.copyWith(handRaised: true)),
        isFalse,
      );
      expect(await repo.publishLocal(), isFalse);
      expect(called, isFalse);
    });
  });
}

OrexVoiceStateRepository _repo({
  required String? localUserId,
  Map<String, Map<dynamic, dynamic>> remote = const {},
  Map<String, Map<String, Object?>>? writes,
}) {
  return OrexVoiceStateRepository(
    localUserIdProvider: () => localUserId,
    readContent: (userId) => remote[userId],
    writeContent: (userId, content) async {
      writes?[userId] = content;
    },
  );
}
