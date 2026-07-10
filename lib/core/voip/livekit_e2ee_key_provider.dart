import 'dart:async';
import 'dart:typed_data';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';

/// One key-provider bridge shared by MatrixRTC signaling and LiveKit media.
///
/// Matrix's VoIP layer distributes/request SFU keys with encrypted to-device
/// events. LiveKit consumes the same per-participant keys for frame crypto.
/// The SFU receives media ciphertext, never this key material.
final class OrexLiveKitE2eeKeyProvider implements EncryptionKeyProvider {
  OrexLiveKitE2eeKeyProvider()
    : _liveKit = lk.BaseKeyProvider.create(sharedKey: false, keyRingSize: 16);

  final Future<lk.BaseKeyProvider> _liveKit;
  final Set<String> _participantsWithKeys = <String>{};
  final StreamController<String> _keyUpdates =
      StreamController<String>.broadcast(sync: true);

  Future<lk.BaseKeyProvider> get liveKit => _liveKit;

  bool hasKeyFor(CallParticipant participant) =>
      _participantsWithKeys.contains(participant.id);

  /// Start key observation for a fresh MatrixRTC media session. The underlying
  /// LiveKit provider may keep raw keys until they are replaced, but readiness
  /// tracking must never carry a participant from one call into the next.
  void resetObservedKeys() => _participantsWithKeys.clear();

  Future<bool> waitForKeys(
    Iterable<CallParticipant> participants, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final participantIds = participants
        .map((participant) => participant.id)
        .toSet();
    if (participantIds.isEmpty || _hasAllKeys(participantIds)) return true;

    final ready = Completer<void>();
    final subscription = _keyUpdates.stream.listen((_) {
      if (!ready.isCompleted && _hasAllKeys(participantIds)) {
        ready.complete();
      }
    });
    try {
      // Close the gap between the initial check and stream subscription: a key
      // may arrive synchronously through MatrixRTC callbacks in that window.
      if (_hasAllKeys(participantIds)) return true;
      await ready.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return _hasAllKeys(participantIds);
    } finally {
      await subscription.cancel();
    }
  }

  bool _hasAllKeys(Set<String> participantIds) =>
      participantIds.every(_participantsWithKeys.contains);

  @override
  Future<Uint8List> onExportKey(CallParticipant participant, int index) async {
    final provider = await _liveKit;
    return provider.exportKey(participant.id, index);
  }

  @override
  Future<Uint8List> onRatchetKey(CallParticipant participant, int index) async {
    final provider = await _liveKit;
    return provider.ratchetKey(participant.id, index);
  }

  @override
  Future<void> onSetEncryptionKey(
    CallParticipant participant,
    Uint8List key,
    int index,
  ) async {
    final provider = await _liveKit;
    await provider.setRawKey(
      key,
      participantId: participant.id,
      keyIndex: index,
    );
    _participantsWithKeys.add(participant.id);
    if (!_keyUpdates.isClosed) _keyUpdates.add(participant.id);
  }

  Future<void> dispose() => _keyUpdates.close();
}
