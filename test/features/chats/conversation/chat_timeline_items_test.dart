import 'package:flutter_test/flutter_test.dart';
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
