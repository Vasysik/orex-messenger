import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/voice_participant_state.dart';

void main() {
  group('VoiceParticipantState', () {
    test('parses fresh reactions from Matrix state content', () {
      final state = VoiceParticipantState.fromContent(
        {
          'hand_raised': true,
          'speaker_muted': true,
          'reaction': '+1',
          'reaction_ts': 1000,
        },
        nowMs: 5000,
      );

      expect(state.handRaised, isTrue);
      expect(state.speakerMuted, isTrue);
      expect(state.reaction, '+1');
      expect(state.reactionTs, 1000);
    });

    test('drops stale reactions while keeping durable flags', () {
      final state = VoiceParticipantState.fromContent(
        {
          'hand_raised': true,
          'speaker_muted': false,
          'reaction': '+1',
          'reaction_ts': 1000,
        },
        nowMs: 8000,
      );

      expect(state.handRaised, isTrue);
      expect(state.speakerMuted, isFalse);
      expect(state.reaction, isNull);
      expect(state.reactionTs, isNull);
    });

    test('serializes only active voice UI state', () {
      const state = VoiceParticipantState(
        handRaised: true,
        speakerMuted: true,
        reaction: 'ok',
        reactionTs: 42,
      );

      expect(state.toContent(), {
        'hand_raised': true,
        'speaker_muted': true,
        'reaction': 'ok',
        'reaction_ts': 42,
      });
    });

    test('copyWith can clear ephemeral reaction state', () {
      const state = VoiceParticipantState(
        handRaised: true,
        reaction: 'ok',
        reactionTs: 42,
      );

      final cleared = state.copyWith(clearReaction: true);

      expect(cleared.handRaised, isTrue);
      expect(cleared.reaction, isNull);
      expect(cleared.reactionTs, isNull);
    });
  });
}
