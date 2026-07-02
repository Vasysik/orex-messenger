import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
// Прячем matrix-овский CallSession — у нас свой одноимённый класс (медиа).
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_controller.dart';
import '../../core/voip/call_session.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/mxc_avatar.dart';
import '../../shared/widgets/squirrel_mascot.dart';
import '../../core/audio/audio_device_utils.dart';
import 'call_device_quick_sheet.dart';
import 'screen_source_picker.dart';
import 'voice_activity_frame.dart';

/// Наш собственный экран звонка поверх LiveKit (стек Element Call / MatrixRTC).
/// Сам звонок живёт в [CallController] (matrix.call) — экран лишь отображает его,
/// поэтому свернуть = выйти, не вешая трубку.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.matrix});

  final MatrixService matrix;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  CallController get _call => widget.matrix.call;
  CallSession? get _session => _call.session;
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

  @override
  void dispose() {
    // Выход с экрана (кнопка ▼ или системный «назад») = свернуть, не завершая.
    // notifyListeners нельзя дёргать прямо в dispose (дерево залочено —
    // ListenableBuilder падает), поэтому откладываем на следующий кадр.
    if (_call.isActive) {
      final call = _call;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (call.isActive) call.minimize();
      });
    }
    super.dispose();
  }

  Future<void> _hangup() async {
    await _call.hangUp();
  }

  Future<void> _showReactions(CallSession session) async {
    final emoji = await _showReactionPopup(_reactionButtonKey);
    if (emoji == null) return;
    await widget.matrix.audio.playReaction();
    await session.sendVoiceReaction(emoji);
  }

  Future<String?> _showReactionPopup(GlobalKey anchorKey) {
    return _showReactionMenu(context, anchorKey);
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
    if (room == null || userId == widget.matrix.client.userID) return false;
    return widget.matrix.isChannel(room) &&
        widget.matrix.canManageRoomSettings(room);
  }

  bool _canGrantVoice(Room? room, String userId) =>
      _canManageVoiceFor(room, userId) &&
      !widget.matrix.canSpeakInVoice(room!, userId);

  bool _canRevokeVoice(Room? room, String userId) =>
      _canManageVoiceFor(room, userId) &&
      widget.matrix.canSpeakInVoice(room!, userId);

  Future<void> _grantVoice(Room room, String userId) async {
    await widget.matrix.grantVoiceInChannel(room, userId);
    await widget.matrix.call.refreshVoicePermissions();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Голос выдан')),
    );
  }

  Future<void> _revokeVoice(Room room, String userId) async {
    await widget.matrix.revokeVoiceInChannel(room, userId);
    await widget.matrix.call.refreshVoicePermissions();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Голос забран')),
    );
  }


  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: AnimatedBuilder(
            animation: _call,
            builder: (context, _) {
              final s = _session;
              if (s == null) {
                // Звонок завершён — закрываем экран.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) Navigator.of(context).maybePop();
                });
                return const SizedBox.shrink();
              }
              return Column(
                children: [
                  _topBar(s),
                  Expanded(child: _body(s)),
                  if (s.status == CallStatus.connected) _controls(s),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar(CallSession session) => Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Свернуть',
              icon: const Icon(Icons.expand_more),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                session.listenOnly ? 'Голосовой канал · просмотр' : 'Звонок',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (session.listenOnly)
              const Tooltip(
                message: 'В каналах обычные участники входят без микрофона. '
                    'Чтобы попросить слово, поднимите руку.',
                child: Icon(Icons.visibility, color: OrexColors.copper),
              ),
          ],
        ),
      );

  Widget _body(CallSession session) {
    switch (session.status) {
      case CallStatus.connecting:
        return const Center(
          child: SquirrelMascot(size: 120, caption: 'Соединение…'),
        );
      case CallStatus.failed:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.phonelink_erase,
                    color: Color(0xFFCF6679), size: 44),
                const SizedBox(height: 12),
                const Text('Не удалось подключиться к звонку'),
                const SizedBox(height: 6),
                Text(session.error ?? '',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => session.connect(video: _call.video),
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        );
      case CallStatus.ended:
        return const Center(child: Text('Звонок завершён'));
      case CallStatus.connected:
        final people = session.participants;
        final room = widget.matrix.client.getRoomById(_call.roomId ?? '');
        return Column(
          children: [
            if (session.cameraError != null) _cameraNote(),
            if (session.error != null) _callNote(session.error!),
            if (!session.canPublishMedia) _listenOnlyNote(),
            Expanded(
              child: people.isEmpty
                  ? const Center(
                      child: SquirrelMascot(
                        size: 120,
                        caption: 'Ожидаем участников…',
                      ),
                    )
                  : _grid(session, people, room),
            ),
          ],
        );
    }
  }

  /// Адаптивная сетка участников, заполняющая доступную область без прокрутки.
  Widget _grid(CallSession session, List<lk.Participant> people, Room? room) {
    lk.Participant? pinned;
    final focused = _call.focusedParticipantIdentity;
    if (focused != null) {
      for (final p in people) {
        if (p.identity == focused) {
          pinned = p;
          break;
        }
      }
    }
    if (pinned != null) {
      final pinnedParticipant = pinned;
      final userId = _matrixUserId(pinnedParticipant.identity);
      final state = session.voiceStateForUser(userId);
      return Padding(
        padding: const EdgeInsets.all(8),
        child: _ParticipantTile(
          participant: pinnedParticipant,
          matrix: widget.matrix,
          room: room,
          voiceState: state,
          speakerMuted: session.speakerMuted,
          zoomable: true,
          cornerIcon: Icons.close_fullscreen,
          cornerTooltip: 'Отменить приближение плитки',
          onCornerTap: () => _call.focusParticipant(null),
          preferScreenShare: _preferScreenShareFor(pinnedParticipant),
          onSwitchVideoSource: orexHasCameraAndScreen(pinnedParticipant)
              ? () => _toggleParticipantVideoSource(pinnedParticipant)
              : null,
          onCycleCamera: pinnedParticipant is lk.LocalParticipant
              ? () => _cycleCamera(session)
              : null,
          onGrantVoice: _canGrantVoice(room, userId)
              ? () => _grantVoice(room!, userId)
              : null,
          onRevokeVoice: _canRevokeVoice(room, userId)
              ? () => _revokeVoice(room!, userId)
              : null,
        ),
      );
    }

    final cols = people.length <= 1 ? 1 : 2;
    final rows = (people.length / cols).ceil();
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          for (var r = 0; r < rows; r++)
            Expanded(
              child: Row(
                children: [
                  for (var c = 0; c < cols; c++)
                    Expanded(
                      child: r * cols + c < people.length
                          ? Builder(
                              builder: (_) {
                                final p = people[r * cols + c];
                                final userId = _matrixUserId(p.identity);
                                final state = session.voiceStateForUser(userId);
                                return Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: _ParticipantTile(
                                    participant: p,
                                    matrix: widget.matrix,
                                    room: room,
                                    voiceState: state,
                                    speakerMuted: session.speakerMuted,
                                    onTap: () => _call.focusParticipant(p.identity),
                                    cornerIcon: Icons.open_in_full,
                                    cornerTooltip: 'Приблизить плитку',
                                    onCornerTap: () => _call.focusParticipant(p.identity),
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
                                );
                              },
                            )
                          : const SizedBox.shrink(),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _matrixUserId(String identity) {
    final m = RegExp(r'@[^:]+:[^:]+').firstMatch(identity);
    return m?.group(0) ?? identity;
  }

  Future<void> _cycleCamera(CallSession session) async {
    final cameras = await enumerateOrexCameraDevices(requestPermission: true);
    if (cameras.isEmpty) return;
    await session.cycleCameraDevice(cameras);
  }

  Widget _cameraNote() => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFE0A03A).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Камера недоступна (возможно, занята другим окном) — звонок идёт со звуком.',
          style: TextStyle(fontSize: 12),
        ),
      );

  Widget _callNote(String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFE0A03A).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );

  Widget _listenOnlyNote() => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: OrexColors.copper.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Режим просмотра: микрофон, камера и трансляция экрана недоступны. Поднимите руку, чтобы попросить голос.',
          style: TextStyle(fontSize: 12),
        ),
      );

  Widget _controls(CallSession session) {
    final controls = <Widget>[
      if (session.canPublishMedia) ...[
        _round(
          tooltip: 'Микрофон · зажмите для выбора устройства',
          icon: session.micOn ? Icons.mic : Icons.mic_off,
          selected: !session.micOn,
          onTap: () { session.toggleMic(); },
          onLongPress: () => showOrexInputQuickSheet(
            context,
            matrix: widget.matrix,
          ),
        ),
        _round(
          tooltip: 'Камера · зажмите для выбора устройства',
          icon: session.camOn ? Icons.videocam : Icons.videocam_off,
          selected: !session.camOn,
          onTap: () { session.toggleCam(); },
          onLongPress: () => showOrexCameraQuickSheet(
            context,
            matrix: widget.matrix,
            session: session,
          ),
        ),
      ],
      _round(
        tooltip: 'Звук · зажмите для выбора вывода',
        icon: session.speakerMuted ? Icons.volume_off : Icons.volume_up,
        selected: session.speakerMuted,
        onTap: () { session.toggleSpeakerMute(); },
        onLongPress: () => showOrexOutputQuickSheet(
          context,
          matrix: widget.matrix,
        ),
      ),
      if (session.canPublishMedia)
        _round(
          tooltip: 'Трансляция экрана',
          icon: session.screenShareOn
              ? Icons.stop_screen_share
              : Icons.screen_share,
          selected: session.screenShareOn,
          onTap: () { _toggleScreenShare(session); },
        ),
      _round(
        tooltip: session.handRaised ? 'Опустить руку' : 'Поднять руку',
        icon: session.handRaised
            ? Icons.back_hand
            : Icons.back_hand_outlined,
        selected: session.handRaised,
        onTap: () { session.toggleHandRaised(); },
      ),
      _round(
        key: _reactionButtonKey,
        tooltip: 'Реакция',
        icon: Icons.emoji_emotions,
        onTap: () { _showReactions(session); },
      ),
      _round(
        tooltip: 'Завершить',
        icon: Icons.call_end,
        background: const Color(0xFFCF6679),
        onTap: () { _hangup(); },
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 24, top: 8, left: 16, right: 16),
      child: _BalancedControlRows(
        buttonCount: controls.length,
        buttonExtent: 54,
        spacing: 12,
        runSpacing: 10,
        children: controls,
      ),
    );
  }

  Widget _round({
    Key? key,
    required IconData icon,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    String? tooltip,
    Color? background,
    bool selected = false,
  }) {
    final child = _PressableCircleButton(
      key: key,
      icon: icon,
      size: 54,
      radius: 32,
      background: background,
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
    return tooltip == null ? child : Tooltip(message: tooltip, child: child);
  }
}


