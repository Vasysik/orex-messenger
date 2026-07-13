/// Explicit ring events can overtake MatrixRTC membership by a small amount,
/// especially after a killed-process Android wake-up. A delayed ring must not
/// resurrect a call whose membership has already disappeared.
bool orexShouldPresentExplicitRing({
  required bool roomHasActiveCall,
  required Duration eventAge,
  Duration membershipGrace = const Duration(seconds: 12),
}) {
  if (eventAge.isNegative) return roomHasActiveCall;
  return roomHasActiveCall || eventAge <= membershipGrace;
}


enum OrexWakeCancellationAction { handled, ended }

/// Plaintext MatrixRTC notification envelopes are only a killed-process wake
/// and ringing-surface cleanup path. They are never authoritative for accepted,
/// rejected or busy state, and cannot directly tear down established media.
OrexWakeCancellationAction? orexParseWakeCancellationAction(Object? raw) {
  final action = raw?.toString().trim().toLowerCase();
  return switch (action) {
    'handled' => OrexWakeCancellationAction.handled,
    'ended' => OrexWakeCancellationAction.ended,
    _ => null,
  };
}
