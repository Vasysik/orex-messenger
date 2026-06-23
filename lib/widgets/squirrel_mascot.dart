import 'package:flutter/material.dart';
import '../theme/orex_theme.dart';

/// Маскот-Белочка. Ожидает ассет `assets/mascot/squirrel.png`
/// (положите PNG/SVG туда и пропишите в pubspec). Пока ассета нет —
/// рисует тёплый медальон-заглушку, чтобы экран не выглядел пустым.
class SquirrelMascot extends StatelessWidget {
  const SquirrelMascot({super.key, this.size = 140, this.caption});

  final double size;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: OrexColors.copperGradient,
          ),
          alignment: Alignment.center,
          child: Image.asset(
            'assets/mascot/squirrel.png',
            width: size * 0.7,
            height: size * 0.7,
            errorBuilder: (_, __, ___) => Text(
              '\u{1F43F}', // 🐿 — временная заглушка
              style: TextStyle(fontSize: size * 0.42),
            ),
          ),
        ),
        if (caption != null) ...[
          const SizedBox(height: 16),
          Text(
            caption!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? OrexColors.darkTextSoft : OrexColors.lightTextSoft,
              fontSize: 14.5,
            ),
          ),
        ],
      ],
    );
  }
}
