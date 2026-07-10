import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_controller.dart';
import 'package:orex_messenger/core/voip/voip_service.dart';

void main() {
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
    test('ignores late reject and busy after a peer joined media', () {
      for (final reason in <OrexRemoteCallTerminationReason>[
        OrexRemoteCallTerminationReason.rejected,
        OrexRemoteCallTerminationReason.busy,
      ]) {
        expect(
          orexShouldEndEstablishedCallForRemoteDisposition(
            reason: reason,
            sawRemote: true,
          ),
          isFalse,
          reason: reason.name,
        );
      }
    });

    test('still applies explicit remote hangup to an established call', () {
      expect(
        orexShouldEndEstablishedCallForRemoteDisposition(
          reason: OrexRemoteCallTerminationReason.ended,
          sawRemote: true,
        ),
        isTrue,
      );
    });

    test('applies reject before a peer joins media', () {
      expect(
        orexShouldEndEstablishedCallForRemoteDisposition(
          reason: OrexRemoteCallTerminationReason.rejected,
          sawRemote: false,
        ),
        isTrue,
      );
    });
  });
}
