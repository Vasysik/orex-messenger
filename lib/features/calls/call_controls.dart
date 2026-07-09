import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_session.dart';
import '../../core/voip/screen_share_controller.dart';
import '../../shared/theme/orex_theme.dart';
import 'call_device_quick_sheet.dart';

class OrexBalancedControlRows extends StatelessWidget {
  const OrexBalancedControlRows({
    super.key,
    required this.children,
    required this.buttonCount,
    required this.buttonExtent,
    required this.spacing,
    required this.runSpacing,
  });

  final List<Widget> children;
  final int buttonCount;
  final double buttonExtent;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final oneRowWidth =
            buttonCount * buttonExtent +
            (buttonCount - 1).clamp(0, buttonCount) * spacing;
        if (oneRowWidth <= constraints.maxWidth) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: _withSpacing(children, spacing),
          );
        }

        final topCount = (children.length + 1) ~/ 2;
        final top = children.take(topCount).toList();
        final bottom = children.skip(topCount).toList();
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: _withSpacing(top, spacing),
            ),
            SizedBox(height: runSpacing),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: _withSpacing(bottom, spacing),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _withSpacing(List<Widget> items, double spacing) {
    final result = <Widget>[];
    for (var i = 0; i < items.length; i++) {
      if (i > 0) result.add(SizedBox(width: spacing));
      result.add(items[i]);
    }
    return result;
  }
}

class OrexCallControlButtonStyle {
  const OrexCallControlButtonStyle({
    required this.size,
    required this.radius,
    required this.iconSize,
    required this.iconColor,
    required this.useCopperGradient,
    required this.defaultBackground,
    required this.selectedBorderWidth,
    required this.unselectedBorderWidth,
    required this.selectedBorderAlpha,
    required this.unselectedBorderAlpha,
    required this.shadow,
  });

  static const full = OrexCallControlButtonStyle(
    size: 54,
    radius: 32,
    iconSize: 24,
    iconColor: OrexColors.cream,
    useCopperGradient: true,
    defaultBackground: Colors.transparent,
    selectedBorderWidth: 2,
    unselectedBorderWidth: 0,
    selectedBorderAlpha: 0.8,
    unselectedBorderAlpha: 0,
    shadow: true,
  );

  static const minimized = OrexCallControlButtonStyle(
    size: 42,
    radius: 26,
    iconSize: 20,
    iconColor: Colors.white,
    useCopperGradient: false,
    defaultBackground: Colors.white24,
    selectedBorderWidth: 2,
    unselectedBorderWidth: 1,
    selectedBorderAlpha: 0.82,
    unselectedBorderAlpha: 0.06,
    shadow: false,
  );

  final double size;
  final double radius;
  final double iconSize;
  final Color iconColor;
  final bool useCopperGradient;
  final Color defaultBackground;
  final double selectedBorderWidth;
  final double unselectedBorderWidth;
  final double selectedBorderAlpha;
  final double unselectedBorderAlpha;
  final bool shadow;
}

class OrexCallControlButton extends StatefulWidget {
  const OrexCallControlButton({
    super.key,
    required this.icon,
    required this.style,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.background,
  });

  final IconData icon;
  final OrexCallControlButtonStyle style;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color? background;

  @override
  State<OrexCallControlButton> createState() => _OrexCallControlButtonState();
}

class _OrexCallControlButtonState extends State<OrexCallControlButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkResponse(
        containedInkWell: true,
        highlightShape: BoxShape.circle,
        radius: style.radius,
        customBorder: const CircleBorder(),
        mouseCursor: SystemMouseCursors.basic,
        hoverColor: Colors.white.withValues(alpha: 0.12),
        splashColor: Colors.white.withValues(alpha: 0.18),
        highlightColor: Colors.white.withValues(alpha: 0.08),
        onHighlightChanged: (value) => setState(() => _pressed = value),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          duration: const Duration(milliseconds: 90),
          scale: _pressed ? 0.94 : 1,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: style.size,
            height: style.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  widget.background ??
                  (style.useCopperGradient ? null : style.defaultBackground),
              gradient: widget.background == null && style.useCopperGradient
                  ? OrexColors.copperGradient
                  : null,
              border: _border(style),
              boxShadow: style.shadow
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              widget.icon,
              color: style.iconColor,
              size: style.iconSize,
            ),
          ),
        ),
      ),
    );
  }

  Border? _border(OrexCallControlButtonStyle style) {
    final width = widget.selected
        ? style.selectedBorderWidth
        : style.unselectedBorderWidth;
    if (width <= 0) return null;
    return Border.all(
      color: Colors.white.withValues(
        alpha: widget.selected
            ? style.selectedBorderAlpha
            : style.unselectedBorderAlpha,
      ),
      width: width,
    );
  }
}

enum OrexCallControlsBarMode { full, minimized }

class OrexCallControlsBar extends StatelessWidget {
  const OrexCallControlsBar({
    super.key,
    required this.mode,
    required this.matrix,
    required this.session,
    required this.reactionButtonKey,
    required this.onReactionTap,
    required this.onScreenShareTap,
    required this.onHangUpTap,
  });

