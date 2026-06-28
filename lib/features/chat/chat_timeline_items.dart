part of 'chat_view.dart';

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

class OrexTimelineAdapter {
  static List<ChatItem> transform(List<Event> events) {
    final List<ChatItem> items = [];
    int i = 0;
    while (i < events.length) {
      final current = events[i];
      if (current.redacted ||
          (current.messageType != MessageTypes.Image &&
              current.messageType != MessageTypes.Video)) {
        items.add(SingleEventItem(current));
        i++;
        continue;
      }

      final List<Event> albumList = [current];
      int j = i + 1;
      while (j < events.length) {
        final next = events[j];
        if (!next.redacted &&
            (next.messageType == MessageTypes.Image ||
                next.messageType == MessageTypes.Video) &&
            next.senderId == current.senderId &&
            next.originServerTs
                    .difference(current.originServerTs)
                    .abs()
                    .inMinutes <
                1) {
          albumList.add(next);
          j++;
        } else {
          break;
        }
      }

      if (albumList.length > 1) {
        items.add(AlbumItem(leader: current, events: albumList));
        i = j;
      } else {
        items.add(SingleEventItem(current));
        i++;
      }
    }
    return items;
  }
}