class _BalancedControlRows extends StatelessWidget {
  const _BalancedControlRows({
    required this.children,
    required this.buttonCount,
    required this.buttonExtent,
    required this.spacing,
    required this.runSpacing,
  });

  final List<Widget> children;
  final int buttonCount;
  final double buttonExtent;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final oneRowWidth = buttonCount * buttonExtent +
            (buttonCount - 1).clamp(0, buttonCount) * spacing;
        if (oneRowWidth <= constraints.maxWidth) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: _withSpacing(children, spacing),
          );
        }

        final topCount = (children.length + 1) ~/ 2;
        final top = children.take(topCount).toList();
        final bottom = children.skip(topCount).toList();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: _withSpacing(top, spacing),
            ),
            SizedBox(height: runSpacing),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: _withSpacing(bottom, spacing),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _withSpacing(List<Widget> items, double spacing) {
    final result = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) result.add(SizedBox(width: spacing));
      result.add(items[i]);
    }
    return result;
  }
}

class _PressableCircleButton extends StatefulWidget {
  const _PressableCircleButton({
    super.key,
    required this.icon,
    required this.size,
    required this.radius,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.background,
  });

  final IconData icon;
  final double size;
  final double radius;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color? background;

  @override
  State<_PressableCircleButton> createState() => _PressableCircleButtonState();
}

