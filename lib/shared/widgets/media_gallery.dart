import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../../core/files/file_helper.dart';
import '../theme/orex_theme.dart';
import 'media_player.dart';

class MediaGalleryDialog extends StatefulWidget {
  const MediaGalleryDialog({
    super.key,
    required this.timeline,
    required this.initialEventId,
    required this.myUserId, 
  });

  final Timeline timeline;
  final String initialEventId;
  final String myUserId;

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

  Future<void> _deleteCurrent() async {
    final event = _mediaEvents[_currentIndex];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить медиафайл?'),
        content: const Text('Это сообщение будет удалено для всех участников чата.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFCF6679)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await event.room.redactEvent(event.eventId);
        if (mounted) {
          Navigator.pop(context); 
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Удалено')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Ошибка удаления: $e')),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_mediaEvents.isEmpty) {
      return const SizedBox.shrink();
    }

    final currentEvent = _mediaEvents[_currentIndex];
    final canDelete = currentEvent.senderId == widget.myUserId;

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
          if (canDelete)
            IconButton(
              tooltip: 'Удалить сообщение',
              icon: const Icon(Icons.delete_outline, color: Color(0xFFCF6679)),
              onPressed: _deleteCurrent,
            ),
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
  double _currentScale = 1.0;

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

  void _onInteractionUpdate(ScaleUpdateDetails details) {
    final double scale = _transformController.value.getMaxScaleOnAxis();
    if (scale != _currentScale) {
      setState(() {
        _currentScale = scale;
      });
    }
  }

  void _onInteractionEnd(ScaleEndDetails details) {
    final double scale = _transformController.value.getMaxScaleOnAxis();
    if (scale < 1.0) {
      // Плавно возвращаем масштаб к 1.0 при завершении жеста пальцами
      _transformController.value = Matrix4.identity();
      setState(() {
        _currentScale = 1.0;
      });
    }
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
    final filename = widget.event.content.tryGet<String>('filename') ??
        widget.event.content.tryGet<String>('body') ??
        'video.mp4';

    // Рендерим InteractiveViewer со стандартным pinch-to-zoom (сжатие/растяжение) без вылетов
    return Center(
      child: isVideo
          ? InteractiveViewer(
              transformationController: _transformController,
              minScale: 0.5, // Позволяет отдалять медиа
              maxScale: 4.0,
              panEnabled: _currentScale > 1.0, 
              onInteractionUpdate: _onInteractionUpdate,
              onInteractionEnd: _onInteractionEnd,
              child: Center(
                child: OrexMediaPlayer(bytes: _bytes!, filename: filename, isVideo: true),
              ),
            )
          : InteractiveViewer(
              transformationController: _transformController,
              minScale: 0.5, // Позволяет отдалять изображение
              maxScale: 4.0,
              panEnabled: _currentScale > 1.0, 
              onInteractionUpdate: _onInteractionUpdate,
              onInteractionEnd: _onInteractionEnd,
              child: Center(
                child: Image.memory(
                  _bytes!,
                  fit: BoxFit.contain, 
                ),
              ),
            ),
    );
  }
}
