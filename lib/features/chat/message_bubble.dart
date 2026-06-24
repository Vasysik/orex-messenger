import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import '../../theme/orex_theme.dart';

/// Бабл сообщения в орехово-медных тонах. Долгое нажатие — меню (копировать +
/// быстрые реакции). Под баблом — чипы реакций.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.event,
    required this.isMine,
    this.showSender = false,
    this.timeline,
    this.myUserId,
    this.onReact,
    this.onRedact,
    this.onEdit,
    this.onDelete,
    this.onReply,
  });

  final Event event;
  final bool isMine;
  final bool showSender;
  final Timeline? timeline;
  final String? myUserId;
  final void Function(String emoji)? onReact;
  final void Function(String reactionEventId)? onRedact;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onReply;

  /// Сообщение, на которое отвечает это (если это ответ) — ищем в ленте.
  Event? _repliedEvent() {
    final t = timeline;
    if (t == null) return null;
    final id = event.inReplyToEventId();
    if (id == null) return null;
    for (final ev in t.events) {
      if (ev.eventId == id) return ev;
    }
    return null;
  }

  static const _quickEmojis = ['👍', '❤️', '😂', '🎉', '😮', '😢', '🔥', '🙏'];

  Map<String, _ReactionInfo> _reactions() {
    final map = <String, _ReactionInfo>{};
    final t = timeline;
    if (t == null) return map;
    for (final r in event.aggregatedEvents(t, RelationshipTypes.reaction)) {
      final key = r.content
          .tryGetMap<String, Object?>('m.relates_to')?['key'] as String?;
      if (key == null) continue;
      final info = map.putIfAbsent(key, () => _ReactionInfo());
      info.count++;
      if (r.senderId == myUserId) info.myReactionId = r.eventId;
    }
    return map;
  }

  void _openMenu(BuildContext context, String body) {
    final canModify = isMine && !event.redacted;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Wrap(
                spacing: 4,
                children: _quickEmojis
                    .map((e) => IconButton(
                          icon: Text(e, style: const TextStyle(fontSize: 26)),
                          onPressed: () {
                            Navigator.pop(ctx);
                            onReact?.call(e);
                          },
                        ))
                    .toList(),
              ),
            ),
            const Divider(height: 1),
            if (onReply != null)
              ListTile(
                leading: const Icon(Icons.reply, color: OrexColors.copper),
                title: const Text('Ответить'),
                onTap: () {
                  Navigator.pop(ctx);
                  onReply?.call();
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy, color: OrexColors.copper),
              title: const Text('Копировать'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: body));
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Скопировано')),
                );
              },
            ),
            if (canModify && onEdit != null)
              ListTile(
                leading: const Icon(Icons.edit, color: OrexColors.copper),
                title: const Text('Изменить'),
                onTap: () {
                  Navigator.pop(ctx);
                  onEdit?.call();
                },
              ),
            if (canModify && onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: Color(0xFFCF6679)),
                title: const Text('Удалить',
                    style: TextStyle(color: Color(0xFFCF6679))),
                onTap: () {
                  Navigator.pop(ctx);
                  onDelete?.call();
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isMine
        ? (isDark ? OrexColors.darkBubbleOut : OrexColors.lightBubbleOut)
        : (isDark ? OrexColors.darkBubbleIn : OrexColors.lightBubbleIn);
    final textColor = isMine
        ? (isDark ? OrexColors.cream : OrexColors.walnutDeep)
        : (isDark ? OrexColors.darkText : OrexColors.lightText);

    // getDisplayEvent применяет правки (m.replace) — иначе правка приходила
    // отдельным сообщением «* …».
    final displayEvent =
        timeline != null ? event.getDisplayEvent(timeline!) : event;
    final redacted = displayEvent.redacted;
    final edited = !redacted &&
        timeline != null &&
        event.hasAggregatedEvents(timeline!, RelationshipTypes.edit);
    final body = redacted
        ? 'Сообщение удалено'
        : displayEvent
            .calcLocalizedBodyFallback(const MatrixDefaultLocalizations());
    final ts = event.originServerTs;
    final reactions = _reactions();
    final replied = _repliedEvent();

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onLongPress: redacted ? null : () => _openMenu(context, body),
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
              padding: const EdgeInsets.fromLTRB(14, 9, 12, 7),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * 0.62,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(isMine ? 18 : 6),
                  bottomRight: Radius.circular(isMine ? 6 : 18),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showSender && !isMine)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        event.senderFromMemoryOrFallback.calcDisplayname(),
                        style: const TextStyle(
                          color: OrexColors.copper,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  if (replied != null)
                    Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                        border: const Border(
                          left: BorderSide(color: OrexColors.copper, width: 3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            replied.senderFromMemoryOrFallback.calcDisplayname(),
                            style: const TextStyle(
                              color: OrexColors.copper,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            replied.calcLocalizedBodyFallback(
                                const MatrixDefaultLocalizations()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: textColor.withValues(alpha: 0.8),
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Text(
                    body,
                    style: TextStyle(
                      color: redacted
                          ? textColor.withValues(alpha: 0.6)
                          : textColor,
                      height: 1.3,
                      fontStyle:
                          redacted ? FontStyle.italic : FontStyle.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${edited ? 'изм. · ' : ''}'
                    '${ts.hour.toString().padLeft(2, '0')}:'
                    '${ts.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.6),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (reactions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 6, right: 6, bottom: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: reactions.entries.map((e) {
                  final mine = e.value.myReactionId != null;
                  return GestureDetector(
                    onTap: () {
                      if (mine) {
                        onRedact?.call(e.value.myReactionId!);
                      } else {
                        onReact?.call(e.key);
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: mine
                            ? OrexColors.copper.withValues(alpha: 0.30)
                            : (isDark ? Colors.black : Colors.white)
                                .withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(12),
                        border: mine
                            ? Border.all(color: OrexColors.copper, width: 1)
                            : null,
                      ),
                      child: Text('${e.key} ${e.value.count}',
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}

class _ReactionInfo {
  int count = 0;
  String? myReactionId;
}
