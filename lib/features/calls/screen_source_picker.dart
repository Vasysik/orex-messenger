import 'dart:async';
import 'dart:typed_data';

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

class _OrexScreenSourceDialogState extends State<_OrexScreenSourceDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final Map<String, rtc.DesktopCapturerSource> _sources = <String, rtc.DesktopCapturerSource>{};
  final List<StreamSubscription<dynamic>> _subscriptions = <StreamSubscription<dynamic>>[];

  rtc.SourceType _activeType = rtc.SourceType.Screen;
  rtc.DesktopCapturerSource? _selected;
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;
  int _screenCount = 0;
  int _windowCount = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(_onTabChanged);
    _subscribeDesktopCapturer();
    unawaited(_loadSources(_activeType));
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _shutdownSourceWatching();
    super.dispose();
  }

  void _subscribeDesktopCapturer() {
    _subscriptions.add(rtc.desktopCapturer.onAdded.stream.listen((source) {
      if (!mounted || source.type != _activeType) return;
      setState(() {
        _sources[source.id] = source;
        _updateCountFor(_activeType, _sources.length);
      });
    }));
    _subscriptions.add(rtc.desktopCapturer.onRemoved.stream.listen((source) {
      if (!mounted) return;
      setState(() {
        _sources.remove(source.id);
        if (_selected?.id == source.id) _selected = null;
        _updateCountFor(_activeType, _sources.length);
      });
    }));
    _subscriptions.add(rtc.desktopCapturer.onThumbnailChanged.stream.listen((_) {
      if (!mounted) return;
      setState(() {});
    }));
    _subscriptions.add(rtc.desktopCapturer.onNameChanged.stream.listen((_) {
      if (!mounted) return;
      setState(() {});
    }));
  }

  void _shutdownSourceWatching() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    final next = _tabController.index == 0 ? rtc.SourceType.Screen : rtc.SourceType.Window;
    if (next == _activeType) return;
    _activeType = next;
    _selected = null;
    unawaited(_loadSources(next));
  }

  Future<void> _loadSources(rtc.SourceType type) async {
    setState(() {
      _loading = true;
      _error = null;
      _sources.clear();
    });
    _refreshTimer?.cancel();
    OrexLog.d('ScreenShare', 'loading desktop sources type=${_sourceTypeName(type)}');
    try {
      // Важно: не грузим Screen и Window подряд. В flutter_webrtc desktopCapturer
      // внутренне держит активный набор источников по типу; если после Screen
      // сразу запросить Window, screen id может стать "source not found" при
      // getDisplayMedia. Это повторяет подход LiveKit ScreenSelectDialog:
      // активная вкладка -> getSources только для её типа.
      final sources = await rtc.desktopCapturer.getSources(
        types: [type],
        thumbnailSize: rtc.ThumbnailSize(320, 180),
      );
      if (!mounted || type != _activeType) return;
      final clean = _clean(sources);
      setState(() {
        _sources
          ..clear()
          ..addEntries(clean.map((source) => MapEntry(source.id, source)));
        _updateCountFor(type, clean.length);
        _loading = false;
      });
      OrexLog.d(
        'ScreenShare',
        'desktop sources loaded type=${_sourceTypeName(type)} count=${clean.length} thumbs=${_thumbCount(clean)}',
      );
      _startRefreshTimer(type);
      Future<void>.delayed(const Duration(milliseconds: 500), () {
        if (!mounted || type != _activeType) return;
        setState(() {});
      });
    } catch (e, st) {
      OrexLog.d(
        'ScreenShare',
        'desktopCapturer.getSources failed type=${_sourceTypeName(type)} stack=$st',
        e,
      );
      if (!mounted || type != _activeType) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  void _startRefreshTimer(rtc.SourceType type) {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted || type != _activeType) return;
      try {
        await rtc.desktopCapturer.updateSources(types: [type]);
      } catch (e) {
        OrexLog.d('ScreenShare', 'desktopCapturer.updateSources failed type=${_sourceTypeName(type)}', e);
      }
    });
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

  void _updateCountFor(rtc.SourceType type, int count) {
    if (type == rtc.SourceType.Screen) {
      _screenCount = count;
    } else if (type == rtc.SourceType.Window) {
      _windowCount = count;
    }
  }

  void _reload() {
    _selected = null;
    unawaited(_loadSources(_activeType));
  }

  Future<void> _share() async {
    final selected = _selected;
    if (selected == null) return;
    final source = OrexScreenSource.fromDesktop(selected);
    OrexLog.d(
      'ScreenShare',
      'source selected id=${source.id} type=${source.type} name=${source.name}',
    );
    _refreshTimer?.cancel();
    _refreshTimer = null;
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
                      controller: _tabController,
                      indicatorSize: TabBarIndicatorSize.tab,
                      dividerColor: Colors.transparent,
                      indicator: BoxDecoration(
                        color: OrexColors.copper.withValues(alpha: 0.22),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      labelColor: OrexColors.cream,
                      unselectedLabelColor: OrexColors.darkTextSoft,
                      onTap: (index) {
                        final next = index == 0 ? rtc.SourceType.Screen : rtc.SourceType.Window;
                        if (next == _activeType) return;
                        _activeType = next;
                        _selected = null;
                        unawaited(_loadSources(next));
                      },
                      tabs: [
                        Tab(text: 'Экраны · $_screenCount'),
                        Tab(text: 'Окна · $_windowCount'),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Flexible(child: _body()),
                _PickerFooter(
                  selectedName: _selected?.name,
                  hasSelection: _selected != null,
                  onCancel: () => Navigator.of(context).pop(),
                  onShare: () { unawaited(_share()); },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const SizedBox(
        height: 300,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return _PickerError(error: _error!, onRetry: _reload);
    }
    final sources = _sources.values.where((source) => source.type == _activeType).toList();
    return _SourceGrid(
      sources: sources,
      emptyText: _activeType == rtc.SourceType.Screen
          ? 'Экраны не найдены'
          : 'Окна не найдены. Если окно свёрнуто, Windows часто не отдаёт его в capturer.',
      selectedId: _selected?.id,
      onSelect: (source) => setState(() => _selected = source),
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

class _SourceCard extends StatefulWidget {
  const _SourceCard({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final rtc.DesktopCapturerSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<_SourceCard> {
  StreamSubscription<dynamic>? _thumbSub;
  StreamSubscription<dynamic>? _nameSub;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _SourceCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _unsubscribe();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _subscribe() {
    try {
      _thumbSub = widget.source.onThumbnailChanged.stream.listen((_) {
        if (mounted) setState(() {});
      });
    } catch (_) {}
    try {
      _nameSub = widget.source.onNameChanged.stream.listen((_) {
        if (mounted) setState(() {});
      });
    } catch (_) {}
  }

  void _unsubscribe() {
    unawaited(_thumbSub?.cancel());
    unawaited(_nameSub?.cancel());
    _thumbSub = null;
    _nameSub = null;
  }

  Uint8List? get _thumbnail {
    final bytes = widget.source.thumbnail;
    if (bytes == null || bytes.isEmpty) return null;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final isScreen = widget.source.type == rtc.SourceType.Screen;
    final title = widget.source.name.trim().isEmpty
        ? widget.source.id
        : widget.source.name.trim();
    final thumbnail = _thumbnail;
    final selected = widget.selected;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
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
                                'Превью загружается…',
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
              'Окна должны быть развернуты/видимы. Свёрнутые и защищённые окна Windows часто не дают кадр или источник.',
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
