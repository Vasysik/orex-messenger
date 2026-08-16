import 'package:flutter/material.dart';

import '../../core/platform/orex_download_page.dart';
import '../theme/orex_theme.dart';

/// Ненавязчивая Web-кнопка страницы загрузок. Она живёт поверх основного UI,
/// чтобы ссылка на дистрибутивы не занимала место в формах/панелях приложения.
class OrexDownloadCornerButton extends StatelessWidget {
  const OrexDownloadCornerButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!orexDownloadPageAvailable) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: 'Скачать приложение',
      child: Tooltip(
        message: 'Скачать приложение',
        child: Material(
          elevation: 8,
          shadowColor: Colors.black.withValues(alpha: 0.22),
          color: isDark ? OrexColors.walnutDeep : OrexColors.cream,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: openOrexDownloadPage,
            child: const SizedBox.square(
              dimension: 52,
              child: Icon(
                Icons.download_rounded,
                color: OrexColors.copper,
                size: 25,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
