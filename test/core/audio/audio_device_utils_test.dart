import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/audio/audio_device_utils.dart';

void main() {
  group('orexHasReadableAudioInputLabels', () {
    test(
      'requires a non-empty audio-input label before skipping permission',
      () {
        expect(
          orexHasReadableAudioInputLabels(const <Map<String, String>>[
            <String, String>{
              'deviceId': 'mic-1',
              'kind': 'audioinput',
              'label': '',
            },
            <String, String>{
              'deviceId': 'speaker-1',
              'kind': 'audiooutput',
              'label': 'Speakers',
            },
          ]),
          isFalse,
        );

        expect(
          orexHasReadableAudioInputLabels(const <Map<String, String>>[
            <String, String>{
              'deviceId': 'mic-1',
              'kind': 'audioinput',
              'label': 'USB Microphone',
            },
          ]),
          isTrue,
        );
      },
    );

    test(
      'web does not reopen the default input after labels are available',
      () {
        const labeledInput = <Map<String, String>>[
          <String, String>{
            'deviceId': 'usb-mic',
            'kind': 'audioinput',
            'label': 'USB Microphone',
          },
        ];

        expect(
          orexShouldRequestAudioPermission(
            requestPermission: true,
            isWeb: true,
            rawDevices: labeledInput,
          ),
          isFalse,
        );
        expect(
          orexShouldRequestAudioPermission(
            requestPermission: true,
            isWeb: true,
            rawDevices: const <Map<String, String>>[],
          ),
          isTrue,
        );
        expect(
          orexShouldRequestAudioPermission(
            requestPermission: true,
            isWeb: false,
            rawDevices: labeledInput,
          ),
          isTrue,
        );
      },
    );

    test('uses the chosen web microphone as an exact constraint', () {
      expect(
        orexAudioPermissionConstraint(' usb-mic ', isWeb: true),
        <String, dynamic>{
          'deviceId': <String, String>{'exact': 'usb-mic'},
        },
      );
      expect(orexAudioPermissionConstraint(null, isWeb: true), isTrue);
    });
  });

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

  group('web Bluetooth output routing', () {
    const handsFree = OrexAudioDevice(
      id: 'bt-hfp',
      kind: 'audiooutput',
      label: 'Headset (WH-1000XM5 Hands-Free AG Audio)',
      category: 'bluetooth_hands_free',
    );
    const stereo = OrexAudioDevice(
      id: 'bt-stereo',
      kind: 'audiooutput',
      label: 'Headphones (WH-1000XM5 Stereo)',
      category: 'headphones',
    );

    test('recognizes strong Hands-Free profile labels', () {
      expect(
        orexLooksLikeBluetoothHandsFreeOutput(
          'WH-1000XM5 Hands-Free AG Audio',
        ),
        isTrue,
      );
      expect(
        orexLooksLikeBluetoothHandsFreeOutput('WH-1000XM5 Stereo'),
        isFalse,
      );
    });

    test('hides HFP duplicate when a stereo endpoint exists', () {
      final visible = orexFilterRedundantWebHandsFreeOutputs(
        const <OrexAudioDevice>[handsFree, stereo],
      );

      expect(visible.map((device) => device.id), <String>['bt-stereo']);
    });

    test('keeps standalone HFP output when there is no stereo sibling', () {
      final visible = orexFilterRedundantWebHandsFreeOutputs(
        const <OrexAudioDevice>[handsFree],
      );

      expect(visible.map((device) => device.id), <String>['bt-hfp']);
    });

    test('remaps a persisted HFP id to the stereo endpoint', () {
      expect(
        orexResolvePreferredWebAudioOutputId(
          const <OrexAudioDevice>[handsFree, stereo],
          selectedId: 'bt-hfp',
        ),
        'bt-stereo',
      );
      expect(
        orexResolvePreferredWebAudioOutputId(
          const <OrexAudioDevice>[handsFree, stereo],
          selectedId: 'bt-stereo',
        ),
        'bt-stereo',
      );
    });

    test('pins the stereo endpoint behind the browser default alias', () {
      expect(
        orexResolvePreferredWebAudioOutputId(
          const <OrexAudioDevice>[handsFree, stereo],
          selectedId: null,
          defaultOutputLabel:
              'Default - Headphones (WH-1000XM5 Stereo)',
        ),
        'bt-stereo',
      );
    });

    test('reads the browser default output label', () {
      expect(
        orexDefaultAudioOutputLabel(const <Map<String, String>>[
          <String, String>{
            'deviceId': 'default',
            'kind': 'audiooutput',
            'label': 'Default - Headphones (WH-1000XM5 Stereo)',
          },
        ]),
        'Default - Headphones (WH-1000XM5 Stereo)',
      );
    });
  });
}
