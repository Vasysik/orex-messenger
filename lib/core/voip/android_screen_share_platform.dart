import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
// flutter_webrtc 1.5.2 exposes one process-wide broadcast stream here. Orex's
// Android source overlay emits onScreenCaptureStopped into that existing stream
// rather than opening a competing EventChannel subscription.
import 'package:flutter_webrtc/src/native/event_channel.dart'
    show FlutterWebRTCEventChannel;

import '../logging/orex_logger.dart';

typedef OrexAndroidScreenShareStopHandler =
    FutureOr<void> Function(String reason);

/// Android-only ownership around flutter_webrtc's MediaProjection capture.
///
/// The order is intentional and required on Android 14+: system consent first,
/// then the mediaProjection foreground service, then LiveKit/getDisplayMedia.
final class OrexAndroidScreenSharePlatform {
  OrexAndroidScreenSharePlatform._();

  static const MethodChannel _channel = MethodChannel('orex/screen_share');
  static const Duration _foregroundReadyTimeout = Duration(seconds: 4);
  static const Duration _foregroundReadyPoll = Duration(milliseconds: 50);

  static StreamSubscription<Map<String, dynamic>>? _captureEvents;
  static OrexAndroidScreenShareStopHandler? _stopHandler;
  static String? _activeTrackId;
  static bool _stopRequestInFlight = false;
  static bool _methodHandlerInstalled = false;

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static void setStopHandler(OrexAndroidScreenShareStopHandler handler) {
    if (!isAndroid) return;
    _stopHandler = handler;
    _installMethodHandler();
    _listenForCaptureStop();
  }

  static void clearStopHandler(OrexAndroidScreenShareStopHandler handler) {
    if (!identical(_stopHandler, handler)) return;
    _stopHandler = null;
  }

  static Future<bool> requestCapturePermission() async {
    if (!isAndroid) return true;
    try {
      // Android 14's full-display configuration deliberately avoids an
      // ambiguous per-app share that can end when the user changes tasks.
      return await rtc.Helper.requestCapturePermission(fullScreenOnly: true);
    } on PlatformException catch (e) {
      OrexLog.d(
        'ScreenShare',
        'MediaProjection permission request failed ${e.code}',
      );
      return false;
    } catch (e) {
      OrexLog.d('ScreenShare', 'MediaProjection permission request failed', e);
      return false;
    }
  }

  static Future<bool> startForeground() async {
    if (!isAndroid) return true;
    try {
      final started =
          await _channel.invokeMethod<bool>('startForeground') ?? false;
      if (!started) return false;
      final deadline = DateTime.now().add(_foregroundReadyTimeout);
      while (DateTime.now().isBefore(deadline)) {
        final ready =
            await _channel.invokeMethod<bool>('isForegroundReady') ?? false;
        if (ready) return true;
        await Future<void>.delayed(_foregroundReadyPoll);
      }
      OrexLog.d(
        'ScreenShare',
        'mediaProjection foreground acknowledgement timed out',
      );
    } on MissingPluginException {
      OrexLog.d('ScreenShare', 'mediaProjection native bridge is unavailable');
    } on PlatformException catch (e) {
      OrexLog.d(
        'ScreenShare',
        'mediaProjection foreground start failed ${e.code}',
      );
    } catch (e) {
      OrexLog.d('ScreenShare', 'mediaProjection foreground start failed', e);
    }
    await stopForeground();
    return false;
  }

  static Future<void> stopForeground() async {
    if (!isAndroid) return;
    _activeTrackId = null;
    try {
      await _channel.invokeMethod<bool>('stopForeground');
    } on MissingPluginException {
      // Safe when tests/desktop have no Android implementation.
    } on PlatformException catch (e) {
      OrexLog.d(
        'ScreenShare',
        'mediaProjection foreground stop failed ${e.code}',
      );
    } catch (e) {
      OrexLog.d('ScreenShare', 'mediaProjection foreground stop failed', e);
    }
  }

  /// Starts matching patched flutter_webrtc revoke events to this capture.
  static void trackProjection(String trackId) {
    if (!isAndroid || trackId.trim().isEmpty) return;
    _activeTrackId = trackId.trim();
    _listenForCaptureStop();
  }

  /// Arms notification/system Stop handling during the small gap between
  /// foreground readiness and creation of the WebRTC video track.
  static void armStopHandling() {
    if (!isAndroid) return;
    _activeTrackId = 'pending';
    _listenForCaptureStop();
  }

  static void clearTrackedProjection() {
    _activeTrackId = null;
  }

  static void _installMethodHandler() {
    if (_methodHandlerInstalled) return;
    _methodHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'screenShareStopRequested') return false;
      final raw = call.arguments;
      final reason = raw is Map ? raw['reason']?.toString() : null;
      await _requestStop(
        reason?.trim().isNotEmpty == true ? reason!.trim() : 'system',
      );
      return true;
    });
  }

  static void _listenForCaptureStop() {
    if (_captureEvents != null) return;
    _captureEvents = FlutterWebRTCEventChannel.instance.handleEvents.stream
        .listen(
          (event) {
            if (!event.containsKey('onScreenCaptureStopped')) return;
            unawaited(_requestStop('projection_revoked'));
          },
          onError: (Object error, StackTrace stackTrace) {
            OrexLog.d(
              'ScreenShare',
              'flutter_webrtc capture-event stream failed',
              error,
            );
          },
        );
  }

  static Future<void> _requestStop(String reason) async {
    if (_activeTrackId == null || _stopRequestInFlight) return;
    final handler = _stopHandler;
    if (handler == null) return;
    _stopRequestInFlight = true;
    try {
      OrexLog.d(
        'ScreenShare',
        'system requested Android screen-share stop reason=$reason',
      );
      await handler(reason);
    } catch (e) {
      OrexLog.d('ScreenShare', 'system screen-share stop handler failed', e);
    } finally {
      _stopRequestInFlight = false;
    }
  }
}
