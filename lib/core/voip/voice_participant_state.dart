const orexVoiceParticipantEventType = 'ru.orex.voice.participant';

final class VoiceParticipantState {
  const VoiceParticipantState({
    this.handRaised = false,
    this.speakerMuted = false,
    this.reaction,
    this.reactionTs,
  });

  factory VoiceParticipantState.fromContent(
    Map<dynamic, dynamic>? content, {
    int? nowMs,
  }) {
    if (content == null) return const VoiceParticipantState();
    final reactionTs = content['reaction_ts'] is num
        ? (content['reaction_ts'] as num).toInt()
        : null;
    final reactionFresh =
        reactionTs != null &&
        (nowMs ?? DateTime.now().millisecondsSinceEpoch) - reactionTs < 6000;
    return VoiceParticipantState(
      handRaised: content['hand_raised'] == true,
      speakerMuted: content['speaker_muted'] == true,
      reaction: reactionFresh ? content['reaction']?.toString() : null,
      reactionTs: reactionFresh ? reactionTs : null,
    );
  }

  final bool handRaised;
  final bool speakerMuted;
  final String? reaction;
  final int? reactionTs;

  Map<String, Object?> toContent() {
    return <String, Object?>{
      'hand_raised': handRaised,
      'speaker_muted': speakerMuted,
      if (reaction != null) 'reaction': reaction,
      if (reactionTs != null) 'reaction_ts': reactionTs,
    };
  }

  VoiceParticipantState copyWith({
    bool? handRaised,
    bool? speakerMuted,
    String? reaction,
    int? reactionTs,
    bool clearReaction = false,
  }) {
    return VoiceParticipantState(
      handRaised: handRaised ?? this.handRaised,
      speakerMuted: speakerMuted ?? this.speakerMuted,
      reaction: clearReaction ? null : reaction ?? this.reaction,
      reactionTs: clearReaction ? null : reactionTs ?? this.reactionTs,
    );
  }
}
