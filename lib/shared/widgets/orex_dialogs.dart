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
}) {
  return showDialog<String>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => _OrexTextInputDialog(
      title: title,
      message: message,
      initialValue: initialValue ?? '',
      hintText: hintText,
      labelText: labelText,
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      obscureText: obscureText,
      trim: trim,
      danger: danger,
    ),
  );
}

/// External controllers used by a generic dialog must outlive its reverse route
/// animation. Dialog-specific controllers should instead be owned by the dialog
/// State itself, as in [_OrexTextInputDialog].
void disposeOrexDialogControllers(
  Iterable<TextEditingController> controllers,
) {
  final owned = controllers.toList(growable: false);
  Future<void>.delayed(
    kThemeAnimationDuration + const Duration(milliseconds: 100),
    () {
      for (final controller in owned) {
        controller.dispose();
      }
    },
  );
}

class _OrexTextInputDialog extends StatefulWidget {
  const _OrexTextInputDialog({
    required this.title,
    required this.message,
    required this.initialValue,
    required this.hintText,
    required this.labelText,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.obscureText,
    required this.trim,
    required this.danger,
  });

  final String title;
  final String? message;
  final String initialValue;
  final String? hintText;
  final String? labelText;
  final String cancelLabel;
  final String confirmLabel;
  final bool obscureText;
  final bool trim;
  final bool danger;

  @override
  State<_OrexTextInputDialog> createState() => _OrexTextInputDialogState();
}

class _OrexTextInputDialogState extends State<_OrexTextInputDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.message != null) ...[
              Text(widget.message!),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: _controller,
              autofocus: true,
              obscureText: widget.obscureText,
              decoration: InputDecoration(
                hintText: widget.hintText,
                labelText: widget.labelText,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.cancelLabel),
        ),
        FilledButton(
          style: widget.danger
              ? FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFCF6679),
                )
              : null,
          onPressed: () {
            final value = widget.trim
                ? _controller.text.trim()
                : _controller.text;
            Navigator.pop(context, value);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
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
