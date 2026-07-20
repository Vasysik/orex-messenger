import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';

import '../logging/orex_logger.dart';

/// One key-provider bridge shared by MatrixRTC signaling and LiveKit media.
///
/// Matrix's VoIP layer distributes/request SFU keys with encrypted to-device
/// events. LiveKit consumes the same per-participant keys for frame crypto.
/// The SFU receives media ciphertext, never this key material.
final class OrexLiveKitE2eeKeyProvider implements EncryptionKeyProvider {
  OrexLiveKitE2eeKeyProvider();

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

  Future<lk.BaseKeyProvider>? _liveKit;
  Future<lk.BaseKeyProvider>? _preparedLiveKit;
  final Set<Future<lk.BaseKeyProvider>> _activeSessionProviders =
      <Future<lk.BaseKeyProvider>>{};
  final Set<Future<void>> _providerReleaseTasks = <Future<void>>{};
  final Set<String> _participantsWithKeys = <String>{};
  final Map<String, int> _latestKeyIndexes = <String, int>{};
  final Map<String, int> _keyRevisions = <String, int>{};
  final Map<String, Future<void>> _participantOperationTails =
      <String, Future<void>>{};
  lk.Room? _attachedRoom;
  int _sessionGeneration = 0;
  final StreamController<String> _keyUpdates =
      StreamController<String>.broadcast(sync: true);

  bool hasKeyFor(CallParticipant participant) =>
      _participantsWithKeys.contains(participant.id);

  int keyRevisionFor(String participantId) => _keyRevisions[participantId] ?? 0;

  /// Reserves a native key provider for the next CallSession without making it
  /// visible to Matrix callbacks yet. This gives the media layer a stable lease
  /// while VoipService replaces any SDK-created, unscoped backend.
  Future<lk.BaseKeyProvider> prepareSession() {
    final abandoned = _preparedLiveKit;
    if (abandoned != null) {
      _scheduleProviderRelease(abandoned, label: 'abandoned prepared provider');
    }
    final prepared = _createLiveKitProvider();
    _preparedLiveKit = prepared;
    return prepared;
  }

  void discardPreparedSession([Future<lk.BaseKeyProvider>? provider]) {
    final prepared = _preparedLiveKit;
    if (prepared == null ||
        (provider != null && !identical(prepared, provider))) {
      return;
    }
    _preparedLiveKit = null;
    _scheduleProviderRelease(prepared, label: 'discarded prepared provider');
  }

  Future<void> _disposeNativeProvider(
    Future<lk.BaseKeyProvider> providerFuture,
    String label,
  ) async {
    try {
      final provider = await providerFuture;
      await provider.keyProvider.dispose();
    } catch (error) {
      OrexLog.d('VoipE2EE', '$label cleanup failed', error);
    }
  }

  /// Activates the reserved provider after the session-scoped Matrix backend is
  /// installed. Raw keys from the previous call then become unreachable by the
  /// new LiveKit Room, while an old reconnect retains its captured provider.
  Future<lk.BaseKeyProvider> activatePreparedSession() {
    final nextProvider = _preparedLiveKit ?? _createLiveKitProvider();
    _sessionGeneration++;
    _participantsWithKeys.clear();
    _latestKeyIndexes.clear();
    _keyRevisions.clear();
    _participantOperationTails.clear();
    _attachedRoom = null;
    _liveKit = nextProvider;
    _activeSessionProviders.add(nextProvider);
    _preparedLiveKit = null;
    return nextProvider;
  }

  void releaseSession(
    Future<lk.BaseKeyProvider> provider, {
    Iterable<Future<void>> after = const <Future<void>>[],
  }) {
    if (!_activeSessionProviders.remove(provider)) return;
    if (identical(_liveKit, provider)) _liveKit = null;
    _scheduleProviderRelease(
      provider,
      label: 'released session provider',
      after: after,
    );
  }

  void _scheduleProviderRelease(
    Future<lk.BaseKeyProvider> provider, {
    required String label,
    Iterable<Future<void>> after = const <Future<void>>[],
  }) {
    late final Future<void> task;
    task = (() async {
      for (final barrier in after) {
        try {
          await barrier;
        } catch (_) {
          // Cleanup barriers report their own operational failure. Native key
          // material must still be released after they settle.
        }
      }
      await _disposeNativeProvider(provider, label);
    })().whenComplete(() => _providerReleaseTasks.remove(task));
    _providerReleaseTasks.add(task);
  }

