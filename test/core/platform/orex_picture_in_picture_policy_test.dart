import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/platform/orex_picture_in_picture_policy.dart';

void main() {
  group('orexShouldRebindWebPictureInPictureTrack', () {
    const track = _TrackToken();

    test('keeps a healthy renderer bound to the unchanged media track', () {
      expect(
        orexShouldRebindWebPictureInPictureTrack(
          trackUnavailable: false,
          activeTrack: track,
          candidateTrack: track,
          boundMediaTrackId: 'camera-A',
          candidateMediaTrackId: 'camera-A',
        ),
        isFalse,
      );
    });

    test(
      'rebinds after media disappeared even when LiveKit track is identical',
      () {
        expect(
          orexShouldRebindWebPictureInPictureTrack(
            trackUnavailable: true,
            activeTrack: track,
            candidateTrack: track,
            boundMediaTrackId: 'camera-A',
            candidateMediaTrackId: 'camera-A',
          ),
          isTrue,
        );
      },
    );

    test(
      'rebinds when camera switching replaces MediaStreamTrack in place',
      () {
        expect(
          orexShouldRebindWebPictureInPictureTrack(
            trackUnavailable: false,
            activeTrack: track,
            candidateTrack: track,
            boundMediaTrackId: 'camera-A',
            candidateMediaTrackId: 'camera-B',
          ),
          isTrue,
        );
      },
    );

    test('rebinds when LiveKit selects a different video track object', () {
      expect(
        orexShouldRebindWebPictureInPictureTrack(
          trackUnavailable: false,
          activeTrack: track,
          candidateTrack: const _OtherTrackToken(),
          boundMediaTrackId: 'camera-A',
          candidateMediaTrackId: 'camera-A',
        ),
        isTrue,
      );
    });
  });
}

final class _TrackToken {
  const _TrackToken();
}

final class _OtherTrackToken {
  const _OtherTrackToken();
}
