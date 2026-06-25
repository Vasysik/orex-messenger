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
  });

  final Uint8List bytes;
  final String filename;
  final bool isVideo;

  @override
  State<OrexMediaPlayer> createState() => _OrexMediaPlayerState();
}

class _OrexMediaPlayerState extends State<OrexMediaPlayer> {
  late final String _viewId;
  late final web.Blob _blob;
  late final String _objectUrl;
  
  web.HTMLAudioElement? _audioElement;
  bool _isPlaying = false;
  double _currentTime = 0.0;
  double _duration = 0.0;

  @override
  void initState() {
    super.initState();
    _blob = web.Blob([widget.bytes.toJS].toJS);
    _objectUrl = web.URL.createObjectURL(_blob);

    if (!widget.isVideo) {
      // Для аудио создаем невидимый элемент в DOM
      _audioElement = web.HTMLAudioElement()
        ..src = _objectUrl
        ..autoplay = false;
      web.document.body?.appendChild(_audioElement!);

      // Синхронизация состояния HTML5-аудио с Flutter UI
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
    } else {
      _viewId = 'orex-video-${DateTime.now().microsecondsSinceEpoch}';
      ui_web.platformViewRegistry.registerViewFactory(_viewId, (int viewId) {
        final video = web.document.createElement('video') as web.HTMLVideoElement
          ..src = _objectUrl
          ..controls = true
          ..autoplay = false;
        video.style.setProperty('width', '100%');
        video.style.setProperty('height', '100%');
        video.style.setProperty('border-radius', '12px');
        return video;
      });
    }
  }

  @override
  void dispose() {
    if (_audioElement != null) {
      _audioElement!.pause();
      web.document.body?.removeChild(_audioElement!);
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
        width: 280,
        height: 180,
        child: HtmlElementView(viewType: _viewId),
      );
    }

    // Кастомный медный аудио-плеер Orex
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
