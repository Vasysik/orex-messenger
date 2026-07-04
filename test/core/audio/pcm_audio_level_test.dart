import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/audio/audio_cue_service.dart';
import 'package:orex_messenger/core/audio/pcm_audio_level.dart';

void main() {
  group('OrexPcmAudioLevel', () {
    test('returns minimum level for empty or incomplete buffers', () {
      expect(
        OrexPcmAudioLevel.dbFromPcm16(Uint8List(0)),
        AudioCueService.minSpeakingThresholdDb,
      );
      expect(
        OrexPcmAudioLevel.dbFromPcm16(Uint8List.fromList([0x01])),
        AudioCueService.minSpeakingThresholdDb,
      );
    });

    test('returns minimum level for silence', () {
      expect(
        OrexPcmAudioLevel.dbFromPcm16(_pcm16([0, 0, 0])),
        AudioCueService.minSpeakingThresholdDb,
      );
    });

    test('converts half-amplitude pcm to roughly minus six decibels', () {
      expect(
        OrexPcmAudioLevel.dbFromPcm16(_pcm16([16384, -16384])),
        closeTo(-6.02, 0.05),
      );
    });

    test('clamps full-scale pcm close to zero decibels', () {
      expect(
        OrexPcmAudioLevel.dbFromPcm16(_pcm16([32767, -32768])),
        closeTo(0, 0.01),
      );
    });
  });
}

Uint8List _pcm16(List<int> samples) {
  final bytes = Uint8List(samples.length * 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(i * 2, samples[i], Endian.little);
  }
  return bytes;
}
