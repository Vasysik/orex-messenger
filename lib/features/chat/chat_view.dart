import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
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
  Event? _replyTo; // сообщение, на которое отвечаем

  @override
  void initState() {
    super.initState();
    _openTimeline();
    // Перестраиваемся на sync (имя/аватар/пресенс собеседника в шапке).
    widget.matrix.addListener(_onMatrix);
  }

  void _onMatrix() {
    if (mounted) setState(() {});
  }

  Future<void> _openTimeline() async {
    final room = widget.matrix.client.getRoomById(widget.roomId);
    if (room == null) return;
    // Приглашение: ленту не открываем (мы не в комнате) — покажем приём/отказ.
    if (room.membership == Membership.invite) {
      if (mounted) setState(() => _room = room);
      return;
    }
    final timeline = await room.getTimeline(onUpdate: () {
      if (mounted) setState(() {});
      // Пришло новое сообщение, пока чат открыт → сразу отмечаем прочитанным,
      // чтобы у отправителя появилось «просмотрено» без передёргивания чата.
      _markRead(room);
    });
    await _markRead(room);
    if (mounted) {
      setState(() {
        _room = room;
        _timeline = timeline;
      });
    }
  }

  String? _lastReadId;

  Future<void> _markRead(Room room) async {
    final id = room.lastEvent?.eventId;
    if (id == null || id == _lastReadId) return;
    _lastReadId = id;
    try {
      await room.setReadMarker(id, mRead: id);
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _room == null) return;
    final editing = _editing;
    final replyTo = _replyTo;
    _input.clear();
    setState(() {
      _editing = null;
      _replyTo = null;
    });
    if (editing != null) {
      await _room!.sendTextEvent(text, editEventId: editing.eventId);
    } else {
      await _room!.sendTextEvent(text, inReplyTo: replyTo);
    }
  }

  void _startEdit(Event e) {
    final body = e.getDisplayEvent(_timeline!).calcLocalizedBodyFallback(
          const MatrixDefaultLocalizations(),
        );
    setState(() {
      _editing = e;
      _replyTo = null;
    });
    _input.text = body;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _input.clear();
  }

  void _startReply(Event e) {
    setState(() {
      _replyTo = e;
      _editing = null;
    });
  }

  void _cancelReply() => setState(() => _replyTo = null);

  static const _imgExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

  Future<void> _attach() async {
    final room = _room;
    if (room == null) return;
    final res = await FilePicker.platform.pickFiles(withData: true);
    final files = res?.files ?? const [];
    if (files.isEmpty) return;
    final f = files.first;
    final bytes = f.bytes;
    if (bytes == null) return;
    final ext = (f.extension ?? '').toLowerCase();
    final isImg = _imgExts.contains(ext);
    final data = Uint8List.fromList(bytes);
    final MatrixFile file = isImg
        ? MatrixImageFile(
            bytes: data, name: f.name, mimeType: 'image/$ext')
        : MatrixFile(bytes: data, name: f.name);
    final replyTo = _replyTo;
    setState(() => _replyTo = null);
    await room.sendFileEvent(file, inReplyTo: replyTo);
  }

  void _insertEmoji(String emoji) {
    final sel = _input.selection;
    final text = _input.text;
    if (sel.isValid) {
      final newText = text.replaceRange(sel.start, sel.end, emoji);
      _input.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + emoji.length),
      );
    } else {
      _input.text = text + emoji;
    }
  }

  Future<void> _acceptInvite() async {
    final room = _room;
    if (room == null) return;
    await widget.matrix.acceptInvite(room);
    if (!mounted) return;
    // После join открываем ленту напрямую — membership в кэше мог ещё не доехать.
    final timeline = await room.getTimeline(onUpdate: () {
      if (mounted) setState(() {});
    });
    if (mounted) setState(() => _timeline = timeline);
  }

  Future<void> _rejectInvite() async {
    final room = _room;
    if (room == null) return;
    await widget.matrix.rejectInvite(room);
    if (mounted) widget.onBack?.call();
  }

  void _openCall(bool video) {
    widget.matrix.call.start(widget.roomId, video: video);
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    if (isWide) {
      // На десктопе показываем звонок свёрнутой панелью над чатом.
      widget.matrix.call.minimize();
    } else {
      widget.matrix.call.expand();
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CallScreen(matrix: widget.matrix)),
      );
    }
  }

  @override
  void dispose() {
    widget.matrix.removeListener(_onMatrix);
    _timeline?.cancelSubscriptions();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    if (room == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Приглашение: вместо ленты — приём/отказ прямо в блоке чата.
    // (после принятия лента уже загружена — показываем чат, даже если
    //  membership в кэше ещё «invite».)
    if (room.membership == Membership.invite && _timeline == null) {
      return _InviteView(
        matrix: widget.matrix,
        room: room,
        onBack: widget.onBack,
        onAccept: _acceptInvite,
        onReject: _rejectInvite,
      );
    }

    if (_timeline == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Правки (m.replace) не показываем отдельными сообщениями — их применяет
    // getDisplayEvent на оригинале.
    final events = _timeline!.events
        .where((e) =>
            e.type == EventTypes.Message &&
            !e.redacted && // удалённые просто прячем (без подписи)
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
                onReply: () => _startReply(e),
              );
            },
          ),
        ),
        _InputBar(
          controller: _input,
          onSend: _send,
          editing: _editing != null,
          onCancelEdit: _cancelEdit,
          replyTo: _replyTo,
          onCancelReply: _cancelReply,
          onPickEmoji: _insertEmoji,
          onAttach: _attach,
        ),
      ],
    );
  }
}

