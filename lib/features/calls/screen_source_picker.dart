import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../shared/theme/orex_theme.dart';

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
    builder: (_) => const _OrexScreenSourceDialog(),
  );
}

class _OrexScreenSourceDialog extends StatefulWidget {
  const _OrexScreenSourceDialog();

  @override
  State<_OrexScreenSourceDialog> createState() => _OrexScreenSourceDialogState();
}

class _OrexScreenSourceDialogState extends State<_OrexScreenSourceDialog> {
  late Future<_SourceGroups> _future = _loadSources();
  rtc.DesktopCapturerSource? _selected;

  Future<_SourceGroups> _loadSources() async {
    // Грузим экраны и окна раздельно: так flutter_webrtc на desktop отдаёт
    // более полный список, а выбранный source.id дальше можно передать в
    // ScreenShareCaptureOptions/LocalVideoTrack.
    final screens = await rtc.desktopCapturer.getSources(
      types: const [rtc.SourceType.Screen],
      thumbnailSize: rtc.ThumbnailSize(360, 220),
    );
    final windows = await rtc.desktopCapturer.getSources(
      types: const [rtc.SourceType.Window],
      thumbnailSize: rtc.ThumbnailSize(360, 220),
    );

    return _SourceGroups(
      screens: _clean(screens),
      windows: _clean(windows),
    );
  }

  List<rtc.DesktopCapturerSource> _clean(
    List<rtc.DesktopCapturerSource> sources,
  ) {
    final byId = <String, rtc.DesktopCapturerSource>{};
    for (final source in sources) {
      final id = source.id.trim();
      if (id.isEmpty) continue;
      byId[id] = source;
    }
    return byId.values.toList();
  }

  void _reload() {
    setState(() {
      _selected = null;
      _future = _loadSources();
    });
  }

