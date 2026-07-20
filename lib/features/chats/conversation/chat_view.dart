import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../../../core/haptics/orex_haptics.dart';
import '../../../core/matrix/matrix_service.dart';
import '../../../core/logging/orex_logger.dart';
import '../../../shared/theme/orex_theme.dart';
import '../../../shared/widgets/mxc_avatar.dart';
import '../../calls/call_launch_coordinator.dart';
import '../../calls/minimized_call_panel.dart';
import 'chat_timeline_items.dart';
import 'message_bubble.dart';
import 'message_composer_controller.dart';
import 'conversation_preview_view.dart';
import 'room_settings_screen.dart';
import 'supergroup_child_picker.dart';

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
    this.selectedSupergroupChildId,
    this.onSupergroupChildVisibleChanged,
    this.onOpenRoomReference,
    this.showInlineCallPanel = true,
  });

  final MatrixService matrix;
  final String roomId;
  final VoidCallback? onBack;
  final String? supergroupSpaceId;
  final List<OrexRoomPreview>? supergroupChildren;
  final ValueChanged<String>? onSupergroupChildSelected;
  final String? selectedSupergroupChildId;
  final void Function(String spaceId, String childId)?
  onSupergroupChildVisibleChanged;
  final ValueChanged<String>? onOpenRoomReference;
  final bool showInlineCallPanel;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final FocusNode _focusNode = FocusNode();

  static const int _historyPageSize = 40;
  static const int _initialVisibleMessageCount = 40;
  static const int _openHistoryMaxPages = 32;

  Timeline? _timeline;
  Room? _room;
  bool _loadingHistory = false;
  bool _noMoreHistory = false;
  final OrexMessageComposerController<Event> _composer =
      OrexMessageComposerController();
  String? _spaceChildId;
  String? _accessRepairedSpaceId;
  String? _lastReportedSupergroupChildId;

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

  bool _isRenderableTimelineEventForRoom(Room? room, Event e) {
    final hideMemberEvents = room != null && widget.matrix.isChannel(room);
    return (e.type == EventTypes.Message ||
            e.type == EventTypes.Encrypted ||
            (!hideMemberEvents && e.type == EventTypes.RoomMember)) &&
        !e.redacted &&
        e.relationshipType != RelationshipTypes.edit;
  }

  bool _isRenderableTimelineEvent(Event e) =>
      _isRenderableTimelineEventForRoom(_room, e);

  bool get _isAtLatestEdge =>
      !_scroll.hasClients ||
      _scroll.position.pixels <= _scroll.position.minScrollExtent + 80;

  void _jumpToLatestAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final min = _scroll.position.minScrollExtent;
      if ((_scroll.position.pixels - min).abs() > 1) {
        _scroll.jumpTo(min);
      }
    });
  }

  void _preserveHistoryViewportAfterFrame(double oldMaxScrollExtent) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      final delta = pos.maxScrollExtent - oldMaxScrollExtent;
      if (delta <= 0) return;
      final target = (pos.pixels + delta).clamp(
        pos.minScrollExtent,
        pos.maxScrollExtent,
      );
      if ((target - pos.pixels).abs() > 1) {
        _scroll.jumpTo(target.toDouble());
      }
    });
  }

  void _buildChatItems(List<Event> rawEvents) {
    _chatItems = OrexTimelineAdapter.transform(
      rawEvents,
      isRenderable: _isRenderableTimelineEvent,
    );
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
      final oldMaxScrollExtent = _scroll.hasClients
          ? _scroll.position.maxScrollExtent
          : null;
      await timeline.requestHistory(historyCount: _historyPageSize);
      final afterLen = timeline.events.length;

      if (mounted) {
        setState(() {
          _buildChatItems(timeline.events);
        });
        if (oldMaxScrollExtent != null) {
          _preserveHistoryViewportAfterFrame(oldMaxScrollExtent);
        }
      }

      if (beforeLen == afterLen && !timeline.canRequestHistory) {
        setState(() => _noMoreHistory = true);
      }
    } catch (e) {
      OrexLog.d('Chat', 'history load failed room=${widget.roomId}', e);
    } finally {
      if (mounted) {
        setState(() => _loadingHistory = false);
      }
    }
  }

  void _openRoomReference(String reference) {
    OrexLog.d(
      'Chat',
      'open room reference ref=$reference from=${widget.roomId}',
    );
    final handler = widget.onOpenRoomReference;
    if (handler == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Открытие комнат здесь недоступно')),
      );
      return;
    }
    // Не режем ссылку только локальным резолвером внутри ChatView.
    // HomeShell знает, как открыть уже синкнутую комнату, invite-комнату,
    // public preview или попробовать join по alias/roomId.
    handler(reference);
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
    final timeline = await room.getTimeline(
      onUpdate: () {
        final events = _timeline?.events ?? const <Event>[];
        final wasAtLatest = _isAtLatestEdge;
        if (mounted) {
          setState(() {
            _buildChatItems(events);
          });
          if (wasAtLatest) _jumpToLatestAfterFrame();
        }
        _markRead(room);
      },
    );
    await _markRead(room);
    // Do not paint the short cache tail and then append the normal initial
    // page a moment later. Besides looking like a lost-message bug, that
    // layout jump makes the first scroll gesture unreliable on slower phones.
    // Start with a full visible message window. Additional requests are needed
    // when Matrix's page contains hidden channel state/member events.
    await _warmInitialTimelineHistory(room, timeline);
    if (!mounted) return;
    if (mounted) {
      setState(() {
        _room = room;
        _timeline = timeline;
        _noMoreHistory = !timeline.canRequestHistory;
        _buildChatItems(timeline.events);
      });
      _jumpToLatestAfterFrame();
    }
  }

  Future<void> _warmInitialTimelineHistory(
    Room room,
    Timeline timeline,
  ) async {
    if (!timeline.canRequestHistory) return;
    try {
      var renderableCount = timeline.events
          .where((event) => _isRenderableTimelineEventForRoom(room, event))
          .length;
      for (
        var page = 0;
        page < _openHistoryMaxPages &&
            timeline.canRequestHistory &&
            renderableCount < _initialVisibleMessageCount;
        page++
      ) {
        final beforeLen = timeline.events.length;
        await timeline.requestHistory(historyCount: _historyPageSize);
        renderableCount = timeline.events
            .where((event) => _isRenderableTimelineEventForRoom(room, event))
            .length;

        if (timeline.events.length == beforeLen) {
          break;
        }
      }
    } catch (e) {
      OrexLog.d('Chat', 'initial history warm-up failed room=${room.id}', e);
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
    if (!widget.matrix.canSendMessages(room)) return;
    await widget.matrix.ensureCanSendToChannel(room);
    OrexLog.d(
      'Chat',
      'send message room=${room.id} text=${text.length} files=${_composer.attachments.length}',
    );

    final attachedList = _composer.attachmentSnapshot();
    if (attachedList.isNotEmpty) {
      final replyTo = _composer.replyTo;
      setState(() {
        _composer.clearAfterAttachmentSend();
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
                bytes: data,
                name: attached.name,
                mimeType: 'image/$ext',
              )
            : MatrixFile(bytes: data, name: attached.name);

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
      final editing = _composer.editing;
      final replyTo = _composer.replyTo;
      _input.clear();
      _focusNode.requestFocus();

      setState(_composer.clearAfterTextSend);
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
    setState(() => _composer.startEdit(e));
    _input.text = body;
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _focusNode.requestFocus();
  }

  void _cancelEdit() {
    setState(_composer.cancelEdit);
    _input.clear();
    _focusNode.requestFocus();
  }

  void _startReply(Event e) {
    setState(() => _composer.startReply(e));
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(_composer.cancelReply);
    _focusNode.requestFocus();
  }

  static const _imgExts = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};
  void _showAttachmentRejectedSnack(int rejected) {
    if (rejected <= 0 || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Часть файлов не добавлена: максимум 10 файлов, 50 МБ на файл и 100 МБ за раз.',
        ),
      ),
    );
  }

  void _queueAttachments(List<PlatformFile> files) {
    if (files.isEmpty || !mounted) return;
    final result = _composer.queueAttachments(files);
    if (result.hasAccepted && mounted) {
      setState(() {});
      _focusNode.requestFocus();
    }
    _showAttachmentRejectedSnack(result.rejectedCount);
  }

  Future<void> _attach() async {
    final res = await FilePicker.pickFiles(
      withData: true,
      allowMultiple: true,
    );
    final picked = res?.files ?? const <PlatformFile>[];
    if (picked.isEmpty) return;

    _queueAttachments(picked);
  }

  Future<void> _attachDroppedFiles(DropDoneDetails details) async {
    if (details.files.isEmpty) return;

    final accepted = <PlatformFile>[];
    var pendingBytes = 0;
    var rejected = 0;
    for (final file in details.files) {
      final int size;
      try {
        size = await file.length();
      } catch (e) {
        OrexLog.d('Chat', 'drop file length failed name=${file.name}', e);
        rejected++;
        continue;
      }
      if (!mounted) return;
      if (!_composer.attachments.canAcceptSize(
        fileBytes: size,
        pendingCount: accepted.length,
        pendingBytes: pendingBytes,
      )) {
        rejected++;
        continue;
      }

      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (e) {
        OrexLog.d('Chat', 'drop file read failed name=${file.name}', e);
        rejected++;
        continue;
      }
      if (!mounted) return;
      accepted.add(
        PlatformFile(
          name: file.name,
          size: size,
          bytes: bytes,
          path: file.path.isEmpty ? null : file.path,
        ),
      );
      pendingBytes += size;
    }

    final result = _composer.queueAttachments(accepted);
    if (result.hasAccepted && mounted) {
      setState(() {});
      _focusNode.requestFocus();
    }
    _showAttachmentRejectedSnack(rejected + result.rejectedCount);
  }

  void _cancelAttachment(int index) {
    setState(() {
      _composer.attachments.removeAt(index);
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
          setState(_composer.showEmojiPickerAfterKeyboardHide);
        }
      });
    } else {
      setState(_composer.toggleEmojiPicker);
    }
  }

  Future<void> _acceptInvite() async {
    final room = _room;
    if (room == null) return;
    await widget.matrix.acceptInvite(room);
    if (!mounted) return;
    final timeline = await room.getTimeline(
      onUpdate: () {
        if (mounted) setState(() {});
      },
    );
    if (mounted) setState(() => _timeline = timeline);
  }

  Future<void> _rejectInvite() async {
    final room = _room;
    if (room == null) return;
    await widget.matrix.rejectInvite(room);
    if (mounted) widget.onBack?.call();
  }

  Future<void> _openCall(bool video) async {
    await launchOrexCall(
      context,
      matrix: widget.matrix,
      roomId: widget.roomId,
      video: video,
    );
  }

  void _openRoomSettings(Room room) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => RoomSettingsScreen(matrix: widget.matrix, room: room),
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
        border: Border.all(color: OrexColors.copper.withValues(alpha: 0.25)),
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
            child: Center(child: Text(e, style: const TextStyle(fontSize: 22))),
          );
        },
      ),
    );
  }

  void _reportVisibleSupergroupChild(String spaceId, String childId) {
    if (_lastReportedSupergroupChildId == childId) return;
    _lastReportedSupergroupChildId = childId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onSupergroupChildVisibleChanged?.call(spaceId, childId);
    });
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
                    if (widget.matrix.canManageRoomSettings(space))
                      FilledButton.icon(
                        onPressed: () => _openRoomSettings(space),
                        icon: const Icon(Icons.add),
                        label: const Text('Добавить чат'),
                      )
                    else
                      Text(
                        'Администраторы ещё не добавили чаты',
                        style: Theme.of(context).textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Внутренний выбор должен быть главным источником правды для dropdown.
    // HomeShell хранит выбранный child только для верхней панели звонка; если
    // отдавать ему приоритет, post-frame репорт старого child может откатить
    // ручное переключение и dropdown будто перестаёт работать.
    var selectedId = _spaceChildId ?? widget.selectedSupergroupChildId;
    if (selectedId == null ||
        !childPreviews.any((child) => child.roomId == selectedId)) {
      selectedId = childPreviews.first.roomId;
    }
    if (_spaceChildId != selectedId) {
      _spaceChildId = selectedId;
    }
    _reportVisibleSupergroupChild(space.id, selectedId);

    final selectedChildId = selectedId;
    final selectedPreview = childPreviews.firstWhere(
      (child) => child.roomId == selectedChildId,
      orElse: () => childPreviews.first,
    );
    final selectedRoom = widget.matrix.client.getRoomById(selectedChildId);

    void selectChild(String roomId) {
      if (!mounted) return;
      setState(() => _spaceChildId = roomId);
      _reportVisibleSupergroupChild(space.id, roomId);
    }

    if (selectedRoom == null || selectedRoom.membership != Membership.join) {
      return ConversationPreviewView(
        key: ValueKey('supergroup-preview-$selectedChildId'),
        matrix: widget.matrix,
        preview: OrexConversationPreview.fromRoom(selectedPreview),
        onEnter: widget.matrix.enterConversationPreview,
        onBack: widget.onBack,
        parentSpace: space,
        supergroupChildren: childPreviews,
        onSupergroupChildSelected: selectChild,
        onEntered: (roomId) {
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
      onOpenRoomReference: widget.onOpenRoomReference,
      showInlineCallPanel: false,
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

    if (_timeline == null && _chatItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final myId = widget.matrix.client.userID;
    final liveTimeline = _timeline;

    if (liveTimeline != null) {
      _buildChatItems(liveTimeline.events);
    }

    return DropTarget(
      onDragDone: _attachDroppedFiles,
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
              height: 1,
              color: OrexColors.copper.withValues(alpha: 0.12),
            ),
            if (widget.showInlineCallPanel &&
                widget.supergroupSpaceId != null &&
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
                  parent: BouncingScrollPhysics(),
                ),
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 8,
                ),
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
                            strokeWidth: 2,
                            color: OrexColors.copper,
                          ),
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
                      timeline: liveTimeline,
                      myUserId: myId,
                      onReact: (emoji) =>
                          room.sendReaction(item.leader.eventId, emoji),
                      onRedact: (rid) => room.redactEvent(rid),
                      onEdit: liveTimeline == null
                          ? null
                          : () => _startEdit(item.leader),
                      onDelete: () => room.redactEvent(item.leader.eventId),
                      onReply: liveTimeline == null
                          ? null
                          : () => _startReply(item.leader),
                      onOpenRoomReference: _openRoomReference,
                      onCancelSend: () async {
                        try {
                          await item.leader.cancelSend();
                          if (mounted) setState(() {});
                        } catch (e) {
                          OrexLog.d(
                            'Chat',
                            'cancel send failed room=${room.id}',
                            e,
                          );
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
                      timeline: liveTimeline,
                      myUserId: myId,
                      onReact: (emoji) =>
                          room.sendReaction(item.event.eventId, emoji),
                      onRedact: (rid) => room.redactEvent(rid),
                      onEdit: liveTimeline == null
                          ? null
                          : () => _startEdit(item.event),
                      onDelete: () => room.redactEvent(item.event.eventId),
                      onReply: liveTimeline == null
                          ? null
                          : () => _startReply(item.event),
                      onOpenRoomReference: _openRoomReference,
                      onCancelSend: () async {
                        try {
                          await item.event.cancelSend();
                          if (mounted) setState(() {});
                        } catch (e) {
                          OrexLog.d(
                            'Chat',
                            'cancel send failed room=${room.id}',
                            e,
                          );
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
              canSend: widget.matrix.canSendMessages(room),
              onSend: _send,
              editing: _composer.isEditing,
              onCancelEdit: _cancelEdit,
              replyTo: _composer.replyTo,
              onCancelReply: _cancelReply,
              onPickEmoji: _insertEmoji,
              onAttach: _attach,
              attachedFiles: _composer.attachments.files,
              onCancelAttachment: _cancelAttachment,
              showEmojiPicker: _composer.showEmojiPicker,
              onToggleEmojiPicker: _toggleEmojiPicker,
              onTapInput: () {
                if (_composer.showEmojiPicker) {
                  setState(_composer.hideEmojiPicker);
                }
              },
            ),
            if (_composer.showEmojiPicker) _buildResponsiveEmojiPicker(context),
          ],
        ),
      ),
    );
  }
}
