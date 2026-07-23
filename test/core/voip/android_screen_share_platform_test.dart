import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/android_screen_share_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const screenShareChannel = MethodChannel('orex/screen_share');
  const webRtcEventChannel = 'FlutterWebRTC.Event';
  const codec = StandardMethodCodec();

  test('starts the Android foreground owner before capture', () async {
    final calls = <MethodCall>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenShareChannel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'startForeground' => true,
            'isForegroundReady' => true,
            'stopForeground' => true,
            _ => null,
          };
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(screenShareChannel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    expect(await OrexAndroidScreenSharePlatform.startForeground(), isTrue);
    await OrexAndroidScreenSharePlatform.stopForeground();

    expect(calls.map((call) => call.method), [
      'startForeground',
      'isForegroundReady',
      'stopForeground',
    ]);
  });

  test('an armed Android stop is delivered before a track id exists', () async {
    final receivedReasons = <String>[];
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
          webRtcEventChannel,
          (_) async => codec.encodeSuccessEnvelope(null),
        );
    void stopHandler(String reason) {
      receivedReasons.add(reason);
    }

    OrexAndroidScreenSharePlatform.setStopHandler(stopHandler);
    OrexAndroidScreenSharePlatform.armStopHandling();
    addTearDown(() {
      OrexAndroidScreenSharePlatform.clearTrackedProjection();
      OrexAndroidScreenSharePlatform.clearStopHandler(stopHandler);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler(webRtcEventChannel, null);
      debugDefaultTargetPlatformOverride = null;
    });

    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          screenShareChannel.name,
          codec.encodeMethodCall(
            const MethodCall('screenShareStopRequested', <String, String>{
              'reason': 'notification',
            }),
          ),
          null,
        );
    await Future<void>.delayed(Duration.zero);

    expect(receivedReasons, ['notification']);
  });
}
