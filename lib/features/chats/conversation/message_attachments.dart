part of 'message_bubble.dart';

final LinkedHashMap<String, Uint8List> _decryptedCache = LinkedHashMap();
int _decryptedCacheBytes = 0;
const int _decryptedCacheMaxBytes = 96 * 1024 * 1024;

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
    try {
      final file = await widget.event.downloadAndDecryptAttachment(getThumbnail: true);
      _putDecryptedCache(widget.event.eventId, file.bytes);
      if (mounted) setState(() => _bytes = file.bytes);
    } catch (_) {
      try {
        final file = await widget.event.downloadAndDecryptAttachment();
        _putDecryptedCache(widget.event.eventId, file.bytes);
        if (mounted) setState(() => _bytes = file.bytes);
      } catch (_) {
        if (mounted) setState(() => _failed = true);
      }
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
    try {
      final file = await widget.event.downloadAndDecryptAttachment(getThumbnail: true);
      _putDecryptedCache(widget.event.eventId, file.bytes);
      if (mounted) setState(() => _bytes = file.bytes);
    } catch (_) {
      try {
        final file = await widget.event.downloadAndDecryptAttachment();
        _putDecryptedCache(widget.event.eventId, file.bytes);
        if (mounted) setState(() => _bytes = file.bytes);
      } catch (_) {
        if (mounted) setState(() => _failed = true);
      }
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final w = widget.width ?? 240.0;
    final h = widget.height ?? (widget.isVideo ? 150.0 : 54.0);

    if (_failed) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: const Icon(Icons.error_outline, color: Color(0xFFCF6679)),
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
    setState(() => _downloading = true);
    try {
      final file = await widget.event.downloadAndDecryptAttachment();
      final filename = widget.event.content.tryGet<String>('filename') ??
          widget.event.content.tryGet<String>('body') ??
          widget.body;
      await FileHelper.saveAndOpenFile(filename, file.bytes);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть файл: $e')),
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