  final OrexCallControlsBarMode mode;
  final MatrixService matrix;
  final CallSession session;
  final GlobalKey reactionButtonKey;
  final VoidCallback onReactionTap;
  final VoidCallback onScreenShareTap;
  final VoidCallback onHangUpTap;

  bool get _isFull => mode == OrexCallControlsBarMode.full;

  OrexCallControlButtonStyle get _style => _isFull
      ? OrexCallControlButtonStyle.full
      : OrexCallControlButtonStyle.minimized;

  EdgeInsets get _padding => _isFull
      ? const EdgeInsets.only(bottom: 24, top: 8, left: 16, right: 16)
      : const EdgeInsets.only(bottom: 8, top: 2, left: 8, right: 8);

  double get _spacing => _isFull ? 12 : 10;

  double get _runSpacing => _isFull ? 10 : 8;

  @override
  Widget build(BuildContext context) {
    final controls = <Widget>[
      if (session.canPublishMedia) ...[
        _button(
          context,
          tooltip: 'Микрофон · зажмите для выбора устройства',
          icon: session.micOn ? Icons.mic : Icons.mic_off,
          selected: !session.micOn,
          onTap: () {
            session.toggleMic();
          },
          onLongPress: () => showOrexInputQuickSheet(context, matrix: matrix),
        ),
        _button(
          context,
          tooltip: 'Камера · зажмите для выбора устройства',
          icon: session.camOn ? Icons.videocam : Icons.videocam_off,
          selected: !session.camOn,
          onTap: () {
            session.toggleCam();
          },
          onLongPress: () => showOrexCameraQuickSheet(
            context,
            matrix: matrix,
            session: session,
          ),
        ),
      ],
      _button(
        context,
        tooltip: 'Звук · зажмите для выбора вывода',
        icon: session.speakerMuted ? Icons.volume_off : Icons.volume_up,
        selected: session.speakerMuted,
        onTap: () {
          session.toggleSpeakerMute();
        },
        onLongPress: () => showOrexOutputQuickSheet(context, matrix: matrix),
      ),
      if (session.canPublishMedia && OrexScreenShareController.isSupported)
        _button(
          context,
          tooltip: 'Трансляция экрана',
          icon: session.screenShareOn
              ? Icons.stop_screen_share
              : Icons.screen_share,
          selected: session.screenShareOn,
          onTap: onScreenShareTap,
        ),
      _button(
        context,
        tooltip: session.handRaised ? 'Опустить руку' : 'Поднять руку',
        icon: session.handRaised ? Icons.back_hand : Icons.back_hand_outlined,
        selected: session.handRaised,
        onTap: () {
          session.toggleHandRaised();
        },
      ),
      _button(
        context,
        key: reactionButtonKey,
        tooltip: 'Реакция',
        icon: Icons.emoji_emotions,
        onTap: onReactionTap,
      ),
      _button(
        context,
        tooltip: 'Завершить',
        icon: Icons.call_end,
        background: const Color(0xFFCF6679),
        onTap: onHangUpTap,
      ),
    ];

    return Padding(
      padding: _padding,
      child: OrexBalancedControlRows(
        buttonCount: controls.length,
        buttonExtent: _style.size,
        spacing: _spacing,
        runSpacing: _runSpacing,
        children: controls,
      ),
    );
  }

  Widget _button(
    BuildContext context, {
    Key? key,
    required IconData icon,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    String? tooltip,
    Color? background,
    bool selected = false,
  }) {
    final child = OrexCallControlButton(
      key: key,
      icon: icon,
      style: _style,
      background: background,
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
    );
    return _isFull && tooltip != null
        ? Tooltip(message: tooltip, child: child)
        : child;
  }
}

Future<String?> showOrexCallReactionMenu(
  BuildContext context,
  GlobalKey anchorKey, {
  double emojiSize = 26,
}) {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final button = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (overlay == null || button == null) return Future.value(null);

  final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
  final bottomRight = button.localToGlobal(
    button.size.bottomRight(Offset.zero),
    ancestor: overlay,
  );
  final rect = Rect.fromPoints(topLeft, bottomRight);

  return showMenu<String>(
    context: context,
    color: OrexColors.darkSurface.withValues(alpha: 0.98),
    elevation: 18,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    position: RelativeRect.fromLTRB(
      rect.left,
      rect.top - 8,
      overlay.size.width - rect.right,
      overlay.size.height - rect.top,
    ),
    items: [
      PopupMenuItem<String>(
        enabled: true,
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Wrap(
            spacing: 6,
            children: [
              for (final emoji in const ['👍', '🔥', '😂', '❤️', '👏', '😮'])
                _ReactionChoice(emoji: emoji, size: emojiSize),
            ],
          ),
        ),
      ),
    ],
  );
}

class _ReactionChoice extends StatelessWidget {
  const _ReactionChoice({required this.emoji, required this.size});

  final String emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          hoverColor: OrexColors.copper.withValues(alpha: 0.14),
          onTap: () => Navigator.pop(context, emoji),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Text(emoji, style: TextStyle(fontSize: size)),
          ),
        ),
      ),
    );
  }
}
