import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import '../../theme/orex_theme.dart';

/// Бабл сообщения. Контекст-меню (реакции/ответ/копировать/изменить/удалить)
/// открывается долгим нажатием ИЛИ правым кликом — всплывает рядом с сообщением.
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

  static const _quickEmojis = ['👍', '❤️', '😂', '🎉', '😮', '😢', '🔥', '🙏'];

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

  bool get _isMedia =>
      event.messageType == MessageTypes.Image ||
      event.messageType == MessageTypes.Video ||
      event.messageType == MessageTypes.Audio ||
      event.messageType == MessageTypes.File;

  // --- Контекст-меню рядом с сообщением (не на весь экран) ---
  Future<void> _showMenu(BuildContext context, Offset pos, String body) async {
    final canModify = isMine && !event.redacted;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy,
        overlay.size.width - pos.dx,
        overlay.size.height - pos.dy,
      ),
      items: [
        if (onReact != null)
          PopupMenuItem<String>(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: 280,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: _quickEmojis
                      .map((e) => InkWell(
                            onTap: () => Navigator.pop(context, 'react:$e'),
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: Text(e,
                                  style: const TextStyle(fontSize: 22)),
                            ),
                          ))
                      .toList(),
                ),
              ),
            ),
          ),
        if (onReply != null)
          const PopupMenuItem(
            value: 'reply',
            child: _MenuRow(icon: Icons.reply, label: 'Ответить'),
          ),
        if (!_isMedia)
          const PopupMenuItem(
            value: 'copy',
            child: _MenuRow(icon: Icons.copy, label: 'Копировать'),
          ),
        if (canModify && onEdit != null && !_isMedia)
          const PopupMenuItem(
            value: 'edit',
            child: _MenuRow(icon: Icons.edit, label: 'Изменить'),
          ),
        if (canModify && onDelete != null)
          const PopupMenuItem(
            value: 'delete',
            child: _MenuRow(
                icon: Icons.delete_outline,
                label: 'Удалить',
                color: Color(0xFFCF6679)),
          ),
      ],
    );
    if (selected == null) return;
    if (selected.startsWith('react:')) {
      onReact?.call(selected.substring(6));
    } else if (selected == 'reply') {
      onReply?.call();
    } else if (selected == 'copy') {
      await Clipboard.setData(ClipboardData(text: body));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Скопировано')),
        );
      }
    } else if (selected == 'edit') {
      onEdit?.call();
    } else if (selected == 'delete') {
      onDelete?.call();
    }
  }

  Widget _statusIcon(Color base) {
    if (event.status == EventStatus.sending) {
      return Icon(Icons.schedule, size: 13, color: base.withValues(alpha: 0.6));
    }
    if (event.status == EventStatus.error) {
      return const Icon(Icons.error_outline, size: 13, color: Color(0xFFCF6679));
    }
    final readByOther = event.room.receiptState.global.otherUsers.values.any(
      (r) => r.ts >= event.originServerTs.millisecondsSinceEpoch,
    );
    // Отправлено — две серые галочки; просмотрено — две зелёные.
    return Icon(
      Icons.done_all,
      size: 13,
      color: readByOther ? OrexColors.online : base.withValues(alpha: 0.55),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Итог звонка — центрированной служебной плашкой (не обычным баблом).
    final outcome = event.content['com.orex.call_outcome'] as String?;
    if (outcome != null && !event.redacted) {
      return _CallSummaryCard(
        text: event.body,
        outcome: outcome,
        ts: event.originServerTs,
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isMine
        ? (isDark ? OrexColors.darkBubbleOut : OrexColors.lightBubbleOut)
        : (isDark ? OrexColors.darkBubbleIn : OrexColors.lightBubbleIn);
    final textColor = isMine
        ? (isDark ? OrexColors.cream : OrexColors.walnutDeep)
        : (isDark ? OrexColors.darkText : OrexColors.lightText);

    final displayEvent =
        timeline != null ? event.getDisplayEvent(timeline!) : event;
    final redacted = displayEvent.redacted;
    final edited = !redacted &&
        timeline != null &&
        event.hasAggregatedEvents(timeline!, RelationshipTypes.edit);
    final body = redacted
        ? ''
        : displayEvent.calcLocalizedBodyFallback(
            const MatrixDefaultLocalizations(),
            hideReply: true,
            hideEdit: true,
          );
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
            onLongPressStart:
                redacted ? null : (d) => _showMenu(context, d.globalPosition, body),
            onSecondaryTapDown:
                redacted ? null : (d) => _showMenu(context, d.globalPosition, body),
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
                  if (replied != null) _replyQuote(replied, textColor),
                  _content(body, redacted, textColor),
                  const SizedBox(height: 2),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${edited ? 'изм. · ' : ''}'
                        '${ts.hour.toString().padLeft(2, '0')}:'
                        '${ts.minute.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          color: textColor.withValues(alpha: 0.6),
                          fontSize: 11,
                        ),
                      ),
                      if (isMine && !redacted) ...[
                        const SizedBox(width: 4),
                        _statusIcon(textColor),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (reactions.isNotEmpty) _reactionChips(reactions, isDark),
        ],
      ),
    );
  }

  Widget _content(String body, bool redacted, Color textColor) {
    if (redacted) {
      return Text('',
          style: TextStyle(color: textColor.withValues(alpha: 0.6)));
    }
    switch (event.messageType) {
      case MessageTypes.Image:
        return _AttachmentImage(event: event);
      case MessageTypes.Video:
      case MessageTypes.Audio:
      case MessageTypes.File:
        return _FileTile(event: event, body: body, textColor: textColor);
      default:
        return Text(body, style: TextStyle(color: textColor, height: 1.3));
    }
  }

  Widget _replyQuote(Event replied, Color textColor) {
    return Container(
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
              const MatrixDefaultLocalizations(),
              hideReply: true,
              hideEdit: true,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: textColor.withValues(alpha: 0.8),
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _reactionChips(Map<String, _ReactionInfo> reactions, bool isDark) {
    return Padding(
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
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: mine
                    ? OrexColors.copper.withValues(alpha: 0.30)
                    : (isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
                border:
                    mine ? Border.all(color: OrexColors.copper, width: 1) : null,
              ),
              child: Text('${e.key} ${e.value.count}',
                  style: const TextStyle(fontSize: 12.5)),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? OrexColors.copper;
    return Row(
      children: [
        Icon(icon, color: c, size: 20),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

/// Картинка-вложение: грузим и расшифровываем байты через SDK.
class _AttachmentImage extends StatefulWidget {
  const _AttachmentImage({required this.event});
  final Event event;

  @override
  State<_AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<_AttachmentImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await widget.event.downloadAndDecryptAttachment();
      if (mounted) setState(() => _bytes = file.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320, maxWidth: 280),
        child: _bytes != null
            ? Image.memory(_bytes!, fit: BoxFit.cover)
            : Container(
                width: 200,
                height: 150,
                color: Colors.black.withValues(alpha: 0.2),
                alignment: Alignment.center,
                child: _failed
                    ? const Icon(Icons.broken_image, color: OrexColors.cream)
                    : const CircularProgressIndicator(
                        strokeWidth: 2, color: OrexColors.copper),
              ),
      ),
    );
  }
}

/// Файл-вложение: иконка + имя.
class _FileTile extends StatelessWidget {
  const _FileTile(
      {required this.event, required this.body, required this.textColor});
  final Event event;
  final String body;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final name = event.content.tryGet<String>('filename') ??
        event.content.tryGet<String>('body') ??
        body;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file, color: OrexColors.copper),
          const SizedBox(width: 8),
          Flexible(
            child: Text(name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: textColor)),
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

/// Центрированная служебная плашка об итоге звонка (Звонок / Пропущенный /
/// Отклонённый вызов).
class _CallSummaryCard extends StatelessWidget {
  const _CallSummaryCard({
    required this.text,
    required this.outcome,
    required this.ts,
  });
  final String text;
  final String outcome;
  final DateTime ts;

  @override
  Widget build(BuildContext context) {
    final color = switch (outcome) {
      'answered' => OrexColors.online,
      'rejected' => const Color(0xFFCF6679),
      _ => OrexColors.ochre,
    };
    final label = text.replaceFirst('📞 ', '');
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(outcome == 'answered' ? Icons.call : Icons.call_end,
                size: 16, color: color),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 8),
            Text(
              '${ts.hour.toString().padLeft(2, '0')}:'
              '${ts.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.color
                    ?.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
