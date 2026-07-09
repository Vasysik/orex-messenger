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

  Future<lk.BaseKeyProvider> get liveKit => _liveKit;

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
  }
}
