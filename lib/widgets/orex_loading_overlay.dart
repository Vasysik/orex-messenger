import 'package:flutter/material.dart';

import '../theme/orex_theme.dart';

class OrexLoadingOverlay extends StatelessWidget {
  const OrexLoadingOverlay({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.18),
        alignment: Alignment.center,
        child: const SizedBox.square(
          dimension: 42,
          child: CircularProgressIndicator(color: OrexColors.copper),
        ),
      ),
    );
  }
}

Future<T?> showOrexProgressDialog<T>(BuildContext context) {
  return showDialog<T>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: CircularProgressIndicator(color: OrexColors.copper),
    ),
  );
}
