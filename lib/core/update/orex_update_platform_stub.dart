import 'orex_update_models.dart';
import 'orex_update_platform_base.dart';

OrexUpdatePlatform createOrexUpdatePlatform() => const _UnsupportedPlatform();

class _UnsupportedPlatform implements OrexUpdatePlatform {
  const _UnsupportedPlatform();

  @override
  bool get supportsInstall => false;

  @override
  String get platformLabel => 'Web';

  @override
  Future<String?> distributionChannel() async => null;

  @override
  Future<String?> artifactKey() async => null;

  @override
  Future<String> download(
    OrexUpdateArtifact artifact, {
    required OrexUpdateCancellationToken cancellationToken,
    required OrexUpdateProgressCallback onProgress,
  }) {
    throw UnsupportedError('In-app installation is unavailable on this platform');
  }

  @override
  Future<void> launchInstaller(String filePath) {
    throw UnsupportedError('In-app installation is unavailable on this platform');
  }

  @override
  Future<void> deleteFile(String filePath) async {}
}
