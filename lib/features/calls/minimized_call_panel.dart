import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/voip/call_controller.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/mxc_avatar.dart';
import '../../core/voip/call_session.dart';
import 'screen_source_picker.dart';
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

  String _matrixUserId(String identity) {
    final m = RegExp(r'@[^:]+:[^:]+').firstMatch(identity);
    return m?.group(0) ?? identity;
  }

  Future<void> _showReactions(CallSession session) async {
    final emoji = await _showMiniReactionMenu(context, _reactionButtonKey);
    if (emoji == null) return;
    await widget.call.matrix.audio.playReaction();
    await session.sendVoiceReaction(emoji);
  }

  Future<void> _toggleScreenShare(CallSession session) async {
    if (session.screenShareOn) {
      await session.toggleScreenShare();
      return;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      await session.toggleScreenShare();
      return;
    }
    OrexScreenSource? source;
    if (orexNeedsScreenSourcePicker) {
      source = await showOrexScreenSourcePicker(context);
      if (source == null) return;
      // Даём окну выбора закрыться перед стартом захвата, но не пытаемся
      // лечить этим native-crash: реальная диагностика теперь логируется в
      // CallSession при создании screen-share track.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!mounted) return;
    }
    await session.toggleScreenShare(
      sourceId: source?.id,
      sourceName: source?.name,
      sourceType: source?.type,
    );
  }

  bool _canManageVoiceFor(Room? room, String userId) {
    if (room == null || userId == widget.call.matrix.client.userID) return false;
    return widget.call.matrix.isChannel(room) &&
        widget.call.matrix.canManageRoomSettings(room);
  }

  bool _canGrantVoice(Room? room, String userId) =>
      _canManageVoiceFor(room, userId) &&
      !widget.call.matrix.canSpeakInVoice(room!, userId);

  bool _canRevokeVoice(Room? room, String userId) =>
      _canManageVoiceFor(room, userId) &&
      widget.call.matrix.canSpeakInVoice(room!, userId);

  Future<void> _grantVoice(Room room, String userId) async {
    await widget.call.matrix.grantVoiceInChannel(room, userId);
    await widget.call.refreshVoicePermissions();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Голос выдан')),
    );
  }

  Future<void> _revokeVoice(Room room, String userId) async {
    await widget.call.matrix.revokeVoiceInChannel(room, userId);
    await widget.call.refreshVoicePermissions();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Голос забран')),
    );
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

        return Container(
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
                _miniNote('Режим просмотра: микрофон, камера и трансляция экрана недоступны.'),
              SizedBox(
                height: tilesH,
                child: people.isEmpty
                    ? const Center(
                        child: Text('Соединение…',
                            style: TextStyle(color: Colors.white70)),
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
      final userId = _matrixUserId(p.identity);
      final state = session.voiceStateForUser(userId);
      return SizedBox.expand(
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: _MiniTile(
            participant: p,
            matrix: widget.call.matrix,
            room: room,
            voiceState: state,
            zoomable: true,
            cornerIcon: Icons.close_fullscreen,
            cornerTooltip: 'Отменить приближение плитки',
            onCornerTap: () => widget.call.focusParticipant(null),
            preferScreenShare: _preferScreenShareFor(p),
            onSwitchVideoSource: orexHasCameraAndScreen(p)
                ? () => _toggleParticipantVideoSource(p)
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
        final gridHeight =
            tileHeight * rows + _miniTileGap * (rows - 1);
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
                final userId = _matrixUserId(p.identity);
                final state = session.voiceStateForUser(userId);
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: _MiniTile(
                    participant: p,
                    matrix: widget.call.matrix,
                    room: room,
                    voiceState: state,
                    cornerIcon: Icons.open_in_full,
                    cornerTooltip: 'Приблизить плитку',
                    onCornerTap: () => widget.call.focusParticipant(p.identity),
                    onTap: () => widget.call.focusParticipant(p.identity),
                    preferScreenShare: _preferScreenShareFor(p),
                    onSwitchVideoSource: orexHasCameraAndScreen(p)
                        ? () => _toggleParticipantVideoSource(p)
                        : null,
                    onGrantVoice: _canGrantVoice(room, userId)
                        ? () => _grantVoice(room!, userId)
                        : null,
                    onRevokeVoice: _canRevokeVoice(room, userId)
                        ? () => _revokeVoice(room!, userId)
                        : null,
                  ),
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
        onVerticalDragUpdate: (d) {
          setState(() {
            final base = _tilesHeight ??
                (MediaQuery.sizeOf(context).height / 3);
            _tilesHeight = (base + d.delta.dy).clamp(minH, maxH).toDouble();
          });
        },
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

  Widget _controls(CallSession session) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 2, left: 8, right: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 10,
          runSpacing: 8,
          children: [
            if (session.canPublishMedia) ...[
              _btn(
                icon: session.micOn ? Icons.mic : Icons.mic_off,
                onTap: () { session.toggleMic(); },
              ),
              _btn(
                icon: session.camOn ? Icons.videocam : Icons.videocam_off,
                onTap: () { session.toggleCam(); },
              ),
              _btn(
                icon: session.screenShareOn
                    ? Icons.stop_screen_share
                    : Icons.screen_share,
                selected: session.screenShareOn,
                onTap: () { _toggleScreenShare(session); },
              ),
            ],
            _btn(
              icon: session.handRaised
                  ? Icons.back_hand
                  : Icons.back_hand_outlined,
              selected: session.handRaised,
              onTap: () { session.toggleHandRaised(); },
            ),
            _btn(
              key: _reactionButtonKey,
              icon: Icons.emoji_emotions,
              onTap: () { _showReactions(session); },
            ),
            _btn(icon: Icons.open_in_full, onTap: widget.onExpand),
            _btn(
              icon: Icons.call_end,
              bg: const Color(0xFFCF6679),
              onTap: () { widget.call.hangUp(); },
            ),
          ],
        ),
      );


  Widget _btn({
    Key? key,
    required IconData icon,
    required VoidCallback onTap,
    Color? bg,
    bool selected = false,
  }) =>
      MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          key: key,
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkResponse(
            containedInkWell: true,
            highlightShape: BoxShape.circle,
            radius: 26,
            customBorder: const CircleBorder(),
            hoverColor: Colors.white.withValues(alpha: 0.12),
            splashColor: Colors.white.withValues(alpha: 0.18),
            highlightColor: Colors.white.withValues(alpha: 0.08),
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: bg ?? Colors.white24,
                border: Border.all(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.82)
                      : Colors.white.withValues(alpha: 0.06),
                  width: selected ? 2 : 1,
                ),
              ),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
          ),
        ),
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
              child: Builder(builder: (_) {
                final user = room.unsafeGetUserFromMemoryOrFallback(id);
                return MxcAvatar(
                  matrix: matrix,
                  name: user.calcDisplayname(),
                  mxc: user.avatarUrl,
                  size: 32,
                );
              }),
            ),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('Идёт звонок',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w600)),
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


