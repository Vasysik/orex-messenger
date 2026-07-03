import 'package:package_info_plus/package_info_plus.dart';

class OrexAppVersion {
  const OrexAppVersion({
    required this.version,
    required this.buildNumber,
  });

  static const fallback = OrexAppVersion(version: '0.0.0', buildNumber: '0');

  final String version;
  final String buildNumber;

  String get label => '$version+$buildNumber';
  String get versionLine => 'Версия: $version';
  String get buildLine => 'Сборка: $buildNumber';
  String get settingsSubtitle => 'Версия $version · Сборка $buildNumber';

  static Future<OrexAppVersion> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim().isEmpty ? fallback.version : info.version.trim();
      final build = info.buildNumber.trim().isEmpty
          ? fallback.buildNumber
          : info.buildNumber.trim();
      return OrexAppVersion(version: version, buildNumber: build);
    } catch (_) {
      return fallback;
    }
  }
}
