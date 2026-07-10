import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';

/// One key-provider bridge shared by MatrixRTC signaling and LiveKit media.
///
/// Matrix's VoIP layer distributes/request SFU keys with encrypted to-device
/// events. LiveKit consumes the same per-participant keys for frame crypto.
/// The SFU receives media ciphertext, never this key material.
final class OrexLiveKitE2eeKeyProvider implements EncryptionKeyProvider {
  OrexLiveKitE2eeKeyProvider() : _liveKit = _createLiveKitProvider();

  static Future<lk.BaseKeyProvider> _createLiveKitProvider() async {
    // livekit_client 2.9.0-dev.0 accepts
    // discardFrameWhenCryptorNotReady in BaseKeyProvider.create(), but the
    // implementation accidentally ignores the argument and hard-codes false.
    // Build the underlying flutter_webrtc provider directly so a frame cannot
    // bypass E2EE while MatrixRTC is still installing/rotating its key.
    final options = rtc.KeyProviderOptions(
      sharedKey: false,
      ratchetSalt: Uint8List.fromList('LKFrameEncryptionKey'.codeUnits),
      ratchetWindowSize: 16,
      uncryptedMagicBytes: Uint8List.fromList('LK-ROCKS'.codeUnits),
      failureTolerance: -1,
      keyRingSize: 16,
      discardFrameWhenCryptorNotReady: true,
    );
    final provider = await rtc.frameCryptorFactory.createDefaultKeyProvider(
      options,
    );
    return lk.BaseKeyProvider(provider, options);
  }

  final Future<lk.BaseKeyProvider> _liveKit;
  final Set<String> _participantsWithKeys = <String>{};
  final Map<String, Future<void>> _participantOperationTails =
      <String, Future<void>>{};
  int _sessionGeneration = 0;
  final StreamController<String> _keyUpdates =
      StreamController<String>.broadcast(sync: true);

  Future<lk.BaseKeyProvider> get liveKit => _liveKit;

  bool hasKeyFor(CallParticipant participant) =>
      _participantsWithKeys.contains(participant.id);

  /// Start key observation for a fresh MatrixRTC media session. The underlying
  /// LiveKit provider may keep raw keys until they are replaced, but readiness
  /// tracking must never carry a participant from one call into the next.
  void resetObservedKeys() {
    _sessionGeneration++;
    _participantsWithKeys.clear();
  }

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
  Future<Uint8List> onExportKey(CallParticipant participant, int index) {
    return _serializeParticipantOperation(participant.id, () async {
      final provider = await _liveKit;
      return provider.exportKey(participant.id, index);
    });
  }

  @override
  Future<Uint8List> onRatchetKey(CallParticipant participant, int index) {
    return _serializeParticipantOperation(participant.id, () async {
      final provider = await _liveKit;
      return provider.ratchetKey(participant.id, index);
    });
  }

  @override
  Future<void> onSetEncryptionKey(
    CallParticipant participant,
    Uint8List key,
    int index,
  ) {
    final generation = _sessionGeneration;
    final keyCopy = Uint8List.fromList(key);
    return _serializeParticipantOperation(participant.id, () async {
      try {
        final provider = await _liveKit;
        await provider.setRawKey(
          keyCopy,
          participantId: participant.id,
          keyIndex: index,
        );
      } finally {
        // livekit_client 2.9.0-dev.0 copies the raw key into its provider. Do
        // not retain an extra plaintext key copy in Orex after installation.
        keyCopy.fillRange(0, keyCopy.length, 0);
      }

      // A delayed callback from a previous call may finish after reset. It may
      // not make the fresh session look key-ready. The current MatrixRTC key
      // callback will overwrite the provider slot and publish readiness.
      if (generation != _sessionGeneration) return;

      _participantsWithKeys.add(participant.id);
      if (!_keyUpdates.isClosed) _keyUpdates.add(participant.id);
    });
  }

  Future<T> _serializeParticipantOperation<T>(
    String participantId,
    Future<T> Function() operation,
  ) {
    final previous =
        _participantOperationTails[participantId] ?? Future<void>.value();
    final completer = Completer<T>();

    Future<void> run() async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    }

    late final Future<void> tail;
    tail = previous.then<void>(
      (_) => run(),
      onError: (_, _) => run(),
    ).whenComplete(() {
      if (identical(_participantOperationTails[participantId], tail)) {
        _participantOperationTails.remove(participantId);
      }
    });
    _participantOperationTails[participantId] = tail;
    return completer.future;
  }

  Future<void> dispose() async {
    resetObservedKeys();
    await _keyUpdates.close();
  }
}
