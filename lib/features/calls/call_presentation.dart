import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_controller.dart';
import '../../core/voip/call_session.dart';

enum OrexCallNoticeKind { camera, error, listenOnly }

final class OrexCallNotice {
  const OrexCallNotice(this.kind, {this.message});

  final OrexCallNoticeKind kind;
  final String? message;
}

final class OrexCallVideoPreferences {
  final Map<String, bool> _preferScreenShareByIdentity = <String, bool>{};

  bool prefersScreenShare(String identity) {
    return _preferScreenShareByIdentity[identity] ?? true;
  }

  bool prefersParticipantScreenShare(lk.Participant participant) {
    return prefersScreenShare(participant.identity);
  }

  void toggle(String identity) {
    _preferScreenShareByIdentity[identity] = !prefersScreenShare(identity);
  }

  void toggleParticipant(lk.Participant participant) {
    toggle(participant.identity);
  }
}

final class OrexCallPresentation {
  const OrexCallPresentation({
    required this.session,
    required this.room,
    required this.participants,
    required this.focusedParticipant,
    required this.visibleParticipants,
    required this.notices,
  });

  final CallSession session;
  final Room? room;
  final List<lk.Participant> participants;
  final lk.Participant? focusedParticipant;
  final List<lk.Participant> visibleParticipants;
  final List<OrexCallNotice> notices;

  bool get hasFocusedParticipant => focusedParticipant != null;

  factory OrexCallPresentation.from({
    required MatrixService matrix,
    required CallController call,
    required CallSession session,
  }) {
    final roomId = call.roomId;
    final participants = session.participants;
    final focusedIdentity = call.focusedParticipantIdentity;
    return OrexCallPresentation(
      session: session,
      room: roomId == null ? null : matrix.client.getRoomById(roomId),
      participants: participants,
      focusedParticipant: participantByIdentity(participants, focusedIdentity),
      visibleParticipants: visibleItems(
        items: participants,
        focusedIdentity: focusedIdentity,
        identityOf: (participant) => participant.identity,
      ),
      notices: noticesForState(
        hasCameraError: session.cameraError != null,
        error: session.error,
        canPublishMedia: session.canPublishMedia,
      ),
    );
  }

  static String titleFor({required bool listenOnly}) {
    return listenOnly ? 'Голосовой канал · просмотр' : 'Звонок';
  }

  static lk.Participant? participantByIdentity(
    List<lk.Participant> participants,
    String? identity,
  ) {
    if (identity == null) return null;
    for (final participant in participants) {
      if (participant.identity == identity) return participant;
    }
    return null;
  }

  static List<T> visibleItems<T>({
    required List<T> items,
    required String? focusedIdentity,
    required String Function(T item) identityOf,
  }) {
    if (focusedIdentity == null) return items;
    return items.where((item) => identityOf(item) == focusedIdentity).toList();
  }

  static List<OrexCallNotice> noticesForState({
    required bool hasCameraError,
    required String? error,
    required bool canPublishMedia,
  }) {
    return [
      if (hasCameraError) const OrexCallNotice(OrexCallNoticeKind.camera),
      if (error != null)
        OrexCallNotice(OrexCallNoticeKind.error, message: error),
      if (!canPublishMedia) const OrexCallNotice(OrexCallNoticeKind.listenOnly),
    ];
  }
}