class _PressableCircleButtonState extends State<_PressableCircleButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkResponse(
        containedInkWell: true,
        highlightShape: BoxShape.circle,
        radius: widget.radius,
        customBorder: const CircleBorder(),
        mouseCursor: SystemMouseCursors.basic,
        hoverColor: Colors.white.withValues(alpha: 0.10),
        splashColor: Colors.white.withValues(alpha: 0.16),
        highlightColor: Colors.white.withValues(alpha: 0.08),
        onHighlightChanged: (value) => setState(() => _pressed = value),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 90),
          scale: _pressed ? 0.94 : 1,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.background,
              gradient: widget.background == null ? OrexColors.copperGradient : null,
              border: widget.selected
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.8),
                      width: 2,
                    )
                  : null,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Icon(widget.icon, color: OrexColors.cream),
          ),
        ),
      ),
    );
  }
}



class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.participant,
    required this.matrix,
    required this.room,
    required this.voiceState,
    required this.speakerMuted,
    required this.preferScreenShare,
    this.onTap,
    this.zoomable = false,
    this.cornerIcon,
    this.cornerTooltip,
    this.onCornerTap,
    this.onSwitchVideoSource,
    this.onCycleCamera,
    this.onGrantVoice,
    this.onRevokeVoice,
  });

  final lk.Participant participant;
  final MatrixService matrix;
  final Room? room;
  final VoiceParticipantState voiceState;
  final bool speakerMuted;
  final bool preferScreenShare;
  final VoidCallback? onTap;
  final bool zoomable;
  final IconData? cornerIcon;
  final String? cornerTooltip;
  final VoidCallback? onCornerTap;
  final VoidCallback? onSwitchVideoSource;
  final VoidCallback? onCycleCamera;
  final VoidCallback? onGrantVoice;
  final VoidCallback? onRevokeVoice;

  /// LiveKit identity у Element Call / lk-jwt-service — это `@user:server:device`.
  /// Достаём из него matrix-id, чтобы взять имя и аватар из комнаты.
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
    final micMuted = orexParticipantMicMuted(participant);
    final locallyMuted = speakerMuted && participant is lk.LocalParticipant;
    final statusBadgeCount = (micMuted ? 1 : 0) + (locallyMuted ? 1 : 0);
    final cameraButtonBottom = statusBadgeCount == 0
        ? 8.0
        : 8.0 + statusBadgeCount * 44.0;

    final userId = _userId;
    final user = room?.unsafeGetUserFromMemoryOrFallback(userId);
    var name = user?.calcDisplayname() ?? userId;
    if (participant is lk.LocalParticipant) name = '$name · вы';
    Widget media;
    if (track != null) {
      media = Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.contain),
      );
      if (zoomable) {
        media = InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: media,
        );
      }
    } else {
      media = Container(
        decoration: const BoxDecoration(gradient: OrexColors.copperGradient),
        alignment: Alignment.center,
        child: MxcAvatar(
          matrix: matrix,
          name: user?.calcDisplayname() ?? userId,
          mxc: user?.avatarUrl,
          size: zoomable ? 132 : 96,
        ),
      );
    }

    return OrexSpeakingFrame(
      participant: participant,
      matrix: matrix,
      borderRadius: 20,
      activeBlur: 18,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                media,
              Positioned(
                left: 8,
                bottom: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(name,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 12)),
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
                        _TileCornerButton(
                          icon: cornerIcon!,
                          tooltip: cornerTooltip ?? '',
                          onTap: onCornerTap!,
                        ),
                      if (onSwitchVideoSource != null) ...[
                        if (cornerIcon != null && onCornerTap != null)
                          const SizedBox(height: 6),
                        _TileCornerButton(
                          icon: preferScreenShare
                              ? Icons.videocam
                              : Icons.screen_share,
                          tooltip: preferScreenShare
                              ? 'Показать камеру участника'
                              : 'Показать демонстрацию участника',
                          onTap: onSwitchVideoSource!,
                        ),
                      ],
                    ],
                  ),
                ),
              if (statusBadgeCount > 0)
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (micMuted)
                        const _TileStatusBadge(
                          icon: Icons.mic_off,
                          tooltip: 'Микрофон выключен',
                        ),
                      if (locallyMuted) ...[
                        if (micMuted) const SizedBox(height: 6),
                        const _TileStatusBadge(
                          icon: Icons.volume_off,
                          tooltip: 'Вы выключили звук звонка у себя',
                        ),
                      ],
                    ],
                  ),
                ),
              if (track != null && onCycleCamera != null)
                Positioned(
                  right: 8,
                  bottom: cameraButtonBottom,
                  child: _TileCornerButton(
                    icon: Icons.cameraswitch,
                    tooltip: 'Переключить камеру',
                    onTap: onCycleCamera!,
                  ),
                ),
              Positioned(
                right: 8,
                top: 8,
                child: _VoiceStateBadges(
                  handRaised: voiceState.handRaised,
                  reaction: voiceState.reaction,
                  onGrantVoice: onGrantVoice,
                  onRevokeVoice: onRevokeVoice,
                ),
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }

}


