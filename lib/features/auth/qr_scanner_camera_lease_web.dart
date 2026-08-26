import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Owns only the browser MediaStream created by the QR scanner.
///
/// mobile_scanner 7.4.0 clears its polling reader's `_videoStream` reference
/// on Web but does not stop the underlying MediaStreamTrack objects. That leaves
/// the browser camera indicator active after `MobileScannerController.stop()`.
///
/// We deliberately do not stop every camera stream on the page: an authenticated
/// user can open QR login while a LiveKit call exists. Instead, [begin] snapshots
/// streams that already existed, [capture] claims the single new stream created
/// by scanner start, and [release] stops just that stream's tracks. There is no
/// global camera shutdown and no dependency on private mobile_scanner DOM IDs.
/// Remove this bridge once mobile_scanner itself releases polling-reader tracks.
class OrexQrScannerCameraLease {
  OrexQrScannerCameraLease();

  final List<web.MediaStream> _baselineStreams = <web.MediaStream>[];
  web.MediaStream? _scannerStream;
  web.HTMLVideoElement? _scannerVideo;
  bool _armed = false;

  void begin() {
    _baselineStreams
      ..clear()
      ..addAll(_attachedStreams());
    _scannerStream = null;
    _scannerVideo = null;
    _armed = true;
  }

  Future<void> capture() async {
    if (!_armed || _scannerStream != null) return;

    // The platform view can be inserted one frame after controller.start().
    // Keep the wait bounded: this runs on lifecycle transitions, never polling.
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_captureNow()) return;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> release() async {
    if (!_armed) return;
    await capture();

    final video = _scannerVideo;
    final stream = _scannerStream;
    if (video != null) {
      try {
        video.pause();
        if (stream != null && _sameStream(video.srcObject, stream)) {
          video.srcObject = null;
        }
      } catch (_) {
        // Track.stop() below is the authoritative release operation.
      }
    }
    if (stream != null) {
      for (final track in stream.getTracks().toDart) {
        try {
          track.stop();
        } catch (_) {
          // A track can already be ended by the browser/plugin.
        }
      }
    }

    _reset();
  }

  /// Drops ownership bookkeeping without touching any browser media.
  /// Used when scanner start itself fails, where claiming an unrelated stream
  /// would be worse than relying on the plugin/browser failure cleanup.
  void abort() => _reset();

  void _reset() {
    _baselineStreams.clear();
    _scannerStream = null;
    _scannerVideo = null;
    _armed = false;
  }

  bool _captureNow() {
    final candidates = <({
      web.HTMLVideoElement video,
      web.MediaStream stream,
    })>[];
    final videos = web.document.querySelectorAll('video');
    for (var index = 0; index < videos.length; index++) {
      final video = videos.item(index) as web.HTMLVideoElement?;
      if (video == null) continue;
      final source = video.srcObject;
      if (source == null || !source.instanceOfString('MediaStream')) continue;
      final stream = source as web.MediaStream;
      if (_baselineStreams.any((known) => _sameStream(known, stream))) continue;
      if (candidates.any((item) => _sameStream(item.stream, stream))) continue;
      candidates.add((video: video, stream: stream));
    }

    // Ownership is intentionally fail-closed. Normally controller.start() adds
    // exactly one new MediaStream. If some unrelated WebRTC stream appeared in
    // the same tiny window, do not guess and risk stopping call media.
    if (candidates.length != 1) return false;
    _scannerVideo = candidates.single.video;
    _scannerStream = candidates.single.stream;
    return true;
  }

  List<web.MediaStream> _attachedStreams() {
    final result = <web.MediaStream>[];
    final videos = web.document.querySelectorAll('video');
    for (var index = 0; index < videos.length; index++) {
      final video = videos.item(index) as web.HTMLVideoElement?;
      final source = video?.srcObject;
      if (source == null || !source.instanceOfString('MediaStream')) continue;
      final stream = source as web.MediaStream;
      if (!result.any((known) => _sameStream(known, stream))) {
        result.add(stream);
      }
    }
    return result;
  }

  bool _sameStream(JSAny? left, web.MediaStream right) {
    if (left == null) return false;
    return left.strictEquals(right).toDart;
  }
}
