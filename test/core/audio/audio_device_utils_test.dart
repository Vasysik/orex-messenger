import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/audio/audio_device_utils.dart';

void main() {
  group('orexResolveCurrentDeviceId', () {
    test('resolves a stale Android earpiece id by route type/category', () {
      const devices = <OrexAudioDevice>[
        OrexAudioDevice(
          id: 'orex://android/audio-output/audio:2:41',
          kind: 'audiooutput',
          label: 'Динамик телефона',
          category: 'speaker',
        ),
        OrexAudioDevice(
          id: 'orex://android/audio-output/audio:1:42',
          kind: 'audiooutput',
          label: 'Разговорный динамик',
          category: 'earpiece',
        ),
      ];

      expect(
        orexResolveCurrentDeviceId(
          devices,
          selectedId: 'orex://android/audio-output/audio:1:7',
        ),
        'orex://android/audio-output/audio:1:42',
      );
    });
  });
}
