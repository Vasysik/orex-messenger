import 'package:package_info_plus/package_info_plus.dart';

class OrexAppVersion {
  const OrexAppVersion({
    required this.version,
    required this.buildNumber,
  });

  static const fallback = OrexAppVersion(version: '0.3.3', buildNumber: '3');

  final String version;
  final String buildNumber;

  String get label => '$version+$buildNumber';
  String get versionLine => 'Версия: $version';
  String get buildLine => 'Сборка: $buildNumber';
  String get settingsSubtitle => 'Версия $version · Сборка $buildNumber';

  /// Android split-per-ABI APKs can expose a platform `versionCode` like
  /// `2003` for logical build `3` (Flutter encodes ABI in the thousands and
  /// keeps the app build in the lower three digits). For user-facing labels we
  /// show the logical app build, not the Android installer code. The real
  /// platform versionCode stays unchanged.
  static String displayBuildNumberFromPlatform(String raw) {
    final value = raw.trim();
    final code = int.tryParse(value);
    if (code == null) return value;

    final logicalBuild = code % 1000;
    final abiPrefix = code ~/ 1000;
    if (abiPrefix >= 1 && abiPrefix <= 9 && logicalBuild > 0) {
      return logicalBuild.toString();
    }
    return value;
  }

  static Future<OrexAppVersion> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final platformVersion = info.version.trim();
      final version =
          platformVersion.isEmpty ? fallback.version : platformVersion;
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