class _MiniTile extends StatelessWidget {
  const _MiniTile({
    required this.participant,
    required this.matrix,
    required this.room,
    required this.voiceState,
    required this.preferScreenShare,
    this.zoomable = false,
    this.onTap,
    this.cornerIcon,
    this.cornerTooltip,
    this.onCornerTap,
    this.onSwitchVideoSource,
    this.onGrantVoice,
    this.onRevokeVoice,
  });

  final lk.Participant participant;
  final MatrixService matrix;
  final Room? room;
  final VoiceParticipantState voiceState;
  final bool preferScreenShare;
  final bool zoomable;
  final VoidCallback? onTap;
  final IconData? cornerIcon;
  final String? cornerTooltip;
  final VoidCallback? onCornerTap;
  final VoidCallback? onSwitchVideoSource;
  final VoidCallback? onGrantVoice;
  final VoidCallback? onRevokeVoice;

  String get _userId {
    final m = RegExp(r'@[^:]+:[^:]+').firstMatch(participant.identity);
    return m?.group(0) ?? participant.identity;
  }

  @override
  Widget build(BuildContext context) {
    final track = orexSelectVideoTrack(
      participant,
      preferScreenShare: preferScreenShare,
    );
    final user = room?.unsafeGetUserFromMemoryOrFallback(_userId);

    final tile = OrexSpeakingFrame(
      participant: participant,
      matrix: matrix,
      borderRadius: 14,
      activeBlur: 14,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            _miniMedia(
              Container(
                color: Colors.black,
                child: lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.contain),
              ),
            )
          else
            _miniMedia(
              Container(
                decoration:
                    const BoxDecoration(gradient: OrexColors.copperGradient),
                alignment: Alignment.center,
                child: MxcAvatar(
                  matrix: matrix,
                  name: user?.calcDisplayname() ?? _userId,
                  mxc: user?.avatarUrl,
                  size: zoomable ? 72 : 44,
                ),
              ),
            ),
          if ((cornerIcon != null && onCornerTap != null) ||
              onSwitchVideoSource != null)
            Positioned(
              left: 8,
              top: 8,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cornerIcon != null && onCornerTap != null)
                    _MiniTileCornerButton(
                      icon: cornerIcon!,
                      tooltip: cornerTooltip ?? '',
                      onTap: onCornerTap!,
                    ),
                  if (onSwitchVideoSource != null) ...[
                    if (cornerIcon != null && onCornerTap != null)
                      const SizedBox(height: 5),
                    _MiniTileCornerButton(
                      icon: preferScreenShare ? Icons.videocam : Icons.screen_share,
                      tooltip: preferScreenShare
                          ? 'Показать камеру участника'
                          : 'Показать демонстрацию участника',
                      onTap: onSwitchVideoSource!,
                    ),
                  ],
                ],
              ),
            ),
          Positioned(
            right: 8,
            top: 8,
            child: _MiniVoiceBadges(
              handRaised: voiceState.handRaised,
              reaction: voiceState.reaction,
              onGrantVoice: onGrantVoice,
              onRevokeVoice: onRevokeVoice,
            ),
          ),
          ],
        ),
      ),
    );

    if (onTap == null) return tile;
    return GestureDetector(onTap: onTap, child: tile);
  }

  Widget _miniMedia(Widget child) {
    if (!zoomable) return child;
    return InteractiveViewer(
      minScale: 1,
      maxScale: 4,
      child: child,
    );
  }
}

