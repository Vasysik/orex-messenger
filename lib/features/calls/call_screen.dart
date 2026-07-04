import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
// Прячем matrix-овский CallSession — у нас свой одноимённый класс (медиа).
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_controller.dart';
import '../../core/voip/call_session.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/squirrel_mascot.dart';
import 'call_controls.dart';
import 'call_device_quick_sheet.dart';
import 'call_media_actions.dart';
import 'call_participant_tile.dart';
import 'call_voice_actions.dart';
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
    await orexShowCallReaction(
      context: context,
      anchorKey: _reactionButtonKey,
      matrix: widget.matrix,
      session: session,
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
      orexCanGrantVoice(widget.matrix, room, userId);

  bool _canRevokeVoice(Room? room, String userId) =>
      orexCanRevokeVoice(widget.matrix, room, userId);

  Future<void> _grantVoice(Room room, String userId) async {
    await orexGrantVoice(
      matrix: widget.matrix,
      call: widget.matrix.call,
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
      matrix: widget.matrix,
      call: widget.matrix.call,
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
                  if (!mounted) return;
                  final nav = Navigator.of(context);
                  if (nav.canPop()) nav.pop();
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
            message:
                'В каналах обычные участники входят без микрофона. '
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
                const Icon(
                  Icons.phonelink_erase,
                  color: Color(0xFFCF6679),
                  size: 44,
                ),
                const SizedBox(height: 12),
                const Text('Не удалось подключиться к звонку'),
                const SizedBox(height: 6),
                Text(
                  session.error ?? '',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
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
      final userId = orexMatrixUserIdFromParticipantIdentity(
        pinnedParticipant.identity,
      );
      final state = session.voiceStateForUser(userId);
      return Padding(
        padding: const EdgeInsets.all(8),
        child: OrexCallParticipantTile(
          participant: pinnedParticipant,
          matrix: widget.matrix,
          room: room,
          voiceState: state,
          style: OrexCallParticipantTileStyle.full,
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
                                final userId =
                                    orexMatrixUserIdFromParticipantIdentity(
                                      p.identity,
                                    );
                                final state = session.voiceStateForUser(userId);
                                return Padding(
                                  padding: const EdgeInsets.all(4),
                                  child: OrexCallParticipantTile(
                                    participant: p,
                                    matrix: widget.matrix,
                                    room: room,
                                    voiceState: state,
                                    style: OrexCallParticipantTileStyle.full,
                                    onTap: () =>
                                        _call.focusParticipant(p.identity),
                                    cornerIcon: Icons.open_in_full,
                                    cornerTooltip: 'Приблизить плитку',
                                    onCornerTap: () =>
                                        _call.focusParticipant(p.identity),
                                    preferScreenShare: _preferScreenShareFor(p),
                                    onSwitchVideoSource:
                                        orexHasCameraAndScreen(p)
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

  Future<void> _cycleCamera(CallSession session) async {
    await orexCycleCamera(session);
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
          onTap: () {
            session.toggleMic();
          },
          onLongPress: () =>
              showOrexInputQuickSheet(context, matrix: widget.matrix),
        ),
        _round(
          tooltip: 'Камера · зажмите для выбора устройства',
          icon: session.camOn ? Icons.videocam : Icons.videocam_off,
          selected: !session.camOn,
          onTap: () {
            session.toggleCam();
          },
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
        onTap: () {
          session.toggleSpeakerMute();
        },
        onLongPress: () =>
            showOrexOutputQuickSheet(context, matrix: widget.matrix),
      ),
      if (session.canPublishMedia)
        _round(
          tooltip: 'Трансляция экрана',
          icon: session.screenShareOn
              ? Icons.stop_screen_share
              : Icons.screen_share,
          selected: session.screenShareOn,
          onTap: () {
            _toggleScreenShare(session);
          },
        ),
      _round(
        tooltip: session.handRaised ? 'Опустить руку' : 'Поднять руку',
        icon: session.handRaised ? Icons.back_hand : Icons.back_hand_outlined,
        selected: session.handRaised,
        onTap: () {
          session.toggleHandRaised();
        },
      ),
      _round(
        key: _reactionButtonKey,
        tooltip: 'Реакция',
        icon: Icons.emoji_emotions,
        onTap: () {
          _showReactions(session);
        },
      ),
      _round(
        tooltip: 'Завершить',
        icon: Icons.call_end,
        background: const Color(0xFFCF6679),
        onTap: () {
          _hangup();
        },
      ),
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 24, top: 8, left: 16, right: 16),
      child: OrexBalancedControlRows(
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
    final child = OrexCallControlButton(
      key: key,
      icon: icon,
      style: OrexCallControlButtonStyle.full,
      background: background,
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
    return tooltip == null ? child : Tooltip(message: tooltip, child: child);
  }
}
