import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:multiview_desktop/multiview_desktop.dart';

import 'orex_web_picture_in_picture.dart';

/// Owns one real system-level Picture-in-Picture surface.
///
/// * Web: browser video PiP.
/// * Android: Android Activity Picture-in-Picture.
/// * Windows: a separate always-on-top OS window sharing the same Flutter
///   engine/isolate, so the existing LiveKit [lk.VideoTrack] is reused directly.
///
/// This object never owns call controls or call lifecycle. It only mirrors the
/// selected video/screen-share track.
class OrexSystemPictureInPicture extends ChangeNotifier {
  OrexSystemPictureInPicture._() {
    _androidChannel.setMethodCallHandler(_handleAndroidMethodCall);
  }

  static final OrexSystemPictureInPicture instance =
      OrexSystemPictureInPicture._();

  static const MethodChannel _androidChannel = MethodChannel(
    'orex/picture_in_picture',
  );

  String? _activeIdentity;
  lk.VideoTrack? _activeTrack;
  int? _desktopViewId;
  bool _androidSurfaceVisible = false;
  bool _opening = false;
  double? _renderedAspectRatio;

  String? get activeIdentity => _activeIdentity;
  lk.VideoTrack? get activeTrack => _activeTrack;
  bool get isOpening => _opening;

  bool get shouldRenderAndroidSurface =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      _androidSurfaceVisible &&
      _activeTrack != null;

  bool isActiveFor(String identity) => _activeIdentity == identity;

  bool get canOffer {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.windows;
  }

