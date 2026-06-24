import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import 'call_screen.dart';

/// Экран входящего звонка. Появляется, когда кто-то опубликовал членство в
/// звонке (`com.famedly.call.member`) в комнате, где нас ещё нет в звонке.
class IncomingCallScreen extends StatelessWidget {
  const IncomingCallScreen({
    super.key,
    required this.matrix,
    required this.groupCall,
  });

  final MatrixService matrix;
  final GroupCallSession groupCall;

  Room get room => groupCall.room;

  void _decline(BuildContext context) {
    // Просто закрываем экран — мы не публиковали своё членство, поэтому ничего
    // удалять не нужно. Звонок продолжит звонить у инициатора.
    Navigator.of(context).maybePop();
  }

  void _accept(BuildContext context, {required bool video}) {
    matrix.call.start(room.id, video: video);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => CallScreen(matrix: matrix)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(),
              MxcAvatar(
                matrix: matrix,
                name: name,
                mxc: room.avatar,
                size: 112,
              ),
              const SizedBox(height: 20),
              Text(name,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Text('Входящий звонок…',
                  style: Theme.of(context).textTheme.bodyMedium),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 48, left: 24, right: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _ActionButton(
                      icon: Icons.call_end,
                      label: 'Отклонить',
                      color: const Color(0xFFCF6679),
                      onTap: () => _decline(context),
                    ),
                    _ActionButton(
                      icon: Icons.videocam,
                      label: 'Видео',
                      color: OrexColors.copper,
                      onTap: () => _accept(context, video: true),
                    ),
                    _ActionButton(
                      icon: Icons.call,
                      label: 'Ответить',
                      color: OrexColors.online,
                      onTap: () => _accept(context, video: false),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 66,
            height: 66,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: OrexColors.cream, size: 28),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
