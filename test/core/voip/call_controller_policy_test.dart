import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_controller.dart';
import 'package:orex_messenger/core/voip/voip_service.dart';

void main() {
  group('encrypted call-room policy', () {
    test('production policy fails closed for unencrypted rooms', () {
      expect(
        orexCanEnterCallRoom(
          roomEncrypted: false,
          allowUnencryptedCalls: false,
        ),
        isFalse,
      );
    });

    test('encrypted rooms are always allowed', () {
      expect(
        orexCanEnterCallRoom(
          roomEncrypted: true,
          allowUnencryptedCalls: false,
        ),
        isTrue,
      );
    });

    test('legacy escape hatch is explicit', () {
      expect(
        orexCanEnterCallRoom(
          roomEncrypted: false,
          allowUnencryptedCalls: true,
        ),
        isTrue,
      );
    });
  });

  group('orexShouldInitiateCall', () {
    test('an accepted system incoming call never rings back', () {
      expect(
        orexShouldInitiateCall(
          systemIncoming: true,
          recovering: false,
          roomExists: true,
          roomHasActiveCall: false,
        ),
        isFalse,
      );
    });

    test('a recovered call never creates a new ring attempt', () {
      expect(
        orexShouldInitiateCall(
          systemIncoming: false,
          recovering: true,
          roomExists: true,
          roomHasActiveCall: false,
        ),
        isFalse,
      );
    });

    test('a fresh outgoing call rings only when no call is active', () {
      expect(
        orexShouldInitiateCall(
          systemIncoming: false,
          recovering: false,
          roomExists: true,
          roomHasActiveCall: false,
        ),
        isTrue,
      );
      expect(
        orexShouldInitiateCall(
          systemIncoming: false,
          recovering: false,
          roomExists: true,
          roomHasActiveCall: true,
        ),
        isFalse,
      );
    });
  });

  group('orexShouldEndEstablishedCallForRemoteDisposition', () {
    test('reject and busy keep the encrypted MatrixRTC channel alive', () {
      for (final reason in <OrexRemoteCallTerminationReason>[
        OrexRemoteCallTerminationReason.rejected,
        OrexRemoteCallTerminationReason.busy,
      ]) {
        expect(
          orexShouldEndEstablishedCallForRemoteDisposition(reason: reason),
          isFalse,
          reason: reason.name,
        );
      }
    });

    test('explicit remote ended tears down the established call', () {
      expect(
        orexShouldEndEstablishedCallForRemoteDisposition(
          reason: OrexRemoteCallTerminationReason.ended,
        ),
        isTrue,
      );
    });
  });

  group('incoming Android Telecom registration', () {
    test('reuses a native incoming call that already exists', () {
      expect(
        orexShouldReusePreparedIncomingSystemCall(
          fromSystem: false,
          hasPreparedIncomingCall: true,
          nativeCallExists: true,
        ),
        isTrue,
      );
    });

    test('does not create a fresh ringing call after a Flutter answer', () {
      expect(
        orexShouldReusePreparedIncomingSystemCall(
          fromSystem: false,
          hasPreparedIncomingCall: false,
          nativeCallExists: false,
        ),
        isFalse,
      );
    });

    test('system answer always owns an existing native incoming call', () {
      expect(
        orexShouldReusePreparedIncomingSystemCall(
          fromSystem: true,
          hasPreparedIncomingCall: false,
          nativeCallExists: true,
        ),
        isTrue,
      );
    });

    test('a stale system PendingIntent cannot impersonate a native call', () {
      expect(
        orexShouldReusePreparedIncomingSystemCall(
          fromSystem: true,
          hasPreparedIncomingCall: true,
          nativeCallExists: false,
        ),
        isFalse,
      );
    });
  });

  group('answered state latch', () {
    test('an accepted incoming call is answered while media connects', () {
      expect(
        orexNextAnsweredState(
          alreadyAnswered: false,
          answerAccepted: true,
          mediaConnected: false,
        ),
        isTrue,
      );
    });

    test('a reconnect cannot turn an answered call back into ringing', () {
      expect(
        orexNextAnsweredState(
          alreadyAnswered: true,
          answerAccepted: false,
          mediaConnected: false,
        ),
        isTrue,
      );
    });

    test('an unanswered outgoing connection stays pending', () {
      expect(
        orexNextAnsweredState(
          alreadyAnswered: false,
          answerAccepted: false,
          mediaConnected: false,
        ),
        isFalse,
      );
    });
  });

  group('queued call start cancellation', () {
    test('disconnect invalidates a start waiting behind older cleanup', () {
      expect(
        orexIsCallStartRequestCancelled(
          disposed: false,
          capturedGeneration: 4,
          currentGeneration: 5,
        ),
        isTrue,
      );
    });

    test('controller disposal invalidates an otherwise current start', () {
      expect(
        orexIsCallStartRequestCancelled(
          disposed: true,
          capturedGeneration: 5,
          currentGeneration: 5,
        ),
        isTrue,
      );
    });
  });

  group('system termination disposition', () {
    test('quick disconnect after answer notifies the remote caller', () {
      expect(
        orexShouldNotifyEndedForSystemTermination(
          rejected: false,
          acceptedInProgress: true,
        ),
        isTrue,
      );
    });

    test('a reject remains a rejected disposition, not ended', () {
      expect(
        orexShouldNotifyEndedForSystemTermination(
          rejected: true,
          acceptedInProgress: true,
        ),
        isFalse,
      );
    });
  });
}