  Future<void> toggle({
    required String identity,
    required lk.VideoTrack track,
    lk.VideoDimensions? dimensions,
  }) async {
    if (_opening) return;
    if (_activeIdentity == identity) {
      await close();
      return;
    }

    _opening = true;
    notifyListeners();
    try {
      if (kIsWeb) {
        final trackId = track.mediaStreamTrack.id;
        if (trackId == null || trackId.isEmpty) return;
        final opened = await orexOpenWebPictureInPicture(
          trackId,
          onClosed: _handleExternalClosed,
        );
        if (!opened) return;
        _setActive(identity, track);
        return;
      }

      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          await _openAndroid(identity, track, dimensions);
          return;
        case TargetPlatform.windows:
          await _openWindows(identity, track, dimensions);
          return;
        case TargetPlatform.iOS:
        case TargetPlatform.macOS:
        case TargetPlatform.linux:
        case TargetPlatform.fuchsia:
          return;
      }
    } finally {
      _opening = false;
      notifyListeners();
    }
  }

  /// Keeps the native PiP on the same participant when the user explicitly
  /// switches that participant between camera and screen share.
  Future<void> updateTrack({
    required String identity,
    required lk.VideoTrack track,
    lk.VideoDimensions? dimensions,
  }) async {
    if (_activeIdentity != identity || identical(_activeTrack, track)) return;

    // Browser video PiP is bound to an HTMLVideoElement. Re-requesting PiP for
    // another element is intentionally left to the next explicit PiP click so
    // the browser's transient-user-activation requirement is never bypassed.
    if (kIsWeb) return;

    _activeTrack = track;
    _renderedAspectRatio = null;
    notifyListeners();
    await _updateNativeAspectRatio(_videoAspectRatio(dimensions));
  }

  Future<void> close() async {
    final desktopViewId = _desktopViewId;
    _desktopViewId = null;

    if (kIsWeb) {
      await orexCloseWebPictureInPicture();
    } else if (defaultTargetPlatform == TargetPlatform.windows &&
        desktopViewId != null) {
      try {
        await MultiViewDesktop.fromId(desktopViewId).closeWindow();
      } catch (_) {
        // The native close button may already have destroyed the window.
      }
    }

    _clearActive();
  }

  Future<void> _openAndroid(
    String identity,
    lk.VideoTrack track,
    lk.VideoDimensions? dimensions,
  ) async {
    bool supported = false;
    try {
      supported =
          await _androidChannel.invokeMethod<bool>('isSupported') ?? false;
    } catch (_) {
      supported = false;
    }
    if (!supported) return;

    _setActive(identity, track);
    _androidSurfaceVisible = true;
    notifyListeners();

    // The selected media must be painted before Android snapshots the Activity
    // into its system PiP surface. The renderer may already know the real
    // decoded-frame ratio by the end of this frame; if not, PiP opens with the
    // metadata hint and is corrected as soon as the first frame reports size.
    await WidgetsBinding.instance.endOfFrame;
    final aspectRatio =
        _renderedAspectRatio ?? _videoAspectRatio(dimensions);

    bool entered = false;
    try {
      entered =
          await _androidChannel.invokeMethod<bool>(
            'enter',
            _androidAspectArguments(aspectRatio),
          ) ??
          false;
    } catch (_) {
      entered = false;
    }
    if (!entered) _clearActive();
  }

  Future<void> _openWindows(
    String identity,
    lk.VideoTrack track,
    lk.VideoDimensions? dimensions,
  ) async {
    // Only one system PiP is useful at a time. Close the previous secondary
    // view before replacing it with another participant.
    final previousViewId = _desktopViewId;
    if (previousViewId != null) {
      try {
        await MultiViewDesktop.fromId(previousViewId).closeWindow();
      } catch (_) {}
      _desktopViewId = null;
    }

    _setActive(identity, track);
    final initialAspectRatio = _videoAspectRatio(dimensions);
    try {
      final viewId = await openWindow(
        (context, publicId) => OrexDesktopPictureInPictureWindow(
          service: this,
          viewId: publicId,
        ),
        options: WindowOptions(
          size: _desktopPipSize(initialAspectRatio, longSide: 384),
          minimumSize: _desktopPipSize(initialAspectRatio, longSide: 256),
          title: 'Orex — Picture in Picture',
          titleBarStyle: TitleBarStyle.hidden,
          windowButtonVisibility: false,
          alwaysOnTop: true,
          alignment: Alignment.bottomRight,
          backgroundColor: Colors.black,
        ),
      );
      _desktopViewId = viewId;
      final window = MultiViewDesktop.fromId(viewId);
      await _configureDesktopAspectRatio(
        window,
        _renderedAspectRatio ?? initialAspectRatio,
      );
      await window.setAlwaysOnTop(true);
      await window.setMinimizable(false);
      await window.setMaximizable(false);
      await window.hideCurrentAppTabFromTaskbar(true);
      notifyListeners();
    } catch (_) {
      _clearActive();
    }
  }

  void _reportRenderedAspectRatio(double aspectRatio) {
    if (!aspectRatio.isFinite || aspectRatio <= 0) return;

    final previous = _renderedAspectRatio;
    if (previous != null && (previous - aspectRatio).abs() < 0.002) return;

    _renderedAspectRatio = aspectRatio;
    unawaited(_updateNativeAspectRatio(aspectRatio));
  }

  Future<void> _updateNativeAspectRatio(double aspectRatio) async {
    if (kIsWeb || !aspectRatio.isFinite || aspectRatio <= 0) return;

    if (defaultTargetPlatform == TargetPlatform.android &&
        _androidSurfaceVisible) {
      try {
        await _androidChannel.invokeMethod<bool>(
          'updateAspectRatio',
          _androidAspectArguments(aspectRatio),
        );
      } catch (_) {
        // PiP may already be closing; aspect updates are best-effort only.
      }
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.windows) {
      final viewId = _desktopViewId;
      if (viewId == null) return;
      try {
        await _configureDesktopAspectRatio(
          MultiViewDesktop.fromId(viewId),
          aspectRatio,
        );
      } catch (_) {
        // The user may have closed the secondary window concurrently.
      }
    }
  }

  Future<void> _configureDesktopAspectRatio(
    MultiViewDesktop window,
    double aspectRatio,
  ) async {
    await window.setAspectRatio(aspectRatio);
    await window.setMinimumSize(
      _desktopPipSize(aspectRatio, longSide: 256),
    );
    await window.setSize(
      _desktopPipSize(aspectRatio, longSide: 384),
    );
    await window.setAlignment(Alignment.bottomRight);
  }

  Map<String, int> _androidAspectArguments(double aspectRatio) {
    final safeRatio =
        aspectRatio.isFinite && aspectRatio > 0 ? aspectRatio : 16 / 9;
    const denominator = 10000;
    return <String, int>{
      'width': (safeRatio * denominator)
          .round()
          .clamp(1, 1000000)
          .toInt(),
      'height': denominator,
    };
  }

  double _videoAspectRatio(lk.VideoDimensions? dimensions) {
    if (dimensions == null ||
        dimensions.width <= 0 ||
        dimensions.height <= 0) {
      return 16 / 9;
    }
    final ratio = dimensions.width / dimensions.height;
    return ratio.isFinite && ratio > 0 ? ratio : 16 / 9;
  }

  Size _desktopPipSize(
    double aspectRatio, {
    required double longSide,
  }) {
    return aspectRatio >= 1
        ? Size(longSide, longSide / aspectRatio)
        : Size(longSide * aspectRatio, longSide);
  }

  Future<void> _handleAndroidMethodCall(MethodCall call) async {
    if (call.method != 'onPictureInPictureModeChanged') return;
    final active = call.arguments == true;
    if (active) {
      _androidSurfaceVisible = true;
      notifyListeners();
    } else {
      _clearActive();
    }
  }

  void onDesktopWindowDisposed(int viewId) {
    if (_desktopViewId != viewId) return;
    _desktopViewId = null;
    _clearActive();
  }

  void _handleExternalClosed() {
    if (!kIsWeb) return;
    _clearActive();
  }

  void _setActive(String identity, lk.VideoTrack track) {
    _activeIdentity = identity;
    _activeTrack = track;
    _renderedAspectRatio = null;
    notifyListeners();
  }

  void _clearActive() {
    final changed = _activeIdentity != null ||
        _activeTrack != null ||
        _androidSurfaceVisible;
    _activeIdentity = null;
    _activeTrack = null;
    _androidSurfaceVisible = false;
    _renderedAspectRatio = null;
    if (changed) notifyListeners();
  }
}

