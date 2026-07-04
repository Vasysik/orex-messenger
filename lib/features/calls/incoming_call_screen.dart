import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/mxc_avatar.dart';
import 'call_screen.dart';

/// Входящий звонок. На узком экране — на весь экран; на десктопе показывается
/// компактным окном (`asDialog`). Сам закрывается, если звонок завершился или
/// был принят/отклонён на другом нашем устройстве.
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.matrix,
    required this.room,
    this.asDialog = false,
  });

  final MatrixService matrix;
  final Room room;
  final bool asDialog;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<String>? _dismissSub;

  Room get room => widget.room;
  String get _callId => widget.room.id;

  @override
  void initState() {
    super.initState();
    _dismissSub = widget.matrix.voip?.onDismissIncoming.listen((callId) {
      if (callId == _callId && mounted) Navigator.of(context).maybePop();
    });
    widget.matrix.audio.startIncomingRingtone();
  }

  @override
  void dispose() {
    widget.matrix.audio.stopIncomingRingtone();
    _dismissSub?.cancel();
    super.dispose();
  }

  Future<void> _decline() async {
    // Закрыть входящий на других своих устройствах + сообщить инициатору, что
    // мы отклонили (он напишет «Отклонённый вызов»).
    widget.matrix.audio.stopIncomingRingtone();
    await widget.matrix.voip?.markCallHandled(room.id, _callId);
    await widget.matrix.voip?.notifyRejected(room.id);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _accept({required bool video}) async {
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    final navigator = Navigator.of(context, rootNavigator: true);
    widget.matrix.audio.stopIncomingRingtone();
    await widget.matrix.voip?.markCallHandled(room.id, _callId);
    await widget.matrix.call.start(room.id, video: video);
    if (!mounted) return;
    if (!widget.matrix.call.isActive) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.matrix.call.lastError ?? 'Не удалось принять звонок',
          ),
        ),
      );
      navigator.maybePop();
      return;
    }
    if (isWide) {
      widget.matrix.call.minimize(); // десктоп — звонок панелью над чатом
      if (mounted) navigator.maybePop();
    } else {
      // Мобильный — входящий был модальным overlay, а сам звонок открываем уже
      // после ответа. Так звонок не выбивает пользователя из текущего чата до
      // принятия вызова.
      widget.matrix.call.expand();
      if (widget.asDialog) {
        if (mounted) await navigator.maybePop();
        navigator.push(
          MaterialPageRoute(builder: (_) => CallScreen(matrix: widget.matrix)),
        );
      } else if (mounted) {
        navigator.pushReplacement(
          MaterialPageRoute(builder: (_) => CallScreen(matrix: widget.matrix)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    if (widget.asDialog) {
      return Dialog(
        backgroundColor: OrexColors.darkSurface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _avatarName(name, 72),
                const SizedBox(height: 24),
                _buttonsRow(),
              ],
            ),
          ),
        ),
      );
    }
    // Полный экран: аватар сверху-по центру, кнопки приёма — внизу.
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),
              _avatarName(name, 120),
              const Spacer(flex: 3),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                child: _buttonsRow(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatarName(String name, double size) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        MxcAvatar(
          matrix: widget.matrix,
          name: name,
          mxc: room.avatar,
          size: size,
        ),
        const SizedBox(height: 16),
        Text(
          name,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text('Входящий звонок…', style: Theme.of(context).textTheme.bodyMedium),
      ],
    );
  }

  Widget _buttonsRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ActionButton(
          icon: Icons.call_end,
          label: 'Отклонить',
          color: const Color(0xFFCF6679),
          onTap: _decline,
        ),
        _ActionButton(
          icon: Icons.videocam,
          label: 'Видео',
          color: OrexColors.copper,
          onTap: () => _accept(video: true),
        ),
        _ActionButton(
          icon: Icons.call,
          label: 'Ответить',
          color: OrexColors.online,
          onTap: () => _accept(video: false),
        ),
      ],
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
            width: 60,
            height: 60,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: Icon(icon, color: OrexColors.cream, size: 26),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
