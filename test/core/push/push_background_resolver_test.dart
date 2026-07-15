import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:orex_messenger/core/push/push_background_resolver.dart';

void main() {
  late Client client;
  late Room room;

  setUp(() {
    client = Client(
      'OrexPushBackgroundResolverTest',
      database: MatrixSdkDatabase.buildWithoutOpen(
        'OrexPushBackgroundResolverTest',
      ),
    );
    room = Room(id: '!room:example.org', client: client);
  });

  tearDown(() => client.dispose(closeDatabase: false));

  Event message(Map<String, dynamic> content) => Event(
    content: content,
    type: EventTypes.Message,
    eventId: r'$event',
    senderId: '@alice:example.org',
    originServerTs: DateTime.now(),
    room: room,
  );

  test('does not turn a call outcome into an ordinary OS notification', () {
    final event = message(<String, dynamic>{
      'msgtype': 'm.notice',
      'body': 'Missed call',
      'com.orex.call_outcome': 'missed',
    });

    expect(resolveOrexSyncedMatrixNotification(event), isNull);
    expect(event.content['com.orex.call_outcome'], 'missed');
  });

  test('does not suppress ordinary notices', () {
    expect(orexIsCallOutcomeSummary(
      eventType: EventTypes.Message,
      content: <String, dynamic>{
      'msgtype': 'm.notice',
      'body': 'Room settings changed',
      },
    ), isFalse);
  });
}
