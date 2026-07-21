import 'package:flutter/material.dart';

import '../../core/config/orex_config.dart';
import '../../core/update/orex_update_controller.dart';
import '../../core/update/orex_update_platform.dart';
import '../theme/orex_theme.dart';

Future<void> showOrexUpdateDialog(
  BuildContext context, {
  required OrexUpdateController controller,
}) {
  if (controller.availableRelease == null ||
      controller.selectedArtifact == null) {
    return Future<void>.value();
  }
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => OrexUpdateDialog(controller: controller),
  );
}

class OrexUpdateDialog extends StatefulWidget {
  const OrexUpdateDialog({super.key, required this.controller});

  final OrexUpdateController controller;

  @override
  State<OrexUpdateDialog> createState() => _OrexUpdateDialogState();
}

enum _UpdateDialogState { information, downloading, error }

class _OrexUpdateDialogState extends State<OrexUpdateDialog> {
  _UpdateDialogState _state = _UpdateDialogState.information;
  OrexUpdateCancellationToken? _cancellationToken;
  int _receivedBytes = 0;
  int? _totalBytes;
  String? _errorMessage;
  String? _downloadedPath;
  bool _installPermissionRequired = false;

  Future<void> _startDownload() async {
    if (_state == _UpdateDialogState.downloading) return;
    final token = OrexUpdateCancellationToken();
    setState(() {
      _state = _UpdateDialogState.downloading;
      _cancellationToken = token;
      _receivedBytes = 0;
      _totalBytes = widget.controller.selectedArtifact?.sizeBytes;
      _errorMessage = null;
      _installPermissionRequired = false;
    });

    String? downloadedPath = _downloadedPath;
    try {
      if (downloadedPath == null) {
        downloadedPath = await widget.controller.downloadAvailable(
          cancellationToken: token,
          onProgress: (received, total) {
            if (!mounted || token.isCancelled) return;
            setState(() {
              _receivedBytes = received;
              _totalBytes = total;
            });
          },
        );
        _downloadedPath = downloadedPath;
      }
      token.throwIfCancelled();
      await widget.controller.launchInstaller(downloadedPath);
      _downloadedPath = null;
      if (mounted) Navigator.of(context).pop();
    } on OrexUpdateCancelled {
      if (downloadedPath != null) {
        await widget.controller.deleteDownloadedFile(downloadedPath);
      }
      _downloadedPath = null;
      if (mounted) {
        setState(() {
          _state = _UpdateDialogState.information;
          _cancellationToken = null;
          _receivedBytes = 0;
        });
      }
    } on OrexUpdateInstallPermissionRequired {
      if (mounted) {
        setState(() {
          _state = _UpdateDialogState.error;
          _cancellationToken = null;
          _installPermissionRequired = true;
          _errorMessage =
              'Разрешите установку приложений из Orex в открывшихся '
              'настройках Android, вернитесь сюда и нажмите «Установить».';
        });
      }
    } catch (_) {
      if (downloadedPath != null) {
        await widget.controller.deleteDownloadedFile(downloadedPath);
      }
      _downloadedPath = null;
      if (mounted) {
        setState(() {
          _state = _UpdateDialogState.error;
          _cancellationToken = null;
          _installPermissionRequired = false;
          _errorMessage =
              'Не удалось скачать или открыть установщик. Проверьте '
              'подключение и повторите попытку.';
        });
      }
    }
  }

  Future<void> _closeDialog() async {
    final downloadedPath = _downloadedPath;
    _downloadedPath = null;
    if (downloadedPath != null) {
      await widget.controller.deleteDownloadedFile(downloadedPath);
    }
    if (mounted) Navigator.of(context).pop();
  }

  void _cancelDownload() {
    _cancellationToken?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final release = widget.controller.availableRelease!;
    final artifact = widget.controller.selectedArtifact!;
    final total = _totalBytes;
    final double? progress = total != null && total > 0
        ? (_receivedBytes / total).clamp(0.0, 1.0).toDouble()
        : null;

    return PopScope(
      canPop: _state == _UpdateDialogState.information,
      child: AlertDialog(
        title: Text(switch (_state) {
          _UpdateDialogState.information => 'Доступна новая версия',
          _UpdateDialogState.downloading => 'Скачивание обновления',
          _UpdateDialogState.error => 'Не удалось обновить приложение',
        }),
        content: SizedBox(
          width: 480,
          child: switch (_state) {
            _UpdateDialogState.information => SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.controller.platformLabel} · ${_formatBytes(artifact.sizeBytes)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${OrexConfig.appDisplayName} ${release.version} '
                    '(сборка ${release.build})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Установлено: ${widget.controller.currentVersion.version} '
                    '(сборка ${widget.controller.currentVersion.buildNumber})',
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'Что нового',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    release.notes ??
                        'Описание изменений для этой версии не добавлено.',
                  ),
                ],
              ),
            ),
            _UpdateDialogState.downloading => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: progress,
                  color: OrexColors.copper,
                ),
                const SizedBox(height: 12),
                Text(
                  total == null
                      ? 'Скачано ${_formatBytes(_receivedBytes)}'
                      : 'Скачано ${_formatBytes(_receivedBytes)} из '
                            '${_formatBytes(total)}',
                ),
                if (progress != null) ...[
                  const SizedBox(height: 4),
                  Text('${(progress * 100).round()}%'),
                ],
              ],
            ),
            _UpdateDialogState.error => Text(
              _errorMessage ?? 'Не удалось выполнить обновление.',
            ),
          },
        ),
        actions: switch (_state) {
          _UpdateDialogState.information => [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton.icon(
              onPressed: _startDownload,
              icon: const Icon(Icons.download),
              label: const Text('Установить'),
            ),
          ],
          _UpdateDialogState.downloading => [
            TextButton(
              onPressed: _cancelDownload,
              child: const Text('Отменить загрузку'),
            ),
          ],
          _UpdateDialogState.error => [
            TextButton(onPressed: _closeDialog, child: const Text('Закрыть')),
            FilledButton(
              onPressed: _startDownload,
              child: Text(
                _installPermissionRequired ? 'Установить' : 'Повторить',
              ),
            ),
          ],
        },
      ),
    );
  }

  String _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return 'размер неизвестен';
    const units = <String>['Б', 'КБ', 'МБ', 'ГБ'];
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final digits = unit == 0 || value >= 100 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${units[unit]}';
  }
}
