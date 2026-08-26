import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_version.dart';
import '../config/orex_config.dart';
import '../logging/orex_logger.dart';
import 'orex_update_models.dart';
import 'orex_update_platform.dart';

enum OrexUpdateCheckState {
  idle,
  checking,
  upToDate,
  available,
  error,
  unsupported,
}

class OrexUpdateController extends ChangeNotifier {
  OrexUpdateController._({
    required this.currentVersion,
    required this.updateBaseUri,
    required this.channel,
    required this._preferences,
    required this._client,
    required this._platform,
  });

  static const int _maximumFeedBytes = 128 * 1024;
  static const int _maximumNotesBytes = 256 * 1024;

  final OrexAppVersion currentVersion;
  final Uri updateBaseUri;
  final String channel;
  final SharedPreferences _preferences;
  final http.Client _client;
  final OrexUpdatePlatform _platform;

  OrexUpdateCheckState _state = OrexUpdateCheckState.idle;
  OrexUpdateRelease? _availableRelease;
  OrexUpdateArtifact? _selectedArtifact;
  String? _errorMessage;
  String? _dismissedRelease;
  DateTime? _lastCheckedAt;
  bool _disposed = false;

  OrexUpdateCheckState get state => _state;
  OrexUpdateRelease? get availableRelease => _availableRelease;
  OrexUpdateArtifact? get selectedArtifact => _selectedArtifact;
  String? get errorMessage => _errorMessage;
  DateTime? get lastCheckedAt => _lastCheckedAt;
  bool get isChecking => _state == OrexUpdateCheckState.checking;
  bool get supportsInstall => _platform.supportsInstall;
  String get platformLabel => _platform.platformLabel;

  int get currentBuild => int.tryParse(currentVersion.buildNumber) ?? 0;

  bool get shouldShowBanner {
    final release = _availableRelease;
    return release != null &&
        release.label != _dismissedRelease &&
        _selectedArtifact != null;
  }

  String get settingsTitle {
    if (_availableRelease != null && _selectedArtifact != null) {
      return 'Обновить приложение';
    }
    return switch (_state) {
      OrexUpdateCheckState.checking => 'Проверяем обновления…',
      OrexUpdateCheckState.upToDate => 'Установлена последняя версия',
      OrexUpdateCheckState.error => 'Не удалось проверить обновления',
      OrexUpdateCheckState.unsupported => 'Обновления в приложении недоступны',
      _ => 'Проверить обновления',
    };
  }

  String get settingsSubtitle {
    final release = _availableRelease;
    if (release != null && _selectedArtifact != null) {
      return 'Доступна версия ${release.displayLabel}';
    }
    return switch (_state) {
      OrexUpdateCheckState.checking => 'Запрашиваем ${updateBaseUri.host}',
      OrexUpdateCheckState.upToDate => currentVersion.settingsSubtitle,
      OrexUpdateCheckState.error =>
        _errorMessage ?? 'Нажмите, чтобы повторить проверку',
      OrexUpdateCheckState.unsupported =>
        'Web-версия обновляется при перезагрузке страницы',
      _ => 'Канал: $channel',
    };
  }

