import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr/qr.dart';

import '../../core/logging/orex_logger.dart';
import '../../core/matrix/matrix_service.dart';
import '../../core/voip/matrix_request_gate.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/orex_dialogs.dart';

enum _QrMode { scan, show }

enum _QrTerminalState { none, used, expired, rejected }

const _qrPollInterval = Duration(milliseconds: 2500);

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

class _QrLoginScreenState extends State<QrLoginScreen>
    with WidgetsBindingObserver {
  late final MobileScannerController _scannerController;
  Future<void> _scannerLifecycle = Future<void>.value();
  bool _scannerWanted = false;
  bool _scannerShuttingDown = false;
  bool _scannerControllerDisposed = false;

  _QrMode? _mode;
  OrexQrRendezvousSession? _activeSession;
  String? _qrData;
  String? _status;
  String? _error;
  bool _busy = false;
  bool _handlingScan = false;
  int? _secondsLeft;
  Timer? _countdown;
  StreamSubscription? _loginStateSubscription;
  int _displayGeneration = 0;
  _QrTerminalState _terminalState = _QrTerminalState.none;
  bool _loginCompleted = false;

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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scannerController = MobileScannerController(
      autoStart: false,
      formats: const [BarcodeFormat.qrCode],
    );
    if (!widget.authenticated) {
      _loginStateSubscription = widget
          .matrix
          .client
          .onLoginStateChanged
          .stream
          .listen((_) {
            if (widget.matrix.client.isLogged()) _completeLogin();
          });
    }
  }

  void _requestScanner(bool wanted) {
    _scannerWanted = wanted;
    _scannerLifecycle = _scannerLifecycle.then((_) => _applyScannerState());
  }

  Future<void> _applyScannerState() async {
    if (_scannerControllerDisposed) return;
    final shouldRun =
        _scannerWanted &&
        !_scannerShuttingDown &&
        mounted &&
        _mode == _QrMode.scan &&
        !_handlingScan &&
        !_busy;
    try {
      if (shouldRun) {
        await _scannerController.start();
      } else {
        await _scannerController.stop();
      }
    } catch (error) {
      if (!_scannerShuttingDown) {
        OrexLog.d('QR', 'scanner lifecycle failed', error);
      }
    }
  }

  void _scheduleScannerStart() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _requestScanner(true);
    });
  }

  Future<void> _disposeScanner() async {
    _requestScanner(false);
    await _scannerLifecycle;
    if (_scannerControllerDisposed) return;
    _scannerControllerDisposed = true;
    try {
      await _scannerController.dispose();
    } catch (error) {
      OrexLog.d('QR', 'scanner dispose failed', error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_mode != _QrMode.scan || _scannerShuttingDown) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _scheduleScannerStart();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _requestScanner(false);
    }
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
    } else {
      _scheduleScannerStart();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scannerShuttingDown = true;
    unawaited(_disposeScanner());
    _loginStateSubscription?.cancel();
    _countdown?.cancel();
    _displayGeneration++;
    final session = _activeSession;
    _activeSession = null;
    if (session != null && !session.responseSent) {
      unawaited(widget.matrix.cancelQrRendezvous(session));
    }
    super.dispose();
  }

  void _completeLogin() {
    if (!mounted || _loginCompleted) return;
    _loginCompleted = true;
    _requestScanner(false);
    _displayGeneration++;
    _countdown?.cancel();
    _activeSession = null;
    setState(() {
      _qrData = null;
      _secondsLeft = null;
      _busy = false;
      _handlingScan = false;
      _terminalState = _QrTerminalState.none;
      _status = 'Вход выполнен';
      _error = null;
    });

    // Сначала закрываем QR-route, затем перестраиваем корневой экран. Иначе
    // MaterialApp успевает заменить LoginScreen на HomeShell под всё ещё
    // открытым QR-route, и пользователь видит уже ненужный код поверх аккаунта.
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop(true);
    widget.onLoggedIn?.call();
  }

  void _setMode(_QrMode mode) {
    if (_waitingForLoginCompletion) return;
    if (mode == _QrMode.scan && !_scannerModeAvailable) return;
    if (_mode == mode) return;
    if (mode == _QrMode.show) _requestScanner(false);
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
    if (mode == _QrMode.show) {
      unawaited(_prepareDisplay());
    } else {
      _scheduleScannerStart();
    }
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
      _startCountdown(session.expiresAt, generation);
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
    var transientFailures = 0;
    while (mounted &&
        generation == _displayGeneration &&
        _mode == _QrMode.show &&
        !session.isExpired) {
      await Future<void>.delayed(_qrPollInterval);
      if (!mounted || generation != _displayGeneration) return;
      try {
        final result = await widget.matrix.pollQrRendezvous(session);
        if (!mounted || generation != _displayGeneration) return;
        transientFailures = 0;
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
            _completeLogin();
            return;
          case OrexQrRendezvousPollState.used:
            _activeSession = null;
            _countdown?.cancel();
            setState(() {
              _qrData = null;
              _secondsLeft = null;
              _busy = false;
              _terminalState = _QrTerminalState.used;
              _status = 'Временная сессия закрыта.';
              _error = null;
            });
            return;
          case OrexQrRendezvousPollState.rejected:
            _activeSession = null;
            _countdown?.cancel();
            setState(() {
              _qrData = null;
              _secondsLeft = null;
              _busy = false;
              _terminalState = _QrTerminalState.rejected;
              _status = 'Вход отклонён.';
              _error = null;
            });
            return;
        }
      } catch (error) {
        if (!mounted || generation != _displayGeneration) return;
        if (_isTransientQrFailure(error) && !session.isExpired) {
          transientFailures++;
          if (transientFailures == 1) {
            OrexLog.d('QR', 'poll rendezvous temporarily failed', error);
          }
          setState(() {
            // Не оставляем экран в вечном spinner-state после временного
            // сетевого сбоя. Polling продолжает работать до TTL сессии.
            _busy = false;
            _error = null;
            _status = _isQrRateLimited(error)
                ? 'Сервер ограничил частые запросы. Ждём и повторяем…'
                : session.responseSent
                    ? 'Связь с сервером нестабильна. '
                        'Продолжаем ждать завершения…'
                    : 'Связь с сервером нестабильна. Повторяем проверку…';
          });
          await Future<void>.delayed(
            _qrRetryDelay(error, transientFailures),
          );
          continue;
        }
        OrexLog.d('QR', 'poll rendezvous failed', error);
        _activeSession = null;
        _countdown?.cancel();
        setState(() {
          _qrData = null;
          _secondsLeft = null;
          _busy = false;
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
      _busy = false;
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
      await widget.matrix.rejectDisplayedQrRendezvous(session);
      if (!mounted || generation != _displayGeneration) return;
      _activeSession = null;
      _countdown?.cancel();
      setState(() {
        _qrData = null;
        _secondsLeft = null;
        _terminalState = _QrTerminalState.rejected;
        _status = 'Вход отклонён.';
        _error = null;
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

  void _startCountdown(DateTime expiresAt, int generation) {
    _countdown?.cancel();
    void tick() {
      if (!mounted || generation != _displayGeneration) return;
      final seconds = expiresAt.difference(DateTime.now().toUtc()).inSeconds;
      setState(() => _secondsLeft = seconds.clamp(0, 999).toInt());
      if (seconds <= 0) _countdown?.cancel();
    }

    tick();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  Future<void> _handleScanned(String raw) async {
    if (_handlingScan || _busy) return;
    final generation = ++_displayGeneration;
    setState(() {
      _handlingScan = true;
      _error = null;
      _status = 'Проверяем QR-код…';
      _terminalState = _QrTerminalState.none;
    });
    _requestScanner(false);
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
        if (!mounted || generation != _displayGeneration) return;
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
        if (!mounted || generation != _displayGeneration) return;
        if (!confirmed) {
          await widget.matrix.rejectQrRendezvous(approval);
          if (!mounted || generation != _displayGeneration) return;
          setState(() {
            _handlingScan = false;
            _status = 'Вход отклонён.';
            _error = null;
          });
          _scheduleScannerStart();
          return;
        }
        await widget.matrix.approveQrRendezvous(approval);
        if (!mounted || generation != _displayGeneration) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Вход разрешён новому устройству')),
        );
        Navigator.of(context).pop(true);
        return;
      }

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
      if (!mounted || generation != _displayGeneration) return;
      _activeSession = null;
      setState(() {
        _handlingScan = false;
        _status = null;
        _error = _messageFor(error);
      });
      _scheduleScannerStart();
    }
  }

  Future<void> _waitForClaimedLogin(
    OrexQrRendezvousSession session,
    int generation,
  ) async {
    var transientFailures = 0;
    while (mounted &&
        generation == _displayGeneration &&
        !session.isExpired) {
      await Future<void>.delayed(_qrPollInterval);
      if (!mounted || generation != _displayGeneration) return;
      try {
        final result = await widget.matrix.pollQrRendezvous(session);
        if (!mounted || generation != _displayGeneration) return;
        transientFailures = 0;
        switch (result.state) {
          case OrexQrRendezvousPollState.waiting:
            continue;
          case OrexQrRendezvousPollState.loggedIn:
            _completeLogin();
            return;
          case OrexQrRendezvousPollState.rejected:
            throw const OrexAuthProtocolException(
              code: 'OREX_QR_REJECTED',
              message: 'Вход отклонён на другом устройстве',
            );
          case OrexQrRendezvousPollState.used:
            throw const OrexAuthProtocolException(
              code: 'OREX_QR_ALREADY_USED',
              message: 'QR-код уже использован другим устройством',
            );
          case OrexQrRendezvousPollState.approvalRequested:
            throw const OrexAuthProtocolException(
              code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
              message: 'Получено неожиданное состояние QR-сессии',
            );
        }
      } catch (error) {
        // Если Matrix login завершился, но последующий ACK/HTTP-ответ потерялся,
        // не показываем пользователю ложную ошибку входа.
        if (widget.matrix.client.isLogged()) {
          if (!mounted || generation != _displayGeneration) return;
          _completeLogin();
          return;
        }
        if (_isTransientQrFailure(error) && !session.isExpired) {
          transientFailures++;
          if (!mounted || generation != _displayGeneration) return;
          if (transientFailures == 1) {
            OrexLog.d('QR', 'claimed login temporarily failed', error);
          }
          setState(() {
            _error = null;
            _status = _isQrRateLimited(error)
                ? 'Сервер ограничил частые попытки входа. Ждём и повторяем…'
                : 'Связь с сервером нестабильна. Повторяем проверку…';
          });
          await Future<void>.delayed(
            _qrRetryDelay(error, transientFailures),
          );
          continue;
        }
        rethrow;
      }
    }
    throw const OrexAuthProtocolException(
      code: 'OREX_QR_EXPIRED',
      message: 'Срок действия QR-кода истёк',
    );
  }

  bool _isTransientQrFailure(Object error) {
    if (error is TimeoutException) return true;
    if (_isQrRateLimited(error)) return true;
    if (error is OrexAuthProtocolException) {
      final status = error.statusCode;
      return status == 408 ||
          status == 425 ||
          status == 429 ||
          (status != null && status >= 500);
    }
    final details = error.toString();
    return details.contains('SocketException') ||
        details.contains('ClientException') ||
        details.contains('Connection reset') ||
        details.contains('Connection closed');
  }

  Duration _qrRetryDelay(Object error, int failures) {
    final rateLimit = orexMatrixRateLimitInfo(error);
    if (rateLimit.isRateLimited) {
      const fallbacks = <Duration>[
        Duration(seconds: 4),
        Duration(seconds: 7),
        Duration(seconds: 11),
        Duration(seconds: 16),
      ];
      final fallback = fallbacks[
        math.min(failures - 1, fallbacks.length - 1)
      ];
      final milliseconds = (rateLimit.retryAfter ?? fallback)
          .inMilliseconds
          .clamp(4000, 30000)
          .toInt();
      return Duration(milliseconds: milliseconds);
    }

    const delays = <Duration>[
      Duration(milliseconds: 750),
      Duration(milliseconds: 1500),
      Duration(seconds: 3),
      Duration(seconds: 5),
    ];
    return delays[math.min(failures - 1, delays.length - 1)];
  }

  bool _isQrRateLimited(Object error) => orexIsMatrixRateLimitError(error);

  String _messageFor(Object error) {
    if (_isQrRateLimited(error)) {
      return 'Слишком много попыток входа. Подождите несколько секунд '
          'и повторите.';
    }
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
              controller: _scannerController,
              useAppLifecycleState: false,
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
    if (_terminalState == _QrTerminalState.used) {
      return Semantics(
        label: 'QR-код использован, временная сессия закрыта',
        child: const Icon(
          Icons.qr_code_2,
          size: 96,
          color: OrexColors.online,
        ),
      );
    }

    final color = switch (_terminalState) {
      _QrTerminalState.expired => OrexColors.copper,
      _QrTerminalState.rejected => const Color(0xFFCF6679),
      _ => OrexColors.copper,
    };
    final icon = switch (_terminalState) {
      _QrTerminalState.expired => Icons.timer_off_outlined,
      _QrTerminalState.rejected => Icons.block_outlined,
      _ => Icons.qr_code_2,
    };
    final label = switch (_terminalState) {
      _QrTerminalState.expired => 'QR истёк',
      _QrTerminalState.rejected => 'Вход отклонён',
      _ => '',
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
    late final QrImage qrImage;
    try {
      qrImage = QrImage(
        QrCode.fromData(
          data: data,
          errorCorrectLevel: QrErrorCorrectLevel.H,
        ),
      );
    } catch (error) {
      OrexLog.d('QR', 'render QR failed', error);
      return const SizedBox.square(
        dimension: 312,
        child: Center(
          child: Icon(
            Icons.qr_code_2,
            size: 96,
            color: OrexColors.copper,
          ),
        ),
      );
    }

    return Semantics(
      image: true,
      label: 'Защищённый QR-код входа Orex',
      child: Container(
        width: 312,
        height: 312,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: qrPaper,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: OrexColors.copperDeep, width: 2),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: const Size.square(312),
                painter: _OrexLineQrPainter(
                  image: qrImage,
                  ink: qrInk,
                  paper: qrPaper,
                ),
              ),
            ),
            Image.asset(
              'assets/mascot/squirrel.png',
              width: 72,
              height: 72,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, _, _) => const Icon(
                Icons.eco_outlined,
                color: OrexColors.copperDeep,
                size: 44,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Рисует QR как сеть мягких соединённых штрихов.
///
/// Finder patterns остаются отдельными и максимально близкими к стандартным,
/// вокруг матрицы сохраняется quiet zone в четыре модуля, а код строится с
/// коррекцией H. Это важнее декоративности: сканер должен уверенно читать код
/// с экрана телефона и монитора.
class _OrexLineQrPainter extends CustomPainter {
  _OrexLineQrPainter({
    required this.image,
    required this.ink,
    required this.paper,
  });

  static const int _quietModules = 4;

  final QrImage image;
  final Color ink;
  final Color paper;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final count = image.moduleCount;
    final totalModules = count + _quietModules * 2;
    final unit = side / totalModules;
    final origin = Offset(
      (size.width - side) / 2,
      (size.height - side) / 2,
    );
    final inkPaint = Paint()
      ..color = ink
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final paperPaint = Paint()
      ..color = paper
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.drawRect(origin & Size.square(side), paperPaint);

    // Сначала соединения между соседними модулями, затем сами мягкие модули.
    // В результате группы битов выглядят как плавные линии, а не как точки.
    for (var row = 0; row < count; row++) {
      for (var column = 0; column < count; column++) {
        if (!_isDataDark(row, column)) continue;
        final center = _moduleCenter(origin, unit, row, column);
        if (_isDataDark(row, column + 1)) {
          final rect = Rect.fromCenter(
            center: center + Offset(unit / 2, 0),
            width: unit * 1.08,
            height: unit * 0.62,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(unit * 0.31)),
            inkPaint,
          );
        }
        if (_isDataDark(row + 1, column)) {
          final rect = Rect.fromCenter(
            center: center + Offset(0, unit / 2),
            width: unit * 0.62,
            height: unit * 1.08,
          );
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(unit * 0.31)),
            inkPaint,
          );
        }
      }
    }

    for (var row = 0; row < count; row++) {
      for (var column = 0; column < count; column++) {
        if (!_isDataDark(row, column)) continue;
        final center = _moduleCenter(origin, unit, row, column);
        final rect = Rect.fromCenter(
          center: center,
          width: unit * 0.82,
          height: unit * 0.82,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(unit * 0.28)),
          inkPaint,
        );
      }
    }

    _drawFinder(canvas, origin, unit, 0, 0, inkPaint, paperPaint);
    _drawFinder(canvas, origin, unit, 0, count - 7, inkPaint, paperPaint);
    _drawFinder(canvas, origin, unit, count - 7, 0, inkPaint, paperPaint);
  }

  bool _isDataDark(int row, int column) {
    if (row < 0 || column < 0 ||
        row >= image.moduleCount || column >= image.moduleCount) {
      return false;
    }
    if (_isFinderCell(row, column)) return false;
    return image.isDark(row, column);
  }

  bool _isFinderCell(int row, int column) {
    final lastStart = image.moduleCount - 7;
    return (row < 7 && column < 7) ||
        (row < 7 && column >= lastStart) ||
        (row >= lastStart && column < 7);
  }

  Offset _moduleCenter(
    Offset origin,
    double unit,
    int row,
    int column,
  ) =>
      origin +
      Offset(
        (column + _quietModules + 0.5) * unit,
        (row + _quietModules + 0.5) * unit,
      );

  void _drawFinder(
    Canvas canvas,
    Offset origin,
    double unit,
    int row,
    int column,
    Paint inkPaint,
    Paint paperPaint,
  ) {
    final left = origin.dx + (column + _quietModules) * unit;
    final top = origin.dy + (row + _quietModules) * unit;
    final outer = Rect.fromLTWH(left, top, unit * 7, unit * 7);
    final middle = outer.deflate(unit);
    final center = outer.deflate(unit * 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(outer, Radius.circular(unit * 1.25)),
      inkPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(middle, Radius.circular(unit * 0.82)),
      paperPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(center, Radius.circular(unit * 0.72)),
      inkPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _OrexLineQrPainter oldDelegate) =>
      oldDelegate.image != image ||
      oldDelegate.ink != ink ||
      oldDelegate.paper != paper;
}
