import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
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

    test('maps front and back camera positions to enumerated device ids', () {
      const devices = <OrexAudioDevice>[
        OrexAudioDevice(
          id: 'front-id',
          kind: 'videoinput',
          label: 'Front',
          category: 'front_camera',
        ),
        OrexAudioDevice(
          id: 'back-id',
          kind: 'videoinput',
          label: 'Back',
          category: 'back_camera',
        ),
      ];

      expect(
        OrexCameraDeviceController.deviceIdForPosition(
          devices,
          lk.CameraPosition.front,
        ),
        'front-id',
      );
      expect(
        OrexCameraDeviceController.deviceIdForPosition(
          devices,
          lk.CameraPosition.back,
        ),
        'back-id',
      );
    });

    test('serializes rapid camera cycle requests', () async {
      String? configured = 'camera-a';
      final persisted = <String?>[];
      final firstPersist = Completer<void>();
      final secondPersist = Completer<void>();
      final secondStarted = Completer<void>();
      var persistCount = 0;
      final controller = OrexCameraDeviceController(
        videoInputDeviceIdProvider: () => configured,
        cameraDeviceIdSink: (deviceId) async {
          persistCount += 1;
          if (persistCount == 1) {
            await firstPersist.future;
          } else if (persistCount == 2) {
            secondStarted.complete();
            await secondPersist.future;
          }
          configured = deviceId;
          persisted.add(deviceId);
        },
      );
      const devices = <OrexAudioDevice>[
        OrexAudioDevice(id: 'camera-a', kind: 'videoinput', label: 'A'),
        OrexAudioDevice(id: 'camera-b', kind: 'videoinput', label: 'B'),
        OrexAudioDevice(id: 'camera-c', kind: 'videoinput', label: 'C'),
      ];

      final first = controller.cycleDevice(
        participant: null,
        canPublishMedia: false,
        devices: devices,
      );
      final second = controller.cycleDevice(
        participant: null,
        canPublishMedia: false,
        devices: devices,
      );
      await Future<void>.delayed(Duration.zero);

      expect(persistCount, 1);
      firstPersist.complete();
      await secondStarted.future;
      expect(persistCount, 2);
      secondPersist.complete();
      await Future.wait([first, second]);

      expect(persisted, ['camera-b', 'camera-c']);
    });
  });
}
