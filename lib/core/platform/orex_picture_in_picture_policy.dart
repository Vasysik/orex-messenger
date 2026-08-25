/// Returns whether Web PiP must rebind its dedicated RTCVideoRenderer.
///
/// LiveKit can keep the same VideoTrack object while flutter_webrtc replaces
/// the underlying MediaStreamTrack (camera switch), and a mute/resume cycle can
/// leave the renderer bound to a stale internal stream. Object identity alone
/// is therefore not a sufficient lifetime signal on Web.
bool orexShouldRebindWebPictureInPictureTrack({
  required bool trackUnavailable,
  required Object? activeTrack,
  required Object candidateTrack,
  required String? boundMediaTrackId,
  required String? candidateMediaTrackId,
}) {
  final mediaTrackChanged = candidateMediaTrackId != null &&
      candidateMediaTrackId != boundMediaTrackId;
  return trackUnavailable ||
      !identical(activeTrack, candidateTrack) ||
      mediaTrackChanged;
}
