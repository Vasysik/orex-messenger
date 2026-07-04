import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/voip/call_controller.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/mxc_avatar.dart';
import '../../core/voip/call_session.dart';
import 'call_controls.dart';
import 'call_device_quick_sheet.dart';
import 'call_media_actions.dart';
import 'call_participant_tile.dart';
import 'call_voice_actions.dart';
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
  static const double _miniTileMinHeight = 132;
  static const double _miniTileMaxHeight = 260;
  static const double _miniTileMinWidth = 220;
  static const double _miniTileMaxWidth = 420;
  static const double _miniTileGap = 6;

  double? _tilesHeight; // null → дефолт = 1/3 высоты экрана
  double? _dragStartTilesHeight;
  final GlobalKey _reactionButtonKey = GlobalKey();
  final Map<String, bool> _preferScreenShareByIdentity = <String, bool>{};

  bool _preferScreenShareFor(lk.Participant participant) =>
      _preferScreenShareByIdentity[participant.identity] ?? true;

  void _toggleParticipantVideoSource(lk.Participant participant) {
    setState(() {
      _preferScreenShareByIdentity[participant.identity] =
          !_preferScreenShareFor(participant);
    });
  }

  Future<void> _showReactions(CallSession session) async {
    await orexShowCallReaction(
      context: context,
      anchorKey: _reactionButtonKey,
      matrix: widget.call.matrix,
      session: session,
      emojiSize: 24,
    );
  }

  Future<void> _toggleScreenShare(CallSession session) async {
    await orexToggleScreenShare(
      context: context,
      session: session,
      isMounted: () => mounted,
    );
  }

  bool _canGrantVoice(Room? room, String userId) =>
      orexCanGrantVoice(widget.call.matrix, room, userId);

  bool _canRevokeVoice(Room? room, String userId) =>
      orexCanRevokeVoice(widget.call.matrix, room, userId);

  Future<void> _grantVoice(Room room, String userId) async {
    await orexGrantVoice(
      matrix: widget.call.matrix,
      call: widget.call,
      room: room,
      userId: userId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Голос выдан')));
  }

  Future<void> _revokeVoice(Room room, String userId) async {
    await orexRevokeVoice(
      matrix: widget.call.matrix,
      call: widget.call,
      room: room,
      userId: userId,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Голос забран')));
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
        final room = call.roomId != null
            ? call.matrix.client.getRoomById(call.roomId!)
            : null;
        final people = session.participants;
        final focused = call.focusedParticipantIdentity;
        final visiblePeople = focused == null
            ? people
            : people.where((p) => p.identity == focused).toList();

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
                  if (session.cameraError != null)
                    _miniNote('Камера недоступна — звонок идёт со звуком.'),
                  if (session.error != null) _miniNote(session.error!),
                  if (!session.canPublishMedia)
                    _miniNote(
                      'Режим просмотра: микрофон, камера и трансляция экрана недоступны.',
                    ),
                  SizedBox(
                    height: tilesH,
                    child: people.isEmpty
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
                              child: _miniTiles(
                                session: session,
                                people: visiblePeople,
                                room: room,
                                pinned: focused != null,
                              ),
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

  Widget _miniTiles({
    required CallSession session,
    required List<lk.Participant> people,
    required Room? room,
    required bool pinned,
  }) {
    if (pinned) {
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
            preferScreenShare: _preferScreenShareFor(p),
            onSwitchVideoSource: orexHasCameraAndScreen(p)
                ? () => _toggleParticipantVideoSource(p)
                : null,
            onCycleCamera: p is lk.LocalParticipant
                ? () => _cycleCamera(session)
                : null,
            onGrantVoice: _canGrantVoice(room, userId)
                ? () => _grantVoice(room!, userId)
                : null,
            onRevokeVoice: _canRevokeVoice(room, userId)
                ? () => _revokeVoice(room!, userId)
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
                  onTap: () => widget.call.focusParticipant(p.identity),
                  preferScreenShare: _preferScreenShareFor(p),
                  onSwitchVideoSource: orexHasCameraAndScreen(p)
                      ? () => _toggleParticipantVideoSource(p)
                      : null,
                  onCycleCamera: p is lk.LocalParticipant
                      ? () => _cycleCamera(session)
                      : null,
                  onGrantVoice: _canGrantVoice(room, userId)
                      ? () => _grantVoice(room!, userId)
                      : null,
                  onRevokeVoice: _canRevokeVoice(room, userId)
                      ? () => _revokeVoice(room!, userId)
                      : null,
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _cycleCamera(CallSession session) async {
    await orexCycleCamera(session);
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

  Widget _controls(CallSession session) {
    final controls = <Widget>[
      if (session.canPublishMedia) ...[
        _btn(
          icon: session.micOn ? Icons.mic : Icons.mic_off,
          selected: !session.micOn,
          onTap: () {
            session.toggleMic();
          },
          onLongPress: () =>
              showOrexInputQuickSheet(context, matrix: widget.call.matrix),
        ),
        _btn(
          icon: session.camOn ? Icons.videocam : Icons.videocam_off,
          selected: !session.camOn,
          onTap: () {
            session.toggleCam();
          },
          onLongPress: () => showOrexCameraQuickSheet(
            context,
            matrix: widget.call.matrix,
            session: session,
          ),
        ),
      ],
      _btn(
        icon: session.speakerMuted ? Icons.volume_off : Icons.volume_up,
        selected: session.speakerMuted,
        onTap: () {
          session.toggleSpeakerMute();
        },
        onLongPress: () =>
            showOrexOutputQuickSheet(context, matrix: widget.call.matrix),
      ),
      if (session.canPublishMedia)
        _btn(
          icon: session.screenShareOn
              ? Icons.stop_screen_share
              : Icons.screen_share,
          selected: session.screenShareOn,
          onTap: () {
            _toggleScreenShare(session);
          },
        ),
      _btn(
        icon: session.handRaised ? Icons.back_hand : Icons.back_hand_outlined,
        selected: session.handRaised,
        onTap: () {
          session.toggleHandRaised();
        },
      ),
      _btn(
        key: _reactionButtonKey,
        icon: Icons.emoji_emotions,
        onTap: () {
          _showReactions(session);
        },
      ),
      _btn(
        icon: Icons.call_end,
        bg: const Color(0xFFCF6679),
        onTap: () {
          widget.call.hangUp();
        },
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 2, left: 8, right: 8),
      child: OrexBalancedControlRows(
        buttonCount: controls.length,
        buttonExtent: 42,
        spacing: 10,
        runSpacing: 8,
        children: controls,
      ),
    );
  }

  Widget _btn({
    Key? key,
    required IconData icon,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    Color? bg,
    bool selected = false,
  }) => OrexCallControlButton(
    key: key,
    icon: icon,
    style: OrexCallControlButtonStyle.minimized,
    selected: selected,
    background: bg,
    onTap: onTap,
    onLongPress: onLongPress,
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
