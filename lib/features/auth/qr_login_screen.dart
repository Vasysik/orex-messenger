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

enum _QrTerminalState { none, used, expired, rejected }

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
  OrexQrRendezvousSession? _activeSession;
  String? _qrData;
  String? _status;
  String? _error;
  bool _busy = false;
  bool _handlingScan = false;
  int? _secondsLeft;
  Timer? _countdown;
  int _displayGeneration = 0;
  _QrTerminalState _terminalState = _QrTerminalState.none;

  bool get _waitingForLoginCompletion =>
      _activeSession?.responseSent == true;

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
    final session = _activeSession;
    _activeSession = null;
    if (session != null && !session.responseSent) {
      unawaited(widget.matrix.cancelQrRendezvous(session));
    }
    super.dispose();
  }

  void _setMode(_QrMode mode) {
    if (_waitingForLoginCompletion) return;
    if (mode == _QrMode.scan && !_scannerModeAvailable) return;
    if (_mode == mode) return;
    _countdown?.cancel();
    _displayGeneration++;
    final session = _activeSession;
    _activeSession = null;
    if (session != null && !session.responseSent) {
      unawaited(widget.matrix.cancelQrRendezvous(session));
    }
    setState(() {
      _mode = mode;
      _qrData = null;
      _secondsLeft = null;
      _status = null;
      _error = null;
      _busy = false;
      _handlingScan = false;
      _terminalState = _QrTerminalState.none;
    });
    if (mode == _QrMode.show) _prepareDisplay();
  }

  Future<void> _prepareDisplay() async {
    if (!mounted || _mode != _QrMode.show || _busy) return;
    if (widget.authenticated) {
      setState(() {
        _status = 'Создайте защищённый QR-код для нового устройства.';
        _error = null;
      });
      return;
    }
    await _createRendezvous();
  }

  Future<void> _createRendezvous() async {
    if (_busy) return;
    if (_waitingForLoginCompletion) {
      setState(() {
        _status = 'Дождитесь завершения уже разрешённого входа.';
        _error = null;
      });
      return;
    }
    final generation = ++_displayGeneration;
    final previous = _activeSession;
    _activeSession = null;
    _countdown?.cancel();
    setState(() {
      _busy = true;
      _qrData = null;
      _secondsLeft = null;
      _error = null;
      _terminalState = _QrTerminalState.none;
      _status = previous == null
          ? 'Создаём защищённую QR-сессию…'
          : 'Отзываем старый QR-код…';
    });
    try {
      if (previous != null) {
        final cancelled = await widget.matrix.cancelQrRendezvous(previous);
        if (!cancelled) {
          throw const OrexAuthProtocolException(
            code: 'OREX_QR_REVOKE_FAILED',
            message: 'Не удалось отозвать предыдущий QR-код. '
                'Проверьте соединение и повторите попытку.',
          );
        }
      }
      if (!mounted || generation != _displayGeneration) return;
      setState(() => _status = 'Создаём защищённую QR-сессию…');

      final session = await widget.matrix.createQrRendezvous(
        authenticatedOwner: widget.authenticated,
      );
      if (!mounted || generation != _displayGeneration) {
        unawaited(widget.matrix.cancelQrRendezvous(session));
        return;
      }
      _activeSession = session;
      setState(() {
        _qrData = session.qrData;
        _status = widget.authenticated
            ? 'Покажите код новому устройству. После сканирования '
                'подтвердите вход здесь.'
            : 'Отсканируйте код на уже авторизованном устройстве.';
        _busy = false;
      });
      _startCountdown(session.expiresAt);
      unawaited(_pollDisplayedRendezvous(session, generation));
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

  Future<void> _pollDisplayedRendezvous(
    OrexQrRendezvousSession session,
    int generation,
  ) async {
    while (mounted &&
        generation == _displayGeneration &&
        _mode == _QrMode.show &&
        !session.isExpired) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted || generation != _displayGeneration) return;
      try {
        final result = await widget.matrix.pollQrRendezvous(session);
        if (!mounted || generation != _displayGeneration) return;
        switch (result.state) {
          case OrexQrRendezvousPollState.waiting:
            continue;
          case OrexQrRendezvousPollState.approvalRequested:
            await _approveDisplayedRequest(
              session,
              generation,
              result.deviceName,
            );
            if (!mounted || generation != _displayGeneration) return;
            if (_activeSession == null) return;
            continue;
          case OrexQrRendezvousPollState.loggedIn:
            _activeSession = null;
            _countdown?.cancel();
            setState(() {
              _qrData = null;
              _secondsLeft = null;
              _status = 'Вход выполнен';
              _error = null;
            });
            widget.onLoggedIn?.call();
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop(true);
            }
            return;
          case OrexQrRendezvousPollState.used:
            _activeSession = null;
            _countdown?.cancel();
            setState(() {
              _qrData = null;
              _secondsLeft = null;
              _busy = false;
              _terminalState = _QrTerminalState.used;
              _status = 'QR-код использован. Временная сессия закрыта.';
              _error = null;
            });
            return;
        }
      } catch (error) {
        OrexLog.d('QR', 'poll rendezvous failed', error);
        if (!mounted || generation != _displayGeneration) return;
        _activeSession = null;
        _countdown?.cancel();
        setState(() {
          _qrData = null;
          _secondsLeft = null;
          _error = _messageFor(error);
          _status = null;
        });
        return;
      }
    }
    if (!mounted || generation != _displayGeneration) return;
    _activeSession = null;
    _countdown?.cancel();
    setState(() {
      _qrData = null;
      _secondsLeft = null;
      _terminalState = _QrTerminalState.expired;
      _status = 'Срок действия QR-кода истёк.';
      _error = null;
    });
  }

  Future<void> _approveDisplayedRequest(
    OrexQrRendezvousSession session,
    int generation,
    String? deviceName,
  ) async {
    setState(() {
      _qrData = null;
      _status = 'Новое устройство ожидает вашего решения.';
      _error = null;
    });
    final confirmed = await showOrexConfirmDialog(
      context,
      title: 'Разрешить вход?',
      message: '${deviceName ?? 'Новое устройство Orex'} получит полный '
          'доступ к аккаунту ${widget.matrix.client.userID ?? ''}. '
          'Разрешайте вход только если это ваше устройство.',
      confirmLabel: 'Разрешить',
      cancelLabel: 'Отклонить',
      barrierDismissible: false,
    );
    if (!mounted || generation != _displayGeneration) return;
    if (!confirmed) {
      final rejected = await widget.matrix.cancelQrRendezvous(session);
      if (!mounted || generation != _displayGeneration) return;
      _activeSession = null;
      _countdown?.cancel();
      setState(() {
        _qrData = null;
        _secondsLeft = null;
        _terminalState = _QrTerminalState.rejected;
        _status = rejected
            ? 'Вход отклонён. QR-код больше не действует.'
            : null;
        _error = rejected
            ? null
            : 'Не удалось закрыть QR-сессию. Повторите попытку.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Разрешаем вход…';
    });
    await widget.matrix.approveDisplayedQrRendezvous(session);
    if (!mounted || generation != _displayGeneration) return;
    setState(() {
      _busy = false;
      _status = 'Вход разрешён. Ожидаем завершения на новом устройстве…';
    });
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
      if (!payload.isRendezvous) {
        throw const OrexAuthProtocolException(
          code: 'OREX_QR_LEGACY_TOKEN',
          message: 'Этот QR-код создан старой версией Orex. Создайте новый код.',
        );
      }

      if (widget.authenticated) {
        final approval = await widget.matrix.inspectQrRendezvous(raw);
        if (!mounted) return;
        final confirmed = await showOrexConfirmDialog(
          context,
          title: 'Разрешить вход?',
          message: '${approval.deviceName} получит полный доступ к аккаунту '
              '${widget.matrix.client.userID ?? ''}. Продолжайте только если '
              'это ваше устройство.',
          confirmLabel: 'Разрешить',
          cancelLabel: 'Отклонить',
          barrierDismissible: false,
        );
        if (!mounted) return;
        if (!confirmed) {
          final rejected = await widget.matrix.rejectQrRendezvous(approval);
          if (!mounted) return;
          setState(() {
            _handlingScan = false;
            _status = rejected ? 'Вход отклонён' : null;
            _error = rejected
                ? null
                : 'Не удалось закрыть QR-сессию нового устройства';
          });
          return;
        }
        await widget.matrix.approveQrRendezvous(approval);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Вход разрешён новому устройству')),
        );
        Navigator.of(context).pop(true);
        return;
      }

      final generation = ++_displayGeneration;
      final session = await widget.matrix.claimQrRendezvous(raw);
      if (!mounted || generation != _displayGeneration) {
        unawaited(widget.matrix.cancelQrRendezvous(session));
        return;
      }
      _activeSession = session;
      setState(() {
        _status = 'Запрос отправлен. Подтвердите вход на устройстве, '
            'которое показывает QR-код.';
      });
      await _waitForClaimedLogin(session, generation);
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

  Future<void> _waitForClaimedLogin(
    OrexQrRendezvousSession session,
    int generation,
  ) async {
    while (mounted &&
        generation == _displayGeneration &&
        !session.isExpired) {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (!mounted || generation != _displayGeneration) return;
      final result = await widget.matrix.pollQrRendezvous(session);
      if (result.state == OrexQrRendezvousPollState.waiting) continue;
      if (result.state != OrexQrRendezvousPollState.loggedIn) {
        throw const OrexAuthProtocolException(
          code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
          message: 'Получено неожиданное состояние QR-сессии',
        );
      }
      _activeSession = null;
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
    }
    throw const OrexAuthProtocolException(
      code: 'OREX_QR_EXPIRED',
      message: 'Срок действия QR-кода истёк',
    );
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
                          onSelectionChanged: _busy ||
                                  _handlingScan ||
                                  _waitingForLoginCompletion
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
    final waitingForCompletion = _waitingForLoginCompletion;
    return Column(
      key: const ValueKey('qr-display'),
      children: [
        if (data != null)
          _OrexQrCard(key: ValueKey(data), data: data)
        else if (_busy)
          const SizedBox.square(
            dimension: 72,
            child: CircularProgressIndicator(),
          )
        else if (_terminalState != _QrTerminalState.none)
          _buildTerminalState()
        else
          const Icon(Icons.qr_code_2, size: 96, color: OrexColors.copper),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: _busy || waitingForCompletion ? null : _createRendezvous,
          icon: Icon(
            waitingForCompletion ? Icons.hourglass_top : Icons.refresh,
          ),
          label: Text(
            waitingForCompletion
                ? 'Ожидаем завершения входа'
                : data == null
                    ? 'Создать QR-код'
                    : 'Обновить QR-код',
          ),
        ),
      ],
    );
  }

  Widget _buildTerminalState() {
    final (icon, label, color) = switch (_terminalState) {
      _QrTerminalState.used => (
          Icons.check_circle_outline,
          'QR использован',
          OrexColors.online,
        ),
      _QrTerminalState.expired => (
          Icons.timer_off_outlined,
          'QR истёк',
          OrexColors.copper,
        ),
      _QrTerminalState.rejected => (
          Icons.block_outlined,
          'Вход отклонён',
          const Color(0xFFCF6679),
        ),
      _QrTerminalState.none => (
          Icons.qr_code_2,
          '',
          OrexColors.copper,
        ),
    };
    return Container(
      width: 280,
      height: 280,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withValues(alpha: 0.65), width: 2),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 72, color: color),
          const SizedBox(height: 14),
          Text(
            label,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _OrexQrCard extends StatelessWidget {
  const _OrexQrCard({super.key, required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    const qrInk = Color(0xFF5E2D13);
    const qrPaper = Color(0xFFFFF8EF);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: qrPaper,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: OrexColors.copperDeep, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrImageView(
            data: data,
            version: QrVersions.auto,
            errorCorrectionLevel: QrErrorCorrectLevel.Q,
            size: 280,
            padding: EdgeInsets.zero,
            backgroundColor: qrPaper,
            gapless: true,
            eyeStyle: const QrEyeStyle(
              eyeShape: QrEyeShape.square,
              color: OrexColors.copperDeep,
            ),
            dataModuleStyle: const QrDataModuleStyle(
              dataModuleShape: QrDataModuleShape.circle,
              color: qrInk,
            ),
            semanticsLabel: 'Защищённый QR-код входа Orex',
          ),
          const SizedBox(height: 8),
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 15, color: OrexColors.copperDeep),
              SizedBox(width: 6),
              Text(
                'OREX · ЗАЩИЩЁННЫЙ ВХОД',
                style: TextStyle(
                  color: OrexColors.copperDeep,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
