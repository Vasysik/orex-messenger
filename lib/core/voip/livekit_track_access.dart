import 'package:livekit_client/livekit_client.dart' as lk;

final class OrexLiveKitTrackAccess {
  const OrexLiveKitTrackAccess._();

  static bool setLocalMicrophoneTrackEnabled(
    lk.LocalParticipant? participant,
    bool enabled,
  ) {
    final pub = localMicrophonePublication(participant);
    final track = pub == null ? null : readDynamic(pub, 'track');
    return setMediaTrackEnabled(track, enabled) ||
        setMediaTrackEnabled(pub, enabled);
  }

  static dynamic localMicrophonePublication(lk.LocalParticipant? participant) {
    if (participant == null) return null;
    try {
      final dynamic dynamicParticipant = participant;
      final pub = dynamicParticipant.getTrackPublicationBySource(
        lk.TrackSource.microphone,
      );
      if (pub != null) return pub;
    } catch (_) {}
    try {
      final dynamic dynamicParticipant = participant;
      for (final dynamic pub in dynamicValues(
        dynamicParticipant.audioTrackPublications,
      )) {
        if (readDynamic(pub, 'source') == lk.TrackSource.microphone) {
          return pub;
        }
      }
    } catch (_) {}
    try {
      final dynamic dynamicParticipant = participant;
      for (final dynamic pub in dynamicValues(
        dynamicParticipant.trackPublications,
      )) {
        if (readDynamic(pub, 'source') == lk.TrackSource.microphone) {
          return pub;
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> setParticipantAudioEnabled(
    lk.Participant participant,
    bool enabled,
  ) async {
    var changed = false;
    final seen = <Object>{};
    try {
      final dynamic dynamicParticipant = participant;
      for (final dynamic pub in dynamicValues(
        dynamicParticipant.audioTrackPublications,
      )) {
        if (pub is Object && !seen.add(pub)) continue;
        changed = await setRemotePublicationEnabled(pub, enabled) || changed;
      }
    } catch (_) {}
    try {
      final dynamic dynamicParticipant = participant;
      for (final dynamic pub in dynamicValues(
        dynamicParticipant.trackPublications,
      )) {
        if (readDynamic(pub, 'source') == lk.TrackSource.microphone) {
          if (pub is Object && !seen.add(pub)) continue;
          changed = await setRemotePublicationEnabled(pub, enabled) || changed;
        }
      }
    } catch (_) {}
    return changed;
  }

  static Future<bool> setRemotePublicationEnabled(
    dynamic publication,
    bool enabled,
  ) async {
    if (publication == null) return false;
    try {
      final dynamic result = enabled
          ? publication.enable()
          : publication.disable();
      if (result is Future) {
        await result.timeout(const Duration(seconds: 4));
      }
      return true;
    } catch (_) {
      return setMediaTrackEnabled(publication, enabled);
    }
  }

  static bool participantMicrophoneMuted(lk.Participant participant) {
    final enabled = readMicrophoneEnabled(participant);
    if (enabled != null) return !enabled;
    return microphoneMutedFromPublications(participant.audioTrackPublications);
  }

  static bool? readMicrophoneEnabled(dynamic participant) {
    try {
      final enabled = participant.isMicrophoneEnabled();
      if (enabled is bool) return enabled;
    } catch (_) {}
    return null;
  }

  static bool microphoneMutedFromPublications(
    Iterable<dynamic> publications,
  ) {
    var sawMic = false;
    for (final pub in publications) {
      if (readDynamic(pub, 'source') != lk.TrackSource.microphone) continue;
      sawMic = true;
      if (readDynamic(pub, 'muted') == true) return true;
      if (readDynamic(pub, 'subscribed') == false ||
          readDynamic(pub, 'track') == null) {
        return true;
      }
    }
    return !sawMic;
  }

  static Iterable<dynamic> localVideoPublications(
    lk.LocalParticipant participant,
  ) sync* {
    final dynamic dynamicParticipant = participant;
    try {
      yield* dynamicValues(dynamicParticipant.videoTrackPublications);
    } catch (_) {}
    try {
      yield* dynamicValues(dynamicParticipant.trackPublications);
    } catch (_) {}
  }

  static Iterable<dynamic> dynamicValues(dynamic value) sync* {
    if (value == null) return;
    if (value is Map) {
      yield* value.values;
      return;
    }
    if (value is Iterable) yield* value;
  }

  static bool setMediaTrackEnabled(dynamic candidate, bool enabled) {
    if (candidate == null) return false;
    if (trySetEnabled(candidate, enabled)) return true;

    for (final getter in const [
      'mediaStreamTrack',
      'rtcTrack',
      'track',
      'senderTrack',
    ]) {
      final nested = readDynamic(candidate, getter);
      if (trySetEnabled(nested, enabled)) return true;
    }

    for (final getter in const ['mediaStream', 'stream']) {
      final mediaStream = readDynamic(candidate, getter);
      if (setAudioTracksEnabled(mediaStream, enabled)) return true;
    }

    return false;
  }

  static bool trySetEnabled(dynamic candidate, bool enabled) {
    if (candidate == null) return false;
    try {
      candidate.enabled = enabled;
      return true;
    } catch (_) {
      return false;
    }
  }

  static bool setAudioTracksEnabled(dynamic mediaStream, bool enabled) {
    if (mediaStream == null) return false;
    try {
      final tracks = mediaStream.getAudioTracks() as List<dynamic>;
      var changed = false;
      for (final rawTrack in tracks) {
        if (trySetEnabled(rawTrack, enabled)) changed = true;
      }
      return changed;
    } catch (_) {
      return false;
    }
  }

  static dynamic readDynamic(dynamic object, String getterName) {
    if (object == null) return null;
    try {
      return switch (getterName) {
        'track' => object.track,
        'source' => object.source,
        'mediaStream' => object.mediaStream,
        'stream' => object.stream,
        'mediaStreamTrack' => object.mediaStreamTrack,
        'rtcTrack' => object.rtcTrack,
        'senderTrack' => object.senderTrack,
        'muted' => object.muted,
        'subscribed' => object.subscribed,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }
}
