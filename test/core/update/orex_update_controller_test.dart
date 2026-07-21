import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orex_messenger/core/config/app_version.dart';
import 'package:orex_messenger/core/update/orex_update_controller.dart';
import 'package:orex_messenger/core/update/orex_update_models.dart';
import 'package:orex_messenger/core/update/orex_update_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUpdatePlatform implements OrexUpdatePlatform {
  _FakeUpdatePlatform({this.channel = 'debug'});

  final String channel;

  @override
  bool get supportsInstall => true;

  @override
  String get platformLabel => 'Windows x64';

  @override
  Future<String?> distributionChannel() async => channel;

  @override
  Future<String?> artifactKey() async => 'windows-x64';

  @override
  Future<String> download(
    OrexUpdateArtifact artifact, {
    required OrexUpdateCancellationToken cancellationToken,
    required OrexUpdateProgressCallback onProgress,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> launchInstaller(String filePath) {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteFile(String filePath) async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('finds a newer build and loads optional notes', () async {
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/latest.json')) {
        return http.Response(
          '''{
            "version":"0.4.4",
            "build":8,
            "notes_url":"/updates/debug/0.4.4+8/notes.md",
            "artifacts":{
              "windows-x64":{
                "url":"/updates/debug/0.4.4+8/Orex-Setup-0.4.4+8.exe",
                "size_bytes":4096
              }
            }
          }''',
          200,
        );
      }
      return http.Response(
        'Исправления звонков',
        200,
        headers: const <String, String>{
          'content-type': 'text/plain; charset=utf-8',
        },
      );
    });
    final controller = await OrexUpdateController.create(
      const OrexAppVersion(version: '0.4.4', buildNumber: '7'),
      updateBaseUri: Uri.parse('https://orex.example/updates/'),
      channel: 'debug',
      client: client,
      platform: _FakeUpdatePlatform(),
    );

    await controller.check();

    expect(controller.state, OrexUpdateCheckState.available);
    expect(controller.availableRelease?.build, 8);
    expect(controller.availableRelease?.notes, 'Исправления звонков');
    expect(controller.shouldShowBanner, isTrue);

    await controller.dismissAvailableBanner();
    expect(controller.shouldShowBanner, isFalse);
    controller.dispose();
  });

  test('rejects mismatched native and Dart channels before HTTP', () async {
    var requestCount = 0;
    final controller = await OrexUpdateController.create(
      const OrexAppVersion(version: '0.4.4', buildNumber: '7'),
      updateBaseUri: Uri.parse('https://orex.example/updates/'),
      channel: 'debug',
      client: MockClient((_) async {
        requestCount++;
        return http.Response('{}', 200);
      }),
      platform: _FakeUpdatePlatform(channel: 'stable'),
    );

    await controller.check();

    expect(requestCount, 0);
    expect(controller.state, OrexUpdateCheckState.error);
    expect(controller.errorMessage, contains('Native-сборка'));
    controller.dispose();
  });

  test('does not offer the installed build', () async {
    final controller = await OrexUpdateController.create(
      const OrexAppVersion(version: '0.4.4', buildNumber: '8'),
      updateBaseUri: Uri.parse('https://orex.example/updates/'),
      channel: 'stable',
      client: MockClient(
        (_) async => http.Response(
          '''{
            "version":"0.4.4",
            "build":8,
            "artifacts":{
              "windows-x64":{
                "url":"/updates/stable/0.4.4+8/Orex-Setup-0.4.4+8.exe"
              }
            }
          }''',
          200,
        ),
      ),
      platform: _FakeUpdatePlatform(channel: 'stable'),
    );

    await controller.check();

    expect(controller.state, OrexUpdateCheckState.upToDate);
    expect(controller.availableRelease, isNull);
    controller.dispose();
  });
}
