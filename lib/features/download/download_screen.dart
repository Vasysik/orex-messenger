import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/config/orex_config.dart';
import '../../core/platform/orex_download_page.dart';
import '../../core/update/orex_update_models.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/theme/theme_controller.dart';
import '../../shared/widgets/orex_app_brand.dart';

class OrexDownloadApp extends StatefulWidget {
  const OrexDownloadApp({super.key});

  @override
  State<OrexDownloadApp> createState() => _OrexDownloadAppState();
}

class _OrexDownloadAppState extends State<OrexDownloadApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreTheme());
  }

  Future<void> _restoreTheme() async {
    final controller = await ThemeController.load();
    final mode = controller.mode;
    controller.dispose();
    if (!mounted) return;
    setState(() => _themeMode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Скачать $orexAppName',
      debugShowCheckedModeBanner: false,
      theme: OrexTheme.light,
      darkTheme: OrexTheme.dark,
      themeMode: _themeMode,
      home: const OrexDownloadScreen(),
    );
  }
}

class OrexDownloadScreen extends StatefulWidget {
  const OrexDownloadScreen({super.key});

  @override
  State<OrexDownloadScreen> createState() => _OrexDownloadScreenState();
}

class _OrexDownloadScreenState extends State<OrexDownloadScreen> {
  static const int _maximumFeedBytes = 128 * 1024;
  static const Duration _timeout = Duration(seconds: 12);

  final http.Client _client = http.Client();
  OrexUpdateRelease? _release;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_loadRelease());
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadRelease() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final baseUri = OrexConfig.updateBaseUri;
    final feedUri = baseUri.resolve('stable/latest.json');
    try {
      final request = http.Request('GET', feedUri)
        ..followRedirects = false
        ..headers.addAll(const <String, String>{
          'Accept': 'application/json',
          'Cache-Control': 'no-cache',
        });
      final response = await _client.send(request).timeout(_timeout);
      if (response.statusCode != 200) {
        throw http.ClientException(
          'Update feed returned HTTP ${response.statusCode}',
          feedUri,
        );
      }

      final declaredLength = response.contentLength;
      if (declaredLength != null && declaredLength > _maximumFeedBytes) {
        throw const FormatException('Update feed is too large');
      }

      final builder = BytesBuilder(copy: false);
      var received = 0;
      await for (final chunk in response.stream.timeout(_timeout)) {
        received += chunk.length;
        if (received > _maximumFeedBytes) {
          throw const FormatException('Update feed is too large');
        }
        builder.add(chunk);
      }

      final release = OrexUpdateRelease.parse(
        utf8.decode(builder.takeBytes()),
        feedUri: feedUri,
        updateBaseUri: baseUri,
      );
      if (!mounted) return;
      setState(() {
        _release = release;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _release = null;
        _loading = false;
        _error = 'Не удалось получить актуальную стабильную сборку.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: GlassPanel(
                  borderRadius: 28,
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const OrexBrandHeader(
                        iconSize: 116,
                        showVersion: false,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Скачать приложение',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: _loading
                            ? const _LoadingReleaseStatus()
                            : _error != null
                                ? _ReleaseError(
                                    message: _error!,
                                    onRetry: _loadRelease,
                                  )
                                : Text(
                                    'Стабильная версия ${release!.version} · '
                                    'Сборка ${release.build}',
                                    key: ValueKey(release.label),
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                      ),
                      const SizedBox(height: 20),
                      _DownloadTile(
                        icon: Icons.desktop_windows_rounded,
                        title: 'Windows x64',
                        artifact: release?.artifactFor('windows-x64'),
                      ),
                      const SizedBox(height: 10),
                      _DownloadTile(
                        icon: Icons.android_rounded,
                        title: 'Android · ARM64',
                        subtitle: 'Для современных устройств',
                        artifact: release?.artifactFor('android-arm64-v8a'),
                      ),
                      const SizedBox(height: 10),
                      _DownloadTile(
                        icon: Icons.android_rounded,
                        title: 'Android · ARMv7',
                        subtitle: 'Для старых 32-битных устройств',
                        artifact: release?.artifactFor('android-armeabi-v7a'),
                        secondary: true,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Orex пока находится в стадии prerelease.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingReleaseStatus extends StatelessWidget {
  const _LoadingReleaseStatus();

  @override
  Widget build(BuildContext context) {
    return const Row(
      key: ValueKey('loading'),
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox.square(
          dimension: 15,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(width: 8),
        Text('Получаем актуальную версию…'),
      ],
    );
  }
}

class _ReleaseError extends StatelessWidget {
  const _ReleaseError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('error'),
      children: [
        Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
        ),
        const SizedBox(height: 4),
        TextButton(onPressed: onRetry, child: const Text('Повторить')),
      ],
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({
    required this.icon,
    required this.title,
    required this.artifact,
    this.subtitle,
    this.secondary = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final OrexUpdateArtifact? artifact;
  final bool secondary;

  @override
  Widget build(BuildContext context) {
    final artifact = this.artifact;
    final enabled = artifact != null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final foreground = secondary
        ? (isDark ? OrexColors.darkText : OrexColors.lightText)
        : OrexColors.cream;
    final size = artifact?.sizeBytes;
    final detail = [
      if (size != null) _formatBytes(size),
      ?subtitle,
    ].join(' · ');

    return Semantics(
      button: true,
      enabled: enabled,
      child: Opacity(
        opacity: enabled ? 1 : 0.46,
        child: Material(
          color: secondary
              ? OrexColors.walnut.withValues(alpha: isDark ? 0.12 : 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              gradient: secondary ? null : OrexColors.copperGradient,
              borderRadius: BorderRadius.circular(16),
              border: secondary
                  ? Border.all(
                      color: OrexColors.copper.withValues(alpha: 0.24),
                    )
                  : null,
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: artifact == null
                  ? null
                  : () => openOrexDownloadArtifact(artifact.uri),
              mouseCursor: artifact == null
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    Icon(icon, size: 24, color: foreground),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(
                                  color: foreground,
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          if (detail.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              detail,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: foreground.withValues(alpha: 0.78),
                                  ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Icon(
                      Icons.download_rounded,
                      size: 21,
                      color: foreground.withValues(alpha: 0.9),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatBytes(int bytes) {
    final megabytes = bytes / (1024 * 1024);
    final digits = megabytes < 10 ? 1 : 0;
    return '${megabytes.toStringAsFixed(digits)} МБ';
  }
}
