import 'dart:math' as math;
import 'dart:typed_data';

import 'audio_cue_service.dart';

final class OrexPcmAudioLevel {
  const OrexPcmAudioLevel._();

  static double dbFromPcm16(
    Uint8List bytes, {
    double minDb = AudioCueService.minSpeakingThresholdDb,
  }) {
    if (bytes.length < 2) return minDb;

    final data = ByteData.sublistView(bytes);
    var sumSquares = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final sample = data.getInt16(i, Endian.little) / 32768.0;
      sumSquares += sample * sample;
      count++;
    }
    if (count == 0 || sumSquares <= 0) return minDb;

    final rms = math.sqrt(sumSquares / count);
    if (rms <= 0) return minDb;
    return (20 * math.log(rms) / math.ln10).clamp(minDb, 0.0).toDouble();
  }
}