  static Future<OrexUpdateController> create(
    OrexAppVersion currentVersion, {
    Uri? updateBaseUri,
    String? channel,
    SharedPreferences? preferences,
    http.Client? client,
    OrexUpdatePlatform? platform,
  }) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    final resolvedBase = _withTrailingSlash(
      updateBaseUri ?? OrexConfig.updateBaseUri,
    );
    if (resolvedBase.scheme != 'https' ||
        resolvedBase.host.isEmpty ||
        resolvedBase.userInfo.isNotEmpty ||
        resolvedBase.hasQuery ||
        resolvedBase.hasFragment) {
      throw ArgumentError.value(
        resolvedBase,
        'updateBaseUri',
        'must be a credential-free absolute HTTPS URL',
      );
    }
    final resolvedChannel = (channel ?? OrexConfig.updateChannel)
        .trim()
        .toLowerCase();
    if (resolvedChannel != 'stable' && resolvedChannel != 'debug') {
      throw ArgumentError.value(
        resolvedChannel,
        'channel',
        'must be stable or debug',
      );
    }
    final controller = OrexUpdateController._(
      currentVersion: currentVersion,
      updateBaseUri: resolvedBase,
      channel: resolvedChannel,
      preferences: prefs,
      client: client ?? http.Client(),
      platform: platform ?? createOrexUpdatePlatform(),
    );
    controller._restorePreferences();
    if (!controller.supportsInstall) {
      controller._state = OrexUpdateCheckState.unsupported;
    }
    return controller;
  }

  void _restorePreferences() {
    _dismissedRelease = _preferences.getString(_dismissedPreferenceKey);
    final lastCheckMs = _preferences.getInt(_lastCheckPreferenceKey);
    if (lastCheckMs != null && lastCheckMs > 0) {
      _lastCheckedAt = DateTime.fromMillisecondsSinceEpoch(lastCheckMs);
    }
  }

  String get _dismissedPreferenceKey =>
      'orex_update_dismissed_${channel.toLowerCase()}';
  String get _lastCheckPreferenceKey =>
      'orex_update_last_check_${channel.toLowerCase()}';

  Future<void> check({bool manual = true}) async {
    if (isChecking) return;
    if (!supportsInstall) {
      _setState(OrexUpdateCheckState.unsupported);
      return;
    }

    _errorMessage = null;
    _setState(OrexUpdateCheckState.checking);
    final feedUri = updateBaseUri.resolve('$channel/latest.json');
    try {
      final nativeChannel = await _platform.distributionChannel();
      if (nativeChannel != null && nativeChannel != channel) {
        throw StateError(
          'Native-сборка использует канал $nativeChannel, а Dart — $channel. '
          'Пересоберите приложение с совпадающими параметрами.',
        );
      }
      final response = await _getWithoutRedirects(
        feedUri,
        maxBytes: _maximumFeedBytes,
        timeout: const Duration(seconds: 12),
        headers: const <String, String>{
          'Accept': 'application/json',
          'Cache-Control': 'no-cache',
        },
      );
      if (response.statusCode != 200) {
        throw http.ClientException(
          'Update feed returned HTTP ${response.statusCode}',
          feedUri,
        );
      }

      var release = OrexUpdateRelease.parse(
        utf8.decode(response.bodyBytes),
        feedUri: feedUri,
        updateBaseUri: updateBaseUri,
      );
      final artifactKey = await _platform.artifactKey();
      if (artifactKey == null) {
        throw StateError(
          'Для архитектуры этого устройства нет поддерживаемой сборки',
        );
      }
      final artifact = release.artifactFor(artifactKey);
      if (release.build <= currentBuild) {
        _availableRelease = null;
        _selectedArtifact = null;
        await _recordSuccessfulCheck();
        _setState(OrexUpdateCheckState.upToDate);
        return;
      }
      if (artifact == null) {
        throw StateError(
          'В релизе ${release.label} нет файла для $artifactKey',
        );
      }

      final notes = await _loadNotes(release.notesUri);
      release = release.copyWithNotes(notes);
      _availableRelease = release;
      _selectedArtifact = artifact;
      await _recordSuccessfulCheck();
      _setState(OrexUpdateCheckState.available);
    } catch (error, stackTrace) {
      _errorMessage = _friendlyError(error);
      OrexLog.d(
        'Updater',
        'update check failed channel=$channel manual=$manual',
        error,
        stackTrace,
      );
      _setState(OrexUpdateCheckState.error);
    }
  }

  Future<String?> _loadNotes(Uri? notesUri) async {
    if (notesUri == null) return null;
    try {
      final response = await _getWithoutRedirects(
        notesUri,
        maxBytes: _maximumNotesBytes,
        timeout: const Duration(seconds: 8),
        headers: const <String, String>{'Accept': 'text/markdown, text/plain'},
      );
      if (response.statusCode != 200) return null;
      final text = utf8.decode(response.bodyBytes).trim();
      return text.isEmpty ? null : text;
    } catch (error) {
      OrexLog.d('Updater', 'release notes download failed', error);
      return null;
    }
  }

  Future<({int statusCode, Uint8List bodyBytes})> _getWithoutRedirects(
    Uri uri, {
    required int maxBytes,
    required Duration timeout,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll(headers);
    final response = await _client.send(request).timeout(timeout);
    final declaredLength = response.contentLength;
    if (declaredLength != null && declaredLength > maxBytes) {
      throw http.ClientException('Update response is too large', uri);
    }

    final builder = BytesBuilder(copy: false);
    var received = 0;
    await for (final chunk in response.stream.timeout(timeout)) {
      received += chunk.length;
      if (received > maxBytes) {
        throw http.ClientException('Update response is too large', uri);
      }
      builder.add(chunk);
    }
    return (statusCode: response.statusCode, bodyBytes: builder.takeBytes());
  }

  Future<void> _recordSuccessfulCheck() async {
    _lastCheckedAt = DateTime.now();
    await _preferences.setInt(
      _lastCheckPreferenceKey,
      _lastCheckedAt!.millisecondsSinceEpoch,
    );
  }

  Future<void> dismissAvailableBanner() async {
    final release = _availableRelease;
    if (release == null) return;
    _dismissedRelease = release.label;
    await _preferences.setString(_dismissedPreferenceKey, release.label);
    _notify();
  }

  Future<String> downloadAvailable({
    required OrexUpdateCancellationToken cancellationToken,
    required OrexUpdateProgressCallback onProgress,
  }) {
    final release = _availableRelease;
    final artifact = _selectedArtifact;
    if (release == null || artifact == null || release.build <= currentBuild) {
      throw StateError('Нет доступного обновления для установки');
    }
    return _platform.download(
      artifact,
      cancellationToken: cancellationToken,
      onProgress: onProgress,
    );
  }

  Future<void> launchInstaller(String filePath) =>
      _platform.launchInstaller(filePath);

  Future<void> deleteDownloadedFile(String filePath) =>
      _platform.deleteFile(filePath);

  void _setState(OrexUpdateCheckState value) {
    _state = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _friendlyError(Object error) {
    if (error is TimeoutException) {
      return 'Сервер обновлений не ответил вовремя';
    }
    if (error is StateError) {
      return error.toString().replaceFirst('Bad state: ', '');
    }
    if (error is OrexUpdateFormatException) {
      return 'Сервер вернул некорректное описание релиза';
    }
    return 'Проверьте подключение и повторите попытку';
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }

  static Uri _withTrailingSlash(Uri uri) {
    final path = uri.path.endsWith('/') ? uri.path : '${uri.path}/';
    return uri.replace(path: path, query: null, fragment: null);
  }
}
