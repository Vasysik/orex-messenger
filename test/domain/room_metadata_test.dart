import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/domain/rooms/room_metadata.dart';

void main() {
  group('OrexRoomAlias', () {
    test('normalizes local aliases for Matrix room aliases', () {
      expect(OrexRoomAlias.normalizeLocalpart(' Team News '), 'team-news');
      expect(
        OrexRoomAlias.normalizeLocalpart('#Orex.Chat:example.org'),
        'orex.chat',
      );
      expect(OrexRoomAlias.normalizeLocalpart('***'), isNull);
    });

    test('displays local parts for room aliases and user ids', () {
      expect(OrexRoomAlias.displayAlias('#general:example.org'), '#general');
      expect(OrexRoomAlias.displayAlias('general'), 'general');
      expect(OrexRoomAlias.displayUserId('@alice:example.org'), '@alice');
      expect(OrexRoomAlias.displayUserId('alice'), 'alice');
    });
  });

  group('OrexConversationPreview', () {
    test('builds a room target without losing join metadata', () {
      const room = OrexRoomPreview(
        roomId: '!room:example.org',
        name: 'General',
        alias: '#general:example.org',
        topic: 'Team updates',
        memberCount: 7,
        via: ['example.org'],
      );

      final preview = OrexConversationPreview.fromRoom(room);

      expect(preview.kind, OrexConversationPreviewKind.publicRoom);
      expect(preview.id, '!room:example.org');
      expect(preview.title, 'General');
      expect(preview.subtitle, '#general · 7 участников');
      expect(preview.topic, 'Team updates');
      expect(preview.roomPreview, same(room));
      expect(preview.historyRoomId, '!room:example.org');
      expect(preview.userId, isNull);
      expect(preview.actionLabel, 'Войти в чат');
    });

    test('marks supergroup child room targets separately', () {
      const room = OrexRoomPreview(
        roomId: '!child:example.org',
        name: 'Voice',
        parentSpaceId: '!space:example.org',
      );

      final preview = OrexConversationPreview.fromRoom(room);

      expect(preview.kind, OrexConversationPreviewKind.supergroupChild);
      expect(preview.emptyBody, contains('после входа'));
    });

    test('builds a direct target that does not point at a room yet', () {
      final user = OrexUserPreview(
        userId: '@alice:example.org',
        compactUserId: '@alice',
        displayName: 'Alice',
        avatar: Uri.parse('mxc://example.org/avatar'),
      );

      final preview = OrexConversationPreview.direct(user);

      expect(preview.kind, OrexConversationPreviewKind.direct);
      expect(preview.id, '@alice:example.org');
      expect(preview.title, 'Alice');
      expect(preview.subtitle, '@alice');
      expect(preview.userId, '@alice:example.org');
      expect(preview.historyRoomId, isNull);
      expect(preview.roomPreview, isNull);
      expect(preview.actionLabel, 'Войти в личный чат');
    });
  });
}
