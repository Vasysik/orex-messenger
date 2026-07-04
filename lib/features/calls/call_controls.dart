import 'package:flutter/material.dart';

import '../../shared/theme/orex_theme.dart';

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
