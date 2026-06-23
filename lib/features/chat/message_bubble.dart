import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../../theme/orex_theme.dart';

/// Бабл сообщения в орехово-медных тонах.
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.event,
    required this.isMine,
    this.showSender = false,
  });

  final Event event;
  final bool isMine;
  final bool showSender;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isMine
        ? (isDark ? OrexColors.darkBubbleOut : OrexColors.lightBubbleOut)
        : (isDark ? OrexColors.darkBubbleIn : OrexColors.lightBubbleIn);
    final textColor = isMine
        ? (isDark ? OrexColors.cream : OrexColors.walnutDeep)
        : (isDark ? OrexColors.darkText : OrexColors.lightText);

    final body = event.calcLocalizedBodyFallback(MatrixDefaultLocalizations());
    final ts = event.originServerTs;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        padding: const EdgeInsets.fromLTRB(14, 9, 12, 7),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.62,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(isMine ? 18 : 6),
            bottomRight: Radius.circular(isMine ? 6 : 18),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showSender && !isMine)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  event.senderFromMemoryOrFallback.calcDisplayname(),
                  style: const TextStyle(
                    color: OrexColors.copper,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            Text(body, style: TextStyle(color: textColor, height: 1.3)),
            const SizedBox(height: 2),
            Text(
              '${ts.hour.toString().padLeft(2, '0')}:'
              '${ts.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                color: textColor.withValues(alpha: 0.6),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
