import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/call_controller.dart';
import '../../core/matrix_service.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import 'call_session.dart';

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
  double? _tilesHeight; // null → дефолт = 1/3 высоты экрана

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final screenH = MediaQuery.sizeOf(context).height;
    final minH = 100.0;
    final maxH = screenH * 0.7;
    final tilesH = (_tilesHeight ?? screenH / 3).clamp(minH, maxH);

    return AnimatedBuilder(
      animation: call,
      builder: (context, _) {
        final session = call.session;
        if (session == null) return const SizedBox.shrink();
        final room = call.roomId != null
            ? call.matrix.client.getRoomById(call.roomId!)
            : null;
        final people = session.participants;

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                          child: Row(
                            children: [
                              for (final p in people)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.all(3),
                                    child: _MiniTile(
                                      participant: p,
                                      matrix: call.matrix,
                                      room: room,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
              ),
              _controls(session),
              _resizeHandle(tilesH, minH, maxH),
            ],
          ),
        );
      },
    );
  }

  /// Нижняя кромка-«ручка»: тянуть вверх/вниз, чтобы менять высоту плиток.
  Widget _resizeHandle(double current, double minH, double maxH) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) {
          setState(() {
            _tilesHeight = (current + d.delta.dy).clamp(minH, maxH);
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
        padding: const EdgeInsets.only(bottom: 8, top: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _btn(
              icon: session.micOn ? Icons.mic : Icons.mic_off,
              onTap: session.toggleMic,
            ),
            const SizedBox(width: 12),
            _btn(
              icon: session.camOn ? Icons.videocam : Icons.videocam_off,
              onTap: session.toggleCam,
            ),
            const SizedBox(width: 12),
            _btn(icon: Icons.open_in_full, onTap: widget.onExpand),
            const SizedBox(width: 12),
            _btn(
              icon: Icons.call_end,
              bg: const Color(0xFFCF6679),
              onTap: widget.call.hangUp,
            ),
          ],
        ),
      );

  Widget _btn({
    required IconData icon,
    required VoidCallback onTap,
    Color? bg,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: bg ?? Colors.white24,
          ),
          child: Icon(icon, color: Colors.white, size: 20),
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
  });

  final lk.Participant participant;
  final MatrixService matrix;
  final Room? room;

  String get _userId {
    final m = RegExp(r'@[^:]+:[^:]+').firstMatch(participant.identity);
    return m?.group(0) ?? participant.identity;
  }

  @override
  Widget build(BuildContext context) {
    lk.VideoTrack? track;
    for (final pub in participant.videoTrackPublications) {
      if (pub.track != null && pub.subscribed && !pub.muted) {
        track = pub.track as lk.VideoTrack;
        break;
      }
    }
    final user = room?.unsafeGetUserFromMemoryOrFallback(_userId);

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            Container(
              color: Colors.black,
              child: lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.contain),
            )
          else
            Container(
              decoration:
                  const BoxDecoration(gradient: OrexColors.copperGradient),
              alignment: Alignment.center,
              child: MxcAvatar(
                matrix: matrix,
                name: user?.calcDisplayname() ?? _userId,
                mxc: user?.avatarUrl,
                size: 44,
              ),
            ),
        ],
      ),
    );
  }
}
