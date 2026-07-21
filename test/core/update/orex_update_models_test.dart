import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/update/orex_update_models.dart';

void main() {
  final base = Uri.parse('https://orex.example/updates/');
  final feed = Uri.parse('https://orex.example/updates/debug/latest.json');

  test('parses a trusted versioned release', () {
    final release = OrexUpdateRelease.parse(
      '''{
        "version": "0.4.4",
        "build": 8,
        "notes_url": "/updates/debug/0.4.4+8/notes.md",
        "artifacts": {
          "windows-x64": {
            "url": "/updates/debug/0.4.4+8/Orex-Setup-0.4.4+8.exe",
            "size_bytes": 1234
          }
        }
      }''',
      feedUri: feed,
      updateBaseUri: base,
    );

    expect(release.label, '0.4.4+8');
    expect(release.notesUri.toString(),
        'https://orex.example/updates/debug/0.4.4+8/notes.md');
    expect(release.artifactFor('windows-x64')?.sizeBytes, 1234);
  });

  test('rejects an artifact outside the configured update origin', () {
    expect(
      () => OrexUpdateRelease.parse(
        '''{
          "version": "0.4.4",
          "build": 8,
          "artifacts": {
            "windows-x64": {
              "url": "https://evil.example/Orex-Setup.exe"
            }
          }
        }''',
        feedUri: feed,
        updateBaseUri: base,
      ),
      throwsA(isA<OrexUpdateFormatException>()),
    );
  });

  test('rejects a non-numeric release version', () {
    expect(
      () => OrexUpdateRelease.parse(
        '''{
          "version": "latest",
          "build": 8,
          "artifacts": {
            "windows-x64": {
              "url": "/updates/debug/latest/file.exe"
            }
          }
        }''',
        feedUri: feed,
        updateBaseUri: base,
      ),
      throwsA(isA<OrexUpdateFormatException>()),
    );
  });
  test('rejects an artifact from another update channel', () {
    expect(
      () => OrexUpdateRelease.parse(
        '''{
          "version": "0.4.4",
          "build": 8,
          "artifacts": {
            "windows-x64": {
              "url": "/updates/stable/0.4.4+8/Orex-Setup-0.4.4+8.exe"
            }
          }
        }''',
        feedUri: feed,
        updateBaseUri: base,
      ),
      throwsA(isA<OrexUpdateFormatException>()),
    );
  });

  test('rejects an installer filename that does not match the release', () {
    expect(
      () => OrexUpdateRelease.parse(
        '''{
          "version": "0.4.4",
          "build": 8,
          "artifacts": {
            "windows-x64": {
              "url": "/updates/debug/0.4.4+8/Orex-Setup-latest.exe"
            }
          }
        }''',
        feedUri: feed,
        updateBaseUri: base,
      ),
      throwsA(isA<OrexUpdateFormatException>()),
    );
  });
}
