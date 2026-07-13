import 'package:flutter/foundation.dart';

import 'voip_service.dart';

/// Pure lifecycle decisions for calls.
///
/// Keeping these rules outside the stateful controller makes signaling
/// races testable without constructing Matrix, LiveKit or Android Telecom objects.
@visibleForTesting
bool orexShouldInitiateCall({
  required bool systemIncoming,
  required bool recovering,
  required bool roomExists,
  required bool roomHasActiveCall,
}) {
  return !systemIncoming && !recovering && roomExists && !roomHasActiveCall;
}

@visibleForTesting
bool orexShouldEndEstablishedCallForRemoteDisposition({
  required OrexRemoteCallTerminationReason reason,
}) {
  // Reject/busy only stop the outstanding ring attempt. The caller has already
  // joined MatrixRTC and published an encrypted media membership, so that voice
  // channel must remain alive even when nobody accepted it yet. Only an explicit
  // remote `ended` disposition tears down the active local call.
  return reason == OrexRemoteCallTerminationReason.ended;
}

@visibleForTesting
bool orexShouldReusePreparedIncomingSystemCall({
  required bool fromSystem,
  required bool hasPreparedIncomingCall,
  required bool nativeCallExists,
}) => nativeCallExists && (fromSystem || hasPreparedIncomingCall);

@visibleForTesting
bool orexNextAnsweredState({
  required bool alreadyAnswered,
  required bool answerAccepted,
  required bool mediaConnected,
}) => alreadyAnswered || answerAccepted || mediaConnected;

@visibleForTesting
bool orexIsCallStartRequestCancelled({
  required bool disposed,
  required int capturedGeneration,
  required int currentGeneration,
}) => disposed || capturedGeneration != currentGeneration;

@visibleForTesting
bool orexShouldNotifyEndedForSystemTermination({
  required bool rejected,
  required bool acceptedInProgress,
}) => !rejected && acceptedInProgress;