class _MiniTileCornerButton extends StatelessWidget {
  const _MiniTileCornerButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Icon(icon, size: 17, color: Colors.white),
        ),
      ),
    );
    return Tooltip(message: tooltip, child: button);
  }
}


Future<String?> _showMiniReactionMenu(BuildContext context, GlobalKey anchorKey) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final button = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (overlay == null || button == null) return Future.value(null);

  final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
  final bottomRight = button.localToGlobal(
    button.size.bottomRight(Offset.zero),
    ancestor: overlay,
  );
  final rect = Rect.fromPoints(topLeft, bottomRight);

  return showMenu<String>(
    context: context,
    color: OrexColors.darkSurface.withValues(alpha: 0.98),
    elevation: 18,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    position: RelativeRect.fromLTRB(
      rect.left,
      rect.top - 8,
      overlay.size.width - rect.right,
      overlay.size.height - rect.top,
    ),
    items: [
      PopupMenuItem<String>(
        enabled: true,
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Wrap(
            spacing: 6,
            children: [
              for (final emoji in const ['👍', '🔥', '😂', '❤️', '👏', '😮'])
                _MiniReactionChoice(emoji: emoji),
            ],
          ),
        ),
      ),
    ],
  );
}

class _MiniReactionChoice extends StatelessWidget {
  const _MiniReactionChoice({required this.emoji});

  final String emoji;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          hoverColor: OrexColors.copper.withValues(alpha: 0.14),
          onTap: () => Navigator.pop(context, emoji),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text(emoji, style: const TextStyle(fontSize: 24)),
          ),
        ),
      ),
    );
  }
}

class _MiniVoiceBadges extends StatelessWidget {
  const _MiniVoiceBadges({
    required this.handRaised,
    required this.reaction,
    this.onGrantVoice,
    this.onRevokeVoice,
  });

  final bool handRaised;
  final String? reaction;
  final VoidCallback? onGrantVoice;
  final VoidCallback? onRevokeVoice;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (reaction != null) _badge(text: reaction!, tooltip: 'Реакция'),
        if (handRaised) ...[
          if (reaction != null) const SizedBox(width: 6),
          _badge(text: '✋', tooltip: 'Просит голос'),
        ],
        if (onGrantVoice != null) ...[
          if (handRaised || reaction != null) const SizedBox(width: 6),
          _badge(
            icon: Icons.record_voice_over,
            tooltip: 'Дать голос',
            onTap: onGrantVoice,
            accent: true,
          ),
        ],
        if (onRevokeVoice != null) ...[
          if (handRaised || reaction != null || onGrantVoice != null)
            const SizedBox(width: 6),
          _badge(
            icon: Icons.mic_off,
            tooltip: 'Забрать голос',
            onTap: onRevokeVoice,
            accent: true,
          ),
        ],
      ],
    );
  }

  Widget _badge({
    IconData? icon,
    String? text,
    required String tooltip,
    VoidCallback? onTap,
    bool accent = false,
  }) {
    final child = Container(
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: accent
            ? OrexColors.copper.withValues(alpha: 0.90)
            : Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: icon != null
          ? Icon(icon, color: Colors.white, size: 16)
          : Text(text!, style: const TextStyle(fontSize: 20)),
    );
    final wrapped = onTap == null
        ? child
        : Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: onTap, child: child),
          );
    return Tooltip(message: tooltip, child: wrapped);
  }
}
