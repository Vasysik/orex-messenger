import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../../core/matrix_service.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import '../call/call_screen.dart';
import 'message_bubble.dart';
import 'room_settings_sheet.dart';

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

/// Правая панель: шапка чата, лента сообщений, строка ввода.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.matrix,
    required this.roomId,
    this.onBack,
    this.supergroupSpaceId,
    this.supergroupChildIds,
    this.onSupergroupChildSelected,
  });

  final MatrixService matrix;
  final String roomId;
  final VoidCallback? onBack;
  final String? supergroupSpaceId;
  final List<String>? supergroupChildIds;
  final ValueChanged<String>? onSupergroupChildSelected;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final FocusNode _focusNode = FocusNode();

  Timeline? _timeline;
  Room? _room;
  Event? _editing;
  Event? _replyTo;
  bool _loadingHistory = false;
  bool _noMoreHistory = false;
  bool _showEmojiPicker = false;
  List<PlatformFile> _attachedFiles = [];
  String? _spaceChildId;

  List<ChatItem> _chatItems = [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_scrollListener);
    _openTimeline();
    widget.matrix.addListener(_onMatrix);
  }

  void _onMatrix() {
    if (mounted) setState(() {});
  }

  void _buildChatItems(List<Event> rawEvents) {
    final events = rawEvents
        .where((e) =>
            (e.type == EventTypes.Message || e.type == EventTypes.Encrypted) &&
            !e.redacted &&
            e.relationshipType != RelationshipTypes.edit)
        .toList();

    final List<ChatItem> items = [];
    int i = 0;
    while (i < events.length) {
      final current = events[i];
      if (current.messageType != MessageTypes.Image &&
          current.messageType != MessageTypes.Video) {
        items.add(SingleEventItem(current));
        i++;
        continue;
      }

      final List<Event> albumList = [current];
      int j = i + 1;
      while (j < events.length) {
        final next = events[j];
        if ((next.messageType == MessageTypes.Image ||
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
    _chatItems = items;
  }

  void _scrollListener() {
    if (!mounted || _timeline == null || _loadingHistory || _noMoreHistory) {
      return;
    }
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 200 ||
        (pos.outOfRange && pos.pixels > 0)) {
      _loadMoreHistory();
    }
  }

  Future<void> _loadMoreHistory() async {
    final timeline = _timeline;
    if (timeline == null || _loadingHistory || _noMoreHistory) return;

    if (!timeline.canRequestHistory) {
      setState(() => _noMoreHistory = true);
      return;
    }

    setState(() => _loadingHistory = true);
    try {
      final beforeLen = timeline.events.length;
      await timeline.requestHistory(historyCount: 30);
      final afterLen = timeline.events.length;

      if (mounted) {
        setState(() {
          _buildChatItems(timeline.events);
        });
      }

      if (beforeLen == afterLen && !timeline.canRequestHistory) {
        setState(() => _noMoreHistory = true);
      }
    } catch (e) {
      debugPrint('[Orex] Ошибка загрузки истории: $e');
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
      }
    }
  }

  Future<void> _openTimeline() async {
    final room = widget.matrix.client.getRoomById(widget.roomId);
    if (room == null) return;
    if (room.membership == Membership.invite) {
      if (mounted) setState(() => _room = room);
      return;
    }
    if (room.isSpace) {
      if (mounted) setState(() => _room = room);
      return;
    }
    final timeline = await room.getTimeline(onUpdate: () {
      if (mounted) {
        setState(() {
          _buildChatItems(_timeline?.events ?? []);
        });
      }
      _markRead(room);
    });
    await _markRead(room);
    if (mounted) {
      setState(() {
        _room = room;
        _timeline = timeline;
        _noMoreHistory = false;
        _buildChatItems(timeline.events);
      });
      _loadMoreHistory();
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
    final room = _room;
    if (room == null) return;
    if (!room.canSendDefaultMessages) return;

    final attachedList = List<PlatformFile>.from(_attachedFiles);
    if (attachedList.isNotEmpty) {
      setState(() {
        _attachedFiles = [];
        _replyTo = null;
        _editing = null;
        _showEmojiPicker = false;
      });
      _input.clear();
      _focusNode.requestFocus();

      for (var i = 0; i < attachedList.length; i++) {
        final attached = attachedList[i];
        final bytes = attached.bytes;
        if (bytes == null) continue;

        final ext = (attached.extension ?? '').toLowerCase();
        final isImg = _imgExts.contains(ext);
        final data = Uint8List.fromList(bytes);

        final MatrixFile file = isImg
            ? MatrixImageFile(
                bytes: data, name: attached.name, mimeType: 'image/$ext')
            : MatrixFile(bytes: data, name: attached.name);

        final replyTo = _replyTo;
        final fileCaption = (i == 0) ? text : '';

        final Map<String, Object?> extraContent = {
          'filename': attached.name,
          if (fileCaption.isNotEmpty) 'body': fileCaption,
        };

        await Future.delayed(const Duration(milliseconds: 150));

        await room.sendFileEvent(
          file,
          inReplyTo: replyTo,
          extraContent: extraContent,
        );
      }
    } else {
      if (text.isEmpty) return;
      final editing = _editing;
      final replyTo = _replyTo;
      _input.clear();
      _focusNode.requestFocus();

      setState(() {
        _editing = null;
        _replyTo = null;
        _showEmojiPicker = false;
      });
      if (editing != null) {
        await room.sendTextEvent(text, editEventId: editing.eventId);
      } else {
        await room.sendTextEvent(text, inReplyTo: replyTo);
      }
    }
  }

  void _startEdit(Event e) {
    final body = e
        .getDisplayEvent(_timeline!)
        .calcLocalizedBodyFallback(const MatrixDefaultLocalizations());
    setState(() {
      _editing = e;
      _replyTo = null;
      _attachedFiles = [];
      _showEmojiPicker = false;
    });
    _input.text = body;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _focusNode.requestFocus();
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _input.clear();
    _focusNode.requestFocus();
  }

  void _startReply(Event e) {
    setState(() {
      _replyTo = e;
      _editing = null;
      _showEmojiPicker = false;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() => _replyTo = null);
    _focusNode.requestFocus();
  }

  static const _imgExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

  Future<void> _attach() async {
    final res = await FilePicker.platform
        .pickFiles(withData: true, allowMultiple: true);
    final files = res?.files ?? const [];
    if (files.isEmpty) return;
    setState(() {
      _attachedFiles.addAll(files);
      _editing = null;
    });
    _focusNode.requestFocus();
  }

  void _cancelAttachment(int index) {
    setState(() {
      _attachedFiles.removeAt(index);
    });
    _focusNode.requestFocus();
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
    _focusNode.requestFocus();
  }

  void _toggleEmojiPicker() {
    if (_focusNode.hasFocus) {
      _focusNode.unfocus();
      Future.delayed(const Duration(milliseconds: 250), () {
        if (mounted) {
          setState(() {
            _showEmojiPicker = true;
          });
        }
      });
    } else {
      setState(() {
        _showEmojiPicker = !_showEmojiPicker;
      });
    }
  }

  Future<void> _acceptInvite() async {
    final room = _room;
    if (room == null) return;
    await widget.matrix.acceptInvite(room);
    if (!mounted) return;
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
      widget.matrix.call.minimize();
    } else {
      widget.matrix.call.expand();
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CallScreen(matrix: widget.matrix)),
      );
    }
  }

  void _openRoomSettings(Room room) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => RoomSettingsSheet(matrix: widget.matrix, room: room),
    );
  }

  /// Построение адаптивного окна смайликов под вводом
  Widget _buildResponsiveEmojiPicker(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isWide = MediaQuery.sizeOf(context).width >= 900;

    final double pickerHeight = isWide ? 250.0 : 280.0;

    return Container(
      height: pickerHeight,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: OrexColors.copper.withValues(alpha: 0.25),
        ),
      ),
      child: GridView.builder(
        padding: EdgeInsets.zero,
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 44, // Ограничение ширины одной ячейки смайла
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: _InputBar.emojis.length,
        itemBuilder: (context, idx) {
          final e = _InputBar.emojis[idx];
          return InkWell(
            onTap: () => _insertEmoji(e),
            borderRadius: BorderRadius.circular(8),
            child: Center(
              child: Text(e, style: const TextStyle(fontSize: 22)),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    widget.matrix.removeListener(_onMatrix);
    _scroll.removeListener(_scrollListener);
    _timeline?.cancelSubscriptions();
    _input.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Widget _buildSupergroup(Room space) {
    final children = widget.matrix.supergroupChildren(space);
    if (children.isEmpty) {
      return Column(
        children: [
          _ChatHeader(
            matrix: widget.matrix,
            room: space,
            onBack: widget.onBack,
            onCall: (_) {},
            onSettings: _openRoomSettings,
          ),
          const Divider(height: 1),
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.hub, size: 46, color: OrexColors.copper),
                    const SizedBox(height: 12),
                    Text(
                      'В супергруппе пока нет чатов',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => _openRoomSettings(space),
                      icon: const Icon(Icons.add),
                      label: const Text('Добавить чат'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    var selectedId = _spaceChildId;
    if (selectedId == null ||
        !children.any((child) => child.id == selectedId)) {
      selectedId = children.first.id;
      _spaceChildId = selectedId;
    }

    final selectedChildId = selectedId;

    return ChatView(
      key: ValueKey('supergroup-$selectedChildId'),
      matrix: widget.matrix,
      roomId: selectedChildId,
      onBack: widget.onBack,
      supergroupSpaceId: space.id,
      supergroupChildIds: children.map((child) => child.id).toList(),
      onSupergroupChildSelected: (roomId) {
        if (mounted) setState(() => _spaceChildId = roomId);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    if (room == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (room.membership == Membership.invite && _timeline == null) {
      return _InviteView(
        matrix: widget.matrix,
        room: room,
        onBack: widget.onBack,
        onAccept: _acceptInvite,
        onReject: _rejectInvite,
      );
    }

    if (room.isSpace) {
      return _buildSupergroup(room);
    }

    if (_timeline == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final myId = widget.matrix.client.userID;

    _buildChatItems(_timeline!.events);

    return DropTarget(
      onDragDone: (details) async {
        if (details.files.isNotEmpty) {
          final List<PlatformFile> loaded = [];
          for (final file in details.files) {
            final bytes = await file.readAsBytes();
            final filename = file.name;
            loaded.add(
                PlatformFile(name: filename, size: bytes.length, bytes: bytes));
          }
          setState(() {
            _attachedFiles.addAll(loaded);
            _editing = null;
          });
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          _focusNode.unfocus();
        },
        child: Column(
          children: [
            _ChatHeader(
              matrix: widget.matrix,
              room: room,
              onBack: widget.onBack,
              onCall: _openCall,
              onSettings: _openRoomSettings,
              supergroupSpaceId: widget.supergroupSpaceId,
              supergroupChildIds: widget.supergroupChildIds,
              onSupergroupChildSelected: widget.onSupergroupChildSelected,
            ),
            Divider(
                height: 1, color: OrexColors.copper.withValues(alpha: 0.12)),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                reverse: true,
                physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics()),
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                itemCount: _chatItems.length + (_loadingHistory ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == _chatItems.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: OrexColors.copper),
                        ),
                      ),
                    );
                  }

                  final item = _chatItems[i];

                  if (item is AlbumItem) {
                    return MessageBubble(
                      key: ValueKey(item.id),
                      event: item.leader,
                      isMine: item.leader.senderId == myId,
                      showSender: !room.isDirectChat,
                      timeline: _timeline,
                      myUserId: myId,
                      onReact: (emoji) =>
                          room.sendReaction(item.leader.eventId, emoji),
                      onRedact: (rid) => room.redactEvent(rid),
                      onEdit: () => _startEdit(item.leader),
                      onDelete: () => room.redactEvent(item.leader.eventId),
                      onReply: () => _startReply(item.leader),
                      onCancelSend: () async {
                        try {
                          await item.leader.cancelSend();
                          if (mounted) setState(() {});
                        } catch (e) {
                          debugPrint('[Orex] Ошибка отмены отправки: $e');
                        }
                      },
                      albumEvents: item.events,
                    );
                  } else if (item is SingleEventItem) {
                    return MessageBubble(
                      key: ValueKey(item.id),
                      event: item.event,
                      isMine: item.event.senderId == myId,
                      showSender: !room.isDirectChat,
                      timeline: _timeline,
                      myUserId: myId,
                      onReact: (emoji) =>
                          room.sendReaction(item.event.eventId, emoji),
                      onRedact: (rid) => room.redactEvent(rid),
                      onEdit: () => _startEdit(item.event),
                      onDelete: () => room.redactEvent(item.event.eventId),
                      onReply: () => _startReply(item.event),
                      onCancelSend: () async {
                        try {
                          await item.event.cancelSend();
                          if (mounted) setState(() {});
                        } catch (e) {
                          debugPrint('[Orex] Ошибка отмены отправки: $e');
                        }
                      },
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
            _InputBar(
              controller: _input,
              focusNode: _focusNode,
              canSend: room.canSendDefaultMessages,
              onSend: _send,
              editing: _editing != null,
              onCancelEdit: _cancelEdit,
              replyTo: _replyTo,
              onCancelReply: _cancelReply,
              onPickEmoji: _insertEmoji,
              onAttach: _attach,
              attachedFiles: _attachedFiles,
              onCancelAttachment: _cancelAttachment,
              showEmojiPicker: _showEmojiPicker,
              onToggleEmojiPicker: _toggleEmojiPicker,
              onTapInput: () {
                if (_showEmojiPicker) {
                  setState(() => _showEmojiPicker = false);
                }
              },
            ),
            if (_showEmojiPicker) _buildResponsiveEmojiPicker(context),
          ],
        ),
      ),
    );
  }
}

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
                IconButton(
                    onPressed: onBack, icon: const Icon(Icons.arrow_back)),
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
    required this.onSettings,
    this.onBack,
    this.supergroupSpaceId,
    this.supergroupChildIds,
    this.onSupergroupChildSelected,
  });

  final MatrixService matrix;
  final Room room;
  final ValueChanged<bool> onCall;
  final ValueChanged<Room> onSettings;
  final VoidCallback? onBack;
  final String? supergroupSpaceId;
  final List<String>? supergroupChildIds;
  final ValueChanged<String>? onSupergroupChildSelected;

  @override
  Widget build(BuildContext context) {
    final spaceId = supergroupSpaceId;
    final space = spaceId == null ? null : matrix.client.getRoomById(spaceId);
    final childIds = supergroupChildIds ?? const <String>[];
    final childRooms =
        childIds.map(matrix.client.getRoomById).whereType<Room>().toList();
    final inSupergroup = space != null && childRooms.isNotEmpty;
    final titleRoom = inSupergroup ? space : room;

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
            name: titleRoom.getLocalizedDisplayname(),
            mxc: titleRoom.avatar,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titleRoom.getLocalizedDisplayname(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (inSupergroup)
                  _SupergroupChildPicker(
                    matrix: matrix,
                    room: room,
                    children: childRooms,
                    onChanged: onSupergroupChildSelected,
                  )
                else
                  _PresenceLine(room: room),
              ],
            ),
          ),
          if (space != null)
            IconButton(
              tooltip: 'Настройки супергруппы',
              onPressed: () => onSettings(space),
              icon: const Icon(Icons.hub),
              color: OrexColors.copper,
            ),
          IconButton(
            tooltip: 'Настройки чата',
            onPressed: () => onSettings(room),
            icon: const Icon(Icons.info_outline),
            color: OrexColors.copper,
          ),
          if (!room.isSpace) ...[
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
        ],
      ),
    );
  }
}

class _SupergroupChildPicker extends StatelessWidget {
  const _SupergroupChildPicker({
    required this.matrix,
    required this.room,
    required this.children,
    required this.onChanged,
  });

  final MatrixService matrix;
  final Room room;
  final List<Room> children;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: room.id,
        isDense: true,
        isExpanded: true,
        iconSize: 18,
        items: children
            .map(
              (child) => DropdownMenuItem(
                value: child.id,
                child: Row(
                  children: [
                    Icon(
                      matrix.isVoiceRoom(child)
                          ? Icons.graphic_eq
                          : Icons.forum,
                      size: 16,
                      color: OrexColors.copper,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        child.getLocalizedDisplayname(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value == null || value == room.id) return;
          onChanged?.call(value);
        },
      ),
    );
  }
}

class _PresenceLine extends StatelessWidget {
  const _PresenceLine({required this.room});
  final Room room;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final dmId = room.directChatMatrixID;

    if (dmId == null) {
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
    required this.focusNode,
    required this.canSend,
    required this.onSend,
    this.editing = false,
    this.onCancelEdit,
    this.replyTo,
    this.onCancelReply,
    required this.onPickEmoji,
    required this.onAttach,
    required this.attachedFiles,
    required this.onCancelAttachment,
    required this.showEmojiPicker,
    required this.onToggleEmojiPicker,
    required this.onTapInput, // Колбек нажатия на поле ввода
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final VoidCallback onSend;
  final bool editing;
  final VoidCallback? onCancelEdit;
  final Event? replyTo;
  final VoidCallback? onCancelReply;
  final void Function(String emoji) onPickEmoji;
  final VoidCallback onAttach;
  final List<PlatformFile> attachedFiles;
  final ValueChanged<int> onCancelAttachment;
  final bool showEmojiPicker;
  final VoidCallback onToggleEmojiPicker;
  final VoidCallback onTapInput;

  // ИСПРАВЛЕНИЕ: Сделали массив смайликов публичным для доступа препроцессора
  static const emojis = [
    '😀',
    '😁',
    '😂',
    '🤣',
    '😊',
    '😍',
    '😘',
    '😎',
    '🤩',
    '🥳',
    '🤔',
    '😴',
    '😭',
    '😡',
    '👍',
    '👎',
    '🙏',
    '👏',
    '🔥',
    '❤️',
    '🎉',
    '✨',
    '💯',
    '✅',
    '❌',
    '⚡',
    '🌟',
    '😅',
    '😉',
    '🙃',
    '🤝',
    '💪',
    '👀',
    '🍀',
    '☕',
    '🚀',
    '🐿️',
    '💜',
    '😇',
    '🤗',
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reply = replyTo;
    final files = attachedFiles;
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
        if (files.isNotEmpty)
          Container(
            height: 80,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: files.length,
              itemBuilder: (context, idx) {
                final f = files[idx];
                final isImg = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp']
                    .contains((f.extension ?? '').toLowerCase());
                return Container(
                  key: ValueKey(f.name + f.size.toString()),
                  width: 72,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: OrexColors.copper.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: isImg && f.bytes != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(9),
                                child: Image.memory(
                                  f.bytes!,
                                  fit: BoxFit.cover,
                                  width: 72,
                                  height: 72,
                                ),
                              )
                            : const Icon(Icons.insert_drive_file,
                                color: OrexColors.copper),
                      ),
                      Positioned(
                        right: 2,
                        top: 2,
                        child: GestureDetector(
                          onTap: () => onCancelAttachment(idx),
                          child: Container(
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black54,
                            ),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(Icons.close,
                                size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Row(
            children: [
              IconButton(
                onPressed: canSend ? onAttach : null,
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
                          focusNode: focusNode,
                          readOnly: !canSend,
                          onTap: canSend ? onTapInput : null,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.send,
                          onSubmitted: canSend ? (_) => onSend() : null,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: canSend
                                ? (files.isNotEmpty
                                    ? 'Добавить подпись…'
                                    : 'Сообщение')
                                : 'Только чтение',
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: canSend ? onToggleEmojiPicker : null,
                        child: Icon(
                          showEmojiPicker
                              ? Icons.keyboard_hide_outlined
                              : Icons.emoji_emotions_outlined,
                          color: OrexColors.copper
                              .withValues(alpha: canSend ? 0.8 : 0.32),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: canSend ? onSend : null,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: canSend ? OrexColors.copperGradient : null,
                    color: canSend
                        ? null
                        : OrexColors.walnut.withValues(alpha: 0.18),
                  ),
                  child: Icon(
                    Icons.send,
                    color: canSend
                        ? OrexColors.cream
                        : OrexColors.copper.withValues(alpha: 0.36),
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
