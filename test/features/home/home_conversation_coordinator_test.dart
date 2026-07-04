import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/domain/rooms/room_metadata.dart';
import 'package:orex_messenger/features/home/home_conversation_coordinator.dart';

void main() {
  OrexConversationPreview preview(String id) {
    return OrexConversationPreview.fromRoom(
      OrexRoomPreview(roomId: id, name: 'Preview $id'),
    );
  }

  group('OrexHomeConversationCoordinator', () {
    test('selects rooms and reports foreground room ids', () {
      final foreground = <String?>[];
      final coordinator = OrexHomeConversationCoordinator(
        onForegroundRoomIdChanged: foreground.add,
      );
      addTearDown(coordinator.dispose);

      coordinator.syncForeground();
      coordinator.selectRoom('!room:example.org');

      expect(coordinator.selectedRoomId, '!room:example.org');
      expect(coordinator.previewTarget, isNull);
      expect(coordinator.canPop, isFalse);
      expect(foreground, [null, '!room:example.org']);
    });

    test('opens preview without creating/selecting a room', () {
      final foreground = <String?>[];
      final coordinator = OrexHomeConversationCoordinator(
        onForegroundRoomIdChanged: foreground.add,
      );
      addTearDown(coordinator.dispose);

      final target = preview('!public:example.org');
      coordinator.selectRoom('!local:example.org');
      coordinator.openPreview(target);

      expect(coordinator.selectedRoomId, isNull);
      expect(coordinator.previewTarget, same(target));
      expect(coordinator.canPop, isFalse);
      expect(foreground, ['!local:example.org', null]);
    });

    test('enters preview as a selected room', () {
      final foreground = <String?>[];
      final coordinator = OrexHomeConversationCoordinator(
        onForegroundRoomIdChanged: foreground.add,
      );
      addTearDown(coordinator.dispose);

      coordinator.openPreview(preview('!public:example.org'));
      coordinator.enterPreview('!joined:example.org');

      expect(coordinator.selectedRoomId, '!joined:example.org');
      expect(coordinator.previewTarget, isNull);
      expect(foreground, [null, '!joined:example.org']);
    });

    test('clears preview before clearing selected room', () {
      final foreground = <String?>[];
      final coordinator = OrexHomeConversationCoordinator(
        onForegroundRoomIdChanged: foreground.add,
      );
      addTearDown(coordinator.dispose);

      coordinator.openPreview(preview('!public:example.org'));

      expect(coordinator.clearPreview(), isTrue);
      expect(coordinator.clearSelection(), isFalse);
      expect(coordinator.canPop, isTrue);
      expect(foreground, [null, null]);
    });

    test('tracks visible supergroup child without duplicate notifications', () {
      final foreground = <String?>[];
      var changes = 0;
      final coordinator = OrexHomeConversationCoordinator(
        onForegroundRoomIdChanged: foreground.add,
      )..addListener(() => changes++);
      addTearDown(coordinator.dispose);

      expect(
        coordinator.showSupergroupChild('!space:example.org', '!child:one'),
        isTrue,
      );
      expect(
        coordinator.showSupergroupChild('!space:example.org', '!child:one'),
        isFalse,
      );

      expect(
        coordinator.selectedSupergroupChildId('!space:example.org'),
        '!child:one',
      );
      expect(foreground, ['!child:one']);
      expect(changes, 1);
    });
  });
}
