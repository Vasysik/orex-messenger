part of 'message_bubble.dart';

final LinkedHashMap<String, Uint8List> _decryptedCache = LinkedHashMap();
int _decryptedCacheBytes = 0;
int get _decryptedCacheMaxBytes =>
    OrexIncomingMediaPolicy.decryptedCacheLimit(isWeb: kIsWeb);

Uint8List? _getDecryptedCache(String eventId) {
  final bytes = _decryptedCache.remove(eventId);
  if (bytes == null) return null;
  _decryptedCache[eventId] = bytes;
  return bytes;
}

void _putDecryptedCache(String eventId, Uint8List bytes) {
  if (eventId.isEmpty || bytes.lengthInBytes > _decryptedCacheMaxBytes) return;
  final old = _decryptedCache.remove(eventId);
  if (old != null) _decryptedCacheBytes -= old.lengthInBytes;
  _decryptedCache[eventId] = bytes;
  _decryptedCacheBytes += bytes.lengthInBytes;
  while (_decryptedCacheBytes > _decryptedCacheMaxBytes &&
      _decryptedCache.isNotEmpty) {
    final firstKey = _decryptedCache.keys.first;
    final removed = _decryptedCache.remove(firstKey);
    if (removed != null) _decryptedCacheBytes -= removed.lengthInBytes;
  }
  if (_decryptedCacheBytes < 0) _decryptedCacheBytes = 0;
}

class _AttachmentImage extends StatefulWidget {
  const _AttachmentImage({
    super.key, 
    required this.event, 
    required this.timeline,
    required this.myUserId,
    this.width,
    this.height,
  });
  
  final Event event;
  final Timeline timeline;
  final String myUserId;
  final double? width;
  final double? height;

  @override
  State<_AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<_AttachmentImage> with AutomaticKeepAliveClientMixin {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = _getDecryptedCache(widget.event.eventId);
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }

    final content = Map<String, Object?>.from(widget.event.content);
    final canLoadThumbnail = OrexIncomingMediaPolicy.shouldAutoLoadThumbnail(
      content,
      isWeb: kIsWeb,
    );
    final canLoadFullImage = OrexIncomingMediaPolicy.shouldAutoLoadImage(
      content,
      isWeb: kIsWeb,
    );

    if (canLoadThumbnail) {
      try {
        final file = await widget.event.downloadAndDecryptAttachment(
          getThumbnail: true,
        );
        _putDecryptedCache(widget.event.eventId, file.bytes);
        if (mounted) setState(() => _bytes = file.bytes);
        return;
      } catch (_) {
        // Fallback ниже разрешён только для заранее объявленного безопасного
        // размера. Никогда не скачиваем произвольный full-size файл вслепую.
      }
    }

    if (canLoadFullImage) {
      try {
        final file = await widget.event.downloadAndDecryptAttachment();
        _putDecryptedCache(widget.event.eventId, file.bytes);
        if (mounted) setState(() => _bytes = file.bytes);
        return;
      } catch (_) {}
    }

    if (mounted) setState(() => _failed = true);
  }

  void _openGallery() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaGalleryDialog(
          timeline: widget.timeline,
          initialEventId: widget.event.eventId,
          myUserId: widget.myUserId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final w = widget.width ?? 240.0;
    final h = widget.height ?? 200.0;

    return GestureDetector(
      onTap: _openGallery,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: w,
          height: h,
          child: _bytes != null
              ? Image.memory(_bytes!, fit: BoxFit.cover)
              : Container(
                  color: Colors.black.withValues(alpha: 0.2),
                  alignment: Alignment.center,
                  child: _failed
                      ? const Icon(Icons.broken_image, color: OrexColors.cream)
                      : const CircularProgressIndicator(strokeWidth: 2, color: OrexColors.copper),
                ),
        ),
      ),
    );
  }
}

class _AttachmentMedia extends StatefulWidget {
  const _AttachmentMedia({
    super.key,
    required this.event,
    required this.isVideo,
    required this.timeline,
    required this.myUserId,
    this.width,
    this.height,
  });

  final Event event;
  final bool isVideo;
  final Timeline timeline;
  final String myUserId;
  final double? width;
  final double? height;

  @override
  State<_AttachmentMedia> createState() => _AttachmentMediaState();
}

class _AttachmentMediaState extends State<_AttachmentMedia> with AutomaticKeepAliveClientMixin {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cached = _getDecryptedCache(widget.event.eventId);
    if (cached != null) {
      if (mounted) setState(() => _bytes = cached);
      return;
    }

