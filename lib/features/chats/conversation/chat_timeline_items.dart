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
    final events = rawEvents.where(isRenderable).toList()
      ..sort((a, b) => originServerTs(b).compareTo(originServerTs(a)));

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
    return OrexTimelineGrouper.transform<Event>(
      rawEvents,
      isRenderable: isRenderable,
      isMedia: (event) =>
          event.messageType == MessageTypes.Image ||
          event.messageType == MessageTypes.Video,
      isRedacted: (event) => event.redacted,
      senderId: (event) => event.senderId,
      originServerTs: (event) => event.originServerTs,
    ).map((group) {
      if (group.isAlbum) {
        return AlbumItem(leader: group.leader, events: group.items);
      }
      return SingleEventItem(group.leader);
    }).toList();
  }
}
