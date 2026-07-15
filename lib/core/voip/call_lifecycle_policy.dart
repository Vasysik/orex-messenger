import 'call_attempt.dart';

/// Pure lifecycle decisions for calls.
///
/// Keeping these rules outside the stateful controller makes signaling
/// races testable without constructing Matrix, LiveKit or Android Telecom objects.
bool orexCanEnterCallRoom({
  required bool roomEncrypted,
  required bool allowUnencryptedCalls,
}) => roomEncrypted || allowUnencryptedCalls;

bool orexShouldInitiateCall({
  required bool systemIncoming,
  required bool recovering,
  required bool roomExists,
  required bool roomHasActiveCall,
}) {
  return !systemIncoming && !recovering && roomExists && !roomHasActiveCall;
}

bool orexShouldEndEstablishedCallForRemoteDisposition({
  required OrexRemoteCallTerminationReason reason,
}) {
  // Reject/busy only stop the outstanding ring attempt. The caller has already
  // joined MatrixRTC and published an encrypted media membership, so that voice
  // channel must remain alive even when nobody accepted it yet. Only an explicit
  // remote `ended` disposition tears down the active local call.
  return reason == OrexRemoteCallTerminationReason.ended;
}

bool orexShouldReusePreparedIncomingSystemCall({
  required bool fromSystem,
  required bool hasPreparedIncomingCall,
  required bool nativeCallExists,
}) => nativeCallExists && (fromSystem || hasPreparedIncomingCall);

bool orexNextAnsweredState({
  required bool alreadyAnswered,
  required bool answerAccepted,
  required bool mediaConnected,
}) => alreadyAnswered || answerAccepted || mediaConnected;

bool orexIsCallStartRequestCancelled({
  required bool disposed,
  required int capturedGeneration,
  required int currentGeneration,
}) => disposed || capturedGeneration != currentGeneration;

bool orexShouldNotifyEndedForSystemTermination({
  required bool rejected,
  required bool acceptedInProgress,
}) => !rejected && acceptedInProgress;

/// Keeps the native `answered=false` descriptor while an accepted cold-start
/// command is still being loaded or is waiting for the app-level handler.
///
/// Ordinary stale incoming descriptors are discarded once the push bridge is
/// ready and proves that no matching Answer command exists.
bool orexShouldKeepRecoverableAnswerBootstrap({
  required bool incoming,
  required bool answered,
  required bool pushBridgeReady,
  required bool hasPendingIncomingAnswer,
}) {
  if (!incoming || answered) return false;
  return !pushBridgeReady || hasPendingIncomingAnswer;
}

/// One-shot bridge from an accepted incoming call to the expanded mobile UI.
///
/// The bridge is intentionally triggered by local CallSession creation, not by
/// final media readiness. This preserves the UX contract:
/// native answering shell -> expanded "Соединение…" screen -> connected call.
class OrexAcceptedCallUiHandoff {
  OrexAcceptedCallUiHandoff({
    required this.enabled,
    required this.acceptedRoomId,
    required this.currentInstance,
    required this.requestUi,
  });

  final bool enabled;
  final String acceptedRoomId;
  final OrexCallInstance? Function() currentInstance;
  final void Function(OrexCallInstance instance) requestUi;
  bool _requested = false;

  bool get requested => _requested;

  void request(OrexCallInstance instance) {
    if (!enabled || _requested || instance.roomId != acceptedRoomId) return;
    _requested = true;
    requestUi(instance);
  }

  void requestIfReady() {
    if (!enabled || _requested) return;
    final instance = currentInstance();
    if (instance == null || instance.roomId != acceptedRoomId) return;
    request(instance);
  }
}