    final content = Map<String, Object?>.from(widget.event.content);
    if (!widget.isVideo) {
      if (!OrexIncomingMediaPolicy.shouldAutoLoadAudio(
        content,
        isWeb: kIsWeb,
      )) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      try {
        final file = await widget.event.downloadAndDecryptAttachment();
        _putDecryptedCache(widget.event.eventId, file.bytes);
        if (mounted) setState(() => _bytes = file.bytes);
      } catch (_) {
        if (mounted) setState(() => _failed = true);
      }
      return;
    }

    // Для видео в ленте загружаем только безопасный thumbnail. Автоматический
    // fallback на полный ролик — DoS-вектор для Web и поэтому запрещён.
    if (!OrexIncomingMediaPolicy.shouldAutoLoadThumbnail(
      content,
      isWeb: kIsWeb,
    )) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    try {
      final file = await widget.event.downloadAndDecryptAttachment(
        getThumbnail: true,
      );
      _putDecryptedCache(widget.event.eventId, file.bytes);
      if (mounted) setState(() => _bytes = file.bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _openGallery() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MediaGalleryDialog(
          timeline: widget.timeline,
          initialEventId: widget.event.eventId,
          myUserId: widget.myUserId,
        ),
      ),
    );
  }

  Future<void> _loadAudioOnDemand() async {
    final blockReason = OrexIncomingMediaPolicy.manualDownloadBlockReason(
      Map<String, Object?>.from(widget.event.content),
      isWeb: kIsWeb,
    );
    if (blockReason != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(blockReason)),
        );
      }
      return;
    }

    if (mounted) setState(() => _failed = false);
    try {
      final file = await widget.event.downloadAndDecryptAttachment();
      _putDecryptedCache(widget.event.eventId, file.bytes);
      if (mounted) setState(() => _bytes = file.bytes);
    } catch (_) {
      if (mounted) {
        setState(() => _failed = true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось безопасно загрузить аудио')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final w = widget.width ?? 240.0;
    final h = widget.height ?? (widget.isVideo ? 150.0 : 54.0);

    if (_failed) {
      final placeholder = Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Icon(
          widget.isVideo ? Icons.play_circle_outline : Icons.download_outlined,
          color: OrexColors.copper,
          size: widget.isVideo ? 36 : 24,
        ),
      );
      return GestureDetector(
        onTap: widget.isVideo ? _openGallery : _loadAudioOnDemand,
        child: placeholder,
      );
    }
    if (_bytes == null) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: const CircularProgressIndicator(strokeWidth: 2, color: OrexColors.copper),
      );
    }

    final filename = widget.event.content.tryGet<String>('filename') ??
        widget.event.content.tryGet<String>('body') ??
        (widget.isVideo ? 'video.mp4' : 'audio.mp3');

    if (widget.isVideo) {
      return GestureDetector(
        onTap: _openGallery,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: w,
            height: h,
            decoration: const BoxDecoration(gradient: OrexColors.copperGradient),
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (kIsWeb)
                  Positioned.fill(
                    child: OrexMediaPlayer(bytes: _bytes!, filename: filename, isVideo: true, isPreview: true),
                  ),
                const Icon(Icons.play_circle_outline, size: 36, color: Colors.white),
              ],
            ),
          ),
        ),
      );
    }

    return OrexMediaPlayer(bytes: _bytes!, filename: filename, isVideo: false);
  }
}

class _FileTile extends StatefulWidget {
  const _FileTile({super.key, required this.event, required this.body, required this.textColor});
  final Event event;
  final String body;
  final Color textColor;

  @override
  State<_FileTile> createState() => _FileTileState();
}

class _FileTileState extends State<_FileTile> {
  bool _downloading = false;

  Future<void> _download() async {
    if (_downloading) return;
    final blockReason = OrexIncomingMediaPolicy.manualDownloadBlockReason(
      Map<String, Object?>.from(widget.event.content),
      isWeb: kIsWeb,
    );
    if (blockReason != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(blockReason)),
        );
      }
      return;
    }

    setState(() => _downloading = true);
    try {
      final file = await widget.event.downloadAndDecryptAttachment();
      final filename = widget.event.content.tryGet<String>('filename') ??
          widget.event.content.tryGet<String>('body') ??
          widget.body;
      await FileHelper.saveAndOpenFile(filename, file.bytes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось безопасно открыть файл')),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.event.content.tryGet<String>('filename') ??
        widget.event.content.tryGet<String>('body') ??
        widget.body;

    return GestureDetector(
      onTap: _download,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _downloading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: OrexColors.copper),
                  )
                : const Icon(Icons.insert_drive_file, color: OrexColors.copper),
            const SizedBox(width: 8),
            Flexible(
              child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: widget.textColor)),
            ),
          ],
        ),
      ),
    );
  }
}
