import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/platform/orex_system_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('orex/system_ui');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'Android fullscreen forwards hide and restore requests to native UI',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;

      expect(await OrexSystemUi.setCallMediaFullscreen(true), isTrue);
      expect(await OrexSystemUi.setCallMediaFullscreen(false), isTrue);

      expect(calls, hasLength(2));
      expect(calls[0].method, 'setMediaFullscreen');
      expect(calls[0].arguments, <String, Object?>{'enabled': true});
      expect(calls[1].method, 'setMediaFullscreen');
      expect(calls[1].arguments, <String, Object?>{'enabled': false});
    },
  );

  test(
    'non-Android platforms do not touch the native fullscreen channel',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      expect(await OrexSystemUi.setCallMediaFullscreen(true), isFalse);
      expect(calls, isEmpty);
    },
  );
}
