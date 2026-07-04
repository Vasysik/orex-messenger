import 'voice_participant_state.dart';

typedef OrexVoiceStateContentReader =
    Map<dynamic, dynamic>? Function(String userId);
typedef OrexVoiceStateContentWriter =
    Future<void> Function(String userId, Map<String, Object?> content);

final class OrexVoiceStateRepository {
  OrexVoiceStateRepository({
    required this.localUserIdProvider,
    required this.readContent,
    required this.writeContent,
  });

  final String? Function() localUserIdProvider;
  final OrexVoiceStateContentReader readContent;
  final OrexVoiceStateContentWriter writeContent;
  final Map<String, VoiceParticipantState> _cache =
      <String, VoiceParticipantState>{};

  String? get localUserId {
    final userId = localUserIdProvider()?.trim();
    return userId == null || userId.isEmpty ? null : userId;
  }

  bool get hasLocalUser => localUserId != null;

  VoiceParticipantState stateForUser(String userId) {
    final cached = _cache[userId];
    if (cached != null) return cached;
    return VoiceParticipantState.fromContent(readContent(userId));
  }

  VoiceParticipantState get localState => stateForUser(localUserId ?? '');

  bool updateLocal(
    VoiceParticipantState Function(VoiceParticipantState state) update,
  ) {
    final userId = localUserId;
    if (userId == null) return false;
    _cache[userId] = update(stateForUser(userId));
    return true;
  }

  Future<bool> publishLocal() async {
    final userId = localUserId;
    if (userId == null) return false;
    await writeContent(userId, stateForUser(userId).toContent());
    return true;
  }

  Future<bool> updateAndPublishLocal(
    VoiceParticipantState Function(VoiceParticipantState state) update,
  ) async {
    if (!updateLocal(update)) return false;
    return publishLocal();
  }
}
