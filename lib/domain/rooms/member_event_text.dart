enum OrexMembershipNoticeKind { joined, left, invited, removed, banned }

final class OrexMembershipNotice {
  const OrexMembershipNotice({required this.kind, required this.text});

  final OrexMembershipNoticeKind kind;
  final String text;
}

/// Human readable membership changes for the chat timeline.
final class OrexMembershipNotices {
  const OrexMembershipNotices._();

  static OrexMembershipNotice? fromMembershipChange({
    required String senderId,
    required String senderName,
    required String targetId,
    required String? membership,
    required String? previousMembership,
    String? targetDisplayName,
    String? previousTargetDisplayName,
  }) {
    final targetName = _displayName(
      targetDisplayName,
      previousTargetDisplayName,
      targetId,
    );
    final actorName = _displayName(senderName, null, senderId);
    final sameUser = senderId == targetId;

    if (membership == 'join' && previousMembership != 'join') {
      return OrexMembershipNotice(
        kind: OrexMembershipNoticeKind.joined,
        text: '$targetName присоединился к комнате',
      );
    }

    if (membership == 'leave' && previousMembership != 'leave') {
      if (!sameUser && previousMembership == 'join') {
        return OrexMembershipNotice(
          kind: OrexMembershipNoticeKind.removed,
          text: '$actorName удалил $targetName из комнаты',
        );
      }
      return OrexMembershipNotice(
        kind: OrexMembershipNoticeKind.left,
        text: '$targetName покинул комнату',
      );
    }

    if (membership == 'invite' && previousMembership != 'invite') {
      return OrexMembershipNotice(
        kind: OrexMembershipNoticeKind.invited,
        text: '$actorName пригласил $targetName',
      );
    }

    if (membership == 'ban' && previousMembership != 'ban') {
      return OrexMembershipNotice(
        kind: OrexMembershipNoticeKind.banned,
        text: '$actorName заблокировал $targetName',
      );
    }

    return null;
  }

  static String _displayName(
    String? displayName,
    String? previousDisplayName,
    String userId,
  ) {
    final current = displayName?.trim();
    if (current != null && current.isNotEmpty) return current;

    final previous = previousDisplayName?.trim();
    if (previous != null && previous.isNotEmpty) return previous;

    final localpart = userId.startsWith('@')
        ? userId.substring(1).split(':').first
        : userId;
    return localpart.isEmpty ? userId : localpart;
  }
}
