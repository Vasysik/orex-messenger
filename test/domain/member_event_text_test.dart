import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/domain/rooms/member_event_text.dart';

void main() {
  group('OrexMembershipNotices', () {
    test('describes a newly joined member', () {
      final notice = OrexMembershipNotices.fromMembershipChange(
        senderId: '@alice:example.org',
        senderName: 'Alice',
        targetId: '@alice:example.org',
        membership: 'join',
        previousMembership: 'invite',
        targetDisplayName: 'Alice',
      );

      expect(notice?.kind, OrexMembershipNoticeKind.joined);
      expect(notice?.text, 'Alice присоединился к комнате');
    });

    test('describes a moderator removing another member', () {
      final notice = OrexMembershipNotices.fromMembershipChange(
        senderId: '@moderator:example.org',
        senderName: 'Moderator',
        targetId: '@alice:example.org',
        membership: 'leave',
        previousMembership: 'join',
        targetDisplayName: 'Alice',
      );

      expect(notice?.kind, OrexMembershipNoticeKind.removed);
      expect(notice?.text, 'Moderator удалил Alice из комнаты');
    });

    test('falls back to Matrix localpart when display names are absent', () {
      final notice = OrexMembershipNotices.fromMembershipChange(
        senderId: '@moderator:example.org',
        senderName: '',
        targetId: '@alice:example.org',
        membership: 'ban',
        previousMembership: 'join',
      );

      expect(notice?.kind, OrexMembershipNoticeKind.banned);
      expect(notice?.text, 'moderator заблокировал alice');
    });

    test('ignores unchanged membership state', () {
      final notice = OrexMembershipNotices.fromMembershipChange(
        senderId: '@alice:example.org',
        senderName: 'Alice',
        targetId: '@alice:example.org',
        membership: 'join',
        previousMembership: 'join',
      );

      expect(notice, isNull);
    });
  });
}
