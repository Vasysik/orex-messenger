import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../../core/matrix/matrix_service.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import '../../widgets/room_icon.dart';
import '../call/call_screen.dart';
import '../call/minimized_call_panel.dart';
import 'message_bubble.dart';
import 'public_room_preview_view.dart';
import 'room_settings_screen.dart';

part 'chat_timeline_items.dart';
part 'chat_header.dart';
part 'chat_input_bar.dart';

/// Правая панель: шапка чата, лента сообщений, строка ввода.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.matrix,
    required this.roomId,
    this.onBack,
    this.supergroupSpaceId,
    this.supergroupChildren,
    this.onSupergroupChildSelected,
  });

  final MatrixService matrix;
  final String roomId;
  final VoidCallback? onBack;
  final String? supergroupSpaceId;
  final List<OrexRoomPreview>? supergroupChildren;
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
  String? _accessRepairedSpaceId;

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
  static const _maxAttachedFiles = 10;
  static const _maxAttachmentBytes = 50 * 1024 * 1024;
  static const _maxAttachmentBatchBytes = 100 * 1024 * 1024;

  Future<void> _attach() async {
    final res = await FilePicker.platform
        .pickFiles(withData: true, allowMultiple: true);
    final picked = res?.files ?? const <PlatformFile>[];
    if (picked.isEmpty) return;

    final accepted = <PlatformFile>[];
    var batchBytes = _attachedFiles.fold<int>(0, (sum, f) => sum + f.size);
    var rejected = 0;
    for (final file in picked) {
      if (_attachedFiles.length + accepted.length >= _maxAttachedFiles ||
          file.size > _maxAttachmentBytes ||
          batchBytes + file.size > _maxAttachmentBatchBytes) {
        rejected++;
        continue;
      }
      accepted.add(file);
      batchBytes += file.size;
    }

    if (accepted.isNotEmpty) {
      setState(() {
        _attachedFiles.addAll(accepted);
        _editing = null;
      });
      _focusNode.requestFocus();
    }
    if (rejected > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Часть файлов не добавлена: максимум 10 файлов, 50 МБ на файл и 100 МБ за раз.',
          ),
        ),
      );
    }
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
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RoomSettingsScreen(
          matrix: widget.matrix,
          room: room,
        ),
      ),
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
    if (_accessRepairedSpaceId != space.id) {
      _accessRepairedSpaceId = space.id;
      Future.microtask(() async {
        try {
          await widget.matrix.ensureSupergroupChildrenAccess(space);
        } catch (_) {}
      });
    }
    final childPreviews = widget.matrix.supergroupChildPreviews(space);
    if (childPreviews.isEmpty) {
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
        !childPreviews.any((child) => child.roomId == selectedId)) {
      selectedId = childPreviews.first.roomId;
      _spaceChildId = selectedId;
    }

    final selectedChildId = selectedId;
    final selectedPreview = childPreviews.firstWhere(
      (child) => child.roomId == selectedChildId,
      orElse: () => childPreviews.first,
    );
    final selectedRoom = widget.matrix.client.getRoomById(selectedChildId);

    void selectChild(String roomId) {
      if (mounted) setState(() => _spaceChildId = roomId);
    }

    if (selectedRoom == null || selectedRoom.membership != Membership.join) {
      return PublicRoomPreviewView(
        key: ValueKey('supergroup-preview-$selectedChildId'),
        matrix: widget.matrix,
        preview: selectedPreview,
        onBack: widget.onBack,
        parentSpace: space,
        supergroupChildren: childPreviews,
        onSupergroupChildSelected: selectChild,
        onJoined: (roomId) {
          if (mounted) setState(() => _spaceChildId = roomId);
        },
      );
    }

    return ChatView(
      key: ValueKey('supergroup-$selectedChildId'),
      matrix: widget.matrix,
      roomId: selectedChildId,
      onBack: widget.onBack,
      supergroupSpaceId: space.id,
      supergroupChildren: childPreviews,
      onSupergroupChildSelected: selectChild,
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
              supergroupChildren: widget.supergroupChildren,
              onSupergroupChildSelected: widget.onSupergroupChildSelected,
            ),
            Divider(
                height: 1, color: OrexColors.copper.withValues(alpha: 0.12)),
            if (widget.supergroupSpaceId != null &&
                !widget.matrix.call.isActive &&
                widget.matrix.roomHasActiveCall(room))
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                child: JoinCallPanel(
                  matrix: widget.matrix,
                  room: room,
                  onJoin: () => _openCall(false),
                ),
              ),
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
