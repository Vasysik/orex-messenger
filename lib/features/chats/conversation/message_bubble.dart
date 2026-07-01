import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:matrix/matrix.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../../shared/theme/orex_theme.dart';
import '../../../shared/widgets/media_player.dart';
import '../../../core/files/file_helper.dart';
import '../../../core/config/orex_config.dart';
import '../../../domain/rooms/member_event_text.dart';
import '../../../domain/rooms/room_metadata.dart';
import '../../../shared/widgets/media_gallery.dart';

part 'message_attachments.dart';
part 'message_system_cards.dart';


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
    this.albumEvents,
    this.onCancelSend,
    this.onOpenRoomReference,
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
  final List<Event>? albumEvents;
  final VoidCallback? onCancelSend;
  final ValueChanged<String>? onOpenRoomReference;

  static const _quickEmojis = ['👍', '❤️', '😂', '🎉', '🤯', '😢', '🔥', '🙏', '🐿️'];

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

  Future<void> _showMenu(BuildContext context, Offset pos, String body) async {
    final canModify = isMine && !event.redacted;
    // Сообщение ещё не доставлено (отправляется или зависло с ошибкой)
    final isUnsent = event.status == EventStatus.sending ||
        event.status == EventStatus.error;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final scrollController = ScrollController();

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx,
        pos.dy,
        overlay.size.width - pos.dx,
        overlay.size.height - pos.dy,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
      items: [
        // Быстрые реакции — только для доставленных сообщений
        if (onReact != null && !isUnsent)
          PopupMenuItem<String>(
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: 280,
              child: Listener(
                onPointerSignal: (pointerSignal) {
                  if (pointerSignal is PointerScrollEvent) {
                    final double delta = pointerSignal.scrollDelta.dy;
                    scrollController.jumpTo(
                      (scrollController.offset + delta).clamp(0.0, scrollController.position.maxScrollExtent),
                    );
                  }
                },
                child: SingleChildScrollView(
                  controller: scrollController,
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
          ),
        // Отмена отправки — только для недоставленных сообщений
        if (isUnsent && onCancelSend != null)
          const PopupMenuItem(
            value: 'cancel_send',
            child: _MenuRow(
              icon: Icons.cancel_outlined,
              label: 'Отменить отправку',
              color: Color(0xFFCF6679),
            ),
          ),
        if (onReply != null && !isUnsent)
          const PopupMenuItem(
            value: 'reply',
            child: _MenuRow(icon: Icons.reply, label: 'Ответить'),
          ),
        if (!_isMedia && !isUnsent)
          const PopupMenuItem(
            value: 'copy',
            child: _MenuRow(icon: Icons.copy, label: 'Копировать'),
          ),
        if (canModify && onEdit != null && !_isMedia && !_isCallSummary && !isUnsent)
          const PopupMenuItem(
            value: 'edit',
            child: _MenuRow(icon: Icons.edit, label: 'Изменить'),
          ),
        if (canModify && onDelete != null && !isUnsent)
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
    } else if (selected == 'cancel_send') {
      onCancelSend?.call();
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
    return Icon(
      Icons.done_all,
      size: 13,
      color: readByOther ? OrexColors.online : base.withValues(alpha: 0.55),
    );
  }

  bool get _isCallSummary =>
      event.content['com.orex.call_outcome'] is String;

  @override
  Widget build(BuildContext context) {
    final memberNotice = OrexMembershipNotices.fromEvent(event);
    if (memberNotice != null) {
      return _MembershipNoticeCard(data: memberNotice);
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
        : (_isMedia
            ? displayEvent.body
            : displayEvent.calcLocalizedBodyFallback(
                const MatrixDefaultLocalizations(),
                hideReply: true,
                hideEdit: true,
              ));
    
    final ts = event.originServerTs;
    final reactions = _reactions();
    final replied = _repliedEvent();
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment:
            isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onSecondaryTapDown:
                redacted ? null : (d) => _showMenu(context, d.globalPosition, body),
            onTapDown: (!isWide && !redacted)
                ? (d) => _showMenu(context, d.globalPosition, body)
                : null,
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
                  _content(body, redacted, textColor, context),
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

  Widget _content(String body, bool redacted, Color textColor, BuildContext context) {
    if (redacted) {
      return Text('', style: TextStyle(color: textColor.withValues(alpha: 0.6)));
    }
    if (event.type == EventTypes.Encrypted) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 15, color: textColor.withValues(alpha: 0.6)),
          const SizedBox(width: 6),
          Flexible(
            child: Text('Зашифровано — ключ недоступен',
                style: TextStyle(color: textColor.withValues(alpha: 0.7), fontStyle: FontStyle.italic)),
          ),
        ],
      );
    }
    final outcome = event.content['com.orex.call_outcome'] as String?;
    if (outcome != null) {
      final color = switch (outcome) {
        'answered' => OrexColors.online,
        'rejected' => const Color(0xFFCF6679),
        _ => OrexColors.ochre,
      };
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(outcome == 'answered' ? Icons.call : Icons.call_end, size: 18, color: color),
          const SizedBox(width: 8),
          Flexible(
            child: Text(body.replaceFirst('📞 ', ''), style: TextStyle(color: textColor)),
          ),
        ],
      );
    }

    final invite = _InviteNoticeData.tryParse(body);
    if (invite != null) {
      return _InviteNoticeCard(
        data: invite,
        textColor: textColor,
        onTap: invite.reference == null
            ? null
            : () => onOpenRoomReference?.call(invite.reference!),
      );
    }

    final t = timeline;
    if (t == null) return const SizedBox.shrink();

    final isAlbum = albumEvents != null && albumEvents!.isNotEmpty;
    
    String activeCaption = body;
    if (isAlbum) {
      activeCaption = '';
      for (final ev in albumEvents!) {
        final evFname = ev.content.tryGet<String>('filename') ?? '';
        final evBody = ev.body; 
        if (evFname.isNotEmpty && evBody.isNotEmpty && evBody != evFname) {
          activeCaption = evBody;
          break;
        }
      }
    }

    final filename = event.content.tryGet<String>('filename') ?? '';
    final hasCaption = isAlbum ? activeCaption.isNotEmpty : (filename.isNotEmpty && body.isNotEmpty && body != filename);

    final bubbleKey = ValueKey(event.eventId);

    Widget mediaWidget;
    if (isAlbum) {
      mediaWidget = _albumGrid(albumEvents!, context);
    } else {
      switch (event.messageType) {
        case MessageTypes.Image:
          mediaWidget = _AttachmentImage(key: bubbleKey, event: event, timeline: t, myUserId: myUserId ?? '');
          break;
        case MessageTypes.Video:
          mediaWidget = _AttachmentMedia(key: bubbleKey, event: event, isVideo: true, timeline: t, myUserId: myUserId ?? '');
          break;
        case MessageTypes.Audio:
          mediaWidget = _AttachmentMedia(key: bubbleKey, event: event, isVideo: false, timeline: t, myUserId: myUserId ?? '');
          break;
        case MessageTypes.File:
          mediaWidget = _FileTile(key: bubbleKey, event: event, body: body, textColor: textColor);
          break;
        default:
          return Text(body, style: TextStyle(color: textColor, height: 1.3));
      }
    }

    if (hasCaption) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          mediaWidget, 
          const SizedBox(height: 8), 
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              activeCaption, 
              style: TextStyle(color: textColor, height: 1.35, fontSize: 14),
            ),
          ),
        ],
      );
    }

    return mediaWidget;
  }

  Widget _albumGrid(List<Event> album, BuildContext context) {
    final displayLength = album.length > 4 ? 4 : album.length;
    final cols = displayLength == 1 ? 1 : 2;
    final rows = (displayLength / cols).ceil();

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 240),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var r = 0; r < rows; r++)
                Row(
                  children: [
                    for (var c = 0; c < cols; c++)
                      Expanded(
                        child: r * cols + c < displayLength
                            ? Padding(
                                padding: const EdgeInsets.all(1.5),
                                child: SizedBox(
                                  height: 110,
                                  child: _albumTile(r * cols + c, album, context),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _albumTile(int idx, List<Event> album, BuildContext context) {
    final ev = album[idx];
    final bubbleKey = ValueKey(ev.eventId);
    final isLastTile = idx == 3 && album.length > 4;

    Widget tileChild;
    if (ev.messageType == MessageTypes.Image) {
      tileChild = _AttachmentImage(
        key: bubbleKey, 
        event: ev, 
        timeline: timeline!,
        myUserId: myUserId ?? '',
        width: double.infinity,
        height: double.infinity,
      );
    } else {
      tileChild = _AttachmentMedia(
        key: bubbleKey, 
        event: ev, 
        isVideo: true, 
        timeline: timeline!,
        myUserId: myUserId ?? '',
        width: double.infinity,
        height: double.infinity,
      );
    }

    if (isLastTile) {
      final remainingCount = album.length - 3;
      return Stack(
        fit: StackFit.expand,
        children: [
          tileChild,
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => MediaGalleryDialog(
                      timeline: timeline!,
                      initialEventId: ev.eventId,
                      myUserId: myUserId ?? '',
                    ),
                  ),
                );
              },
              child: Container(
                color: Colors.black.withValues(alpha: 0.65),
                alignment: Alignment.center,
                child: Text(
                  '+$remainingCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    return tileChild;
  }

  Widget _replyQuote(Event replied, Color textColor) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: const Border(left: BorderSide(color: OrexColors.copper, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            replied.senderFromMemoryOrFallback.calcDisplayname(),
            style: const TextStyle(color: OrexColors.copper, fontWeight: FontWeight.w600, fontSize: 12),
          ),
          Text(
            replied.calcLocalizedBodyFallback(const MatrixDefaultLocalizations(), hideReply: true, hideEdit: true),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: textColor.withValues(alpha: 0.8), fontSize: 12.5),
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
                    : (isDark ? Colors.black : Colors.white).withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
                border: mine ? Border.all(color: OrexColors.copper, width: 1) : null,
              ),
              child: Text('${e.key} ${e.value.count}', style: const TextStyle(fontSize: 12.5)),
            ),
          );
        }).toList(),
      ),
    );
  }
}


