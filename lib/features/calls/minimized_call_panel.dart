import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/voip/call_controller.dart';
import '../../core/platform/orex_system_picture_in_picture.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/mxc_avatar.dart';
import '../../core/voip/call_session.dart';
import 'call_controls.dart';
import 'call_participant_tile.dart';
import 'call_presentation.dart';
import 'call_ui_actions.dart';
import 'voice_activity_frame.dart';

/// Свёрнутый звонок панелью над чатом (как в Discord): плитки участников +
/// управление. Тап по плиткам — развернуть на весь экран. Высоту можно тянуть
/// мышью за нижнюю кромку.
class MinimizedCallPanel extends StatefulWidget {
  const MinimizedCallPanel({
    super.key,
    required this.call,
    required this.onExpand,
  });

  final CallController call;
  final VoidCallback onExpand;

  @override
  State<MinimizedCallPanel> createState() => _MinimizedCallPanelState();
}

class _MinimizedCallPanelState extends State<MinimizedCallPanel> {
  OrexSystemPictureInPicture get _pip =>
      OrexSystemPictureInPicture.instance;
  static const double _miniTileMinHeight = 132;
  static const double _miniTileMaxHeight = 260;
  static const double _miniTileMinWidth = 220;
  static const double _miniTileMaxWidth = 420;
  static const double _miniTileGap = 6;

  double? _tilesHeight; // null → дефолт = 1/3 высоты экрана
  double? _dragStartTilesHeight;
  final GlobalKey _reactionButtonKey = GlobalKey();
  final OrexCallVideoPreferences _videoPreferences = OrexCallVideoPreferences();

  OrexCallUiActions get _actions => OrexCallUiActions(
    context: context,
    matrix: widget.call.matrix,
    call: widget.call,
    reactionButtonKey: _reactionButtonKey,
    isMounted: () => mounted,
    reactionEmojiSize: 24,
  );

  bool _preferScreenShareFor(lk.Participant participant) =>
      _videoPreferences.prefersParticipantScreenShare(participant);

  void _toggleParticipantVideoSource(lk.Participant participant) {
    setState(() {
      _videoPreferences.toggleParticipant(participant);
    });
    if (_pip.isActiveFor(participant.identity)) {
      final track = orexSelectVideoTrack(
        participant,
        preferScreenShare: _preferScreenShareFor(participant),
      );
      if (track != null) {
        unawaited(
          _pip.updateTrack(identity: participant.identity, track: track),
        );
      }
    }
  }

  void _toggleParticipantPictureInPicture(lk.Participant participant) {
    final track = orexSelectVideoTrack(
      participant,
      preferScreenShare: _preferScreenShareFor(participant),
    );
    if (track == null || !_pip.canOffer) return;
    unawaited(_pip.toggle(identity: participant.identity, track: track));
  }

