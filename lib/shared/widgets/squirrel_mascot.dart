import 'package:flutter/material.dart';
import '../theme/orex_theme.dart';

/// Маскот-Белочка. Пока ассета нет — рисует тёплый медальон с эмодзи-белочкой,
/// чтобы экран не выглядел пустым. Когда добавите `assets/mascot/squirrel.png`
/// (и пропишете в pubspec) — верните сюда `Image.asset(...)` с тем же
/// `errorBuilder`. Раньше здесь был Image.asset, который на web спамил 404 в
/// консоль (ассета нет) — заменено на прямую заглушку.
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
          child: Text(
            '\u{1F43F}', // 🐿 — временная заглушка вместо ассета
            style: TextStyle(fontSize: size * 0.42),
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
