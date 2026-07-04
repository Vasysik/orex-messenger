import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/voice_gate_controller.dart';

void main() {
  group('OrexVoiceGateController', () {
    test('normalizes selected input device ids', () {
      expect(OrexVoiceGateController.normalizeInputDeviceId(null), isNull);
      expect(OrexVoiceGateController.normalizeInputDeviceId(''), isNull);
      expect(
        OrexVoiceGateController.normalizeInputDeviceId(' default '),
        isNull,
      );
      expect(
        OrexVoiceGateController.normalizeInputDeviceId(' mic-1 '),
        'mic-1',
      );
    });

    test('treats audio above threshold as active', () {
      final now = DateTime(2026);

      expect(
        OrexVoiceGateController.isVoiceActive(
          db: -24,
          thresholdDb: -30,
          now: now,
          lastVoiceAboveThreshold: now.subtract(const Duration(seconds: 1)),
        ),
        isTrue,
      );
    });

    test('keeps voice active briefly after dropping below threshold', () {
      final lastVoice = DateTime(2026);

      expect(
        OrexVoiceGateController.isVoiceActive(
          db: -60,
          thresholdDb: -30,
          now: lastVoice.add(const Duration(milliseconds: 219)),
          lastVoiceAboveThreshold: lastVoice,
        ),
        isTrue,
      );
      expect(
        OrexVoiceGateController.isVoiceActive(
          db: -60,
          thresholdDb: -30,
          now: lastVoice.add(const Duration(milliseconds: 220)),
          lastVoiceAboveThreshold: lastVoice,
        ),
        isFalse,
      );
    });
  });
}
