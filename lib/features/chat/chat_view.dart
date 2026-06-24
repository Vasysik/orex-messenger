import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../../core/matrix_service.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import '../call/call_screen.dart';
import 'message_bubble.dart';

/// Правая панель: шапка чата, лента сообщений, строка ввода.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.matrix,
    required this.roomId,
    this.onBack,
  });

  final MatrixService matrix;
  final String roomId;
  final VoidCallback? onBack;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  Timeline? _timeline;
  Room? _room;
  Event? _editing; // редактируемое сообщение (если есть)

  @override
  void initState() {
    super.initState();
    _openTimeline();
  }

  Future<void> _openTimeline() async {
    final room = widget.matrix.client.getRoomById(widget.roomId);
    if (room == null) return;
    final timeline = await room.getTimeline(onUpdate: () {
      if (mounted) setState(() {});
    });
    final lastId = room.lastEvent?.eventId;
    if (lastId != null) {
      await room.setReadMarker(lastId, mRead: lastId);
    }
    if (mounted) {
      setState(() {
        _room = room;
        _timeline = timeline;
      });
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _room == null) return;
    final editing = _editing;
    _input.clear();
    setState(() => _editing = null);
    if (editing != null) {
      await _room!.sendTextEvent(text, editEventId: editing.eventId);
    } else {
      await widget.matrix.sendText(_room!, text);
    }
  }

  void _startEdit(Event e) {
    final body = e.getDisplayEvent(_timeline!).calcLocalizedBodyFallback(
          const MatrixDefaultLocalizations(),
        );
    setState(() => _editing = e);
    _input.text = body;
    _input.selection =
        TextSelection.collapsed(offset: _input.text.length);
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _input.clear();
  }

  void _openCall(bool video) {
    widget.matrix.call.start(widget.roomId, video: video);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CallScreen(matrix: widget.matrix)),
    );
  }

  @override
  void dispose() {
    _timeline?.cancelSubscriptions();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    if (room == null || _timeline == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Правки (m.replace) не показываем отдельными сообщениями — их применяет
    // getDisplayEvent на оригинале.
    final events = _timeline!.events
        .where((e) =>
            e.type == EventTypes.Message &&
            e.relationshipType != RelationshipTypes.edit)
        .toList();
    final myId = widget.matrix.client.userID;

    return Column(
      children: [
        _ChatHeader(
          matrix: widget.matrix,
          room: room,
          onBack: widget.onBack,
          onCall: _openCall,
        ),
        Divider(height: 1, color: OrexColors.copper.withValues(alpha: 0.12)),
        _CallJoinBanner(matrix: widget.matrix, room: room, onJoin: _openCall),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            reverse: true, // новые снизу
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            itemCount: events.length,
            itemBuilder: (_, i) {
              final e = events[i];
              return MessageBubble(
                event: e,
                isMine: e.senderId == myId,
                showSender: !room.isDirectChat,
                timeline: _timeline,
                myUserId: myId,
                onReact: (emoji) => room.sendReaction(e.eventId, emoji),
                onRedact: (rid) => room.redactEvent(rid),
                onEdit: () => _startEdit(e),
                onDelete: () => room.redactEvent(e.eventId),
              );
            },
          ),
        ),
        _InputBar(
          controller: _input,
          onSend: _send,
          editing: _editing != null,
          onCancelEdit: _cancelEdit,
        ),
      ],
    );
  }
}

/// Полоска «Идёт звонок · Войти» в чате, когда в комнате активен звонок,
/// а мы в нём не участвуем.
class _CallJoinBanner extends StatelessWidget {
  const _CallJoinBanner({
    required this.matrix,
    required this.room,
    required this.onJoin,
  });

  final MatrixService matrix;
  final Room room;
  final void Function(bool video) onJoin;

  @override
  Widget build(BuildContext context) {
    final voipSvc = matrix.voip;
    if (voipSvc == null) return const SizedBox.shrink();
    final hasCall =
        room.hasActiveGroupCall(voipSvc.voip, ignoreDirectChats: false);
    if (!hasCall) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: matrix.call,
      builder: (context, _) {
        final inThisCall =
            matrix.call.isActive && matrix.call.roomId == room.id;
        if (inThisCall) return const SizedBox.shrink();
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => onJoin(false),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: OrexColors.online.withValues(alpha: 0.18),
              child: Row(
                children: [
                  const Icon(Icons.call, color: OrexColors.online, size: 20),
                  const SizedBox(width: 10),
                  const Expanded(child: Text('Идёт звонок')),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: OrexColors.online,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => onJoin(false),
                    child: const Text('Войти'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.matrix,
    required this.room,
    required this.onCall,
    this.onBack,
  });

  final MatrixService matrix;
  final Room room;
  final ValueChanged<bool> onCall; // true = видео
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
            ),
          MxcAvatar(
            matrix: matrix,
            name: room.getLocalizedDisplayname(),
            mxc: room.avatar,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  room.getLocalizedDisplayname(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                _PresenceLine(room: room),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Аудиозвонок',
            onPressed: () => onCall(false),
            icon: const Icon(Icons.call),
            color: OrexColors.copper,
          ),
          IconButton(
            tooltip: 'Видеозвонок',
            onPressed: () => onCall(true),
            icon: const Icon(Icons.videocam),
            color: OrexColors.copper,
          ),
        ],
      ),
    );
  }
}

/// Подпись под именем: статус сети для личных чатов, число участников для групп.
class _PresenceLine extends StatelessWidget {
  const _PresenceLine({required this.room});
  final Room room;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final dmId = room.directChatMatrixID;

    if (dmId == null) {
      // Группа/канал — показываем количество участников.
      return Text('${room.summary.mJoinedMemberCount ?? 0} участников',
          style: style);
    }

    return FutureBuilder<CachedPresence>(
      future: room.client.fetchCurrentPresence(dmId),
      builder: (context, snap) {
        final p = snap.data;
        final text = switch (p?.presence) {
          PresenceType.online => 'в сети',
          PresenceType.unavailable => 'был(а) недавно',
          _ => p?.lastActiveTimestamp != null ? 'был(а) недавно' : 'не в сети',
        };
        return Text(text, style: style);
      },
    );
  }
}

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.onSend,
    this.editing = false,
    this.onCancelEdit,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool editing;
  final VoidCallback? onCancelEdit;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (editing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
            child: Row(
              children: [
                const Icon(Icons.edit, size: 16, color: OrexColors.copper),
                const SizedBox(width: 8),
                const Expanded(child: Text('Редактирование сообщения')),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onCancelEdit,
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Row(
            children: [
              IconButton(
                onPressed: () {}, // вложения
                icon: const Icon(Icons.attach_file),
                color: OrexColors.copper,
              ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: (isDark ? Colors.black : Colors.white)
                    .withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: OrexColors.copper.withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 5,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Сообщение',
                      ),
                    ),
                  ),
                  Icon(Icons.emoji_emotions_outlined,
                      color: OrexColors.copper.withValues(alpha: 0.8)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onSend,
            child: Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: OrexColors.copperGradient,
              ),
              child: const Icon(Icons.send, color: OrexColors.cream, size: 20),
            ),
          ),
            ],
          ),
        ),
      ],
    );
  }
}
