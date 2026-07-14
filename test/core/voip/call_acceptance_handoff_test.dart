import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_attempt.dart';
import 'package:orex_messenger/core/voip/call_lifecycle_policy.dart';

void main() {
  test('cold answer descriptor survives until pending command is loaded', () {
    expect(
      orexShouldKeepRecoverableAnswerBootstrap(
        incoming: true,
        answered: false,
        pushBridgeReady: false,
        hasPendingIncomingAnswer: false,
      ),
      isTrue,
    );
    expect(
      orexShouldKeepRecoverableAnswerBootstrap(
        incoming: true,
        answered: false,
        pushBridgeReady: true,
        hasPendingIncomingAnswer: true,
      ),
      isTrue,
    );
    expect(
      orexShouldKeepRecoverableAnswerBootstrap(
        incoming: true,
        answered: false,
        pushBridgeReady: true,
        hasPendingIncomingAnswer: false,
      ),
      isFalse,
    );
  });

  test('accepted mobile UI is requested when session exists, before media completes', () async {
    const instance = OrexCallInstance(
      roomId: '!room:orex',
      ringEventId: r'$ring',
    );
    final media = Completer<void>();
    final requested = <OrexCallInstance>[];
    final handoff = OrexAcceptedCallUiHandoff(
      enabled: true,
      acceptedRoomId: instance.roomId,
      currentInstance: () => instance,
      requestUi: requested.add,
    );

    // This is the onSessionCreated moment. Media is deliberately still pending.
    handoff.requestIfReady();

    expect(media.isCompleted, isFalse);
    expect(requested, [instance]);
    expect(handoff.requested, isTrue);

    // Final media completion/fallback must not push a duplicate route.
    media.complete();
    await media.future;
    handoff.requestIfReady();
    expect(requested, hasLength(1));
  });

  test('handoff waits for the exact accepted room and respects disabled desktop flow', () {
    const wrong = OrexCallInstance(roomId: '!other:orex');
    final requested = <OrexCallInstance>[];
    var current = wrong;
    final handoff = OrexAcceptedCallUiHandoff(
      enabled: true,
      acceptedRoomId: '!room:orex',
      currentInstance: () => current,
      requestUi: requested.add,
    );

    handoff.requestIfReady();
    expect(requested, isEmpty);

    current = const OrexCallInstance(roomId: '!room:orex');
    handoff.requestIfReady();
    expect(requested.single.roomId, '!room:orex');

    final disabled = OrexAcceptedCallUiHandoff(
      enabled: false,
      acceptedRoomId: '!room:orex',
      currentInstance: () => current,
      requestUi: requested.add,
    );
    disabled.requestIfReady();
    expect(requested, hasLength(1));
  });
}
