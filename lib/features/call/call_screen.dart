import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
// Прячем matrix-овский CallSession — у нас свой одноимённый класс (медиа).
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/call_controller.dart';
import '../../core/matrix/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import '../../widgets/squirrel_mascot.dart';
import 'call_session.dart';

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

  void _hangup() {
    _call.hangUp();
    if (mounted) Navigator.of(context).pop();
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
                  _topBar(),
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

  Widget _topBar() => Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Свернуть',
              icon: const Icon(Icons.expand_more),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: 4),
            Text('Звонок', style: Theme.of(context).textTheme.titleMedium),
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
        if (people.length <= 1) {
          return Column(
            children: [
              if (session.cameraError != null) _cameraNote(),
              const Expanded(
                child: Center(
                  child:
                      SquirrelMascot(size: 120, caption: 'Ожидаем собеседника…'),
                ),
              ),
            ],
          );
        }
        final room = widget.matrix.client.getRoomById(_call.roomId ?? '');
        return Column(
          children: [
            if (session.cameraError != null) _cameraNote(),
            Expanded(child: _grid(people, room)),
          ],
        );
    }
  }

  /// Адаптивная сетка участников, заполняющая доступную область без прокрутки.
  Widget _grid(List<lk.Participant> people, Room? room) {
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
                          ? Padding(
                              padding: const EdgeInsets.all(4),
                              child: _ParticipantTile(
                                participant: people[r * cols + c],
                                matrix: widget.matrix,
                                room: room,
                              ),
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

  Widget _controls(CallSession session) => Padding(
        padding: const EdgeInsets.only(bottom: 24, top: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _round(
              icon: session.micOn ? Icons.mic : Icons.mic_off,
              onTap: session.toggleMic,
            ),
            const SizedBox(width: 16),
            _round(
              icon: session.camOn ? Icons.videocam : Icons.videocam_off,
              onTap: session.toggleCam,
            ),
            const SizedBox(width: 16),
            _round(
              icon: Icons.call_end,
              background: const Color(0xFFCF6679),
              onTap: _hangup,
            ),
          ],
        ),
      );

  Widget _round({
    required IconData icon,
    required VoidCallback onTap,
    Color? background,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 58,
          height: 58,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: background,
            gradient: background == null ? OrexColors.copperGradient : null,
          ),
          child: Icon(icon, color: OrexColors.cream),
        ),
      );
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({
    required this.participant,
    required this.matrix,
    required this.room,
  });

  final lk.Participant participant;
  final MatrixService matrix;
  final Room? room;

  /// LiveKit identity у Element Call / lk-jwt-service — это `@user:server:device`.
  /// Достаём из него matrix-id, чтобы взять имя и аватар из комнаты.
  String get _userId {
    final m = RegExp(r'@[^:]+:[^:]+').firstMatch(participant.identity);
    return m?.group(0) ?? participant.identity;
  }

  @override
  Widget build(BuildContext context) {
    lk.VideoTrack? track;
    for (final pub in participant.videoTrackPublications) {
      // !pub.muted — иначе при выключенной камере остаётся последний кадр.
      if (pub.track != null && pub.subscribed && !pub.muted) {
        track = pub.track as lk.VideoTrack;
        break;
      }
    }

    final userId = _userId;
    final user = room?.unsafeGetUserFromMemoryOrFallback(userId);
    var name = user?.calcDisplayname() ?? userId;
    if (participant is lk.LocalParticipant) name = '$name · вы';

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.contain),
            )
          else
            Container(
              decoration:
                  const BoxDecoration(gradient: OrexColors.copperGradient),
              alignment: Alignment.center,
              child: MxcAvatar(
                matrix: matrix,
                name: user?.calcDisplayname() ?? userId,
                mxc: user?.avatarUrl,
                size: 96,
              ),
            ),
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(name,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}
