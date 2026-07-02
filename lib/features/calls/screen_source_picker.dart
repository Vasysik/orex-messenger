import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../../core/logging/orex_logger.dart';
import '../../shared/theme/orex_theme.dart';

bool get orexNeedsScreenSourcePicker {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
}

class OrexScreenSource {
  const OrexScreenSource({
    required this.id,
    required this.name,
    required this.type,
  });

  final String id;
  final String name;
  final String type;

  factory OrexScreenSource.fromDesktop(rtc.DesktopCapturerSource source) {
    return OrexScreenSource(
      id: source.id,
      name: source.name.trim().isEmpty ? source.id : source.name.trim(),
      type: _sourceTypeName(source.type),
    );
  }
}

String _sourceTypeName(rtc.SourceType type) {
  if (type == rtc.SourceType.Screen) return 'screen';
  if (type == rtc.SourceType.Window) return 'window';
  return 'unknown';
}

Future<OrexScreenSource?> showOrexScreenSourcePicker(BuildContext context) async {
  if (!orexNeedsScreenSourcePicker) return null;

  return showDialog<OrexScreenSource>(
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
  final List<StreamSubscription<dynamic>> _sourceSubscriptions = <StreamSubscription<dynamic>>[];

  @override
  void dispose() {
    _cancelSourceSubscriptions();
    super.dispose();
  }

  void _cancelSourceSubscriptions() {
    for (final subscription in _sourceSubscriptions) {
      unawaited(subscription.cancel());
    }
    _sourceSubscriptions.clear();
  }

  Future<_SourceGroups> _loadSources() async {
    OrexLog.d('ScreenShare', 'loading desktop sources');
    final screens = await _loadGroup(rtc.SourceType.Screen);
    final windows = await _loadGroup(rtc.SourceType.Window);
    final groups = _SourceGroups(
      screens: _clean(screens),
      windows: _clean(windows),
    );
    _attachSourceListeners(groups.all);
    OrexLog.d(
      'ScreenShare',
      'desktop sources loaded screens=${groups.screens.length} windows=${groups.windows.length} '
      'screenThumbs=${_thumbCount(groups.screens)} windowThumbs=${_thumbCount(groups.windows)}',
    );
    return groups;
  }

  Future<List<rtc.DesktopCapturerSource>> _loadGroup(rtc.SourceType type) async {
    try {
      return await rtc.desktopCapturer.getSources(
        types: [type],
        thumbnailSize: rtc.ThumbnailSize(320, 180),
      );
    } catch (e, st) {
      OrexLog.d('ScreenShare', 'desktopCapturer.getSources failed type=${_sourceTypeName(type)} stack=$st', e);
      rethrow;
    }
  }

  int _thumbCount(List<rtc.DesktopCapturerSource> sources) {
    return sources.where((source) {
      final thumbnail = source.thumbnail;
      return thumbnail != null && thumbnail.isNotEmpty;
    }).length;
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

  void _attachSourceListeners(List<rtc.DesktopCapturerSource> sources) {
    _cancelSourceSubscriptions();
    for (final source in sources) {
      _sourceSubscriptions.add(source.onThumbnailChanged.stream.listen((_) {
        if (!mounted) return;
        setState(() {});
      }));
      _sourceSubscriptions.add(source.onNameChanged.stream.listen((_) {
        if (!mounted) return;
        setState(() {});
      }));
    }
    // flutter_webrtc often returns sources before thumbnails are populated.
    // One late repaint is enough to show thumbnails delivered immediately after
    // getSources(), without running a noisy periodic update loop.
    Future<void>.delayed(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _reload() {
    setState(() {
      _selected = null;
      _cancelSourceSubscriptions();
      _future = _loadSources();
    });
  }

  void _share() {
    final selected = _selected;
    if (selected == null) return;
    final source = OrexScreenSource.fromDesktop(selected);
    OrexLog.d(
      'ScreenShare',
      'source selected id=${source.id} type=${source.type} name=${source.name}',
    );
    Navigator.of(context).pop(source);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 560),
        child: Container(
          decoration: BoxDecoration(
            color: OrexColors.darkSurface.withValues(alpha: 0.98),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: OrexColors.copper.withValues(alpha: 0.22)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
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
                          height: 300,
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
      padding: const EdgeInsets.fromLTRB(20, 16, 10, 8),
      child: Row(
        children: [
          const Icon(Icons.screen_share, color: OrexColors.copper),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Трансляция экрана',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          IconButton(
            tooltip: 'Обновить превью',
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
              height: 38,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
              ),
              child: TabBar(
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                indicator: BoxDecoration(
                  color: OrexColors.copper.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(11),
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
          const SizedBox(height: 10),
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
                  emptyText: 'Окна не найдены. Если окно свёрнуто, Windows часто не отдаёт его в capturer.',
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
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyText,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final columns = width >= 520 ? 2 : 1;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.34,
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
                ? OrexColors.copper.withValues(alpha: 0.14)
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
                        Container(
                          color: Colors.black.withValues(alpha: 0.22),
                          alignment: Alignment.center,
                          child: Image.memory(
                            thumbnail,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            filterQuality: FilterQuality.low,
                          ),
                        )
                      else
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                OrexColors.walnutDeep.withValues(alpha: 0.78),
                                OrexColors.copper.withValues(alpha: 0.24),
                              ],
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                isScreen ? Icons.monitor : Icons.web_asset,
                                color: OrexColors.cream.withValues(alpha: 0.82),
                                size: 34,
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Превью недоступно',
                                style: TextStyle(fontSize: 11, color: Colors.white70),
                              ),
                            ],
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
                            width: 24,
                            height: 24,
                            decoration: const BoxDecoration(
                              color: OrexColors.copper,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.check, size: 15, color: OrexColors.cream),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
                child: Text(
                  title,
                  maxLines: 1,
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
    final showWindowsHint = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.14),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showWindowsHint) ...[
            Text(
              'Windows не отдаёт содержимое некоторых свёрнутых/защищённых окон — разверните окно, если его нет или превью пустое.',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white60,
                    fontSize: 11,
                  ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
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

  List<rtc.DesktopCapturerSource> get all => <rtc.DesktopCapturerSource>[
        ...screens,
        ...windows,
      ];
}
