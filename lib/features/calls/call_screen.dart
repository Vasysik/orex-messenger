import 'dart:async';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_controller.dart';
import '../../core/voip/call_session.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/squirrel_mascot.dart';
import 'call_controls.dart';
import 'call_participant_tile.dart';
import 'call_presentation.dart';
import 'call_ui_actions.dart';
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
  final OrexCallVideoPreferences _videoPreferences = OrexCallVideoPreferences();

  OrexCallUiActions get _actions => OrexCallUiActions(
    context: context,
    matrix: widget.matrix,
    call: _call,
    reactionButtonKey: _reactionButtonKey,
    isMounted: () => mounted,
  );

  bool _preferScreenShareFor(lk.Participant participant) =>
      _videoPreferences.prefersParticipantScreenShare(participant);

  void _toggleParticipantVideoSource(lk.Participant participant) {
    setState(() {
      _videoPreferences.toggleParticipant(participant);
    });
  }

  @override
  void dispose() {
    unawaited(widget.matrix.push.notifyCallUiHidden());
    // Выход с экрана (кнопка ▼ или системный «назад») = свернуть, не завершая.
    // notifyListeners нельзя дёргать прямо в dispose (дерево залочено —
    // ListenableBuilder падает), поэтому откладываем на следующий кадр.
    if (_call.isActive || _call.isStarting) {
      final call = _call;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (call.isActive || call.isStarting) call.minimize();
      });
    }
    super.dispose();
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
                if (_call.isStarting) {
                  return Column(
                    children: [
                      _topBar(null),
                      Expanded(
                        child: Center(
                          child: SquirrelMascot(
                            size: 120,
                            caption: _call.setupCaption,
                          ),
                        ),
                      ),
                    ],
                  );
                }
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

  Widget _topBar(CallSession? session) => Padding(
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
            session == null
                ? 'Звонок'
                : OrexCallPresentation.titleFor(
                    listenOnly: session.listenOnly,
                  ),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        if (session?.listenOnly == true)
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
        return Center(
          child: SquirrelMascot(size: 120, caption: _call.setupCaption),
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
        final presentation = OrexCallPresentation.from(
          matrix: widget.matrix,
          call: _call,
          session: session,
        );
        return Column(
          children: [
            for (final notice in presentation.notices) _notice(notice),
            Expanded(
              child: presentation.participants.isEmpty
                  ? const Center(
                      child: SquirrelMascot(
                        size: 120,
                        caption: 'Ожидаем участников…',
                      ),
                    )
                  : _grid(presentation),
            ),
          ],
        );
    }
  }

  /// Адаптивная сетка участников, заполняющая доступную область без прокрутки.
  Widget _grid(OrexCallPresentation presentation) {
    final session = presentation.session;
    final room = presentation.room;
    final people = presentation.participants;
    final pinned = presentation.focusedParticipant;
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
              ? () => _actions.cycleCamera(session)
              : null,
          onGrantVoice: _actions.canGrantVoice(room, userId)
              ? () => _actions.grantVoice(room!, userId)
              : null,
          onRevokeVoice: _actions.canRevokeVoice(room, userId)
              ? () => _actions.revokeVoice(room!, userId)
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
                                        ? () => _actions.cycleCamera(session)
                                        : null,
                                    onGrantVoice:
                                        _actions.canGrantVoice(room, userId)
                                        ? () =>
                                              _actions.grantVoice(room!, userId)
                                        : null,
                                    onRevokeVoice:
                                        _actions.canRevokeVoice(room, userId)
                                        ? () => _actions.revokeVoice(
                                            room!,
                                            userId,
                                          )
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

  Widget _notice(OrexCallNotice notice) {
    return switch (notice.kind) {
      OrexCallNoticeKind.camera => _callNote(
        'Камера недоступна (возможно, занята другим окном) — звонок идёт со звуком.',
      ),
      OrexCallNoticeKind.error => _callNote(notice.message ?? ''),
      OrexCallNoticeKind.listenOnly => _callNote(
        'Режим просмотра: микрофон, камера и трансляция экрана недоступны. Поднимите руку, чтобы попросить голос.',
        copper: true,
      ),
    };
  }

  Widget _callNote(String text, {bool copper = false}) => Container(
    width: double.infinity,
    margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: copper
          ? OrexColors.copper.withValues(alpha: 0.16)
          : const Color(0xFFE0A03A).withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(text, style: const TextStyle(fontSize: 12)),
  );

  Widget _controls(CallSession session) => OrexCallControlsBar(
    mode: OrexCallControlsBarMode.full,
    matrix: widget.matrix,
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
}
