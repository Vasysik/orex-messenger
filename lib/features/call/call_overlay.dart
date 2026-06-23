import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import '../../core/call_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/squirrel_mascot.dart';

/// Полноэкранный стеклянный оверлей звонка поверх чата.
class CallOverlay extends StatelessWidget {
  const CallOverlay({super.key, required this.calls});
  final CallService calls;

  @override
  Widget build(BuildContext context) {
    final room = calls.room;
    final participants = <lk.Participant>[
      if (room?.localParticipant != null) room!.localParticipant!,
      ...?room?.remoteParticipants.values,
    ];

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.45),
        child: Center(
          child: GlassPanel(
            borderRadius: 28,
            opacity: 0.5,
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Expanded(
                    child: participants.length <= 1
                        ? const Center(
                            child: SquirrelMascot(
                              size: 120,
                              caption: 'Ожидаем собеседника…',
                            ),
                          )
                        : GridView.count(
                            crossAxisCount: participants.length <= 2 ? 1 : 2,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            children: participants
                                .map((p) => _ParticipantTile(participant: p))
                                .toList(),
                          ),
                  ),
                  const SizedBox(height: 18),
                  _Controls(calls: calls),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant});
  final lk.Participant participant;

  @override
  Widget build(BuildContext context) {
    lk.VideoTrack? videoTrack;
    for (final pub in participant.videoTrackPublications) {
      if (pub.track != null && pub.subscribed) {
        videoTrack = pub.track as lk.VideoTrack;
        break;
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (videoTrack != null)
            lk.VideoTrackRenderer(videoTrack)
          else
            Container(
              decoration: const BoxDecoration(gradient: OrexColors.copperGradient),
              alignment: Alignment.center,
              child: Text(
                participant.identity.characters.firstOrNull?.toUpperCase() ?? '?',
                style: const TextStyle(
                  color: OrexColors.cream,
                  fontSize: 38,
                  fontWeight: FontWeight.w700,
                ),
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
              child: Text(
                participant.name.isNotEmpty
                    ? participant.name
                    : participant.identity,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({required this.calls});
  final CallService calls;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundButton(
          icon: Icons.mic,
          onTap: calls.toggleMic,
        ),
        const SizedBox(width: 16),
        _RoundButton(
          icon: Icons.videocam,
          onTap: calls.toggleCamera,
        ),
        const SizedBox(width: 16),
        _RoundButton(
          icon: Icons.call_end,
          background: const Color(0xFFCF6679),
          onTap: calls.hangUp,
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.onTap,
    this.background,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
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
}