  void _share() {
    final selected = _selected;
    if (selected == null) return;
    Navigator.of(context).pop(selected.id);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(22),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
        child: Container(
          decoration: BoxDecoration(
            color: OrexColors.darkSurface.withValues(alpha: 0.98),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: OrexColors.copper.withValues(alpha: 0.22)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.38),
                blurRadius: 28,
                offset: const Offset(0, 16),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _PickerHeader(onReload: _reload),
                Flexible(
                  child: FutureBuilder<_SourceGroups>(
                    future: _future,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return const SizedBox(
                          height: 330,
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      if (snapshot.hasError) {
                        return _PickerError(
                          error: snapshot.error.toString(),
                          onRetry: _reload,
                        );
                      }
                      final groups = snapshot.data ?? const _SourceGroups();
                      return _SourceTabs(
                        groups: groups,
                        selectedId: _selected?.id,
                        onSelect: (source) => setState(() => _selected = source),
                      );
                    },
                  ),
                ),
                _PickerFooter(
                  selectedName: _selected?.name,
                  hasSelection: _selected != null,
                  onCancel: () => Navigator.of(context).pop(),
                  onShare: _share,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PickerHeader extends StatelessWidget {
  const _PickerHeader({required this.onReload});

  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: OrexColors.copperGradient,
            ),
            child: const Icon(Icons.screen_share, color: OrexColors.cream, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Что показывать?',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Выберите экран или окно',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Обновить',
            onPressed: onReload,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Закрыть',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _SourceTabs extends StatelessWidget {
  const _SourceTabs({
    required this.groups,
    required this.selectedId,
    required this.onSelect,
  });

  final _SourceGroups groups;
  final String? selectedId;
  final ValueChanged<rtc.DesktopCapturerSource> onSelect;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Container(
              height: 40,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: TabBar(
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                indicator: BoxDecoration(
                  color: OrexColors.copper.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: OrexColors.copper.withValues(alpha: 0.35)),
                ),
                labelColor: OrexColors.cream,
                unselectedLabelColor: OrexColors.darkTextSoft,
                tabs: [
                  Tab(text: 'Экраны · ${groups.screens.length}'),
                  Tab(text: 'Окна · ${groups.windows.length}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: TabBarView(
              children: [
                _SourceGrid(
                  sources: groups.screens,
                  emptyText: 'Экраны не найдены',
                  selectedId: selectedId,
                  onSelect: onSelect,
                ),
                _SourceGrid(
                  sources: groups.windows,
                  emptyText: 'Окна не найдены',
                  selectedId: selectedId,
                  onSelect: onSelect,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceGrid extends StatelessWidget {
  const _SourceGrid({
    required this.sources,
    required this.emptyText,
    required this.selectedId,
    required this.onSelect,
  });

  final List<rtc.DesktopCapturerSource> sources;
  final String emptyText;
  final String? selectedId;
  final ValueChanged<rtc.DesktopCapturerSource> onSelect;

  @override
  Widget build(BuildContext context) {
    if (sources.isEmpty) {
      return Center(
        child: Text(emptyText, style: const TextStyle(color: Colors.white70)),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 660 ? 3 : width >= 430 ? 2 : 1;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.22,
          ),
          itemCount: sources.length,
          itemBuilder: (context, index) {
            final source = sources[index];
            return _SourceCard(
              source: source,
              selected: selectedId == source.id,
              onTap: () => onSelect(source),
            );
          },
        );
      },
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final rtc.DesktopCapturerSource source;
  final bool selected;
  final VoidCallback onTap;

  Uint8List? get _thumbnail {
    final bytes = source.thumbnail;
    if (bytes == null || bytes.isEmpty) return null;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final isScreen = source.type == rtc.SourceType.Screen;
    final title = source.name.trim().isEmpty ? source.id : source.name.trim();
    final thumbnail = _thumbnail;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        hoverColor: OrexColors.copper.withValues(alpha: 0.08),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            color: selected
                ? OrexColors.copper.withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.045),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? OrexColors.copper.withValues(alpha: 0.70)
                  : Colors.white.withValues(alpha: 0.10),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (thumbnail != null)
                        Image.memory(
                          thumbnail,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.low,
                        )
                      else
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                OrexColors.walnutDeep.withValues(alpha: 0.75),
                                OrexColors.copper.withValues(alpha: 0.28),
                              ],
                            ),
                          ),
                          child: Icon(
                            isScreen ? Icons.monitor : Icons.web_asset,
                            color: OrexColors.cream.withValues(alpha: 0.80),
                            size: 40,
                          ),
                        ),
                      Positioned(
                        left: 9,
                        top: 9,
                        child: _TypePill(
                          icon: isScreen ? Icons.monitor : Icons.web_asset,
                          text: isScreen ? 'Экран' : 'Окно',
                        ),
                      ),
                      if (selected)
                        Positioned(
                          right: 9,
                          top: 9,
                          child: Container(
                            width: 25,
                            height: 25,
                            decoration: const BoxDecoration(
                              color: OrexColors.copper,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.check, size: 16, color: OrexColors.cream),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.12,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypePill extends StatelessWidget {
  const _TypePill({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.50),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            text,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _PickerFooter extends StatelessWidget {
  const _PickerFooter({
    required this.selectedName,
    required this.hasSelection,
    required this.onCancel,
    required this.onShare,
  });

  final String? selectedName;
  final bool hasSelection;
  final VoidCallback onCancel;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final selected = selectedName?.trim();
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 11, 18, 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.14),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hasSelection
                  ? 'Выбрано: ${selected?.isNotEmpty == true ? selected : 'источник'}'
                  : 'Сначала выберите источник',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('Отмена')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: hasSelection ? onShare : null,
            icon: const Icon(Icons.screen_share, size: 18),
            label: const Text('Поделиться'),
          ),
        ],
      ),
    );
  }
}

class _PickerError extends StatelessWidget {
  const _PickerError({required this.error, required this.onRetry});

  final String error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFE0A03A).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFE0A03A).withValues(alpha: 0.24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Не удалось получить источники',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceGroups {
  const _SourceGroups({
    this.screens = const <rtc.DesktopCapturerSource>[],
    this.windows = const <rtc.DesktopCapturerSource>[],
  });

  final List<rtc.DesktopCapturerSource> screens;
  final List<rtc.DesktopCapturerSource> windows;
}
