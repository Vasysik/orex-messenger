import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/call_controller.dart';
import '../../core/matrix_service.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import 'call_session.dart';

/// Свёрнутый звонок панелью над чатом (как в Discord): плитки участников +
/// управление. Тап по плиткам — развернуть на весь экран.
class MinimizedCallPanel extends StatelessWidget {
  const MinimizedCallPanel({
    super.key,
    required this.call,
    required this.onExpand,
  });

  final CallController call;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
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
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 120,
                child: people.isEmpty
                    ? const Center(
                        child: Text('Соединение…',
                            style: TextStyle(color: Colors.white70)),
                      )
                    : GestureDetector(
                        onTap: onExpand,
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
            ],
          ),
        );
      },
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
            _btn(icon: Icons.open_in_full, onTap: onExpand),
            const SizedBox(width: 12),
            _btn(
              icon: Icons.call_end,
              bg: const Color(0xFFCF6679),
              onTap: call.hangUp,
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