  void _onPictureInPictureChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _pip.addListener(_onPictureInPictureChanged);
  }

  @override
  void dispose() {
    _pip.removeListener(_onPictureInPictureChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final screenH = MediaQuery.sizeOf(context).height;
    final minH = _miniTileMinHeight;
    final maxH = math.max(minH, screenH * 0.7);
    final tilesH = (_tilesHeight ?? screenH / 3).clamp(minH, maxH).toDouble();

    return AnimatedBuilder(
      animation: call,
      builder: (context, _) {
        final session = call.session;
        if (session == null) return const SizedBox.shrink();
        final presentation = OrexCallPresentation.from(
          matrix: call.matrix,
          call: call,
          session: session,
        );

        return Stack(
          children: [
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final notice in presentation.notices)
                    _noticeText(notice),
                  SizedBox(
                    height: tilesH,
                    child: presentation.participants.isEmpty
                        ? const Center(
                            child: Text(
                              'Соединение…',
                              style: TextStyle(color: Colors.white70),
                            ),
                          )
                        : GestureDetector(
                            onTap: widget.onExpand,
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: _miniTiles(presentation: presentation),
                            ),
                          ),
                  ),
                  _controls(session),
                  _resizeHandle(minH, maxH),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _miniTiles({required OrexCallPresentation presentation}) {
    final session = presentation.session;
    final room = presentation.room;
    final people = presentation.visibleParticipants;
    if (presentation.hasFocusedParticipant) {
      final p = people.isNotEmpty ? people.first : null;
      if (p == null) return const SizedBox.shrink();
      final userId = orexMatrixUserIdFromParticipantIdentity(p.identity);
      final state = session.voiceStateForUser(userId);
      return SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: OrexCallParticipantTile(
            participant: p,
            matrix: widget.call.matrix,
            room: room,
            voiceState: state,
            style: OrexCallParticipantTileStyle.minimized,
            zoomable: true,
            cornerIcon: Icons.close_fullscreen,
            cornerTooltip: 'Отменить приближение плитки',
            onCornerTap: () => widget.call.focusParticipant(null),
            pictureInPictureActive: _pip.isActiveFor(p.identity),
            onPictureInPicture: _pip.canOffer
                ? () => _toggleParticipantPictureInPicture(p)
                : null,
            preferScreenShare: _preferScreenShareFor(p),
            onSwitchVideoSource: orexHasCameraAndScreen(p)
                ? () => _toggleParticipantVideoSource(p)
                : null,
            onCycleCamera: p is lk.LocalParticipant
                ? () => _actions.cycleCamera(session)
                : null,
            onGrantVoice: _actions.canGrantVoice(room, userId)
                ? () => _actions.grantVoice(room!, userId)
                : null,
            onRevokeVoice: _actions.canRevokeVoice(room, userId)
                ? () => _actions.revokeVoice(room!, userId)
                : null,
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final count = people.length;
        if (count == 0) return const SizedBox.shrink();

        final maxColumnsByWidth = math.max(
          1,
          ((constraints.maxWidth + _miniTileGap) /
                  (_miniTileMinWidth + _miniTileGap))
              .floor(),
        );
        final maxColumns = math.min(count, maxColumnsByWidth);

        var columns = 1;
        for (var c = 1; c <= maxColumns; c++) {
          final rows = (count / c).ceil();
          final rawTileHeight =
              (constraints.maxHeight - _miniTileGap * (rows - 1)) / rows;
          if (rawTileHeight >= _miniTileMinHeight) columns = c;
        }
        columns = math.max(1, columns);
        final rows = (count / columns).ceil();

        final rawTileWidth =
            (constraints.maxWidth - _miniTileGap * (columns - 1)) / columns;
        final rawTileHeight =
            (constraints.maxHeight - _miniTileGap * (rows - 1)) / rows;
        final tileWidth = rawTileWidth
            .clamp(_miniTileMinWidth, _miniTileMaxWidth)
            .toDouble();
        final tileHeight = rawTileHeight
            .clamp(_miniTileMinHeight, _miniTileMaxHeight)
            .toDouble();
        final gridWidth = math.min(
          constraints.maxWidth,
          tileWidth * columns + _miniTileGap * (columns - 1),
        );
        final gridHeight = tileHeight * rows + _miniTileGap * (rows - 1);
        final needsScroll = gridHeight > constraints.maxHeight + 0.5;

        return Align(
          alignment: Alignment.center,
          child: SizedBox(
            width: gridWidth,
            height: needsScroll ? constraints.maxHeight : gridHeight,
            child: GridView.builder(
              padding: EdgeInsets.zero,
              physics: needsScroll
                  ? const BouncingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: _miniTileGap,
                mainAxisSpacing: _miniTileGap,
                childAspectRatio: tileWidth / tileHeight,
              ),
              itemCount: count,
              itemBuilder: (context, index) {
                final p = people[index];
                final userId = orexMatrixUserIdFromParticipantIdentity(
                  p.identity,
                );
                final state = session.voiceStateForUser(userId);
                return OrexCallParticipantTile(
                  participant: p,
                  matrix: widget.call.matrix,
                  room: room,
                  voiceState: state,
                  style: OrexCallParticipantTileStyle.minimized,
                  cornerIcon: Icons.open_in_full,
                  cornerTooltip: 'Приблизить плитку',
                  onCornerTap: () => widget.call.focusParticipant(p.identity),
                  pictureInPictureActive: _pip.isActiveFor(p.identity),
                  onPictureInPicture: _pip.canOffer
                      ? () => _toggleParticipantPictureInPicture(p)
                      : null,
                  onTap: () => widget.call.focusParticipant(p.identity),
                  preferScreenShare: _preferScreenShareFor(p),
                  onSwitchVideoSource: orexHasCameraAndScreen(p)
                      ? () => _toggleParticipantVideoSource(p)
                      : null,
                  onCycleCamera: p is lk.LocalParticipant
                      ? () => _actions.cycleCamera(session)
                      : null,
                  onGrantVoice: _actions.canGrantVoice(room, userId)
                      ? () => _actions.grantVoice(room!, userId)
                      : null,
                  onRevokeVoice: _actions.canRevokeVoice(room, userId)
                      ? () => _actions.revokeVoice(room!, userId)
                      : null,
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// Нижняя кромка-«ручка»: тянуть вверх/вниз, чтобы менять высоту плиток.
  /// База берётся из ПОЛЯ (не из build) — иначе при быстром перетаскивании
  /// несколько событий за кадр считают от устаревшей высоты и дельты теряются
  /// (визуально «медленнее мыши»).
  Widget _resizeHandle(double minH, double maxH) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) {
          _dragStartTilesHeight =
              _tilesHeight ?? (MediaQuery.sizeOf(context).height / 3);
        },
        onVerticalDragUpdate: (d) {
          final base = _tilesHeight ?? (MediaQuery.sizeOf(context).height / 3);
          final next = (base + d.delta.dy).clamp(minH, maxH).toDouble();
          if (next >= maxH * 0.96 && d.delta.dy > 0) {
            final restoreHeight =
                (_dragStartTilesHeight ??
                        (MediaQuery.sizeOf(context).height / 3))
                    .clamp(minH, maxH)
                    .toDouble();
            setState(() => _tilesHeight = restoreHeight);
            widget.onExpand();
            return;
          }
          setState(() => _tilesHeight = next);
        },
        onVerticalDragEnd: (_) => _dragStartTilesHeight = null,
        onVerticalDragCancel: () => _dragStartTilesHeight = null,
        child: Container(
          height: 16,
          alignment: Alignment.center,
          child: Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white30,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(CallSession session) => OrexCallControlsBar(
    mode: OrexCallControlsBarMode.minimized,
    matrix: widget.call.matrix,
    session: session,
    reactionButtonKey: _reactionButtonKey,
    onReactionTap: () {
      _actions.showReactions(session);
    },
    onScreenShareTap: () {
      _actions.toggleScreenShare(session);
    },
    onHangUpTap: () {
      _actions.hangUp();
    },
  );

  Widget _miniNote(String text) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: const Color(0xFFE0A03A).withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white, fontSize: 12),
    ),
  );

  Widget _noticeText(OrexCallNotice notice) {
    return switch (notice.kind) {
      OrexCallNoticeKind.camera => _miniNote(
        'Камера недоступна — звонок идёт со звуком.',
      ),
      OrexCallNoticeKind.error => _miniNote(notice.message ?? ''),
      OrexCallNoticeKind.listenOnly => _miniNote(
        'Режим просмотра: микрофон, камера и трансляция экрана недоступны.',
      ),
    };
  }
}

/// Панель «Идёт звонок» для звонка в комнате, в который мы НЕ вошли: аватары
/// участников + кнопка «Войти». Тот же стиль, что и у активного звонка.
class JoinCallPanel extends StatelessWidget {
  const JoinCallPanel({
    super.key,
    required this.matrix,
    required this.room,
    required this.onJoin,
  });

  final MatrixService matrix;
  final Room room;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final memberIds = matrix.callMemberIds(room);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.call, color: OrexColors.online),
          const SizedBox(width: 12),
          for (final id in memberIds.take(4))
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Builder(
                builder: (_) {
                  final user = room.unsafeGetUserFromMemoryOrFallback(id);
                  return MxcAvatar(
                    matrix: matrix,
                    name: user.calcDisplayname(),
                    mxc: user.avatarUrl,
                    size: 32,
                  );
                },
              ),
            ),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              'Идёт звонок',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: OrexColors.online),
            onPressed: onJoin,
            icon: const Icon(Icons.call, size: 18),
            label: const Text('Войти'),
          ),
        ],
      ),
    );
  }
}
