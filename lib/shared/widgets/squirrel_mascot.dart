import 'package:flutter/material.dart';

import '../theme/orex_theme.dart';

/// Маскот Orex. Рендерит пользовательский ассет и откатывается на компактную
/// заглушку только если ассет недоступен на конкретной платформе/сборке.
class SquirrelMascot extends StatelessWidget {
  const SquirrelMascot({super.key, this.size = 140, this.caption});

  static const String assetPath = 'assets/mascot/squirrel.png';

  final double size;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.22),
          child: Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(gradient: OrexColors.copperGradient),
            alignment: Alignment.center,
            child: Image.asset(
              assetPath,
              width: size,
              height: size,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Text(
                '\u{1F43F}',
                style: TextStyle(fontSize: size * 0.42),
              ),
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
