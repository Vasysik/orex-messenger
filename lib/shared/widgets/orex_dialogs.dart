import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/orex_theme.dart';

typedef OrexDialogContentBuilder = Widget Function(
  BuildContext context,
  StateSetter setDialogState,
);

Future<bool> showOrexConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Отмена',
  bool danger = false,
  bool barrierDismissible = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(cancelLabel),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: const Color(0xFFCF6679))
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result == true;
}

Future<T?> showOrexStatefulFormDialog<T>(
  BuildContext context, {
  required String title,
  required OrexDialogContentBuilder contentBuilder,
  required T? Function() onSubmit,
  String cancelLabel = '\u041e\u0442\u043c\u0435\u043d\u0430',
  String confirmLabel = 'OK',
  double width = 420,
  bool barrierDismissible = true,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: width,
          child: SingleChildScrollView(
            child: contentBuilder(ctx, setDialogState),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(cancelLabel),
          ),
          FilledButton(
            onPressed: () {
              final result = onSubmit();
              if (result != null) Navigator.pop(ctx, result);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    ),
  );
}

Future<String?> showOrexTextInputDialog(
  BuildContext context, {
  required String title,
  String? message,
  String? initialValue,
  String? hintText,
  String? labelText,
  String cancelLabel = 'Отмена',
  String confirmLabel = 'OK',
  bool obscureText = false,
  bool trim = false,
  bool danger = false,
  bool barrierDismissible = true,
}) async {
  final controller = TextEditingController(text: initialValue ?? '');
  try {
    return showDialog<String>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null) ...[
                Text(message),
                const SizedBox(height: 12),
              ],
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscureText,
                decoration: InputDecoration(
                  hintText: hintText,
                  labelText: labelText,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(cancelLabel),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFCF6679),
                  )
                : null,
            onPressed: () {
              final value = trim ? controller.text.trim() : controller.text;
              Navigator.pop(ctx, value);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}

void showOrexBlockingProgressDialog(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(
      child: CircularProgressIndicator(color: OrexColors.copper),
    ),
  );
}

Future<void> showOrexRecoveryKeyDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String recoveryKey,
  String copyLabel = 'Копировать',
  String doneLabel = 'Я сохранил',
  String copiedMessage = 'Ключ скопирован в буфер обмена',
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                recoveryKey,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 15),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: recoveryKey));
            if (ctx.mounted) {
              ScaffoldMessenger.of(
                ctx,
              ).showSnackBar(SnackBar(content: Text(copiedMessage)));
            }
          },
          child: Text(copyLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(doneLabel),
        ),
      ],
    ),
  );
}
