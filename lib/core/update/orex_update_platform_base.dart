import 'orex_update_models.dart';

typedef OrexUpdateProgressCallback = void Function(
  int receivedBytes,
  int? totalBytes,
);

class OrexUpdateCancelled implements Exception {
  const OrexUpdateCancelled();
}

class OrexUpdateInstallPermissionRequired implements Exception {
  const OrexUpdateInstallPermissionRequired();
}

class OrexUpdateCancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void addCancelListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.from(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const OrexUpdateCancelled();
  }
}

abstract class OrexUpdatePlatform {
  bool get supportsInstall;
  String get platformLabel;

  Future<String?> distributionChannel();

  Future<String?> artifactKey();

  Future<String> download(
    OrexUpdateArtifact artifact, {
    required OrexUpdateCancellationToken cancellationToken,
    required OrexUpdateProgressCallback onProgress,
  });

  Future<void> launchInstaller(String filePath);

  Future<void> deleteFile(String filePath);
}