  /// Attaches the currently connected LiveKit room to MatrixRTC key rotation.
  /// BaseKeyProvider stores a new raw key but does not move existing sender
  /// cryptors to its index, so the room must apply local rotations explicitly.
  Future<void> attachLiveKitRoom(lk.Room room) async {
    _attachedRoom = room;
    final generation = _sessionGeneration;
    final participantId = room.localParticipant?.identity;
    if (participantId == null) return;

    await _serializeParticipantOperation(participantId, () async {
      if (generation != _sessionGeneration || !identical(_attachedRoom, room)) {
        return;
      }
      final index = _latestKeyIndexes[participantId];
      final manager = room.e2eeManager;
      if (index == null || manager == null) return;
      await manager.setKeyIndex(index, participantIdentity: participantId);
    });
  }

  void detachLiveKitRoom(lk.Room room) {
    if (identical(_attachedRoom, room)) _attachedRoom = null;
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

  Future<bool> waitForKeyUpdates(
    Map<String, int> revisions, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    bool updated() => revisions.entries.every(
      (entry) => keyRevisionFor(entry.key) > entry.value,
    );
    if (revisions.isEmpty || updated()) return true;

    final ready = Completer<void>();
    final subscription = _keyUpdates.stream.listen((_) {
      if (!ready.isCompleted && updated()) ready.complete();
    });
    try {
      if (updated()) return true;
      await ready.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return updated();
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<Uint8List> onExportKey(CallParticipant participant, int index) {
    final providerFuture = _liveKit;
    if (providerFuture == null) {
      return Future<Uint8List>.error(
        StateError('No active LiveKit E2EE provider'),
      );
    }
    return _serializeParticipantOperation(participant.id, () async {
      final provider = await providerFuture;
      return provider.exportKey(participant.id, index);
    });
  }

  @override
  Future<Uint8List> onRatchetKey(CallParticipant participant, int index) {
    final providerFuture = _liveKit;
    if (providerFuture == null) {
      return Future<Uint8List>.error(
        StateError('No active LiveKit E2EE provider'),
      );
    }
    return _serializeParticipantOperation(participant.id, () async {
      final provider = await providerFuture;
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
    final providerFuture = _liveKit;
    if (providerFuture == null) {
      return Future<void>.error(StateError('No active LiveKit E2EE provider'));
    }
    final keyCopy = Uint8List.fromList(key);
    return _serializeParticipantOperation(participant.id, () async {
      try {
        if (generation != _sessionGeneration) return;
        final provider = await providerFuture;
        if (generation != _sessionGeneration) return;
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

      _latestKeyIndexes[participant.id] = index;
      final room = _attachedRoom;
      if (participant.isLocal &&
          room != null &&
          room.localParticipant?.identity == participant.id) {
        final manager = room.e2eeManager;
        if (manager != null) {
          await manager.setKeyIndex(index, participantIdentity: participant.id);
        }
      }
      if (generation != _sessionGeneration) return;

      _participantsWithKeys.add(participant.id);
      _keyRevisions[participant.id] = keyRevisionFor(participant.id) + 1;
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
    tail = previous
        .then<void>((_) => run(), onError: (_, _) => run())
        .whenComplete(() {
          if (identical(_participantOperationTails[participantId], tail)) {
            _participantOperationTails.remove(participantId);
          }
        });
    _participantOperationTails[participantId] = tail;
    return completer.future;
  }

  Future<void> dispose() async {
    final preparedProvider = _preparedLiveKit;
    final activeProviders = _activeSessionProviders.toList(growable: false);
    _sessionGeneration++;
    _participantsWithKeys.clear();
    _latestKeyIndexes.clear();
    _keyRevisions.clear();
    _participantOperationTails.clear();
    _attachedRoom = null;
    _liveKit = null;
    _preparedLiveKit = null;
    _activeSessionProviders.clear();
    for (final provider in activeProviders) {
      _scheduleProviderRelease(provider, label: 'active native provider');
    }
    if (preparedProvider != null &&
        !activeProviders.contains(preparedProvider)) {
      _scheduleProviderRelease(
        preparedProvider,
        label: 'prepared native provider',
      );
    }
    while (_providerReleaseTasks.isNotEmpty) {
      await Future.wait<void>(_providerReleaseTasks.toList(growable: false));
    }
    await _keyUpdates.close();
  }
}
