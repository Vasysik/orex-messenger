import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../core/matrix/matrix_service.dart';
import '../../core/voip/livekit_track_access.dart';
import '../../shared/theme/orex_theme.dart';

double orexAudioLevelToDb(double level) {
  if (level.isNaN || level.isInfinite || level <= 0) return -100;
  return (20 * math.log(level) / math.ln10).clamp(-100.0, 0.0).toDouble();
}

bool orexParticipantVoiceActive(
  lk.Participant participant,
  MatrixService matrix, {
  double? levelDb,
}) {
  if (!participant.isSpeaking) return false;
  if (!matrix.audio.speakingThresholdEnabled) return true;
  final db = levelDb ?? orexAudioLevelToDb(participant.audioLevel);
  return db >= matrix.audio.speakingThresholdDb;
}

lk.VideoTrack? orexSelectVideoTrack(
  lk.Participant participant, {
  required bool preferScreenShare,
}) {
  lk.VideoTrack? camera;
  lk.VideoTrack? screen;
  lk.VideoTrack? fallback;

  for (final pub in participant.videoTrackPublications) {
    if (pub.track == null || !pub.subscribed || pub.muted) continue;
    final track = pub.track;
    if (track is! lk.VideoTrack) continue;
    fallback ??= track;
    if (pub.source == lk.TrackSource.screenShareVideo) {
      screen ??= track;
    } else if (pub.source == lk.TrackSource.camera) {
      camera ??= track;
    }
  }

  return preferScreenShare
      ? (screen ?? camera ?? fallback)
      : (camera ?? screen ?? fallback);
}

lk.VideoDimensions? orexVideoDimensionsForTrack(
  lk.Participant participant,
  lk.VideoTrack track,
) {
  for (final pub in participant.videoTrackPublications) {
    if (!identical(pub.track, track) && pub.track != track) continue;
    final dimensions = pub.dimensions;
    if (dimensions == null ||
        dimensions.width <= 0 ||
        dimensions.height <= 0) {
      return null;
    }
    return dimensions;
  }
  return null;
}

bool orexHasCameraAndScreen(lk.Participant participant) {
  var hasCamera = false;
  var hasScreen = false;

  for (final pub in participant.videoTrackPublications) {
    if (pub.track == null || !pub.subscribed || pub.muted) continue;
    if (pub.track is! lk.VideoTrack) continue;
    if (pub.source == lk.TrackSource.screenShareVideo) {
      hasScreen = true;
    } else if (pub.source == lk.TrackSource.camera) {
      hasCamera = true;
    }
    if (hasCamera && hasScreen) return true;
  }

  return false;
}

class OrexSpeakingFrame extends StatefulWidget {
  const OrexSpeakingFrame({
    super.key,
    required this.participant,
    required this.matrix,
    required this.child,
    this.borderRadius = 20,
    this.activePadding = 2,
    this.inactivePadding = 1,
    this.activeBlur = 18,
    this.preserveChildSize = false,
  });

  final lk.Participant participant;
  final MatrixService matrix;
  final Widget child;
  final double borderRadius;
  final double activePadding;
  final double inactivePadding;
  final double activeBlur;
  final bool preserveChildSize;

  @override
  State<OrexSpeakingFrame> createState() => _OrexSpeakingFrameState();
}

class _OrexSpeakingFrameState extends State<OrexSpeakingFrame>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _active = false;
  double _levelDb = -100;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncSamplingForLifecycle(
      WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
  }

  void _syncSamplingForLifecycle(AppLifecycleState state) {
    _timer?.cancel();
    _timer = null;
    if (state != AppLifecycleState.resumed) return;
    _sample();
    _timer = Timer.periodic(const Duration(milliseconds: 35), (_) => _sample());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncSamplingForLifecycle(state);
  }

  @override
  void didUpdateWidget(covariant OrexSpeakingFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.participant != widget.participant ||
        oldWidget.matrix != widget.matrix) {
      _sample();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  void _sample() {
    if (!mounted) return;
    final db = orexAudioLevelToDb(widget.participant.audioLevel);
    final active = orexParticipantVoiceActive(
      widget.participant,
      widget.matrix,
      levelDb: db,
    );
    if (active == _active && (db - _levelDb).abs() < 1.5) return;
    setState(() {
      _active = active;
      _levelDb = db;
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      border: Border.all(
        color: active
            ? OrexColors.copper.withValues(alpha: 0.95)
            : Colors.white.withValues(alpha: 0.08),
        width: active ? 2 : 1,
      ),
      boxShadow: active
          ? [
              BoxShadow(
                color: OrexColors.copper.withValues(alpha: 0.28),
                blurRadius: widget.activeBlur,
                spreadRadius: 1,
              ),
            ]
          : null,
    );

    if (widget.preserveChildSize) {
      final borderDecoration = BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(
          color: active
              ? OrexColors.copper.withValues(alpha: 0.95)
              : Colors.white.withValues(alpha: 0.08),
          width: active ? 2 : 1,
        ),
      );

      // Keep media itself completely untouched. A blurred copper shadow around
      // a Texture/Surface-backed video can be composited over the decoded frame
      // on some platforms and appears as an orange wash along the top edge.
      // Media tiles therefore use the same active border without blur; the
      // avatar-only path below keeps the existing glow animation.
      return Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 35),
                curve: Curves.linear,
                decoration: borderDecoration,
              ),
            ),
          ),
        ],
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 35),
      curve: Curves.linear,
      padding: EdgeInsets.all(
        active ? widget.activePadding : widget.inactivePadding,
      ),
      decoration: decoration,
      child: widget.child,
    );
  }
}

bool orexParticipantMicMuted(lk.Participant participant) {
  return OrexLiveKitTrackAccess.participantMicrophoneMuted(participant);
}
