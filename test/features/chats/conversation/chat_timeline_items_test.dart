import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:orex_messenger/features/chats/conversation/chat_timeline_items.dart';

void main() {
  group('OrexTimelineGrouper', () {
    test('sorts newest first and groups close media from the same sender', () {
      final base = DateTime(2026, 7, 3, 12);
      final events = [
        _TimelineStub(
          id: 'old-text',
          senderId: '@alice:example.org',
          at: base.subtract(const Duration(minutes: 5)),
          media: false,
        ),
        _TimelineStub(
          id: 'new-image',
          senderId: '@alice:example.org',
          at: base,
          media: true,
        ),
        _TimelineStub(
          id: 'near-video',
          senderId: '@alice:example.org',
          at: base.subtract(const Duration(seconds: 30)),
          media: true,
        ),
      ];

      final groups = _group(events);

      expect(groups, hasLength(2));
      expect(groups.first.isAlbum, isTrue);
      expect(groups.first.items.map((event) => event.id), [
        'new-image',
        'near-video',
      ]);
      expect(groups.last.items.single.id, 'old-text');
    });

    test('does not group media across sender or time boundaries', () {
      final base = DateTime(2026, 7, 3, 12);
      final events = [
        _TimelineStub(
          id: 'image-a',
          senderId: '@alice:example.org',
          at: base,
          media: true,
        ),
        _TimelineStub(
          id: 'image-b',
          senderId: '@bob:example.org',
          at: base.subtract(const Duration(seconds: 10)),
          media: true,
        ),
        _TimelineStub(
          id: 'late-image-a',
          senderId: '@alice:example.org',
          at: base.subtract(const Duration(minutes: 2)),
          media: true,
        ),
      ];

      final groups = _group(events);

      expect(groups, hasLength(3));
      expect(groups.every((group) => !group.isAlbum), isTrue);
    });

    test('does not group media across calendar-day boundaries', () {
      final newer = DateTime(2026, 7, 4, 0, 0, 10);
      final events = [
        _TimelineStub(
          id: 'after-midnight',
          senderId: '@alice:example.org',
          at: newer,
          media: true,
        ),
        _TimelineStub(
          id: 'before-midnight',
          senderId: '@alice:example.org',
          at: newer.subtract(const Duration(seconds: 20)),
          media: true,
        ),
      ];

      final groups = _group(events);

      expect(groups, hasLength(2));
      expect(groups.every((group) => !group.isAlbum), isTrue);
    });

    test('filters non-renderable and redacted events before grouping', () {
      final base = DateTime(2026, 7, 3, 12);
      final events = [
        _TimelineStub(
          id: 'visible-image',
          senderId: '@alice:example.org',
          at: base,
          media: true,
        ),
        _TimelineStub(
          id: 'hidden-image',
          senderId: '@alice:example.org',
          at: base.subtract(const Duration(seconds: 10)),
          media: true,
          renderable: false,
        ),
        _TimelineStub(
          id: 'redacted-image',
          senderId: '@alice:example.org',
          at: base.subtract(const Duration(seconds: 20)),
          media: true,
          redacted: true,
        ),
      ];

      final groups = _group(events);

      expect(groups, hasLength(1));
      expect(groups.single.items.single.id, 'visible-image');
    });
  });

  group('OrexTimelineAdapter day separators', () {
    late Client client;
    late Room room;

    setUp(() {
      client = Client(
        'OrexTimelineAdapterTest',
        database: MatrixSdkDatabase.buildWithoutOpen('OrexTimelineAdapterTest'),
      );
      room = Room(id: '!room:example.org', client: client);
    });

    tearDown(() => client.dispose(closeDatabase: false));

    Event message(String id, DateTime at) => Event(
      content: const <String, dynamic>{
        'msgtype': MessageTypes.Text,
        'body': 'message',
      },
      type: EventTypes.Message,
      eventId: id,
      senderId: '@alice:example.org',
      originServerTs: at,
      room: room,
    );

    test('inserts a separator between different calendar days', () {
      final newer = DateTime(2026, 7, 4, 9);
      final older = DateTime(2026, 7, 3, 23);

      final items = OrexTimelineAdapter.transform(
        [message('newer', newer), message('older', older)],
        isRenderable: (_) => true,
      );

      expect(items, hasLength(3));
      expect(items[0], isA<SingleEventItem>());
      expect(items[1], isA<DaySeparatorItem>());
      expect(items[2], isA<SingleEventItem>());
      expect((items[1] as DaySeparatorItem).date, newer);
    });

    test('does not insert a separator inside one calendar day', () {
      final base = DateTime(2026, 7, 4, 9);

      final items = OrexTimelineAdapter.transform(
        [
          message('newer', base),
          message('older', base.subtract(const Duration(hours: 2))),
        ],
        isRenderable: (_) => true,
      );

      expect(items.whereType<DaySeparatorItem>(), isEmpty);
    });
  });
}

List<OrexTimelineGroup<_TimelineStub>> _group(List<_TimelineStub> events) {
  return OrexTimelineGrouper.transform<_TimelineStub>(
    events,
    isRenderable: (event) => event.renderable && !event.redacted,
    isMedia: (event) => event.media,
    isRedacted: (event) => event.redacted,
    senderId: (event) => event.senderId,
    originServerTs: (event) => event.at,
  );
}

class _TimelineStub {
  const _TimelineStub({
    required this.id,
    required this.senderId,
    required this.at,
    required this.media,
    this.renderable = true,
    this.redacted = false,
  });

  final String id;
  final String senderId;
  final DateTime at;
  final bool media;
  final bool renderable;
  final bool redacted;
}
