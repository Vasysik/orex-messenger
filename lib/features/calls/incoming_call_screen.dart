import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/haptics/orex_haptics.dart';
import '../../core/matrix/matrix_service.dart';
import '../../core/voip/voip_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/mxc_avatar.dart';

/// Входящий звонок. На узком экране — на весь экран; на десктопе показывается
/// компактным окном (`asDialog`). Сам закрывается, если звонок завершился или
/// был принят/отклонён на другом нашем устройстве.
class IncomingCallScreen extends StatefulWidget {
  const IncomingCallScreen({
    super.key,
    required this.matrix,
    required this.incoming,
    this.asDialog = false,
  });

  final MatrixService matrix;
  final OrexIncomingCall incoming;
  final bool asDialog;

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  StreamSubscription<OrexIncomingCallDismissal>? _dismissSub;
  StreamSubscription<OrexCallInstancePromotion>? _promotionSub;
  Timer? _ringTimeout;
  bool _busy = false;
  bool _dismissed = false;
  String? _status;
  late OrexCallInstance _instance;

  Room get room => widget.incoming.room;

  bool _isCurrentCallInstance() =>
      widget.matrix.call.currentCallInstance?.routeKey == _instance.routeKey;

  void _closeOwnRoute() {
    if (!mounted || _dismissed) return;
    _dismissed = true;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    Navigator.of(context, rootNavigator: true).removeRoute(route);
  }

  @override
  void initState() {
    super.initState();
    _instance = widget.incoming.instance;
    final currentRingEventId = widget.matrix.voip?.incomingRingEventId(room.id);
    if (_instance.ringEventId == null && currentRingEventId != null) {
      _instance = OrexCallInstance(
        roomId: room.id,
        ringEventId: currentRingEventId,
      );
    }
    _promotionSub = widget.matrix.voip?.onCallInstancePromotion.listen((
      promotion,
    ) {
      if (promotion.previous.routeKey == _instance.routeKey) {
        _instance = promotion.current;
      }
    });
    _dismissSub = widget.matrix.voip?.onDismissIncoming.listen((dismissal) {
      if (dismissal.routeKey == _instance.routeKey) {
        _closeOwnRoute();
        return;
      }
      if (dismissal.roomId == _instance.roomId &&
          _instance.ringEventId == null &&
          dismissal.ringEventId != null) {
        // Promotion and dismissal use separate streams. Adopt the exact id
        // here too so delivery order cannot leave the legacy route ringing.
        _instance = OrexCallInstance(
          roomId: dismissal.roomId,
          ringEventId: dismissal.ringEventId,
        );
        _closeOwnRoute();
      }
    });
    widget.matrix.audio.startIncomingRingtone();
    _ringTimeout = Timer(const Duration(seconds: 45), () {
      if (!mounted || _busy || _dismissed) return;
      widget.matrix.audio.stopIncomingRingtone();
      widget.matrix.voip?.dismissIncomingFromSystem(_instance);
      _closeOwnRoute();
    });
  }

  @override
  void dispose() {
    _ringTimeout?.cancel();
    widget.matrix.audio.stopIncomingRingtone();
    _dismissSub?.cancel();
    _promotionSub?.cancel();
    super.dispose();
  }

  Future<void> _decline() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Отклоняем звонок…';
    });
    widget.matrix.audio.stopIncomingRingtone();
    unawaited(OrexHaptics.trigger(OrexHapticKind.destructive));
    try {
      await widget.matrix.call.rejectIncoming(room, instance: _instance);
      _closeOwnRoute();
    } catch (_) {
      if (!mounted || _dismissed) return;
      setState(() {
        _busy = false;
        _status = 'Не удалось отклонить. Попробуйте ещё раз.';
      });
    }
  }

  Future<void> _accept({required bool video}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = video ? 'Подключаем видеозвонок…' : 'Подключаем звонок…';
    });
    widget.matrix.audio.stopIncomingRingtone();
    unawaited(OrexHaptics.trigger(OrexHapticKind.confirm));
    try {
      await widget.matrix.call.acceptIncoming(
        room,
        video: video,
        instance: _instance,
        requestExpandedUi: true,
      );
    } catch (_) {
      // CallController сохраняет подробную причину в lastError.
    }
    if (!mounted || _dismissed) return;
    if (!widget.matrix.call.isActive || !_isCurrentCallInstance()) {
      if (widget.matrix.call.isActive) {
        _closeOwnRoute();
        return;
      }
      setState(() {
        _busy = false;
        _status = widget.matrix.call.lastError ?? 'Не удалось принять звонок';
      });
      return;
    }
    // The root listener opens the expanded route only after transport, media
    // keys and restored media state are ready. Remove this exact incoming route
    // even if the expanded route is already above it.
    _closeOwnRoute();
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
          mxc: widget.matrix.conversationAvatar(room),
          size: size,
        ),
        const SizedBox(height: 16),
        Text(
          name,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Text(
            _status ?? 'Входящий звонок',
            key: ValueKey(_status),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        if (_busy) ...[
          const SizedBox(height: 14),
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.2),
          ),
        ],
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
          onTap: _busy ? null : _decline,
        ),
        _ActionButton(
          icon: Icons.videocam,
          label: 'Видео',
          color: OrexColors.copper,
          onTap: _busy ? null : () => _accept(video: true),
        ),
        _ActionButton(
          icon: Icons.call,
          label: 'Ответить',
          color: OrexColors.online,
          onTap: _busy ? null : () => _accept(video: false),
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
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      opacity: enabled ? 1 : 0.45,
      child: Column(
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
      ),
    );
  }
}
