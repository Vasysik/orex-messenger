import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/orex_theme.dart';
import 'squirrel_mascot.dart';

class OrexLoadingOverlay extends StatelessWidget {
  const OrexLoadingOverlay({
    super.key,
    this.caption = 'Загрузка...',
  });

  final String caption;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.24),
        alignment: Alignment.center,
        child: GlassPanel(
          borderRadius: 20,
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SquirrelMascot(size: 96, caption: caption),
                const SizedBox(height: 12),
                const CircularProgressIndicator(color: OrexColors.copper),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
