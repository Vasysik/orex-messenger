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
  });

  final lk.Participant participant;
  final MatrixService matrix;
  final Widget child;
  final double borderRadius;
  final double activePadding;
  final double inactivePadding;
  final double activeBlur;

  @override
  State<OrexSpeakingFrame> createState() => _OrexSpeakingFrameState();
}

class _OrexSpeakingFrameState extends State<OrexSpeakingFrame> {
  Timer? _timer;
  bool _active = false;
  double _levelDb = -100;

  @override
  void initState() {
    super.initState();
    _sample();
    _timer = Timer.periodic(const Duration(milliseconds: 35), (_) => _sample());
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 35),
      curve: Curves.linear,
      padding: EdgeInsets.all(active ? widget.activePadding : widget.inactivePadding),
      decoration: BoxDecoration(
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
      ),
      child: widget.child,
    );
  }
}

bool orexParticipantMicMuted(lk.Participant participant) {
  return OrexLiveKitTrackAccess.participantMicrophoneMuted(participant);
}
