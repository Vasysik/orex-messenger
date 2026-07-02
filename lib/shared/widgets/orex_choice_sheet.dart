import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/orex_theme.dart';

class OrexChoiceSheetOption<T> {
  const OrexChoiceSheetOption({
    required this.value,
    required this.icon,
    required this.title,
    this.subtitle,
    this.selected = false,
  });

  final T value;
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
}

Future<T?> showOrexChoiceSheet<T>(
  BuildContext context, {
  String? title,
  required List<OrexChoiceSheetOption<T>> options,
  String emptyText = 'Ничего не найдено',
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GlassPanel(
          borderRadius: 24,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 460),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  if (title != null) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                      child: Text(
                        title,
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                      ),
                    ),
                  ],
                  if (options.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        emptyText,
                        style: const TextStyle(color: Colors.white54),
                      ),
                    )
                  else
                    for (final option in options)
                      _OrexChoiceTile(
                        icon: option.icon,
                        title: option.title,
                        subtitle: option.subtitle,
                        selected: option.selected,
                        onTap: () => Navigator.pop(ctx, option.value),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _OrexChoiceTile extends StatelessWidget {
  const _OrexChoiceTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: OrexColors.copper),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: selected
          ? const Icon(Icons.check_circle, color: OrexColors.copper)
          : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
