import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/squirrel_mascot.dart';
import 'call_session.dart';

/// Наш собственный экран звонка поверх LiveKit (стек Element Call / MatrixRTC).
class CallScreen extends StatefulWidget {
  const CallScreen({
    super.key,
    required this.matrix,
    required this.roomId,
    required this.video,
  });

  final MatrixService matrix;
  final String roomId;
  final bool video;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  late final CallSession _session = CallSession(
    client: widget.matrix.client,
    matrixRoomId: widget.roomId,
  );

  @override
  void initState() {
    super.initState();
    _session.connect(video: widget.video);
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  void _leave() {
    _session.hangUp();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: AnimatedBuilder(
            animation: _session,
            builder: (context, _) {
              return Column(
                children: [
                  _topBar(),
                  Expanded(child: _body()),
                  if (_session.status == CallStatus.connected) _controls(),
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
              icon: const Icon(Icons.expand_more),
              onPressed: _leave,
            ),
            const SizedBox(width: 4),
            Text('Звонок', style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      );

  Widget _body() {
    switch (_session.status) {
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
                Text(_session.error ?? '',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => _session.connect(video: widget.video),
                  child: const Text('Повторить'),
                ),
              ],
            ),
          ),
        );
      case CallStatus.ended:
        return const Center(child: Text('Звонок завершён'));
      case CallStatus.connected:
        final people = _session.participants;
        if (people.length <= 1) {
          return const Center(
            child: SquirrelMascot(size: 120, caption: 'Ожидаем собеседника…'),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: GridView.count(
            crossAxisCount: people.length <= 2 ? 1 : 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            children:
                people.map((p) => _ParticipantTile(participant: p)).toList(),
          ),
        );
    }
  }

  Widget _controls() => Padding(
        padding: const EdgeInsets.only(bottom: 24, top: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _round(
              icon: _session.micOn ? Icons.mic : Icons.mic_off,
              onTap: _session.toggleMic,
            ),
            const SizedBox(width: 16),
            _round(
              icon: _session.camOn ? Icons.videocam : Icons.videocam_off,
              onTap: _session.toggleCam,
            ),
            const SizedBox(width: 16),
            _round(
              icon: Icons.call_end,
              background: const Color(0xFFCF6679),
              onTap: _leave,
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
  const _ParticipantTile({required this.participant});
  final lk.Participant participant;

  @override
  Widget build(BuildContext context) {
    lk.VideoTrack? track;
    for (final pub in participant.videoTrackPublications) {
      if (pub.track != null && pub.subscribed) {
        track = pub.track as lk.VideoTrack;
        break;
      }
    }
    final name =
        participant.name.isNotEmpty ? participant.name : participant.identity;

    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (track != null)
            lk.VideoTrackRenderer(track)
          else
            Container(
              decoration:
                  const BoxDecoration(gradient: OrexColors.copperGradient),
              alignment: Alignment.center,
              child: Text(
                name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                style: const TextStyle(
                  color: OrexColors.cream,
                  fontSize: 40,
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
              child: Text(name,
                  style: const TextStyle(color: Colors.white, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}