Future<String?> _showReactionMenu(BuildContext context, GlobalKey anchorKey) {
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
                _ReactionChoice(emoji: emoji),
            ],
          ),
        ),
      ),
    ],
  );
}

class _ReactionChoice extends StatelessWidget {
  const _ReactionChoice({required this.emoji});

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
            child: Text(emoji, style: const TextStyle(fontSize: 26)),
          ),
        ),
      ),
    );
  }
}

class _TileCornerButton extends StatelessWidget {
  const _TileCornerButton({
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
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Icon(icon, size: 18, color: Colors.white),
        ),
      ),
    );
    return Tooltip(message: tooltip, child: button);
  }
}


class _TileStatusBadge extends StatelessWidget {
  const _TileStatusBadge({this.icon, this.text, required this.tooltip})
      : assert(icon != null || text != null);

  final IconData? icon;
  final String? text;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.52),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: icon != null
            ? Icon(icon, size: 18, color: Colors.white)
            : Text(text!, style: const TextStyle(fontSize: 21)),
      ),
    );
  }
}

class _VoiceStateBadges extends StatelessWidget {
  const _VoiceStateBadges({
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
        if (reaction != null)
          _TileStatusBadge(text: reaction!, tooltip: 'Реакция'),
        if (handRaised) ...[
          if (reaction != null) const SizedBox(width: 6),
          const _TileStatusBadge(
            icon: Icons.back_hand,
            tooltip: 'Просит голос',
          ),
        ],
        if (onGrantVoice != null) ...[
          if (handRaised || reaction != null) const SizedBox(width: 6),
          _TileCornerButton(
            icon: Icons.record_voice_over,
            tooltip: 'Дать голос',
            onTap: onGrantVoice!,
          ),
        ],
        if (onRevokeVoice != null) ...[
          if (handRaised || reaction != null || onGrantVoice != null)
            const SizedBox(width: 6),
          _TileCornerButton(
            icon: Icons.mic_off,
            tooltip: 'Забрать голос',
            onTap: onRevokeVoice!,
          ),
        ],
      ],
    );
  }
}