/// Full-activity media surface used only while Android is entering/in system
/// PiP. There are deliberately no Orex call controls here.
class OrexAndroidPictureInPictureSurface extends StatelessWidget {
  const OrexAndroidPictureInPictureSurface({super.key});

  @override
  Widget build(BuildContext context) {
    final service = OrexSystemPictureInPicture.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final track = service.activeTrack;
        if (!service.shouldRenderAndroidSurface || track == null) {
          return const SizedBox.shrink();
        }
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: _OrexMeasuredPictureInPictureVideo(
              key: ObjectKey(track),
              track: track,
              onAspectRatioChanged: service._reportRenderedAspectRatio,
            ),
          ),
        );
      },
    );
  }
}

/// Renders the PiP track through a caller-owned WebRTC renderer so Orex can
/// observe the geometry of the frame that is actually decoded on this device.
/// Publication/capture metadata is only a startup hint and may stay 16:9 for a
/// portrait stream.
class _OrexMeasuredPictureInPictureVideo extends StatefulWidget {
  const _OrexMeasuredPictureInPictureVideo({
    super.key,
    required this.track,
    required this.onAspectRatioChanged,
  });

  final lk.VideoTrack track;
  final ValueChanged<double> onAspectRatioChanged;

  @override
  State<_OrexMeasuredPictureInPictureVideo> createState() =>
      _OrexMeasuredPictureInPictureVideoState();
}

class _OrexMeasuredPictureInPictureVideoState
    extends State<_OrexMeasuredPictureInPictureVideo> {
  rtc.RTCVideoRenderer? _renderer;
  double? _lastReportedAspectRatio;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeRenderer());
  }

  Future<void> _initializeRenderer() async {
    final renderer = rtc.RTCVideoRenderer();
    try {
      await renderer.initialize();
    } catch (_) {
      await renderer.dispose();
      return;
    }

    if (!mounted) {
      await renderer.dispose();
      return;
    }

    renderer.addListener(_onRendererChanged);
    setState(() => _renderer = renderer);
    _onRendererChanged();
  }

  void _onRendererChanged() {
    final renderer = _renderer;
    if (renderer == null) return;

    final value = renderer.value;
    if (value.width <= 0 || value.height <= 0) return;

    // RTCVideoValue.aspectRatio accounts for 90/270 degree frame rotation,
    // unlike MediaStreamTrack.getSettings()/publication metadata.
    final aspectRatio = value.aspectRatio;
    if (!aspectRatio.isFinite || aspectRatio <= 0) return;

    final previous = _lastReportedAspectRatio;
    if (previous != null && (previous - aspectRatio).abs() < 0.002) return;
    _lastReportedAspectRatio = aspectRatio;
    widget.onAspectRatioChanged(aspectRatio);
  }

  @override
  void dispose() {
    final renderer = _renderer;
    if (renderer != null) {
      renderer.removeListener(_onRendererChanged);
      renderer.onResize = null;
      try {
        renderer.srcObject = null;
      } catch (_) {}
      unawaited(renderer.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    if (renderer == null) return const SizedBox.shrink();

    return lk.VideoTrackRenderer(
      widget.track,
      fit: lk.VideoViewFit.contain,
      cachedRenderer: renderer,
      autoDisposeRenderer: false,
    );
  }
}

/// Content of the separate Windows always-on-top OS window.
/// The whole media surface is a native drag area; the close button is window
/// chrome, not a call control.
class OrexDesktopPictureInPictureWindow extends StatefulWidget {
  const OrexDesktopPictureInPictureWindow({
    super.key,
    required this.service,
    required this.viewId,
  });

  final OrexSystemPictureInPicture service;
  final int viewId;

  @override
  State<OrexDesktopPictureInPictureWindow> createState() =>
      _OrexDesktopPictureInPictureWindowState();
}

class _OrexDesktopPictureInPictureWindowState
    extends State<OrexDesktopPictureInPictureWindow> {
  @override
  void dispose() {
    widget.service.onDesktopWindowDisposed(widget.viewId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black,
      child: ListenableBuilder(
        listenable: widget.service,
        builder: (context, _) {
          final track = widget.service.activeTrack;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (track != null)
                _OrexMeasuredPictureInPictureVideo(
                  key: ObjectKey(track),
                  track: track,
                  onAspectRatioChanged:
                      widget.service._reportRenderedAspectRatio,
                ),
              const Positioned.fill(
                child: DragToMoveArea(child: SizedBox.expand()),
              ),
              Positioned(
                right: 4,
                top: 2,
                child: IconButton(
                  tooltip: 'Закрыть PiP',
                  mouseCursor: SystemMouseCursors.click,
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  color: Colors.white,
                  onPressed: () => unawaited(
                    MultiViewDesktop.of(context).closeWindow(),
                  ),
                  icon: const Icon(Icons.close),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
