import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:orex_messenger/core/voip/livekit_track_access.dart';

void main() {
  group('OrexLiveKitTrackAccess', () {
    test('iterates values from maps and iterables', () {
      expect(OrexLiveKitTrackAccess.dynamicValues({'a': 1, 'b': 2}), [1, 2]);
      expect(OrexLiveKitTrackAccess.dynamicValues([3, 4]), [3, 4]);
      expect(OrexLiveKitTrackAccess.dynamicValues(null), isEmpty);
    });

    test('sets direct media track enabled state', () {
      final track = _Track(enabled: false);

      final changed = OrexLiveKitTrackAccess.setMediaTrackEnabled(track, true);

      expect(changed, isTrue);
      expect(track.enabled, isTrue);
    });

    test('sets nested publication track enabled state', () {
      final track = _Track(enabled: true);
      final publication = _Publication(track: track);

      final changed = OrexLiveKitTrackAccess.setMediaTrackEnabled(
        publication,
        false,
      );

      expect(changed, isTrue);
      expect(track.enabled, isFalse);
    });

    test('sets all audio tracks from media stream fallback', () {
      final first = _Track(enabled: true);
      final second = _Track(enabled: true);
      final publication = _Publication(
        mediaStream: _MediaStream([first, second]),
      );

      final changed = OrexLiveKitTrackAccess.setMediaTrackEnabled(
        publication,
        false,
      );

      expect(changed, isTrue);
      expect(first.enabled, isFalse);
      expect(second.enabled, isFalse);
    });


    test('uses LiveKit remote publication enable and disable methods', () async {
      final publication = _RemotePublication();

      expect(
        await OrexLiveKitTrackAccess.setRemotePublicationEnabled(
          publication,
          false,
        ),
        isTrue,
      );
      expect(publication.disableCalls, 1);
      expect(publication.enabled, isFalse);

      expect(
        await OrexLiveKitTrackAccess.setRemotePublicationEnabled(
          publication,
          true,
        ),
        isTrue,
      );
      expect(publication.enableCalls, 1);
      expect(publication.enabled, isTrue);
    });

    test('readDynamic returns null for throwing getters', () {
      expect(
        OrexLiveKitTrackAccess.readDynamic(_ThrowingTrack(), 'track'),
        isNull,
      );
    });

    test('reads microphone enabled state when LiveKit exposes it', () {
      expect(
        OrexLiveKitTrackAccess.readMicrophoneEnabled(
          _Participant(microphoneEnabled: true),
        ),
        isTrue,
      );
      expect(
        OrexLiveKitTrackAccess.readMicrophoneEnabled(
          _Participant(microphoneEnabled: false),
        ),
        isFalse,
      );
    });

    test('derives muted microphone state from publications', () {
      expect(
        OrexLiveKitTrackAccess.microphoneMutedFromPublications([
          _TrackPublication(
            source: null,
            muted: false,
            subscribed: true,
            track: _Track(enabled: true),
          ),
        ]),
        isTrue,
      );
      expect(
        OrexLiveKitTrackAccess.microphoneMutedFromPublications([
          _TrackPublication(
            source: lk.TrackSource.microphone,
            muted: false,
            subscribed: true,
            track: _Track(enabled: true),
          ),
        ]),
        isFalse,
      );
      expect(
        OrexLiveKitTrackAccess.microphoneMutedFromPublications([
          _TrackPublication(
            source: lk.TrackSource.microphone,
            muted: true,
            subscribed: true,
            track: _Track(enabled: true),
          ),
        ]),
        isTrue,
      );
    });
  });
}

final class _Track {
  _Track({required this.enabled});

  bool enabled;
}

final class _Publication {
  _Publication({this.track, this.mediaStream});

  final dynamic track;
  final dynamic mediaStream;
}

final class _MediaStream {
  _MediaStream(this._tracks);

  final List<dynamic> _tracks;

  List<dynamic> getAudioTracks() => _tracks;
}

final class _ThrowingTrack {
  dynamic get track => throw StateError('unavailable');
}

final class _Participant {
  _Participant({required this.microphoneEnabled});

  final bool microphoneEnabled;

  bool isMicrophoneEnabled() => microphoneEnabled;
}

final class _TrackPublication {
  _TrackPublication({
    required this.source,
    required this.muted,
    required this.subscribed,
    required this.track,
  });

  final dynamic source;
  final bool muted;
  final bool subscribed;
  final dynamic track;
}

final class _RemotePublication {
  bool enabled = true;
  int enableCalls = 0;
  int disableCalls = 0;

  Future<void> enable() async {
    enableCalls++;
    enabled = true;
  }

  Future<void> disable() async {
    disableCalls++;
    enabled = false;
  }
}
