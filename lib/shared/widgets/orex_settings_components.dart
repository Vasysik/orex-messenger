import 'package:flutter/material.dart';

import '../theme/glass.dart';
import '../theme/orex_theme.dart';

/// Общие строительные блоки экранов настроек Orex.
///
/// Держим карточки/тайлы в одном месте, чтобы настройки аккаунта, чатов и
/// комнат визуально не расходились и не плодили локальные копии одного дизайна.
class OrexSettingsSection extends StatelessWidget {
  const OrexSettingsSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  letterSpacing: 1.1,
                  color: OrexColors.copper,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        GlassPanel(
          borderRadius: 20,
          child: Column(children: children),
        ),
      ],
    );
  }
}

class OrexSettingsTile extends StatelessWidget {
  const OrexSettingsTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? const Color(0xFFCF6679) : null;
    return ListTile(
      leading: Icon(icon, color: color ?? OrexColors.copper),
      title: Text(title, style: TextStyle(color: color)),
      subtitle: subtitle != null ? Text(subtitle!) : null,
      trailing: onTap != null ? const Icon(Icons.chevron_right, size: 20) : null,
      onTap: onTap,
    );
  }
}

class OrexSettingsSaveBar extends StatelessWidget {
  const OrexSettingsSaveBar({
    super.key,
    required this.onSave,
    this.label = 'Сохранить',
  });

  final VoidCallback onSave;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onSave,
        icon: const Icon(Icons.save),
        label: Text(label),
      ),
    );
  }
}
