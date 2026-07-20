import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:orex_messenger/core/voip/call_session.dart';

void main() {
  test('allows a bounded mobile ICE handoff before failing the call stage', () {
    expect(orexMobileIceConnectionTimeout, const Duration(seconds: 25));
  });

  group('orexInitialAudioOutputDeviceId', () {
    test('preserves a concrete output for the initial web track', () {
      expect(orexInitialAudioOutputDeviceId(' bt-stereo '), 'bt-stereo');
    });

    test('does not pass default or Android route ids to LiveKit', () {
      expect(orexInitialAudioOutputDeviceId('default'), isNull);
      expect(
        orexInitialAudioOutputDeviceId(
          'orex://android/audio-output/audio:2:42',
        ),
        isNull,
      );
    });
  });

  group('orexShouldReconnectCallAfterBackground', () {
    test('keeps a healthy room on the existing connection', () {
      expect(
        orexShouldReconnectCallAfterBackground(
          connectionState: lk.ConnectionState.connected,
          hasReachedMediaReady: true,
        ),
        isFalse,
      );
    });

    test('refreshes a previously-ready non-connected room on resume', () {
      for (final state in <lk.ConnectionState?>[
        null,
        lk.ConnectionState.connecting,
        lk.ConnectionState.reconnecting,
        lk.ConnectionState.disconnected,
      ]) {
        expect(
          orexShouldReconnectCallAfterBackground(
            connectionState: state,
            hasReachedMediaReady: true,
          ),
          isTrue,
          reason: 'state=$state',
        );
      }
    });

    test('does not start recovery over the initial connection', () {
      for (final state in <lk.ConnectionState?>[
        null,
        lk.ConnectionState.connecting,
        lk.ConnectionState.reconnecting,
      ]) {
        expect(
          orexShouldReconnectCallAfterBackground(
            connectionState: state,
            hasReachedMediaReady: false,
          ),
          isFalse,
          reason: 'state=$state',
        );
      }
    });
  });

  group('orexShouldRefreshPublishedMediaAfterBackground', () {
    test('hard-refreshes a connected room after a real background pause', () {
      expect(
        orexShouldRefreshPublishedMediaAfterBackground(
          connectionState: lk.ConnectionState.connected,
          backgroundDuration: const Duration(seconds: 2),
        ),
        isTrue,
      );
    });

    test('does not churn camera/mic for a transient lifecycle bounce', () {
      expect(
        orexShouldRefreshPublishedMediaAfterBackground(
          connectionState: lk.ConnectionState.connected,
          backgroundDuration: const Duration(milliseconds: 300),
        ),
        isFalse,
      );
    });

    test('leaves disconnected rooms to the full reconnect path', () {
      expect(
        orexShouldRefreshPublishedMediaAfterBackground(
          connectionState: lk.ConnectionState.reconnecting,
          backgroundDuration: const Duration(seconds: 3),
        ),
        isFalse,
      );
    });
  });

  group('orexShouldEnsureCameraAfterBackground', () {
    test('does not rebuild an already enabled camera publication', () {
      expect(
        orexShouldEnsureCameraAfterBackground(
          cameraRequestedOn: true,
          cameraEnabled: true,
        ),
        isFalse,
      );
    });

    test('enables the camera only when requested but actually disabled', () {
      expect(
        orexShouldEnsureCameraAfterBackground(
          cameraRequestedOn: true,
          cameraEnabled: false,
        ),
        isTrue,
      );
      expect(
        orexShouldEnsureCameraAfterBackground(
          cameraRequestedOn: false,
          cameraEnabled: false,
        ),
        isFalse,
      );
    });
  });

  group('orexEncryptionKeyRetryDelay', () {
    test('backs off and caps retries during a Matrix control-plane outage', () {
      expect(orexEncryptionKeyRetryDelay(-1), const Duration(seconds: 2));
      expect(orexEncryptionKeyRetryDelay(0), const Duration(seconds: 2));
      expect(orexEncryptionKeyRetryDelay(1), const Duration(seconds: 5));
      expect(orexEncryptionKeyRetryDelay(4), const Duration(seconds: 30));
      expect(orexEncryptionKeyRetryDelay(99), const Duration(seconds: 30));
    });
  });

  group('media E2EE provider release barrier', () {
    test(
      'outlives bounded UI teardown until stale media operations drain',
      () async {
        final mediaTeardown = Completer<void>();
        final pendingMediaOperation = Completer<void>();
        var completed = false;
        final barrier = orexWaitForMediaProviderRelease(
          mediaTeardown: mediaTeardown.future,
          waitForPendingMediaOperations: () => pendingMediaOperation.future,
        ).whenComplete(() => completed = true);

        mediaTeardown.complete();
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);

        pendingMediaOperation.complete();
        await barrier;
        expect(completed, isTrue);
      },
    );
  });

  group('orexShouldPlayRemoteReactionCue', () {
    test('does not replay a reaction that predates the media session', () {
      expect(
        orexShouldPlayRemoteReactionCue(
          knownParticipant: false,
          previousTs: null,
          nextTs: 100,
          baselineTs: 200,
        ),
        isFalse,
      );
    });

    test('plays a fresh first reaction from a remote participant', () {
      expect(
        orexShouldPlayRemoteReactionCue(
          knownParticipant: false,
          previousTs: null,
          nextTs: 201,
          baselineTs: 200,
        ),
        isTrue,
      );
    });

    test('plays only a strictly newer reaction timestamp afterwards', () {
      expect(
        orexShouldPlayRemoteReactionCue(
          knownParticipant: true,
          previousTs: 300,
          nextTs: 300,
          baselineTs: 200,
        ),
        isFalse,
      );
      expect(
        orexShouldPlayRemoteReactionCue(
          knownParticipant: true,
          previousTs: 300,
          nextTs: 301,
          baselineTs: 200,
        ),
        isTrue,
      );
    });
  });
}
