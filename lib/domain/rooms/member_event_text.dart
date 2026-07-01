import 'package:matrix/matrix.dart';

enum OrexMembershipNoticeKind { joined, left, invited, removed, banned }

final class OrexMembershipNotice {
  const OrexMembershipNotice({required this.kind, required this.text});

  final OrexMembershipNoticeKind kind;
  final String text;
}

/// Human readable Matrix membership events for the chat timeline.
final class OrexMembershipNotices {
  const OrexMembershipNotices._();

  static OrexMembershipNotice? fromEvent(Event event) {
    if (event.type != EventTypes.RoomMember) return null;

    final content = event.content;
    final prevContent = event.prevContent ?? const <String, Object?>{};

    final membership = content['membership']?.toString();
    final prevMembership = prevContent['membership']?.toString();
    final targetId = event.stateKey ?? event.senderId;
    final targetName = _displayName(content, prevContent, targetId);
    final senderName = event.senderFromMemoryOrFallback.calcDisplayname();
    final sameUser = event.senderId == targetId;

    if (membership == 'join' && prevMembership != 'join') {
      return OrexMembershipNotice(
        kind: OrexMembershipNoticeKind.joined,
        text: '$targetName присоединился к комнате',
      );
    }

    if (membership == 'leave' && prevMembership != 'leave') {
      if (!sameUser && prevMembership == 'join') {
        return OrexMembershipNotice(
          kind: OrexMembershipNoticeKind.removed,
          text: '$senderName удалил $targetName из комнаты',
        );
      }
      return OrexMembershipNotice(
        kind: OrexMembershipNoticeKind.left,
        text: '$targetName покинул комнату',
      );
    }

    if (membership == 'invite' && prevMembership != 'invite') {
      return OrexMembershipNotice(
        kind: OrexMembershipNoticeKind.invited,
        text: '$senderName пригласил $targetName',
      );
    }

    if (membership == 'ban' && prevMembership != 'ban') {
      return OrexMembershipNotice(
        kind: OrexMembershipNoticeKind.banned,
        text: '$senderName заблокировал $targetName',
      );
    }

    return null;
  }

  static String _displayName(
    Map<String, Object?> content,
    Map<String, Object?> prevContent,
    String userId,
  ) {
    final current = content['displayname']?.toString().trim();
    if (current != null && current.isNotEmpty) return current;

    final previous = prevContent['displayname']?.toString().trim();
    if (previous != null && previous.isNotEmpty) return previous;

    final localpart = userId.startsWith('@') ? userId.substring(1).split(':').first : userId;
    return localpart.isEmpty ? userId : localpart;
  }
}
