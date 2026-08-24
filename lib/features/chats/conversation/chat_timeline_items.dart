import 'package:matrix/matrix.dart';

abstract class ChatItem {
  String get id;
}

class SingleEventItem extends ChatItem {
  SingleEventItem(this.event);
  final Event event;

  @override
  String get id => event.eventId;
}

class AlbumItem extends ChatItem {
  AlbumItem({required this.leader, required this.events});
  final Event leader;
  final List<Event> events;

  @override
  String get id => leader.eventId;
}

class DaySeparatorItem extends ChatItem {
  DaySeparatorItem(DateTime date) : date = date.toLocal();

  final DateTime date;

  @override
  String get id =>
      'day:${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

bool orexSameCalendarDay(DateTime a, DateTime b) {
  final left = a.toLocal();
  final right = b.toLocal();
  return left.year == right.year &&
      left.month == right.month &&
      left.day == right.day;
}

class OrexTimelineGroup<T> {
  const OrexTimelineGroup(this.items) : assert(items.length > 0);

  final List<T> items;

  T get leader => items.first;
  bool get isAlbum => items.length > 1;
}

class OrexTimelineGrouper {
  const OrexTimelineGrouper._();

  static List<OrexTimelineGroup<T>> transform<T>(
    List<T> rawEvents, {
    required bool Function(T event) isRenderable,
    required bool Function(T event) isMedia,
    required bool Function(T event) isRedacted,
    required String Function(T event) senderId,
    required DateTime Function(T event) originServerTs,
  }) {
    final events = rawEvents.where(isRenderable).toList();
    // Matrix Timeline уже хранит обычный путь newest-first. Не запускаем
    // O(N log N) sort на каждое onUpdate длинного чата, но сохраняем fallback
    // для импортированных/тестовых входов с произвольным порядком.
    var newestFirst = true;
    for (var i = 1; i < events.length; i++) {
      if (originServerTs(events[i - 1]).isBefore(originServerTs(events[i]))) {
        newestFirst = false;
        break;
      }
    }
    if (!newestFirst) {
      events.sort((a, b) => originServerTs(b).compareTo(originServerTs(a)));
    }

    final groups = <OrexTimelineGroup<T>>[];
    var i = 0;
    while (i < events.length) {
      final current = events[i];
      if (isRedacted(current) || !isMedia(current)) {
        groups.add(OrexTimelineGroup([current]));
        i++;
        continue;
      }

      final album = <T>[current];
      var j = i + 1;
      while (j < events.length) {
        final next = events[j];
        if (!isRedacted(next) &&
            isMedia(next) &&
            senderId(next) == senderId(current) &&
            orexSameCalendarDay(
              originServerTs(next),
              originServerTs(current),
            ) &&
            originServerTs(
                  next,
                ).difference(originServerTs(current)).abs().inMinutes <
                1) {
          album.add(next);
          j++;
        } else {
          break;
        }
      }

      groups.add(OrexTimelineGroup(album));
      i = j;
    }
    return groups;
  }
}

class OrexTimelineAdapter {
  const OrexTimelineAdapter._();

  static List<ChatItem> transform(
    List<Event> rawEvents, {
    required bool Function(Event event) isRenderable,
  }) {
    final messageItems = OrexTimelineGrouper.transform<Event>(
      rawEvents,
      isRenderable: isRenderable,
      isMedia: (event) =>
          event.messageType == MessageTypes.Image ||
          event.messageType == MessageTypes.Video,
      isRedacted: (event) => event.redacted,
      senderId: (event) => event.senderId,
      originServerTs: (event) => event.originServerTs,
    ).map<ChatItem>((group) {
      if (group.isAlbum) {
        return AlbumItem(leader: group.leader, events: group.items);
      }
      return SingleEventItem(group.leader);
    }).toList();

    if (messageItems.length < 2) return messageItems;

    final result = <ChatItem>[];
    for (var i = 0; i < messageItems.length; i++) {
      final current = messageItems[i];
      result.add(current);
      if (i + 1 >= messageItems.length) continue;

      final next = messageItems[i + 1];
      final currentDate = _originServerTs(current);
      final nextDate = _originServerTs(next);
      if (!orexSameCalendarDay(currentDate, nextDate)) {
        // ListView у чата reverse=true. Разделитель идёт после более нового
        // элемента в данных, поэтому визуально оказывается прямо над ним.
        result.add(DaySeparatorItem(currentDate));
      }
    }
    return result;
  }

  static DateTime _originServerTs(ChatItem item) {
    if (item is SingleEventItem) return item.event.originServerTs;
    if (item is AlbumItem) return item.leader.originServerTs;
    if (item is DaySeparatorItem) return item.date;
    throw StateError('Unknown timeline item ${item.runtimeType}');
  }
}
