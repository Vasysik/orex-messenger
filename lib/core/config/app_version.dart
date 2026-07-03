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

  /// Android split-per-ABI APKs can expose a platform `versionCode` like
  /// `2002` for logical build `2` (Flutter encodes ABI in the lower digits).
  /// For user-facing labels we show the logical app build, not the Android
  /// installer code. The real platform versionCode stays unchanged.
  static String displayBuildNumberFromPlatform(String raw) {
    final value = raw.trim();
    final code = int.tryParse(value);
    if (code == null) return value;

    final abiSuffix = code % 1000;
    if (code >= 1000 && abiSuffix >= 1 && abiSuffix <= 3) {
      return (code ~/ 1000).toString();
    }
    return value;
  }

  static Future<OrexAppVersion> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final version = info.version.trim().isEmpty ? fallback.version : info.version.trim();
      final rawBuild = info.buildNumber.trim();
      final build = rawBuild.isEmpty
          ? fallback.buildNumber
          : displayBuildNumberFromPlatform(rawBuild);
      return OrexAppVersion(version: version, buildNumber: build);
    } catch (_) {
      return fallback;
    }
  }
}