/// Экран приглашения внутри блока чата: «вас пригласили» + Принять/Отклонить.
class _InviteView extends StatelessWidget {
  const _InviteView({
    required this.matrix,
    required this.room,
    required this.onAccept,
    required this.onReject,
    this.onBack,
  });

  final MatrixService matrix;
  final Room room;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
          child: Row(
            children: [
              if (onBack != null)
                IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
              MxcAvatar(matrix: matrix, name: name, mxc: room.avatar, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MxcAvatar(
                        matrix: matrix, name: name, mxc: room.avatar, size: 88),
                    const SizedBox(height: 16),
                    Text('Вас пригласили в «$name»',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: onReject,
                            child: const Text('Отклонить'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: OrexColors.copper),
                            onPressed: onAccept,
                            child: const Text('Принять'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
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
    this.replyTo,
    this.onCancelReply,
    required this.onPickEmoji,
    required this.onAttach,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool editing;
  final VoidCallback? onCancelEdit;
  final Event? replyTo;
  final VoidCallback? onCancelReply;
  final void Function(String emoji) onPickEmoji;
  final VoidCallback onAttach;

  static const _emojis = [
    '😀','😁','😂','🤣','😊','😍','😘','😎','🤩','🥳',
    '🤔','😴','😭','😡','👍','👎','🙏','👏','🔥','❤️',
    '🎉','✨','💯','✅','❌','⚡','🌟','😅','😉','🙃',
    '🤝','💪','👀','🍀','☕','🚀','🐿️','💜','😇','🤗',
  ];

  void _openEmoji(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            children: _emojis
                .map((e) => InkWell(
                      onTap: () => onPickEmoji(e),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Text(e, style: const TextStyle(fontSize: 26)),
                      ),
                    ))
                .toList(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reply = replyTo;
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
        if (reply != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
            child: Row(
              children: [
                const Icon(Icons.reply, size: 16, color: OrexColors.copper),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ответ: ${reply.calcLocalizedBodyFallback(const MatrixDefaultLocalizations(), hideReply: true, hideEdit: true)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onCancelReply,
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Row(
            children: [
              IconButton(
                onPressed: onAttach,
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
                  GestureDetector(
                    onTap: () => _openEmoji(context),
                    child: Icon(Icons.emoji_emotions_outlined,
                        color: OrexColors.copper.withValues(alpha: 0.8)),
                  ),
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
