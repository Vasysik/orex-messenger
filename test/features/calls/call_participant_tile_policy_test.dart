import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:orex_messenger/features/calls/call_participant_tile.dart';

void main() {
  group('orexShouldOwnAndroidCameraZoom', () {
    test('owns pinch zoom only for a local Android camera track', () {
      expect(
        orexShouldOwnAndroidCameraZoom(
          isWeb: false,
          platform: TargetPlatform.android,
          isLocalParticipant: true,
          source: lk.TrackSource.camera,
        ),
        isTrue,
      );
    });

    test('never sends screen share or non-Android video to camera zoom', () {
      expect(
        orexShouldOwnAndroidCameraZoom(
          isWeb: false,
          platform: TargetPlatform.android,
          isLocalParticipant: true,
          source: lk.TrackSource.screenShareVideo,
        ),
        isFalse,
      );
      expect(
        orexShouldOwnAndroidCameraZoom(
          isWeb: false,
          platform: TargetPlatform.android,
          isLocalParticipant: false,
          source: lk.TrackSource.camera,
        ),
        isFalse,
      );
      expect(
        orexShouldOwnAndroidCameraZoom(
          isWeb: true,
          platform: TargetPlatform.android,
          isLocalParticipant: true,
          source: lk.TrackSource.camera,
        ),
        isFalse,
      );
      expect(
        orexShouldOwnAndroidCameraZoom(
          isWeb: false,
          platform: TargetPlatform.windows,
          isLocalParticipant: true,
          source: lk.TrackSource.camera,
        ),
        isFalse,
      );
    });
  });

  group('orexShouldBlockLiveKitAndroidLocalVideoGestures', () {
    test('blocks SDK gestures for every local Android video source', () {
      expect(
        orexShouldBlockLiveKitAndroidLocalVideoGestures(
          isWeb: false,
          platform: TargetPlatform.android,
          isLocalParticipant: true,
        ),
        isTrue,
      );
    });

    test('does not block remote or non-Android renderer gestures', () {
      expect(
        orexShouldBlockLiveKitAndroidLocalVideoGestures(
          isWeb: false,
          platform: TargetPlatform.android,
          isLocalParticipant: false,
        ),
        isFalse,
      );
      expect(
        orexShouldBlockLiveKitAndroidLocalVideoGestures(
          isWeb: true,
          platform: TargetPlatform.android,
          isLocalParticipant: true,
        ),
        isFalse,
      );
      expect(
        orexShouldBlockLiveKitAndroidLocalVideoGestures(
          isWeb: false,
          platform: TargetPlatform.windows,
          isLocalParticipant: true,
        ),
        isFalse,
      );
    });
  });
}
