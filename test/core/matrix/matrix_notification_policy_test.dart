import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/matrix/matrix_service.dart';

void main() {
  bool shouldNotify({
    required String roomId,
    required String? foregroundRoomId,
    required bool appIsBackgrounded,
    int previousCount = 0,
    int currentCount = 1,
    bool snapshotReady = true,
  }) => orexShouldPublishSyncedMatrixNotification(
    notificationSnapshotReady: snapshotReady,
    previousCount: previousCount,
    currentCount: currentCount,
    roomId: roomId,
    foregroundRoomId: foregroundRoomId,
    appIsBackgrounded: appIsBackgrounded,
  );

  test('keeps a visible foreground conversation quiet', () {
    expect(
      shouldNotify(
        roomId: '!open:example.org',
        foregroundRoomId: '!open:example.org',
        appIsBackgrounded: false,
      ),
      isFalse,
    );
  });

  test('notifies from the open conversation while the app is minimized', () {
    final appIsBackgrounded = orexIsBackgroundedForNotification(
      lifecycle: AppLifecycleState.resumed,
      isWindows: true,
      desktopWindowVisible: false,
    );

    expect(
      shouldNotify(
        roomId: '!open:example.org',
        foregroundRoomId: '!open:example.org',
        appIsBackgrounded: appIsBackgrounded,
      ),
      isTrue,
    );
  });

  test(
    'a visible Windows host remains foreground while lifecycle is resumed',
    () {
      expect(
        orexIsBackgroundedForNotification(
          lifecycle: AppLifecycleState.resumed,
          isWindows: true,
          desktopWindowVisible: true,
        ),
        isFalse,
      );
    },
  );

  test('sums unread counts for the Windows tray badge', () {
    expect(orexTotalUnreadCount(<int>[2, 0, 3, -7]), 5);
  });

  test('does not turn the initial unread snapshot into notifications', () {
    expect(
      shouldNotify(
        roomId: '!open:example.org',
        foregroundRoomId: null,
        appIsBackgrounded: true,
        snapshotReady: false,
      ),
      isFalse,
    );
  });
}
