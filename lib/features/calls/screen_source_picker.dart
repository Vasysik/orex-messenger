import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';

const String orexDefaultScreenSourceId = '__orex_default_screen__';

bool orexIsDefaultScreenSourceId(String? sourceId) {
  return sourceId == orexDefaultScreenSourceId;
}

bool get orexNeedsScreenSourcePicker {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

Future<String?> showOrexScreenSourcePicker(BuildContext context) async {
  if (!orexNeedsScreenSourcePicker) return null;

  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => const _OrexScreenSourceDialog(),
  );
}

class _OrexScreenSourceDialog extends StatefulWidget {
  const _OrexScreenSourceDialog();

  @override
  State<_OrexScreenSourceDialog> createState() => _OrexScreenSourceDialogState();
}

class _OrexScreenSourceDialogState extends State<_OrexScreenSourceDialog> {
  bool _selected = true;

  bool get _isWindows {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  }

  void _share() {
    if (!_selected) return;
    Navigator.of(context).pop(orexDefaultScreenSourceId);
  }

  @override
  Widget build(BuildContext context) {
    final title = _isWindows ? 'Трансляция экрана' : 'Выбор источника';
    final subtitle = _isWindows
        ? 'Безопасный режим Windows: без desktopCapturer-превью, чтобы приложение не падало.'
        : 'Безопасный режим: будет запущена трансляция основного экрана.';

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: GlassPanel(
          borderRadius: 24,
          opacity: 0.78,
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 12, 10),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: OrexColors.copperGradient,
                      ),
                      child: const Icon(
                        Icons.screen_share,
                        color: OrexColors.cream,
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Закрыть',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
                child: _SafeScreenCard(
                  selected: _selected,
                  onTap: () => setState(() => _selected = true),
                ),
              ),
              if (_isWindows)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 2, 18, 4),
                  child: _WarningNote(
                    text:
                        'Окна и превью временно скрыты именно на Windows: в твоём логе падение происходит после native thumbnail callbacks. Лучше показать стабильную трансляцию экрана, чем снова крашить runner.',
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Выбрано: весь экран',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _share,
                      icon: const Icon(Icons.screen_share, size: 18),
                      label: const Text('Поделиться'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SafeScreenCard extends StatelessWidget {
  const _SafeScreenCard({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        hoverColor: OrexColors.copper.withValues(alpha: 0.08),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? OrexColors.copper.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected
                  ? OrexColors.copper.withValues(alpha: 0.62)
                  : Colors.white.withValues(alpha: 0.10),
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 72,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      OrexColors.copper.withValues(alpha: 0.26),
                      OrexColors.walnutDeep.withValues(alpha: 0.52),
                    ],
                  ),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.monitor,
                  color: OrexColors.cream,
                  size: 26,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Весь экран',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Стабильный запуск без списка окон и без thumbnail callbacks.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? OrexColors.copper : Colors.transparent,
                  border: Border.all(
                    color: selected
                        ? OrexColors.copper
                        : Colors.white.withValues(alpha: 0.34),
                  ),
                ),
                child: selected
                    ? const Icon(Icons.check, color: OrexColors.cream, size: 17)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WarningNote extends StatelessWidget {
  const _WarningNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFE0A03A).withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE0A03A).withValues(alpha: 0.22)),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.25),
      ),
    );
  }
}
