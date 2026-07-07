import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/mxc_avatar.dart';
import 'call_screen.dart';

/// Incoming-call UI. Phones use the same warm Orex visual language as the
/// messenger itself; desktop keeps a compact themed modal.
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
    widget.matrix.audio.stopIncomingRingtone();
    await widget.matrix.call.rejectIncoming(room);
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _accept() async {
    final isWide = MediaQuery.sizeOf(context).width >= 900;
    final navigator = Navigator.of(context, rootNavigator: true);
    widget.matrix.audio.stopIncomingRingtone();
    await widget.matrix.call.acceptIncoming(room, video: false);
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
      widget.matrix.call.minimize();
      if (mounted) navigator.maybePop();
      return;
    }

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

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    if (widget.asDialog) return _desktopDialog(name);

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: OrexColors.darkBg,
        body: Stack(
          fit: StackFit.expand,
          children: [
            const _OrexCallBackground(),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
                child: Column(
                  children: [
                    const _OrexBrandPill(),
                    const SizedBox(height: 34),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: OrexColors.darkText,
                          fontSize: 30,
                          height: 1.08,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Входящий звонок',
                      style: TextStyle(
                        color: OrexColors.darkTextSoft,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(flex: 2),
                    _OrexAvatarFrame(
                      child: MxcAvatar(
                        matrix: widget.matrix,
                        name: name,
                        mxc: room.avatar,
                        size: 144,
                      ),
                    ),
                    const SizedBox(height: 24),
                    const _CallTypePill(),
                    const Spacer(flex: 3),
                    _ActionPanel(child: _twoActions()),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _desktopDialog(String name) {
    return Dialog(
      backgroundColor: OrexColors.darkSurface,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              MxcAvatar(
                matrix: widget.matrix,
                name: name,
                mxc: room.avatar,
                size: 78,
              ),
              const SizedBox(height: 18),
              Text(
                name,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 5),
              const Text('Входящий звонок'),
              const SizedBox(height: 28),
              _twoActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _twoActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _ActionButton(
          icon: Icons.call_end_rounded,
          label: 'Отклонить',
          color: const Color(0xFFC65D58),
          haloColor: const Color(0x55C65D58),
          onTap: _decline,
        ),
        _ActionButton(
          icon: Icons.call_rounded,
          label: 'Ответить',
          color: OrexColors.online,
          haloColor: OrexColors.online.withValues(alpha: .34),
          pulse: true,
          onTap: _accept,
        ),
      ],
    );
  }
}

class _OrexBrandPill extends StatelessWidget {
  const _OrexBrandPill();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OrexColors.darkSurface.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: OrexColors.copper.withValues(alpha: .34),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: OrexColors.copperGradient,
              ),
              child: SizedBox(width: 10, height: 10),
            ),
            SizedBox(width: 8),
            Text(
              'OREX',
              style: TextStyle(
                color: OrexColors.ochreLight,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 2.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrexAvatarFrame extends StatelessWidget {
  const _OrexAvatarFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 174,
      height: 174,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: OrexColors.copperGradient,
        boxShadow: [
          BoxShadow(
            color: OrexColors.copper.withValues(alpha: .28),
            blurRadius: 42,
            spreadRadius: 4,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: .34),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Container(
        width: 162,
        height: 162,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: OrexColors.darkBgRaised,
          border: Border.all(
            color: OrexColors.ochreLight.withValues(alpha: .46),
          ),
        ),
        child: ClipOval(child: child),
      ),
    );
  }
}

class _CallTypePill extends StatelessWidget {
  const _CallTypePill();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OrexColors.walnutDeep.withValues(alpha: .44),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: OrexColors.copper.withValues(alpha: .24),
        ),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        child: Text(
          'OREX • ГОЛОСОВОЙ ЗВОНОК',
          style: TextStyle(
            color: OrexColors.ochreLight,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: .8,
          ),
        ),
      ),
    );
  }
}

class _ActionPanel extends StatelessWidget {
  const _ActionPanel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 15, 12, 12),
      decoration: BoxDecoration(
        color: OrexColors.darkSurface.withValues(alpha: .82),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: OrexColors.copper.withValues(alpha: .22),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: .26),
            blurRadius: 26,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.haloColor,
    required this.onTap,
    this.pulse = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color haloColor;
  final VoidCallback onTap;
  final bool pulse;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1450),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 96,
          height: 96,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (widget.pulse)
                AnimatedBuilder(
                  animation: _controller,
                  builder: (_, __) {
                    final t = _controller.value;
                    return Transform.scale(
                      scale: 1 + t * .52,
                      child: Opacity(
                        opacity: (1 - t) * .44,
                        child: Container(
                          width: 70,
                          height: 70,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.haloColor,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              Material(
                color: widget.color,
                shape: const CircleBorder(),
                elevation: 8,
                shadowColor: widget.color.withValues(alpha: .34),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: widget.onTap,
                  child: SizedBox(
                    width: 70,
                    height: 70,
                    child: Icon(widget.icon, color: OrexColors.cream, size: 31),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          widget.label,
          style: const TextStyle(
            color: OrexColors.darkText,
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _OrexCallBackground extends StatelessWidget {
  const _OrexCallBackground();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF3A2415),
            OrexColors.darkBgRaised,
            OrexColors.darkBg,
          ],
          stops: [0, .48, 1],
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -130,
            top: 50,
            child: _glow(const Color(0x55C8763C), 360),
          ),
          Positioned(
            left: -150,
            bottom: 90,
            child: _glow(const Color(0x44D9A05B), 350),
          ),
          Positioned(
            left: 40,
            right: 40,
            top: 250,
            child: IgnorePointer(
              child: Container(
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      OrexColors.walnut.withValues(alpha: .12),
                      OrexColors.walnut.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _glow(Color color, double size) => IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color, color.withValues(alpha: 0)],
            ),
          ),
        ),
      );
}
