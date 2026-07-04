import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:orex_messenger/core/matrix/matrix_service.dart';

void main() {
  group('Matrix room metadata mappers', () {
    test('maps Matrix Profile to OrexUserPreview', () {
      final profile = Profile(
        userId: '@alice:example.org',
        displayName: 'Alice',
        avatarUrl: Uri.parse('mxc://example.org/avatar'),
      );

      final preview = profile.toOrexUserPreview(compactUserId: '@alice');

      expect(preview.userId, '@alice:example.org');
      expect(preview.compactUserId, '@alice');
      expect(preview.displayName, 'Alice');
      expect(preview.avatar, Uri.parse('mxc://example.org/avatar'));
    });

    test('maps public room directory chunks to OrexRoomPreview', () {
      final room = PublishedRoomsChunk(
        roomId: '!room:example.org',
        name: null,
        canonicalAlias: '#general:example.org',
        avatarUrl: Uri.parse('mxc://example.org/room-avatar'),
        topic: 'Updates',
        numJoinedMembers: 12,
        guestCanJoin: false,
        worldReadable: true,
      );

      final preview = room.toOrexRoomPreview();

      expect(preview.roomId, '!room:example.org');
      expect(preview.name, '#general');
      expect(preview.alias, '#general:example.org');
      expect(preview.avatar, Uri.parse('mxc://example.org/room-avatar'));
      expect(preview.topic, 'Updates');
      expect(preview.memberCount, 12);
    });
  });
}
