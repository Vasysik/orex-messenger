import 'package:matrix/matrix.dart';

import '../../domain/rooms/member_event_text.dart';

export '../../domain/rooms/member_event_text.dart';

extension OrexMatrixMembershipNoticeMapper on Event {
  OrexMembershipNotice? toOrexMembershipNotice() {
    if (type != EventTypes.RoomMember) return null;

    final previousContent = prevContent ?? const <String, Object?>{};
    final targetId = stateKey ?? senderId;

    return OrexMembershipNotices.fromMembershipChange(
      senderId: senderId,
      senderName: senderFromMemoryOrFallback.calcDisplayname(),
      targetId: targetId,
      membership: content['membership']?.toString(),
      previousMembership: previousContent['membership']?.toString(),
      targetDisplayName: content['displayname']?.toString(),
      previousTargetDisplayName: previousContent['displayname']?.toString(),
    );
  }
}
