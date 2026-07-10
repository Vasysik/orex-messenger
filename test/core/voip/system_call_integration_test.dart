import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/system_call_integration.dart';

void main() {
  group('OrexSystemCallAction.fromNative', () {
    test('parses every supported action', () {
      const expectations = <String, OrexSystemCallActionType>{
        'answer': OrexSystemCallActionType.answer,
        'reject': OrexSystemCallActionType.reject,
        'disconnect': OrexSystemCallActionType.disconnect,
        'setActive': OrexSystemCallActionType.setActive,
        'setInactive': OrexSystemCallActionType.setInactive,
        'muteChanged': OrexSystemCallActionType.muteChanged,
        'toggleMic': OrexSystemCallActionType.toggleMic,
        'toggleAudio': OrexSystemCallActionType.toggleAudio,
      };

      for (final entry in expectations.entries) {
        final action = OrexSystemCallAction.fromNative('systemCallAction', {
          'action': entry.key,
          'callId': '!room:example.org',
          'video': true,
          'muted': false,
        });

        expect(action, isNotNull, reason: entry.key);
        expect(action!.type, entry.value, reason: entry.key);
        expect(action.callId, '!room:example.org', reason: entry.key);
      }
    });

    test('parses answer payload metadata', () {
      final action = OrexSystemCallAction.fromNative('systemCallAction', {
        'action': 'answer',
        'callId': '!room:example.org',
        'video': true,
      });

      expect(action, isNotNull);
      expect(action!.video, isTrue);
      expect(action.muted, isNull);
    });

    test('preserves both mute states from Android', () {
      for (final muted in [false, true]) {
        final action = OrexSystemCallAction.fromNative('systemCallAction', {
          'action': 'muteChanged',
          'callId': '!room:example.org',
          'muted': muted,
        });

        expect(action, isNotNull);
        expect(action!.type, OrexSystemCallActionType.muteChanged);
        expect(action.muted, muted);
      }
    });

    test('rejects malformed or unknown actions', () {
      expect(OrexSystemCallAction.fromNative('other', const {}), isNull);
      expect(
        OrexSystemCallAction.fromNative('systemCallAction', const {
          'action': 'unknown',
          'callId': 'call',
        }),
        isNull,
      );
      expect(
        OrexSystemCallAction.fromNative('systemCallAction', const {
          'action': 'answer',
          'callId': '',
        }),
        isNull,
      );
      expect(
        OrexSystemCallAction.fromNative(
          'systemCallAction',
          const <String, Object?>{},
        ),
        isNull,
      );
      expect(
        OrexSystemCallAction.fromNative('systemCallAction', 'not-a-map'),
        isNull,
      );
    });
  });

  group('OrexRecoverableSystemCall.fromNative', () {
    test('parses persisted active call metadata', () {
      final call = OrexRecoverableSystemCall.fromNative({
        'callId': '!room:example.org',
        'displayName': 'Alice',
        'incoming': true,
        'video': false,
        'answered': true,
        'startedAt': 1_749_999_900_000,
        'micEnabled': false,
        'audioEnabled': false,
        'cameraEnabled': false,
        'updatedAt': 1_750_000_000_000,
      });

      expect(call, isNotNull);
      expect(call!.callId, '!room:example.org');
      expect(call.displayName, 'Alice');
      expect(call.incoming, isTrue);
      expect(call.answered, isTrue);
      expect(call.startedAt.millisecondsSinceEpoch, 1_749_999_900_000);
      expect(call.micEnabled, isFalse);
      expect(call.audioEnabled, isFalse);
      expect(call.cameraEnabled, isFalse);
      expect(call.updatedAt.millisecondsSinceEpoch, 1_750_000_000_000);
    });

    test('keeps backward-compatible recovery defaults', () {
      final call = OrexRecoverableSystemCall.fromNative({
        'callId': '!room:example.org',
        'displayName': 'Alice',
        'video': true,
        'answered': true,
        'updatedAt': 1_750_000_000_000,
      });

      expect(call, isNotNull);
      expect(call!.startedAt, call.updatedAt);
      expect(call.micEnabled, isTrue);
      expect(call.audioEnabled, isTrue);
      expect(call.cameraEnabled, isTrue);
    });

    test('rejects incomplete recovery descriptors', () {
      expect(OrexRecoverableSystemCall.fromNative(const {}), isNull);
      expect(
        OrexRecoverableSystemCall.fromNative(const {
          'callId': '!room:example.org',
          'displayName': '',
          'updatedAt': 1,
        }),
        isNull,
      );
    });
  });
}
