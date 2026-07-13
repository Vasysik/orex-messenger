import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:orex_messenger/core/push/orex_push_service.dart';
import 'package:orex_messenger/core/push/push_platform_bridge.dart';
import 'package:orex_messenger/core/push/push_registration_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android app id matches the production Sygnal contract', () {
    expect(OrexNativePushPlatform.androidAppId, 'ru.vasys.orex_messenger');
  });

  test('incoming call open preserves action source and video flag', () {
    const open = OrexPushOpen(<String, String>{
      'orex_kind': 'incoming_call',
      'room_id': '!call:example.org',
      'event_id': r'$ring-event',
      'orex_action': 'answer',
      'orex_from_system': 'true',
      'orex_video': 'true',
    });

    expect(open.kind, 'incoming_call');
    expect(open.roomId, '!call:example.org');
    expect(open.ringEventId, r'$ring-event');
    expect(open.action, 'answer');
    expect(open.fromSystem, isTrue);
    expect(open.video, isTrue);
  });

  test('legacy incoming call open keeps attempt id nullable', () {
    const open = OrexPushOpen(<String, String>{
      'orex_kind': 'incoming_call',
      'room_id': '!call:example.org',
    });

    expect(open.ringEventId, isNull);
  });

  test('Android call lifecycle bridge forwards the exact attempt id', () async {
    const channel = MethodChannel('orex/test_push_attempt');
    final calls = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    final platform = OrexNativePushPlatform(channel: channel);
    addTearDown(() {
      platform.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    await platform.notifyCallAnswering(
      '!call:example.org',
      ringEventId: r'$ring-event',
    );
    await platform.notifyCallUiReady(
      '!call:example.org',
      ringEventId: r'$ring-event',
    );
    await platform.notifyCallEnded(
      '!call:example.org',
      ringEventId: r'$ring-event',
    );

    expect(calls.map((call) => call.method), [
      'callUiAnswering',
      'callUiReady',
      'callUiEnded',
    ]);
    for (final call in calls) {
      expect(call.arguments, {
        'callId': '!call:example.org',
        'ringEventId': r'$ring-event',
      });
    }
  });

  test('cold-start open is held until a UI listener receives it', () async {
    const open = OrexPushOpen(<String, String>{
      'room_id': '!room:example.org',
      'event_id': r'$event',
      'orex_delivery_id': 'delivery-1',
    });
    final platform = _FakePushPlatform(initialOpen: open);
    final client = Client(
      'OrexPushTest',
      database: MatrixSdkDatabase.buildWithoutOpen('OrexPushTest'),
    );
    final service = OrexPushService(
      client: client,
      gateway: null,
      platform: platform,
      tokenStore: _MemoryTokenStore(),
    );

    await service.start();
    expect(platform.acknowledged, isEmpty);

    final received = Completer<OrexPushOpen>();
    final subscription = service.onNotificationOpened.listen((value) {
      if (!received.isCompleted) received.complete(value);
    });

    final delivered = await received.future;
    expect(delivered.roomId, '!room:example.org');
    await platform.firstAcknowledgement.future;
    expect(platform.acknowledged, ['delivery-1']);

    await subscription.cancel();
    await service.dispose();
    await client.dispose(closeDatabase: false);
  });

  test('does not surface local sync notifications while logged out', () async {
    final platform = _FakePushPlatform();
    final client = Client(
      'OrexPushLocalNotificationTest',
      database: MatrixSdkDatabase.buildWithoutOpen(
        'OrexPushLocalNotificationTest',
      ),
    );
    final service = OrexPushService(
      client: client,
      gateway: null,
      platform: platform,
      tokenStore: _MemoryTokenStore(),
    );

    await service.showSyncedMatrixNotification(
      roomId: '!room:example.org',
      eventId: r'$event',
    );

    // Logged-out clients must not surface stale local sync notifications.
    expect(platform.localNotifications, isEmpty);

    await service.dispose();
    await client.dispose(closeDatabase: false);
  });

  test('forwards room-scoped notification dismissal', () async {
    final platform = _FakePushPlatform();
    final client = Client(
      'OrexPushDismissTest',
      database: MatrixSdkDatabase.buildWithoutOpen('OrexPushDismissTest'),
    );
    final service = OrexPushService(
      client: client,
      gateway: null,
      platform: platform,
      tokenStore: _MemoryTokenStore(),
    );

    await service.dismissRoomNotifications('!room:example.org');

    expect(platform.dismissedRooms, ['!room:example.org']);
    await service.dispose();
    await client.dispose(closeDatabase: false);
  });

  test('same native delivery id is not published twice', () async {
    final platform = _FakePushPlatform();
    final client = Client(
      'OrexPushDedupTest',
      database: MatrixSdkDatabase.buildWithoutOpen('OrexPushDedupTest'),
    );
    final service = OrexPushService(
      client: client,
      gateway: null,
      platform: platform,
      tokenStore: _MemoryTokenStore(),
    );
    await service.start();

    final delivered = <OrexPushOpen>[];
    final subscription = service.onNotificationOpened.listen(delivered.add);
    const open = OrexPushOpen(<String, String>{
      'room_id': '!room:example.org',
      'orex_delivery_id': 'delivery-1',
    });

    platform.emitOpen(open);
    platform.emitOpen(open);
    await Future<void>.delayed(Duration.zero);

    expect(delivered, hasLength(1));
    expect(platform.acknowledged, ['delivery-1', 'delivery-1']);

    await subscription.cancel();
    await service.dispose();
    await client.dispose(closeDatabase: false);
  });
}

class _FakePushPlatform implements OrexPushPlatform {
  _FakePushPlatform({this.initialOpen});

  final OrexPushOpen? initialOpen;

  @override
  OrexPushPlatformIdentity get identity => const OrexPushPlatformIdentity(
    appId: 'ru.vasys.orex_messenger',
    platform: 'android',
    deviceLabel: 'Android',
  );
  final StreamController<String> _tokens = StreamController<String>.broadcast();
  final StreamController<OrexPushOpen> _opens =
      StreamController<OrexPushOpen>.broadcast();
  final List<String> acknowledged = <String>[];
  final List<Map<String, String>> localNotifications = <Map<String, String>>[];
  final List<String> dismissedRooms = <String>[];
  final Completer<void> firstAcknowledgement = Completer<void>();

  void emitOpen(OrexPushOpen open) => _opens.add(open);

  @override
  Future<void> acknowledgeNotification(OrexPushOpen open) async {
    final deliveryId = open.deliveryId;
    if (deliveryId == null) return;
    acknowledged.add(deliveryId);
    if (!firstAcknowledgement.isCompleted) firstAcknowledgement.complete();
  }

  @override
  Future<String?> currentToken() async => null;

  @override
  void dispose() {
    unawaited(_tokens.close());
    unawaited(_opens.close());
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isSupported() async => false;

  @override
  Stream<OrexPushOpen> get notificationOpens => _opens.stream;

  @override
  Future<void> notifyCallAnswering(
    String callId, {
    String? ringEventId,
  }) async {}

  @override
  Future<void> notifyCallUiReady(String callId, {String? ringEventId}) async {}

  @override
  Future<void> notifyCallEnded(String callId, {String? ringEventId}) async {}

  @override
  Future<void> notifyCallUiHidden() async {}

  @override
  Future<void> showLocalMatrixNotification(Map<String, String> payload) async {
    localNotifications.add(Map<String, String>.of(payload));
  }

  @override
  Future<void> dismissRoomNotifications(String roomId) async {
    dismissedRooms.add(roomId);
  }

  @override
  Future<OrexPushPermissionStatus> requestPermission() async =>
      OrexPushPermissionStatus.notSupported;

  @override
  Future<OrexPushOpen?> takeInitialNotification() async => initialOpen;

  @override
  Stream<String> get tokenChanges => _tokens.stream;
}

class _MemoryTokenStore implements OrexPushTokenStore {
  @override
  Future<void> clear(String accountKey) async {}

  @override
  Future<String?> read(String accountKey) async => null;

  @override
  Future<void> write(String accountKey, String token) async {}
}
