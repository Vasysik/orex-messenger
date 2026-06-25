import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import '../theme/orex_theme.dart';

class OrexMediaPlayer extends StatefulWidget {
  const OrexMediaPlayer({
    super.key,
    required this.bytes,
    required this.filename,
    required this.isVideo,
    this.isPreview = false,
  });

  final Uint8List bytes;
  final String filename;
  final bool isVideo;
  final bool isPreview;

  @override
  State<OrexMediaPlayer> createState() => _OrexMediaPlayerState();
}

class _OrexMediaPlayerState extends State<OrexMediaPlayer> {
  late final String _viewId;
  late final web.Blob _blob;
  late final String _objectUrl;
  
  web.HTMLAudioElement? _audioElement;
  web.HTMLVideoElement? _videoElement;

  @override
  void initState() {
    super.initState();
    _viewId = 'orex-media-${DateTime.now().microsecondsSinceEpoch}';
    _blob = web.Blob([widget.bytes.toJS].toJS);
    _objectUrl = web.URL.createObjectURL(_blob);

    if (widget.isVideo) {
      _videoElement = web.document.createElement('video') as web.HTMLVideoElement
        ..src = _objectUrl
        ..controls = !widget.isPreview
        ..autoplay = false
        ..muted = widget.isPreview;
      
      _videoElement!.style.setProperty('width', '100%');
      _videoElement!.style.setProperty('height', '100%');
      _videoElement!.style.setProperty('border-radius', '12px');
      
      if (widget.isPreview) {
        _videoElement!.style.setProperty('object-fit', 'cover');
      }

      ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) => _videoElement!);
    } else {
      _audioElement = web.HTMLAudioElement()
        ..src = _objectUrl
        ..autoplay = false;
      web.document.body?.appendChild(_audioElement!);

      _audioElement!.addEventListener('timeupdate', (web.Event e) {
        if (mounted) {
          setState(() {
            _currentTime = _audioElement!.currentTime;
          });
        }
      }.toJS);

      _audioElement!.addEventListener('durationchange', (web.Event e) {
        if (mounted) {
          setState(() {
            _duration = _audioElement!.duration;
          });
        }
      }.toJS);

      _audioElement!.addEventListener('play', (web.Event e) {
        if (mounted) setState(() => _isPlaying = true);
      }.toJS);

      _audioElement!.addEventListener('pause', (web.Event e) {
        if (mounted) setState(() => _isPlaying = false);
      }.toJS);
    }
  }

  bool _isPlaying = false;
  double _currentTime = 0.0;
  double _duration = 0.0;

  @override
  void dispose() {
    if (_audioElement != null) {
      _audioElement!.pause();
      web.document.body?.removeChild(_audioElement!);
    }
    if (_videoElement != null) {
      _videoElement!.pause();
    }
    web.URL.revokeObjectURL(_objectUrl);
    super.dispose();
  }

  String _formatDuration(double seconds) {
    if (seconds.isNaN || seconds.isInfinite) return '0:00';
    final m = seconds ~/ 60;
    final s = (seconds % 60).toInt();
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isVideo) {
      return SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: HtmlElementView(viewType: _viewId),
      );
    }

    return Container(
      width: 280,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              if (_isPlaying) {
                _audioElement?.pause();
              } else {
                _audioElement?.play();
              }
            },
            child: Container(
              width: 38,
              height: 36,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: OrexColors.copperGradient,
              ),
              child: Icon(
                _isPlaying ? Icons.pause : Icons.play_arrow,
                color: OrexColors.cream,
                size: 20,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 2,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor: OrexColors.copper,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: OrexColors.copper,
                  ),
                  child: Slider(
                    value: _currentTime.clamp(0.0, _duration > 0 ? _duration : 1.0),
                    max: _duration > 0 ? _duration : 1.0,
                    onChanged: (val) {
                      if (_audioElement != null) {
                        _audioElement!.currentTime = val;
                      }
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: Text(
                          widget.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10, color: Colors.white70),
                        ),
                      ),
                      Text(
                        '${_formatDuration(_currentTime)} / ${_formatDuration(_duration)}',
                        style: const TextStyle(fontSize: 10, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
