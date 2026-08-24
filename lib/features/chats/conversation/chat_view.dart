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
import 'forward_message_dialog.dart';
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
  final GlobalKey _timelineViewportKey = GlobalKey();
  final Map<String, _TimelineItemProbeState> _timelineProbes =
      <String, _TimelineItemProbeState>{};
  final ValueNotifier<_StickyTimelineOverlay?> _stickyTimelineOverlay =
      ValueNotifier<_StickyTimelineOverlay?>(null);
  final ValueNotifier<String?> _attachedTimelineSeparatorId =
      ValueNotifier<String?>(null);
  final ValueNotifier<bool> _showJumpToLatestButton =
      ValueNotifier<bool>(false);
  final ValueNotifier<bool> _stickyTimelineOverlayVisible =
      ValueNotifier<bool>(true);
  bool _stickyTimelineUpdateScheduled = false;
  Timer? _stickyTimelineFadeOutTimer;
  _StickyTimelineOverlay? _pendingStickyTimelineOverlayAfterFade;
  String? _pendingStickyTimelineSeparatorIdAfterFade;
  double? _lastTimelineScrollPixels;
  bool _scrollingTowardLatest = false;
  DateTime? _initialStickyTimelineDate;
  bool _hasLeftInitialStickyTimelineDate = false;

  static const double _stickyTimelineTop = 6;
  static const Duration _stickyTimelineFadeDuration = Duration(
    milliseconds: 140,
  );
  static const double _timelineSeparatorVerticalMargin = 8;
  static const double _jumpToLatestMinDistance = 420;
  static const double _jumpToLatestViewportFactor = 0.72;

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
      _updateJumpToLatestVisibility();
    });
  }

  void _updateJumpToLatestVisibility() {
    if (!_scroll.hasClients) {
      if (_showJumpToLatestButton.value) {
        _showJumpToLatestButton.value = false;
      }
      return;
    }

    final position = _scroll.position;
    final viewportThreshold =
        position.viewportDimension * _jumpToLatestViewportFactor;
    final threshold = viewportThreshold > _jumpToLatestMinDistance
        ? viewportThreshold
        : _jumpToLatestMinDistance;
    final distanceFromLatest =
        (position.pixels - position.minScrollExtent).abs();
    final shouldShow = distanceFromLatest > threshold;
    if (_showJumpToLatestButton.value != shouldShow) {
      _showJumpToLatestButton.value = shouldShow;
    }
  }

  Future<void> _animateToLatest() async {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target = position.minScrollExtent;
    final distance = (position.pixels - target).abs();
    if (distance <= 1) return;

    unawaited(OrexHaptics.trigger(OrexHapticKind.selection));
    final milliseconds = (260 + distance / 12).clamp(300, 620).round();
    await _scroll.animateTo(
      target,
      duration: Duration(milliseconds: milliseconds),
      curve: Curves.easeOutCubic,
    );
    if (mounted) _updateJumpToLatestVisibility();
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
      _updateJumpToLatestVisibility();
    });
  }

  void _buildChatItems(List<Event> rawEvents) {
    _chatItems = OrexTimelineAdapter.transform(
      rawEvents,
      isRenderable: _isRenderableTimelineEvent,
    );
    _scheduleStickyTimelineDateUpdate();
  }

  Widget _withTimelineProbe(ChatItem item, Widget child) {
    return _TimelineItemProbe(
      key: ValueKey('timeline-probe:${item.id}'),
      item: item,
      onAttach: _attachTimelineProbe,
      onDetach: _detachTimelineProbe,
      child: child,
    );
  }

  void _attachTimelineProbe(_TimelineItemProbeState probe) {
    _timelineProbes[probe.item.id] = probe;
    _scheduleStickyTimelineDateUpdate();
  }

  void _detachTimelineProbe(_TimelineItemProbeState probe) {
    if (identical(_timelineProbes[probe.item.id], probe)) {
      _timelineProbes.remove(probe.item.id);
      _scheduleStickyTimelineDateUpdate();
    }
  }

  void _scheduleStickyTimelineDateUpdate() {
    if (_stickyTimelineUpdateScheduled) return;
    _stickyTimelineUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stickyTimelineUpdateScheduled = false;
      if (!mounted) return;
      _updateStickyTimelineDate();
    });
  }

  void _updateStickyTimelineDate() {
    final viewportContext = _timelineViewportKey.currentContext;
    final viewportBox = viewportContext?.findRenderObject();
    if (viewportBox is! RenderBox || !viewportBox.attached) return;

    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;
    final viewportBottom = viewportTop + viewportBox.size.height;
    final visibleSeparators = <_VisibleTimelineSeparator>[];

    // Сначала измеряем реальные границы pill-разделителей. Probe охватывает
    // также вертикальные margin, поэтому для collision detection вычитаем их
    // и работаем именно с верхом/низом нарисованной даты.
    for (final probe in _timelineProbes.values) {
      final item = probe.item;
      if (item is! DaySeparatorItem) continue;

      final itemBox = probe.renderBox;
      if (itemBox == null || !itemBox.attached || !itemBox.hasSize) continue;

      final itemTop = itemBox.localToGlobal(Offset.zero).dy;
      final pillTop = itemTop + _timelineSeparatorVerticalMargin;
      final pillBottom =
          itemTop + itemBox.size.height - _timelineSeparatorVerticalMargin;
      if (pillBottom <= viewportTop || pillTop >= viewportBottom) continue;

      visibleSeparators.add(
        _VisibleTimelineSeparator(
          id: item.id,
          date: item.date,
          top: pillTop - viewportTop,
          bottom: pillBottom - viewportTop,
        ),
      );
    }

    // Все day-pill имеют одинаковую высоту. Когда граница дня уже рядом, берём
    // её фактический размер, чтобы решение о смене даты не зависело от пары px.
    final stickyHeight = visibleSeparators.isEmpty
        ? _TimelineDaySeparator.estimatedHeight
        : visibleSeparators.first.height;
    final anchorY =
        viewportTop + _stickyTimelineTop + stickyHeight + 1;

    ChatItem? containingAnchor;
    ChatItem? nearestBelowAnchor;
    ChatItem? nearestAboveAnchor;
    var nearestBelowTop = double.infinity;
    var nearestAboveBottom = double.negativeInfinity;

    for (final probe in _timelineProbes.values) {
      final item = probe.item;
      if (item is DaySeparatorItem) continue;

      final itemBox = probe.renderBox;
      if (itemBox == null || !itemBox.attached || !itemBox.hasSize) continue;

      final top = itemBox.localToGlobal(Offset.zero).dy;
      final bottom = top + itemBox.size.height;
      if (bottom <= viewportTop || top >= viewportBottom) continue;

      // Дата переключается только когда сообщение нового дня действительно
      // прошло под всей sticky-pill. Одного показавшегося сверху кусочка уже
      // недостаточно: учитываем одновременно top и bottom каждого элемента.
      if (top <= anchorY && bottom > anchorY) {
        containingAnchor = item;
        break;
      }
      if (top > anchorY && top < nearestBelowTop) {
        nearestBelowTop = top;
        nearestBelowAnchor = item;
      } else if (bottom <= anchorY && bottom > nearestAboveBottom) {
        nearestAboveBottom = bottom;
        nearestAboveAnchor = item;
      }
    }

    final topMessageItem =
        containingAnchor ?? nearestBelowAnchor ?? nearestAboveAnchor;

    DateTime? nextDate;
    if (topMessageItem is SingleEventItem) {
      nextDate = topMessageItem.event.originServerTs.toLocal();
    } else if (topMessageItem is AlbumItem) {
      nextDate = topMessageItem.leader.originServerTs.toLocal();
    }
    if (nextDate == null) {
      _setStickyTimelineOverlay(null, attachedSeparatorId: null);
      return;
    }

    var overlayTop = _stickyTimelineTop;
    String? attachedSeparatorId;
    _VisibleTimelineSeparator? ownSeparator;

    for (final separator in visibleSeparators) {
      if (!orexSameCalendarDay(separator.date, nextDate)) continue;
      if (ownSeparator == null ||
          (separator.top - _stickyTimelineTop).abs() <
              (ownSeparator.top - _stickyTimelineTop).abs()) {
        ownSeparator = separator;
      }
    }

    // Своя метка считается "прикреплённой" только пока её реальная pill хотя
    // бы частично находится ниже линии закрепления. Это устраняет 1–2 px окно,
    // в котором раньше source и floating-копия успевали отрисоваться вместе.
    if (ownSeparator != null &&
        ownSeparator.bottom > _stickyTimelineTop &&
        ownSeparator.top < viewportBox.size.height) {
      overlayTop = ownSeparator.top > _stickyTimelineTop
          ? ownSeparator.top
          : _stickyTimelineTop;
      attachedSeparatorId = ownSeparator.id;
    }

    // Дополнительная защита на границе дней: floating-pill никогда не имеет
    // права пересечь видимую pill другого дня. Проверяем интервалы целиком
    // [top, bottom], а не одну координату, и при столкновении старая дата
    // естественно выталкивается вверх, как sticky header в Telegram.
    for (final separator in visibleSeparators) {
      if (separator.id == attachedSeparatorId ||
          orexSameCalendarDay(separator.date, nextDate)) {
        continue;
      }
      final overlayBottom = overlayTop + stickyHeight;
      final overlaps =
          overlayTop < separator.bottom && overlayBottom > separator.top;
      if (!overlaps) continue;

      final pushedTop = separator.top - stickyHeight - 1;
      if (pushedTop < overlayTop) overlayTop = pushedTop;
    }

    _setStickyTimelineOverlay(
      _StickyTimelineOverlay(
        date: nextDate,
        top: overlayTop,
        animateIn: _shouldAnimateStickyTimelineDate(nextDate),
      ),
      attachedSeparatorId: attachedSeparatorId,
    );
  }

  void _setStickyTimelineOverlay(
    _StickyTimelineOverlay? next, {
    required String? attachedSeparatorId,
  }) {
    final current = _stickyTimelineOverlay.value;
    final fadeOutInProgress =
        _stickyTimelineFadeOutTimer != null &&
        !_stickyTimelineOverlayVisible.value;

    // Пока старая sticky-date гаснет при движении вниз, новые layout-кадры не
    // должны отменять fade только потому, что anchor уже перескочил на следующий
    // календарный день. Запоминаем самый свежий target и применяем его ровно
    // после 140 ms. Так уже прилипшая дата действительно успевает исчезнуть, а
    // следующая метка затем подхватывается без собственного fade-in.
    if (fadeOutInProgress) {
      if (_scrollingTowardLatest) {
        _pendingStickyTimelineOverlayAfterFade = next;
        _pendingStickyTimelineSeparatorIdAfterFade = attachedSeparatorId;
        return;
      }

      // Пользователь успел развернуть направление обратно в историю: старую
      // дату больше не надо уводить. Возвращаем её сразу и снова отдаём появление
      // дат проверенной upward-механике _FadingTimelineDaySeparator.
      _stickyTimelineFadeOutTimer?.cancel();
      _stickyTimelineFadeOutTimer = null;
      _pendingStickyTimelineOverlayAfterFade = null;
      _pendingStickyTimelineSeparatorIdAfterFade = null;
      _stickyTimelineOverlayVisible.value = true;
    }

    final leavesCurrentDayTowardLatest =
        _scrollingTowardLatest &&
        current != null &&
        (next == null || !orexSameCalendarDay(current.date, next.date));

    // При движении к последним сообщениям старая уже прилипшая дата должна
    // зеркально погаснуть, когда её сменяет следующий день. Важно запускать этот
    // fade не только при next == null: обычно anchor сразу перескакивает на
    // следующий день, и прежняя реализация в этот момент мгновенно заменяла
    // overlay, из-за чего анимацию исчезновения было невозможно увидеть.
    if (leavesCurrentDayTowardLatest) {
      _pendingStickyTimelineOverlayAfterFade = next;
      _pendingStickyTimelineSeparatorIdAfterFade = attachedSeparatorId;
      _stickyTimelineOverlayVisible.value = false;
      _stickyTimelineFadeOutTimer = Timer(_stickyTimelineFadeDuration, () {
        if (!mounted) return;

        final target = _pendingStickyTimelineOverlayAfterFade;
        final targetSeparatorId =
            _pendingStickyTimelineSeparatorIdAfterFade;
        _pendingStickyTimelineOverlayAfterFade = null;
        _pendingStickyTimelineSeparatorIdAfterFade = null;
        _stickyTimelineFadeOutTimer = null;

        if (_attachedTimelineSeparatorId.value != targetSeparatorId) {
          _attachedTimelineSeparatorId.value = targetSeparatorId;
        }
        _stickyTimelineOverlay.value = target;

        // Вниз следующая дата уже была частью ленты, поэтому после ухода старой
        // floating-копии она прикрепляется сразу, без повторного fade-in.
        _stickyTimelineOverlayVisible.value = true;
      });
      return;
    }

    _stickyTimelineFadeOutTimer?.cancel();
    _stickyTimelineFadeOutTimer = null;
    _pendingStickyTimelineOverlayAfterFade = null;
    _pendingStickyTimelineSeparatorIdAfterFade = null;
    if (!_stickyTimelineOverlayVisible.value) {
      _stickyTimelineOverlayVisible.value = true;
    }

    if (_attachedTimelineSeparatorId.value != attachedSeparatorId) {
      _attachedTimelineSeparatorId.value = attachedSeparatorId;
    }

    if (current == null && next == null) return;
    if (current != null &&
        next != null &&
        orexSameCalendarDay(current.date, next.date) &&
        (current.top - next.top).abs() < 0.5) {
      return;
    }
    _stickyTimelineOverlay.value = next;
  }

  bool _shouldAnimateStickyTimelineDate(DateTime date) {
    final initialDate = _initialStickyTimelineDate;
    if (initialDate == null) {
      _initialStickyTimelineDate = date;
      return false;
    }
    if (!_hasLeftInitialStickyTimelineDate &&
        !orexSameCalendarDay(initialDate, date)) {
      _hasLeftInitialStickyTimelineDate = true;
    }
    return _hasLeftInitialStickyTimelineDate && !_scrollingTowardLatest;
  }

  void _scrollListener() {
    final pos = _scroll.position;
    final previousPixels = _lastTimelineScrollPixels;
    if (previousPixels != null) {
      final delta = pos.pixels - previousPixels;
      if (delta.abs() >= 0.5) {
        // Timeline reverse=true: уменьшение offset означает движение вниз,
        // к последним сообщениям; увеличение — вверх, в историю.
        _scrollingTowardLatest = delta < 0;
      }
    }
    _lastTimelineScrollPixels = pos.pixels;

    _scheduleStickyTimelineDateUpdate();
    _updateJumpToLatestVisibility();
    if (!mounted || _timeline == null || _loadingHistory || _noMoreHistory) {
      return;
    }
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

  Future<void> _forwardEvents(List<Event> events) async {
    final sourceRoom = _room;
    if (sourceRoom == null || events.isEmpty) return;

    final targets = await showOrexForwardRoomPicker(
      context,
      matrix: widget.matrix,
      sourceRoomId: sourceRoom.id,
    );
    if (!mounted || targets == null || targets.isEmpty) return;

    final result = await showOrexForwardProgressDialog(
      context,
      matrix: widget.matrix,
      events: events,
      timeline: _timeline,
      targets: targets,
    );
    if (!mounted || result == null) return;

    final String message;
    if (result.fatalError != null) {
      message = result.fatalError!;
    } else if (result.cancelled) {
      message = result.sentMessages == 0
          ? 'Пересылка отменена'
          : 'Пересылка остановлена: отправлено ${result.sentMessages}';
    } else if (result.failures.isNotEmpty) {
      final first = result.failures.first;
      final suffix = result.failures.length > 1
          ? ' Ещё ошибок: ${result.failures.length - 1}.'
          : '';
      message = result.sentMessages == 0
          ? 'Не удалось переслать в «${first.roomName}»: ${first.reason}$suffix'
          : 'Переслано частично. «${first.roomName}»: ${first.reason}$suffix';
    } else if (result.completedRooms == 1) {
      message = events.length == 1
          ? 'Сообщение переслано'
          : 'Медиаальбом переслан';
    } else {
      message = 'Переслано в ${result.completedRooms} чатов';
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
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
        final events = _timeline?.events ?? const <Event>[];
        if (mounted) {
          setState(() {
            _buildChatItems(events);
          });
        }
      },
    );
    if (mounted) {
      setState(() {
        _timeline = timeline;
        _buildChatItems(timeline.events);
      });
    }
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
            mouseCursor: SystemMouseCursors.click,
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
    _stickyTimelineFadeOutTimer?.cancel();
    _timeline?.cancelSubscriptions();
    _input.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    _stickyTimelineOverlay.dispose();
    _attachedTimelineSeparatorId.dispose();
    _showJumpToLatestButton.dispose();
    _stickyTimelineOverlayVisible.dispose();
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
              child: Stack(
                key: _timelineViewportKey,
                children: [
                  Positioned.fill(
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

                        if (item is DaySeparatorItem) {
                          return _withTimelineProbe(
                            item,
                            ValueListenableBuilder<String?>(
                              valueListenable: _attachedTimelineSeparatorId,
                              child: _TimelineDaySeparator(
                                key: ValueKey(item.id),
                                date: item.date,
                              ),
                              builder: (context, attachedId, child) => Opacity(
                                opacity: attachedId == item.id ? 0 : 1,
                                child: child!,
                              ),
                            ),
                          );
                        }

                        if (item is AlbumItem) {
                          return _withTimelineProbe(
                            item,
                            MessageBubble(
                              key: ValueKey(item.id),
                              event: item.leader,
                              isMine: item.leader.senderId == myId,
                              showSender: !room.isDirectChat,
                              timeline: liveTimeline,
                              myUserId: myId,
                              onReact: (emoji) => room.sendReaction(
                                item.leader.eventId,
                                emoji,
                              ),
                              onRedact: (rid) => room.redactEvent(rid),
                              onEdit: liveTimeline == null
                                  ? null
                                  : () => _startEdit(item.leader),
                              onDelete: () =>
                                  room.redactEvent(item.leader.eventId),
                              onReply: liveTimeline == null
                                  ? null
                                  : () => _startReply(item.leader),
                              onForward: liveTimeline == null
                                  ? null
                                  : () => unawaited(
                                      _forwardEvents(item.events),
                                    ),
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
                            ),
                          );
                        } else if (item is SingleEventItem) {
                          return _withTimelineProbe(
                            item,
                            MessageBubble(
                              key: ValueKey(item.id),
                              event: item.event,
                              isMine: item.event.senderId == myId,
                              showSender: !room.isDirectChat,
                              timeline: liveTimeline,
                              myUserId: myId,
                              onReact: (emoji) => room.sendReaction(
                                item.event.eventId,
                                emoji,
                              ),
                              onRedact: (rid) => room.redactEvent(rid),
                              onEdit: liveTimeline == null
                                  ? null
                                  : () => _startEdit(item.event),
                              onDelete: () =>
                                  room.redactEvent(item.event.eventId),
                              onReply: liveTimeline == null
                                  ? null
                                  : () => _startReply(item.event),
                              onForward: liveTimeline == null
                                  ? null
                                  : () => unawaited(
                                      _forwardEvents(<Event>[item.event]),
                                    ),
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
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  ),
                  ValueListenableBuilder<_StickyTimelineOverlay?>(
                    valueListenable: _stickyTimelineOverlay,
                    builder: (context, sticky, child) {
                      if (sticky == null) return const SizedBox.shrink();
                      return Positioned(
                        top: sticky.top,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          child: ValueListenableBuilder<bool>(
                            valueListenable: _stickyTimelineOverlayVisible,
                            builder: (context, visible, child) {
                              return AnimatedOpacity(
                                opacity: visible ? 1 : 0,
                                duration: visible
                                    ? Duration.zero
                                    : _stickyTimelineFadeDuration,
                                curve: Curves.easeOut,
                                child: child,
                              );
                            },
                            child: _FadingTimelineDaySeparator(
                              key: ValueKey(
                                'sticky-day-${sticky.date.year}-${sticky.date.month}-${sticky.date.day}',
                              ),
                              date: sticky.date,
                              animateIn: sticky.animateIn,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: _showJumpToLatestButton,
                    child: _JumpToLatestPill(onPressed: _animateToLatest),
                    builder: (context, visible, child) {
                      return Positioned(
                        left: 0,
                        right: 0,
                        bottom: 10,
                        child: IgnorePointer(
                          ignoring: !visible,
                          child: AnimatedSlide(
                            offset: visible
                                ? Offset.zero
                                : const Offset(0, 1.35),
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            child: AnimatedOpacity(
                              opacity: visible ? 1 : 0,
                              duration: const Duration(milliseconds: 140),
                              curve: Curves.easeOut,
                              child: child!,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
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

class _StickyTimelineOverlay {
  const _StickyTimelineOverlay({
    required this.date,
    required this.top,
    required this.animateIn,
  });

  final DateTime date;
  final double top;
  final bool animateIn;
}

class _VisibleTimelineSeparator {
  const _VisibleTimelineSeparator({
    required this.id,
    required this.date,
    required this.top,
    required this.bottom,
  });

  final String id;
  final DateTime date;
  final double top;
  final double bottom;

  double get height => bottom - top;
}

class _TimelineItemProbe extends StatefulWidget {
  const _TimelineItemProbe({
    super.key,
    required this.item,
    required this.onAttach,
    required this.onDetach,
    required this.child,
  });

  final ChatItem item;
  final ValueChanged<_TimelineItemProbeState> onAttach;
  final ValueChanged<_TimelineItemProbeState> onDetach;
  final Widget child;

  @override
  State<_TimelineItemProbe> createState() => _TimelineItemProbeState();
}

class _TimelineItemProbeState extends State<_TimelineItemProbe> {
  ChatItem get item => widget.item;

  RenderBox? get renderBox {
    final renderObject = context.findRenderObject();
    return renderObject is RenderBox ? renderObject : null;
  }

  @override
  void initState() {
    super.initState();
    widget.onAttach(this);
  }

  @override
  void didUpdateWidget(covariant _TimelineItemProbe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id == widget.item.id) return;
    oldWidget.onDetach(this);
    widget.onAttach(this);
  }

  @override
  void dispose() {
    widget.onDetach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _FadingTimelineDaySeparator extends StatefulWidget {
  const _FadingTimelineDaySeparator({
    super.key,
    required this.date,
    required this.animateIn,
  });

  final DateTime date;
  final bool animateIn;

  @override
  State<_FadingTimelineDaySeparator> createState() =>
      _FadingTimelineDaySeparatorState();
}

class _FadingTimelineDaySeparatorState
    extends State<_FadingTimelineDaySeparator> {
  late bool _visible;

  @override
  void initState() {
    super.initState();
    _visible = !widget.animateIn;
    if (widget.animateIn) _revealAfterFrame();
  }

  @override
  void didUpdateWidget(covariant _FadingTimelineDaySeparator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // При движении вниз дата уже физически находится на экране и лишь
    // отрывается от sticky-позиции. В этом направлении никогда не запускаем
    // повторный fade-in: если пользователь развернул скролл во время появления,
    // сразу доводим текущую pill до полной непрозрачности.
    if (!widget.animateIn && oldWidget.animateIn && !_visible) {
      _visible = true;
    }
  }

  void _revealAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _visible || !widget.animateIn) return;
      setState(() => _visible = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: widget.animateIn
          ? const Duration(milliseconds: 140)
          : Duration.zero,
      curve: Curves.easeOut,
      child: _TimelineDaySeparator(date: widget.date, floating: true),
    );
  }
}

class _JumpToLatestPill extends StatelessWidget {
  const _JumpToLatestPill({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Semantics(
        button: true,
        label: 'К последним сообщениям',
        child: Material(
          elevation: 4,
          shadowColor: Colors.black.withValues(alpha: 0.16),
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                OrexColors.copper.withValues(alpha: 0.05),
                (isDark ? Colors.black : Colors.white).withValues(
                  alpha: isDark ? 0.64 : 0.84,
                ),
              ),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: OrexColors.copper.withValues(alpha: 0.28),
              ),
            ),
            child: InkWell(
              onTap: onPressed,
              mouseCursor: SystemMouseCursors.click,
              borderRadius: BorderRadius.circular(999),
              hoverColor: OrexColors.copper.withValues(alpha: 0.09),
              splashColor: OrexColors.copper.withValues(alpha: 0.15),
              highlightColor: OrexColors.copper.withValues(alpha: 0.065),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 15,
                  vertical: 9,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.keyboard_double_arrow_down_rounded,
                      size: 19,
                      color: OrexColors.copper.withValues(alpha: 0.92),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Вниз',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurface.withValues(alpha: 0.82),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TimelineDaySeparator extends StatelessWidget {
  const _TimelineDaySeparator({
    super.key,
    required this.date,
    this.floating = false,
  });

  static const double estimatedHeight = 27;

  final DateTime date;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      heightFactor: 1,
      child: Container(
        margin: EdgeInsets.symmetric(
          vertical: floating ? 0 : _ChatViewState._timelineSeparatorVerticalMargin,
          horizontal: 12,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
        decoration: BoxDecoration(
          color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          _formatTimelineDate(date),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.72),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

String _formatTimelineDate(DateTime value) {
  final date = value.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  final difference = today.difference(day).inDays;

  if (difference == 0) return 'Сегодня';
  if (difference == 1) return 'Вчера';

  const months = <String>[
    'января',
    'февраля',
    'марта',
    'апреля',
    'мая',
    'июня',
    'июля',
    'августа',
    'сентября',
    'октября',
    'ноября',
    'декабря',
  ];
  final base = '${date.day} ${months[date.month - 1]}';
  return date.year == now.year ? base : '$base ${date.year}';
}
