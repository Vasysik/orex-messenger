import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/logging/orex_logger.dart';
import '../../core/matrix/matrix_service.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/orex_dialogs.dart';

enum _QrMode { scan, show }

class QrLoginScreen extends StatefulWidget {
  const QrLoginScreen({
    super.key,
    required this.matrix,
    required this.authenticated,
    this.onLoggedIn,
  });

  final MatrixService matrix;
  final bool authenticated;
  final VoidCallback? onLoggedIn;

  @override
  State<QrLoginScreen> createState() => _QrLoginScreenState();
}

class _QrLoginScreenState extends State<QrLoginScreen> {
  _QrMode? _mode;
  String? _qrData;
  String? _status;
  String? _error;
  bool _busy = false;
  bool _handlingScan = false;
  int? _secondsLeft;
  Timer? _countdown;
  int _displayGeneration = 0;

  bool get _scannerModeAvailable {
    if (kIsWeb) return true;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_mode != null) return;
    final compact = MediaQuery.sizeOf(context).shortestSide < 600;
    final startsWithScanner =
        _scannerModeAvailable &&
        compact &&
        (kIsWeb ||
            defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    _mode = startsWithScanner ? _QrMode.scan : _QrMode.show;
    if (_mode == _QrMode.show) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _prepareDisplay());
    }
  }

  @override
  void dispose() {
    _countdown?.cancel();
    _displayGeneration++;
    super.dispose();
  }

  void _setMode(_QrMode mode) {
    if (mode == _QrMode.scan && !_scannerModeAvailable) return;
    if (_mode == mode) return;
    _countdown?.cancel();
    _displayGeneration++;
    setState(() {
      _mode = mode;
      _qrData = null;
      _secondsLeft = null;
      _status = null;
      _error = null;
      _busy = false;
      _handlingScan = false;
    });
    if (mode == _QrMode.show) _prepareDisplay();
  }

  Future<void> _prepareDisplay() async {
    if (!mounted || _mode != _QrMode.show || _busy) return;
    if (widget.authenticated) {
      setState(() {
        _status = 'Создайте одноразовый QR-код для нового устройства.';
        _error = null;
      });
      return;
    }
    await _createRendezvous();
  }

  Future<void> _createRendezvous() async {
    final generation = ++_displayGeneration;
    _countdown?.cancel();
    setState(() {
      _busy = true;
      _qrData = null;
      _error = null;
      _status = 'Создаём защищённую QR-сессию…';
    });
    try {
      final session = await widget.matrix.createQrRendezvous();
      if (!mounted || generation != _displayGeneration) return;
      setState(() {
        _qrData = session.qrData;
        _status = 'Отсканируйте код на уже авторизованном устройстве.';
        _busy = false;
      });
      _startCountdown(session.expiresAt);
      unawaited(_pollRendezvous(session, generation));
    } catch (error) {
      OrexLog.d('QR', 'create rendezvous failed', error);
      if (!mounted || generation != _displayGeneration) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
        _status = null;
      });
    }
  }

  Future<void> _pollRendezvous(
    OrexQrRendezvousSession session,
    int generation,
  ) async {
    while (mounted &&
        generation == _displayGeneration &&
        _mode == _QrMode.show &&
        !session.isExpired) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted || generation != _displayGeneration) return;
      try {
        final loggedIn = await widget.matrix.pollQrRendezvous(session);
        if (!loggedIn) continue;
        if (!mounted || generation != _displayGeneration) return;
        setState(() {
          _status = 'Вход выполнен';
          _error = null;
        });
        widget.onLoggedIn?.call();
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop(true);
        }
        return;
      } catch (error) {
        OrexLog.d('QR', 'poll rendezvous failed', error);
        if (!mounted || generation != _displayGeneration) return;
        setState(() {
          _error = _messageFor(error);
          _status = null;
        });
        return;
      }
    }
    if (!mounted || generation != _displayGeneration) return;
    setState(() {
      _error = 'Срок действия QR-кода истёк';
      _status = null;
      _secondsLeft = 0;
    });
  }

  Future<void> _createDirectQr() async {
    final confirmed = await showOrexConfirmDialog(
      context,
      title: 'Подключить новое устройство?',
      message: 'QR-код даёт новому устройству полный доступ к аккаунту. '
          'Создавайте его только когда ваше новое устройство находится рядом.',
      confirmLabel: 'Создать QR',
    );
    if (!confirmed || !mounted) return;

    final generation = ++_displayGeneration;
    _countdown?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _status = 'Получаем одноразовый токен…';
      _qrData = null;
    });
    try {
      final qr = await widget.matrix.createDirectQrLogin();
      final payload = OrexQrLoginPayload.parse(qr);
      if (!mounted || generation != _displayGeneration) return;
      setState(() {
        _busy = false;
        _qrData = qr;
        _status = 'Отсканируйте код на новом устройстве.';
      });
      _startCountdown(payload.expiresAt!);
    } catch (error) {
      OrexLog.d('QR', 'create direct login token failed', error);
      if (!mounted || generation != _displayGeneration) return;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
        _status = null;
      });
    }
  }

  void _startCountdown(DateTime expiresAt) {
    _countdown?.cancel();
    void tick() {
      if (!mounted) return;
      final seconds = expiresAt.difference(DateTime.now().toUtc()).inSeconds;
      setState(() => _secondsLeft = seconds.clamp(0, 999).toInt());
      if (seconds <= 0) _countdown?.cancel();
    }

    tick();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<void> _handleScanned(String raw) async {
    if (_handlingScan || _busy) return;
    setState(() {
      _handlingScan = true;
      _error = null;
      _status = 'Проверяем QR-код…';
    });
    try {
      final payload = OrexQrLoginPayload.parse(raw);
      if (widget.authenticated) {
        if (!payload.isRendezvous) {
          throw const OrexAuthProtocolException(
            code: 'OREX_QR_WRONG_MODE',
            message: 'Покажите этот QR новому устройству, а не сканируйте здесь',
          );
        }
        final confirmed = await showOrexConfirmDialog(
          context,
          title: 'Разрешить вход?',
          message: 'Новое устройство получит полный доступ к аккаунту '
              '${widget.matrix.client.userID ?? ''}. Продолжайте только если '
              'это ваше устройство и QR-код открыт на нём прямо сейчас.',
          confirmLabel: 'Разрешить',
        );
        if (!confirmed) {
          if (mounted) {
            setState(() {
              _handlingScan = false;
              _status = null;
            });
          }
          return;
        }
        await widget.matrix.approveQrRendezvous(qrData: raw);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Новое устройство авторизовано')),
        );
        Navigator.of(context).pop(true);
        return;
      }

      if (!payload.isLoginToken) {
        throw const OrexAuthProtocolException(
          code: 'OREX_QR_WRONG_MODE',
          message: 'Этот QR должен сканировать уже авторизованный телефон',
        );
      }
      await widget.matrix.loginWithQrData(raw);
      if (!mounted) return;
      setState(() => _status = 'Вход выполнен');
      widget.onLoggedIn?.call();
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      OrexLog.d('QR', 'scan failed', error);
      if (!mounted) return;
      setState(() {
        _handlingScan = false;
        _status = null;
        _error = _messageFor(error);
      });
    }
  }

  String _messageFor(Object error) {
    if (error is OrexAuthProtocolException) return error.message;
    if (error is MatrixException) {
      if (error.errcode == 'M_FORBIDDEN') {
        return 'Сервер запретил создание одноразовой QR-сессии';
      }
      if (error.errcode == 'M_UNKNOWN_TOKEN') return 'QR-код уже использован';
      if (error.errcode == 'M_UNRECOGNIZED') {
        return 'QR-вход не включён на сервере';
      }
    }
    final details = error.toString();
    if (details.contains('SocketException') ||
        details.contains('ClientException')) {
      return 'Нет подключения к серверу';
    }
    return 'Не удалось выполнить QR-вход';
  }

  @override
  Widget build(BuildContext context) {
    final mode = _mode ?? _QrMode.show;
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Вход по QR'),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: GlassPanel(
                  borderRadius: 24,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_scannerModeAvailable) ...[
                        SegmentedButton<_QrMode>(
                          segments: const [
                            ButtonSegment(
                              value: _QrMode.scan,
                              icon: Icon(Icons.qr_code_scanner),
                              label: Text('Сканировать'),
                            ),
                            ButtonSegment(
                              value: _QrMode.show,
                              icon: Icon(Icons.qr_code_2),
                              label: Text('Показать код'),
                            ),
                          ],
                          selected: {mode},
                          onSelectionChanged: _busy
                              ? null
                              : (selection) => _setMode(selection.first),
                        ),
                        const SizedBox(height: 20),
                      ],
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: mode == _QrMode.scan
                            ? _buildScanner()
                            : _buildQrDisplay(),
                      ),
                      if (_status != null) ...[
                        const SizedBox(height: 14),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _status!,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ],
                      if (_secondsLeft != null && _secondsLeft! > 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Код действует ещё $_secondsLeft сек.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 14),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFFCF6679)),
                          ),
                        ),
                      ],
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

  Widget _buildScanner() {
    if (!_scannerModeAvailable) return const SizedBox.shrink();

    return ClipRRect(
      key: const ValueKey('camera-scanner'),
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: 340,
        child: Stack(
          fit: StackFit.expand,
          children: [
            MobileScanner(
              onDetect: (capture) {
                if (capture.barcodes.isEmpty) return;
                final value = capture.barcodes.first.rawValue;
                if (value != null && value.isNotEmpty) {
                  unawaited(_handleScanned(value));
                }
              },
            ),
            IgnorePointer(
              child: Center(
                child: Container(
                  width: 230,
                  height: 230,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: OrexColors.copper, width: 3),
                  ),
                ),
              ),
            ),
            if (_handlingScan || _busy)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.45),
                child: const Center(child: CircularProgressIndicator()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildQrDisplay() {
    final data = _qrData;
    return Column(
      key: const ValueKey('qr-display'),
      children: [
        if (data != null)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
            ),
            child: QrImageView(
              data: data,
              version: QrVersions.auto,
              size: 280,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
              semanticsLabel: 'QR-код входа Orex',
            ),
          )
        else if (_busy)
          const SizedBox.square(
            dimension: 72,
            child: CircularProgressIndicator(),
          )
        else
          const Icon(Icons.qr_code_2, size: 96, color: OrexColors.copper),
        const SizedBox(height: 16),
        if (widget.authenticated)
          ElevatedButton.icon(
            onPressed: _busy ? null : _createDirectQr,
            icon: const Icon(Icons.refresh),
            label: Text(data == null ? 'Создать QR-код' : 'Обновить QR-код'),
          )
        else if (data == null && !_busy)
          ElevatedButton.icon(
            onPressed: _createRendezvous,
            icon: const Icon(Icons.refresh),
            label: const Text('Создать новый QR-код'),
          ),
      ],
    );
  }
}
