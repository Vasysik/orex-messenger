import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../core/file_helper.dart';
import '../theme/orex_theme.dart';
import 'media_player.dart';

class MediaGalleryDialog extends StatefulWidget {
  const MediaGalleryDialog({
    super.key,
    required this.timeline,
    required this.initialEventId,
  });

  final Timeline timeline;
  final String initialEventId;

  @override
  State<MediaGalleryDialog> createState() => _MediaGalleryDialogState();
}

class _MediaGalleryDialogState extends State<MediaGalleryDialog> {
  late final List<Event> _mediaEvents;
  late final PageController _pageController;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _mediaEvents = widget.timeline.events
        .where((e) =>
            !e.redacted &&
            (e.messageType == MessageTypes.Image ||
                e.messageType == MessageTypes.Video))
        .toList()
        .reversed 
        .toList();

    _currentIndex = _mediaEvents.indexWhere((e) => e.eventId == widget.initialEventId);
    if (_currentIndex == -1) _currentIndex = 0;

    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_mediaEvents.isEmpty) {
      return const SizedBox.shrink();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '${_currentIndex + 1} из ${_mediaEvents.length}',
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        actions: [
          IconButton(
            tooltip: 'Скачать медиафайл',
            icon: const Icon(Icons.download, color: Colors.white),
            onPressed: _downloadCurrent,
          ),
        ],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            itemCount: _mediaEvents.length,
            onPageChanged: (idx) {
              setState(() {
                _currentIndex = idx;
              });
            },
            itemBuilder: (context, idx) {
              final event = _mediaEvents[idx];
              return _GalleryItem(event: event);
            },
          ),
          // Кнопка влево
          if (_currentIndex > 0)
            Positioned(
              left: 16,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black54),
                  child: IconButton(
                    icon: const Icon(Icons.chevron_left, color: Colors.white, size: 36),
                    onPressed: () {
                      _pageController.previousPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                ),
              ),
            ),
          // Кнопка вправо
          if (_currentIndex < _mediaEvents.length - 1)
            Positioned(
              right: 16,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.black54),
                  child: IconButton(
                    icon: const Icon(Icons.chevron_right, color: Colors.white, size: 36),
                    onPressed: () {
                      _pageController.nextPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeInOut,
                      );
                    },
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _downloadCurrent() async {
    final event = _mediaEvents[_currentIndex];
    try {
      final file = await event.downloadAndDecryptAttachment();
      final filename = event.content.tryGet<String>('filename') ??
          event.content.tryGet<String>('body') ??
          'file';
      await FileHelper.saveAndOpenFile(filename, file.bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка скачивания: $e')),
        );
      }
    }
  }
}

class _GalleryItem extends StatefulWidget {
  const _GalleryItem({required this.event});
  final Event event;

  @override
  State<_GalleryItem> createState() => _GalleryItemState();
}

class _GalleryItemState extends State<_GalleryItem> {
  Uint8List? _bytes;
  bool _failed = false;
  final TransformationController _transformController = TransformationController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final file = await widget.event.downloadAndDecryptAttachment();
      if (mounted) setState(() => _bytes = file.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  // Двойной тап для зумирования (auto-zoom)
  void _doubleTapZoom() {
    if (_transformController.value != Matrix4.identity()) {
      _transformController.value = Matrix4.identity();
    } else {
      _transformController.value = Matrix4.identity()
        ..scaleByDouble(2.0, 2.0, 2.0, 1.0);
    }
  }

  Future<void> _downloadRightClick() async {
    final bytes = _bytes;
    if (bytes == null) return;
    final filename = widget.event.content.tryGet<String>('filename') ??
        widget.event.content.tryGet<String>('body') ??
        'file';
    await FileHelper.saveAndOpenFile(filename, bytes);
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Center(
        child: Text('Ошибка загрузки медиафайла', style: TextStyle(color: Colors.white70)),
      );
    }

    if (_bytes == null) {
      return const Center(child: CircularProgressIndicator(color: OrexColors.copper));
    }

    final isVideo = widget.event.messageType == MessageTypes.Video;

    return GestureDetector(
      onSecondaryTap: _downloadRightClick, // Скачивание по ПКМ
      onDoubleTap: _doubleTapZoom, // Двойной клик - Автозум
      child: Center(
        child: isVideo
            ? InteractiveViewer(
                transformationController: _transformController,
                child: _GalleryVideoPlayer(bytes: _bytes!, event: widget.event),
              )
            : InteractiveViewer(
                transformationController: _transformController,
                child: Image.memory(_bytes!),
              ),
      ),
    );
  }
}

class _GalleryVideoPlayer extends StatefulWidget {
  const _GalleryVideoPlayer({required this.bytes, required this.event});
  final Uint8List bytes;
  final Event event;

  @override
  State<_GalleryVideoPlayer> createState() => _GalleryVideoPlayerState();
}

class _GalleryVideoPlayerState extends State<_GalleryVideoPlayer> {
  @override
  Widget build(BuildContext context) {
    final filename = widget.event.content.tryGet<String>('filename') ??
        widget.event.content.tryGet<String>('body') ??
        'video.mp4';
    return OrexMediaPlayer(bytes: widget.bytes, filename: filename, isVideo: true);
  }
}
