import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
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
    widget.matrix.addListener(_onMatrix);
  }

  void _onMatrix() {
    // Звонок завершился (инициатор повесил трубку) — закрываем входящий.
    if (mounted && !widget.matrix.roomHasActiveCall(room)) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _dismissSub?.cancel();
    widget.matrix.removeListener(_onMatrix);
    super.dispose();
  }

  Future<void> _decline() async {
    // Сообщаем своим другим устройствам, что звонок обработан (закрыть входящий).
    await widget.matrix.voip?.markCallHandled(room.id, _callId);
    if (mounted) Navigator.of(context).maybePop();
  }

  void _accept({required bool video}) {
    widget.matrix.voip?.markCallHandled(room.id, _callId);
    widget.matrix.call.start(room.id, video: video);
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    if (widget.asDialog || isWide) {
      widget.matrix.call.minimize(); // десктоп — звонок панелью над чатом
      Navigator.of(context).maybePop();
    } else {
      // Мобильный — разворачиваем на весь экран (а не свёрнуто).
      widget.matrix.call.expand();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => CallScreen(matrix: widget.matrix)),
      );
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
            matrix: widget.matrix, name: name, mxc: room.avatar, size: size),
        const SizedBox(height: 16),
        Text(name,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w700)),
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
