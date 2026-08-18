import 'package:flutter/material.dart';

import '../../core/platform/orex_download_page.dart';
import '../theme/orex_theme.dart';

/// Web-кнопка страницы загрузок в том же визуальном языке, что и кнопка
/// отправки сообщения: медный градиент, кремовая пиктограмма и круглая форма.
/// Она живёт поверх основного UI, чтобы ссылка на дистрибутивы не занимала
/// место в формах и панелях приложения.
class OrexDownloadCornerButton extends StatelessWidget {
  const OrexDownloadCornerButton({super.key});

  @override
  Widget build(BuildContext context) {
    if (!orexDownloadPageAvailable) return const SizedBox.shrink();

    return Semantics(
      button: true,
      label: 'Скачать приложение',
      child: Material(
        elevation: 5,
        shadowColor: Colors.black.withValues(alpha: 0.18),
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: Ink(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: OrexColors.copperGradient,
            border: Border.fromBorderSide(
              BorderSide(color: OrexColors.cream, width: 2),
            ),
          ),
          child: InkWell(
            customBorder: const CircleBorder(),
            mouseCursor: SystemMouseCursors.click,
            hoverColor: OrexColors.cream.withValues(alpha: 0.08),
            splashColor: OrexColors.cream.withValues(alpha: 0.14),
            onTap: openOrexDownloadPage,
            child: const SizedBox.square(
              dimension: 52,
              child: Icon(
                Icons.download_rounded,
                color: OrexColors.cream,
                size: 25,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
