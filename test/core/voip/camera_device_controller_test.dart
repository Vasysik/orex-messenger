import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/audio/audio_device_utils.dart';
import 'package:orex_messenger/core/voip/camera_device_controller.dart';

void main() {
  group('OrexCameraDeviceController', () {
    test('normalizes selected camera device ids', () {
      expect(
        OrexCameraDeviceController.normalizeSelectedDeviceId(null),
        isNull,
      );
      expect(OrexCameraDeviceController.normalizeSelectedDeviceId(''), isNull);
      expect(
        OrexCameraDeviceController.normalizeSelectedDeviceId(' default '),
        isNull,
      );
      expect(
        OrexCameraDeviceController.normalizeSelectedDeviceId(' camera-1 '),
        'camera-1',
      );
    });

    test('deduplicates non-empty camera ids while preserving order', () {
      final ids = OrexCameraDeviceController.uniqueDeviceIds([
        const OrexAudioDevice(id: ' camera-a ', kind: 'videoinput', label: 'A'),
        const OrexAudioDevice(id: '', kind: 'videoinput', label: 'Empty'),
        const OrexAudioDevice(id: 'camera-b', kind: 'videoinput', label: 'B'),
        const OrexAudioDevice(id: 'camera-a', kind: 'videoinput', label: 'A2'),
      ]);

      expect(ids, ['camera-a', 'camera-b']);
    });

    test('cycles from configured camera when present', () {
      final next = OrexCameraDeviceController.nextDeviceId(
        ids: ['camera-a', 'camera-b', 'camera-c'],
        configured: 'camera-b',
        lastRequested: 'camera-a',
        activeTrackId: 'camera-c',
      );

      expect(next, 'camera-c');
    });

    test('falls back to last requested and active camera when cycling', () {
      expect(
        OrexCameraDeviceController.nextDeviceId(
          ids: ['camera-a', 'camera-b', 'camera-c'],
          configured: null,
          lastRequested: 'camera-c',
          activeTrackId: 'camera-a',
        ),
        'camera-a',
      );
      expect(
        OrexCameraDeviceController.nextDeviceId(
          ids: ['camera-a', 'camera-b', 'camera-c'],
          configured: null,
          lastRequested: null,
          activeTrackId: 'camera-a',
        ),
        'camera-b',
      );
    });

    test('cycles to first camera when current camera is unknown', () {
      final next = OrexCameraDeviceController.nextDeviceId(
        ids: ['camera-a', 'camera-b'],
        configured: 'missing',
        lastRequested: null,
        activeTrackId: null,
      );

      expect(next, 'camera-a');
    });
  });
}
