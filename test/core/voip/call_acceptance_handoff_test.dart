import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_attempt.dart';
import 'package:orex_messenger/core/voip/call_lifecycle_policy.dart';

void main() {
  test('ring lifetime covers the Android cold-answer bootstrap window', () {
    expect(orexIncomingCallLifetime, const Duration(seconds: 75));
    expect(
      orexIncomingCallLifetime,
      greaterThan(const Duration(seconds: 70)),
    );
  });

  test('closing the system incoming surface preserves an active answer handoff', () {
    expect(
      orexShouldPreserveAnswerBootstrapForIncomingDismissal(
        cancelsPendingAccept: false,
        acceptInProgress: true,
      ),
      isTrue,
    );
    expect(
      orexShouldPreserveAnswerBootstrapForIncomingDismissal(
        cancelsPendingAccept: true,
        acceptInProgress: true,
      ),
      isFalse,
    );
    expect(
      orexShouldPreserveAnswerBootstrapForIncomingDismissal(
        cancelsPendingAccept: false,
        acceptInProgress: false,
      ),
      isFalse,
    );
  });

  test('account transition tears down every form of local call ownership', () {
    expect(
      orexShouldTerminateCallForAccountTransition(
        active: true,
        starting: false,
        acceptingIncoming: false,
        hasSystemCall: false,
      ),
      isTrue,
    );
    expect(
      orexShouldTerminateCallForAccountTransition(
        active: false,
        starting: true,
        acceptingIncoming: false,
        hasSystemCall: false,
      ),
      isTrue,
    );
    expect(
      orexShouldTerminateCallForAccountTransition(
        active: false,
        starting: false,
        acceptingIncoming: true,
        hasSystemCall: false,
      ),
      isTrue,
    );
    expect(
      orexShouldTerminateCallForAccountTransition(
        active: false,
        starting: false,
        acceptingIncoming: false,
        hasSystemCall: true,
      ),
      isTrue,
    );
    expect(
      orexShouldTerminateCallForAccountTransition(
        active: false,
        starting: false,
        acceptingIncoming: false,
        hasSystemCall: false,
      ),
      isFalse,
    );
  });

  test('caller posts a timeline summary when ending an established call', () {
    expect(
      orexShouldPostCallSummary(
        initiator: true,
        hasRoomId: true,
        hadSession: true,
        fromRemote: false,
        shouldSendEndedSignal: false,
      ),
      isTrue,
    );
  });

  test('call summaries remain initiator-only to avoid duplicate timeline cards', () {
    expect(
      orexShouldPostCallSummary(
        initiator: false,
        hasRoomId: true,
        hadSession: true,
        fromRemote: true,
        shouldSendEndedSignal: true,
      ),
      isFalse,
    );
    expect(
      orexShouldPostCallSummary(
        initiator: true,
        hasRoomId: false,
        hadSession: true,
        fromRemote: false,
        shouldSendEndedSignal: false,
      ),
      isFalse,
    );
  });

  test('fresh cold-answer descriptor survives bridge dispatch races', () {
    expect(
      orexShouldKeepRecoverableAnswerBootstrap(
        incoming: true,
        answered: false,
        pushBridgeReady: false,
        hasPendingIncomingAnswer: false,
        descriptorAge: Duration.zero,
      ),
      isTrue,
    );
    expect(
      orexShouldKeepRecoverableAnswerBootstrap(
        incoming: true,
        answered: false,
        pushBridgeReady: true,
        hasPendingIncomingAnswer: true,
        descriptorAge: const Duration(seconds: 1),
      ),
      isTrue,
    );
    expect(
      orexShouldKeepRecoverableAnswerBootstrap(
        incoming: true,
        answered: false,
        pushBridgeReady: true,
        hasPendingIncomingAnswer: false,
        descriptorAge: const Duration(seconds: 1),
      ),
      isTrue,
    );
    expect(
      orexShouldKeepRecoverableAnswerBootstrap(
        incoming: true,
        answered: false,
        pushBridgeReady: true,
        hasPendingIncomingAnswer: false,
        descriptorAge: const Duration(seconds: 71),
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

  test('accepted UI waits for CallSession identity before latching', () {
    const accepted = OrexCallInstance(
      roomId: '!room:orex',
      ringEventId: r'$ring',
    );
    final requested = <OrexCallInstance>[];
    OrexCallInstance? current;
    final handoff = OrexAcceptedCallUiHandoff(
      enabled: true,
      acceptedRoomId: accepted.roomId,
      currentInstance: () => current,
      requestUi: requested.add,
    );

    handoff.requestIfReady();
    expect(requested, isEmpty);
    expect(handoff.requested, isFalse);

    // This mirrors CallController.onSessionCreated: the local identity has
    // appeared, but LiveKit media is still free to be connecting.
    current = accepted;
    handoff.requestIfReady();

    expect(requested, [accepted]);
    expect(handoff.requested, isTrue);

    // Completion fallback must remain harmless after the handoff is sent.
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
