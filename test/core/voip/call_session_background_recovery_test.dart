import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:orex_messenger/core/voip/call_session.dart';

void main() {
  group('orexShouldReconnectCallAfterBackground', () {
    test('keeps a healthy room on the existing connection', () {
      expect(
        orexShouldReconnectCallAfterBackground(
          connectionState: lk.ConnectionState.connected,
        ),
        isFalse,
      );
    });

    test('refreshes any non-connected room immediately on resume', () {
      for (final state in <lk.ConnectionState?>[
        null,
        lk.ConnectionState.connecting,
        lk.ConnectionState.reconnecting,
        lk.ConnectionState.disconnected,
      ]) {
        expect(
          orexShouldReconnectCallAfterBackground(
            connectionState: state,
          ),
          isTrue,
          reason: 'state=$state',
        );
      }
    });
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
