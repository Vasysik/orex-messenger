import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'orex_update_models.dart';
import 'orex_update_platform_base.dart';

OrexUpdatePlatform createOrexUpdatePlatform() => _IoUpdatePlatform();

class _IoUpdatePlatform implements OrexUpdatePlatform {
  static const MethodChannel _androidChannel = MethodChannel('orex/update');

  @override
  bool get supportsInstall => Platform.isWindows || Platform.isAndroid;

  @override
  String get platformLabel {
    if (Platform.isWindows) return 'Windows x64';
    if (Platform.isAndroid) return 'Android';
    return Platform.operatingSystem;
  }

  @override
  Future<String?> distributionChannel() async {
    if (Platform.isWindows) {
      final executable = p
          .basenameWithoutExtension(Platform.resolvedExecutable)
          .trim()
          .toLowerCase();
      return switch (executable) {
        'orex_messenger_debug' => 'debug',
        'orex_messenger' => 'stable',
        _ => null,
      };
    }
    if (Platform.isAndroid) {
      return _androidChannel.invokeMethod<String>('getDistribution');
    }
    return null;
  }

  @override
  Future<String?> artifactKey() async {
    if (Platform.isWindows) return 'windows-x64';
    if (!Platform.isAndroid) return null;

    final abi = await _androidChannel.invokeMethod<String>('getPrimaryAbi');
    return switch (abi?.trim().toLowerCase()) {
      'arm64-v8a' => 'android-arm64-v8a',
      'armeabi-v7a' => 'android-armeabi-v7a',
      _ => null,
    };
  }

  @override
  Future<String> download(
    OrexUpdateArtifact artifact, {
    required OrexUpdateCancellationToken cancellationToken,
    required OrexUpdateProgressCallback onProgress,
  }) async {
    if (!supportsInstall) {
      throw UnsupportedError('Updates are unavailable on this platform');
    }
    _validateArtifact(artifact);
    cancellationToken.throwIfCancelled();

    final client = http.Client();
    cancellationToken.addCancelListener(client.close);
    final request = http.Request('GET', artifact.uri)
      ..followRedirects = false;
    final Directory tempRoot = await getTemporaryDirectory();
    final directory = Directory(p.join(tempRoot.path, 'orex-updates'));
    await directory.create(recursive: true);

    final fileName = p.basename(artifact.uri.path);
    final finalFile = File(p.join(directory.path, fileName));
    final partialFile = File('${finalFile.path}.part');
    await _deleteIfExists(partialFile);

    IOSink? sink;
    try {
      final response = await client.send(request).timeout(
            const Duration(seconds: 20),
          );
      cancellationToken.throwIfCancelled();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Update download returned HTTP ${response.statusCode}',
          uri: artifact.uri,
        );
      }
      final responseLength = response.contentLength;
      final expectedLength = artifact.sizeBytes ??
          (responseLength != null && responseLength > 0 ? responseLength : null);
      var received = 0;
      sink = partialFile.openWrite();
      onProgress(received, expectedLength);
      await for (final chunk in response.stream) {
        cancellationToken.throwIfCancelled();
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, expectedLength);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      cancellationToken.throwIfCancelled();

      if (artifact.sizeBytes != null && received != artifact.sizeBytes) {
        throw const HttpException(
          'Downloaded update size does not match the feed',
        );
      }
      if (responseLength != null &&
          responseLength >= 0 &&
          received != responseLength) {
        throw const HttpException('Downloaded update is incomplete');
      }

      await _deleteIfExists(finalFile);
      await partialFile.rename(finalFile.path);
      return finalFile.path;
    } on OrexUpdateCancelled {
      await _closeSink(sink);
      await _deleteIfExists(partialFile);
      rethrow;
    } on TimeoutException {
      await _closeSink(sink);
      await _deleteIfExists(partialFile);
      if (cancellationToken.isCancelled) throw const OrexUpdateCancelled();
      rethrow;
    } on http.ClientException {
      await _closeSink(sink);
      await _deleteIfExists(partialFile);
      if (cancellationToken.isCancelled) throw const OrexUpdateCancelled();
      rethrow;
    } catch (_) {
      await _closeSink(sink);
      await _deleteIfExists(partialFile);
      rethrow;
    } finally {
      client.close();
    }
  }

  @override
  Future<void> launchInstaller(String filePath) async {
    if (Platform.isWindows) {
      await Process.start(
        filePath,
        const <String>[],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      return;
    }
    if (Platform.isAndroid) {
      final result = await _androidChannel.invokeMethod<String>(
        'installApk',
        <String, Object?>{'path': filePath},
      );
      if (result == 'permission_required') {
        throw const OrexUpdateInstallPermissionRequired();
      }
      if (result != 'launched') {
        throw StateError('Android не смог открыть системный установщик');
      }
      return;
    }
    throw UnsupportedError('Updates are unavailable on this platform');
  }

  @override
  Future<void> deleteFile(String filePath) => _deleteIfExists(File(filePath));

  void _validateArtifact(OrexUpdateArtifact artifact) {
    if (artifact.uri.scheme != 'https' || artifact.uri.userInfo.isNotEmpty) {
      throw const FormatException('Update artifact must use HTTPS');
    }
    final extension = p.extension(artifact.uri.path).toLowerCase();
    if (Platform.isWindows && extension != '.exe') {
      throw const FormatException('Windows update must be an EXE installer');
    }
    if (Platform.isAndroid && extension != '.apk') {
      throw const FormatException('Android update must be an APK');
    }
    final name = p.basename(artifact.uri.path);
    if (name.isEmpty || name == '.' || name == '..') {
      throw const FormatException('Update artifact has an invalid filename');
    }
  }

  Future<void> _closeSink(IOSink? sink) async {
    if (sink == null) return;
    try {
      await sink.close();
    } catch (_) {
      // Cleanup after cancellation or a failed stream is best-effort.
    }
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Cleanup is best-effort. A later download uses a separate .part write and
      // will report the real filesystem error if the path is unusable.
    }
  }
}
