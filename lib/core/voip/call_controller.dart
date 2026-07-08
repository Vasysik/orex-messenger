import 'dart:async';

import 'package:flutter/foundation.dart';
// Matrix 7.4.0 exports its own VoIP CallSession. Orex intentionally owns a
// separate media-session type below, so keep the SDK symbol out of this file.
import 'package:matrix/matrix.dart' hide CallSession;

import 'call_session.dart';
import 'system_call_integration.dart';
import '../matrix/matrix_service.dart';
import '../logging/orex_logger.dart';

/// Долгоживущий «активный звонок»: владеет медиа-сессией ([CallSession]) и
/// сигналингом ([VoipService]), чтобы звонок переживал сворачивание экрана.
///
/// Раньше [CallSession] жил внутри экрана звонка и умирал при выходе. Теперь
/// экран — лишь «вид» на этот контроллер: свернуть = выйти с экрана, не вешая
/// трубку; над чатом показывается мини-панель управления.
class CallController extends ChangeNotifier {
  CallController(this.matrix) {
    matrix.audio.addListener(_onAudioSettingsChanged);
    _systemCalls.setActionHandler(this, _onSystemCallAction);
    _incomingDismissSub = matrix.voip?.onDismissIncoming.listen(
      _onIncomingDismissed,
    );
  }

  final MatrixService matrix;
  final OrexSystemCallIntegration _systemCalls =
      OrexSystemCallIntegration.instance;
  StreamSubscription<String>? _incomingDismissSub;
  final StreamController<String> _systemIncomingAccepted =
      StreamController<String>.broadcast();

  Stream<String> get onSystemIncomingAccepted =>
      _systemIncomingAccepted.stream;

  void _onAudioSettingsChanged() {
    unawaited(_session?.syncAudioSettingsFromSettings());
    notifyListeners();
  }

  CallSession? _session;
  CallSession? get session => _session;

  String? roomId;
  bool video = false;
  bool listenOnly = false;
  bool minimized = false;
  bool _initiator = false; // мы начали этот звонок (а не присоединились)
  DateTime? _start;
  String? focusedParticipantIdentity;
  String? lastError;
  String? _systemCallId;
  String? _systemPreparationCallId;
  Future<bool>? _systemPreparationFuture;
  bool _systemMutedByTelecom = false;
  bool _systemActiveByTelecom = true;
  String? _systemActionInProgressCallId;
  String? _incomingAcceptRoomId;
  Future<void>? _incomingAcceptFuture;
  int _lifecycleGeneration = 0;

  bool isAcceptingIncoming(String roomId) =>
      _incomingAcceptRoomId == roomId && _incomingAcceptFuture != null;

  void focusParticipant(String? identity) {
    if (focusedParticipantIdentity == identity) return;
    focusedParticipantIdentity = identity;
    notifyListeners();
  }

  bool _canUseMicNowFor(String roomId) {
    final room = matrix.client.getRoomById(roomId);
    if (room == null) return true;
    final kind = matrix.roomKind(room);
    return kind != OrexRoomKind.channel ||
        matrix.voicePermissions.canSpeak(room, matrix.client.userID);
  }

  Future<void> refreshVoicePermissions() async {
    await _session?.refreshVoicePermissions();
    final rid = roomId;
    listenOnly = rid == null ? false : !_canUseMicNowFor(rid);
    notifyListeners();
  }

  bool get isActive => _session != null;

  bool _isSystemCallEligible(Room? room) =>
      room != null &&
      (matrix.voip?.isPersonalCallRoom(room) ?? room.isDirectChat);

  /// Регистрирует входящий личный вызов в Android Telecom до показа Flutter UI.
  ///
  /// Для одного callId существует только один in-flight запрос. Это закрывает
  /// гонку, когда пользователь успевает ответить/отклонить вызов или Matrix
  /// присылает remote-dismiss, пока Core-Telecom ещё создаёт системную сессию.
  Future<bool> prepareIncoming(Room room, {bool video = false}) {
    if (!_isSystemCallEligible(room)) return Future<bool>.value(false);
    if (isActive && roomId != room.id) return Future<bool>.value(false);
    if (_systemCallId != null && _systemCallId != room.id) {
      return Future<bool>.value(false);
    }

    final pending = _systemPreparationFuture;
    if (_systemPreparationCallId == room.id && pending != null) {
      return pending;
    }

    if (_systemCallId != room.id) {
      _systemCallId = room.id;
      _systemMutedByTelecom = false;
      _systemActiveByTelecom = true;
    }

    late final Future<bool> registration;
    registration = _registerIncomingSystemCall(room, video).whenComplete(() {
      if (identical(_systemPreparationFuture, registration)) {
        _systemPreparationCallId = null;
        _systemPreparationFuture = null;
      }
    });
    _systemPreparationCallId = room.id;
    _systemPreparationFuture = registration;
    return registration;
  }

  Future<bool> _registerIncomingSystemCall(Room room, bool video) async {
    final registered = await _systemCalls.reportIncomingCall(
      callId: room.id,
      displayName: room.getLocalizedDisplayname(),
      video: video,
    );
    if (!registered) {
      if (_systemCallId == room.id) _clearSystemCallState();
      return false;
    }

    // Владение могло быть снято, пока native addCall ожидал Telecom. Не даём
    // запоздавшей регистрации оставить фантомный CallStyle/системный звонок.
    if (_systemCallId != room.id) {
      await _systemCalls.endCall(room.id, reason: 'remote');
      return false;
    }
    return true;
  }

  Future<bool> _rejectPreparedSystemCall(String callId) async {
    final pending = _systemPreparationCallId == callId
        ? _systemPreparationFuture
        : null;
    if (pending != null && !await pending) return true;
    if (_systemCallId != callId) return true;
    return _systemCalls.rejectCall(callId);
  }

  Future<void> acceptIncoming(
    Room room, {
    required bool video,
    bool fromSystem = false,
  }) {
    if (isActive && roomId == room.id) return Future<void>.value();
    final pending = _incomingAcceptFuture;
    if (_incomingAcceptRoomId == room.id && pending != null) return pending;

    late final Future<void> operation;
    operation = _acceptIncomingImpl(
      room,
      video: video,
      fromSystem: fromSystem,
    ).whenComplete(() {
      if (identical(_incomingAcceptFuture, operation)) {
        _incomingAcceptRoomId = null;
        _incomingAcceptFuture = null;
      }
    });
    _incomingAcceptRoomId = room.id;
    _incomingAcceptFuture = operation;
    return operation;
  }

  Future<void> _acceptIncomingImpl(
    Room room, {
    required bool video,
    required bool fromSystem,
  }) async {
    matrix.audio.stopIncomingRingtone();
    unawaited(matrix.push.notifyCallAnswering(room.id));
    if (isActive && roomId != room.id) await hangUp();
    final otherSystemCallId = _systemCallId;
    if (otherSystemCallId != null && otherSystemCallId != room.id) {
      await _systemCalls.endCall(otherSystemCallId, reason: 'local');
      if (_systemCallId == otherSystemCallId) _clearSystemCallState();
    }
    if (fromSystem) matrix.voip?.dismissIncomingFromSystem(room.id);
    // Не задерживаем локальный ответ на звонок сетью, но обязательно дожидаемся
    // best-effort Matrix sync до выхода из flow. Это особенно важно при
    // системном answer: native callback уже подтверждён, а дальнейшая работа
    // идёт асинхронно вне Telecom 5-секундного окна.
    final handledSync = _markIncomingHandled(room.id);

    var registered = await prepareIncoming(room, video: video);
    if (registered && !fromSystem) {
      final answered = await _systemCalls.answerCall(room.id, video: video);
      if (!answered) {
        await _systemCalls.endCall(room.id, reason: 'error');
        if (_systemCallId == room.id) _clearSystemCallState();
        registered = false;
      }
    }

    await start(
      room.id,
      video: video,
      systemIncoming: true,
      systemCallPrepared: registered,
    );
    if (fromSystem && isActive && roomId == room.id) {
      _systemIncomingAccepted.add(room.id);
    }
    await handledSync;
  }

  Future<void> rejectIncoming(Room room, {bool fromSystem = false}) async {
    matrix.audio.stopIncomingRingtone();
    unawaited(matrix.push.notifyCallEnded(room.id));
    if (fromSystem) matrix.voip?.dismissIncomingFromSystem(room.id);
    final dispositionSync = Future.wait<void>([
      _markIncomingHandled(room.id),
      _notifyIncomingRejected(room.id),
    ]);
    final systemEnded =
        fromSystem || await _rejectPreparedSystemCall(room.id);
    if (systemEnded && _systemCallId == room.id) _clearSystemCallState();
    await dispositionSync;
  }

  bool _ownsSystemCall(String callId) =>
      _systemCallId == callId || roomId == callId;

  /// Возвращаем native-layer подтверждение только после локальной обработки
  /// команды. Для hold/mute дожидаемся фактического изменения медиа. Долгие
  /// MatrixRTC/LiveKit операции answer/disconnect запускаем после синхронного
  /// перевода локального состояния, чтобы уложиться в Telecom callback timeout.
  Future<bool> _onSystemCallAction(OrexSystemCallAction action) async {
    try {
      switch (action.type) {
        case OrexSystemCallActionType.answer:
          return _acceptIncomingFromSystem(action);
        case OrexSystemCallActionType.reject:
          return _terminateFromSystem(action.callId, rejected: true);
        case OrexSystemCallActionType.disconnect:
          return _terminateFromSystem(action.callId, rejected: false);
        case OrexSystemCallActionType.setActive:
          if (!_ownsSystemCall(action.callId)) return false;
          _systemActiveByTelecom = true;
          final session = roomId == action.callId ? _session : null;
          if (session != null) await session.setSystemActive(true);
          return true;
        case OrexSystemCallActionType.setInactive:
          if (!_ownsSystemCall(action.callId)) return false;
          _systemActiveByTelecom = false;
          final session = roomId == action.callId ? _session : null;
          if (session != null) await session.setSystemActive(false);
          return true;
        case OrexSystemCallActionType.muteChanged:
          final muted = action.muted;
          if (muted == null || !_ownsSystemCall(action.callId)) return false;
          _systemMutedByTelecom = muted;
          final session = roomId == action.callId ? _session : null;
          if (session != null) await session.setSystemMuted(muted);
          return true;
      }
    } catch (e) {
      OrexLog.d(
        'Call',
        'system action failed type=${action.type.name} call=${action.callId}',
        e,
      );
      return false;
    }
  }

  bool _acceptIncomingFromSystem(OrexSystemCallAction action) {
    if (isActive && roomId == action.callId) return true;
    final room = matrix.client.getRoomById(action.callId);
    if (room == null || !_isSystemCallEligible(room)) return false;
    if (_systemActionInProgressCallId == action.callId) return true;
    _systemActionInProgressCallId = action.callId;
    unawaited(_runSystemAnswer(room, action));
    return true;
  }

  Future<void> _runSystemAnswer(
    Room room,
    OrexSystemCallAction action,
  ) async {
    try {
      await acceptIncoming(room, video: action.video ?? false, fromSystem: true);
    } catch (e) {
      OrexLog.d('Call', 'system answer failed call=${action.callId}', e);
      if (_ownsSystemCall(action.callId)) {
        await _systemCalls.endCall(action.callId, reason: 'error');
        if (_systemCallId == action.callId) _clearSystemCallState();
      }
    } finally {
      if (_systemActionInProgressCallId == action.callId) {
        _systemActionInProgressCallId = null;
      }
    }
  }

  bool _terminateFromSystem(String callId, {required bool rejected}) {
    if (!_ownsSystemCall(callId) && matrix.client.getRoomById(callId) == null) {
      return false;
    }
    if (_systemActionInProgressCallId == callId) return true;
    _systemActionInProgressCallId = callId;
    unawaited(_runSystemTermination(callId, rejected: rejected));
    return true;
  }

  Future<void> _runSystemTermination(
    String callId, {
    required bool rejected,
  }) async {
    try {
      if (isActive && roomId == callId) {
        await hangUp(fromSystem: true);
        return;
      }
      final room = matrix.client.getRoomById(callId);
      if (room != null) {
        if (rejected) {
          await rejectIncoming(room, fromSystem: true);
        } else {
          matrix.audio.stopIncomingRingtone();
          matrix.voip?.dismissIncomingFromSystem(callId);
          if (_systemCallId == callId) _clearSystemCallState();
          await _markIncomingHandled(callId);
        }
      } else if (_systemCallId == callId) {
        _clearSystemCallState();
      }
    } catch (e) {
      OrexLog.d('Call', 'system termination failed call=$callId', e);
    } finally {
      if (_systemActionInProgressCallId == callId) {
        _systemActionInProgressCallId = null;
      }
    }
  }

  Future<void> _markIncomingHandled(String callId) async {
    try {
      await matrix.voip?.markCallHandled(callId, callId);
    } catch (e) {
      OrexLog.d('Call', 'failed to sync handled state call=$callId', e);
    }
  }

  Future<void> _notifyIncomingRejected(String callId) async {
    try {
      await matrix.voip?.notifyRejected(callId);
    } catch (e) {
      OrexLog.d('Call', 'failed to sync rejected state call=$callId', e);
    }
  }

  void _onIncomingDismissed(String callId) {
    if (_systemCallId != callId ||
        _systemActionInProgressCallId == callId ||
        (isActive && roomId == callId)) {
      return;
    }
    _clearSystemCallState();
    unawaited(_systemCalls.endCall(callId, reason: 'remote'));
  }

  /// Начать/присоединиться к звонку в комнате.
  Future<void> start(
    String roomId, {
    required bool video,
    bool? initialMicOn,
    bool systemIncoming = false,
    bool? systemCallPrepared,
  }) async {
    if (_session != null) {
      if (this.roomId == roomId) return;
      await hangUp();
    }
    final generation = ++_lifecycleGeneration;
    lastError = null;
    this.roomId = roomId;
    this.video = video;
    minimized = false;
    // Инициатор = в комнате ещё не было активного звонка до нас.
    final room = matrix.client.getRoomById(roomId);
    final kind = room != null ? matrix.roomKind(room) : OrexRoomKind.group;
    if (room != null && kind == OrexRoomKind.channel) {
      await matrix.voicePermissions.ensureParticipantStatePowerLevels(room);
    }
    final canSpeak = _canUseMicNowFor(roomId);
    listenOnly = !canSpeak;
    final micInitiallyOn =
        initialMicOn ??
        matrix.audio.callMicEnabledOverride ??
        (room?.isDirectChat == true ? true : false);
    _initiator = room != null && !matrix.roomHasActiveCall(room);
    _start = DateTime.now();
    final s = CallSession(
      client: matrix.client,
      matrixRoomId: roomId,
      initialMicOn: canSpeak && micInitiallyOn,
      canUseMic: canSpeak,
      listenOnly: listenOnly,
      canUseMicNow: () => _canUseMicNowFor(roomId),
      audioInputDeviceIdProvider: () => matrix.audio.inputDeviceId,
      audioOutputDeviceIdProvider: () => matrix.audio.outputDeviceId,
      videoInputDeviceIdProvider: () => matrix.audio.cameraDeviceId,
      cameraDeviceIdSink: (deviceId) =>
          matrix.audio.setCameraDeviceId(deviceId),
      speakingThresholdDbProvider: () => matrix.audio.speakingThresholdDb,
      speakingThresholdEnabledProvider: () =>
          matrix.audio.speakingThresholdEnabled,
      callMicPreferenceSink: (enabled) =>
          matrix.audio.setCallMicEnabled(enabled),
    );
    focusedParticipantIdentity = null;
    _session = s;
    s.addListener(notifyListeners);
    notifyListeners();
    // Сигналинг (membership) — чтобы у собеседника зазвонило. Если он
    // не прошёл, медиа не подключаем: иначе можно получить локальный фантомный
    // звонок и зависшее состояние MatrixRTC.
    final voip = matrix.voip;
    if (voip == null) {
      OrexLog.d('Call', 'signaling unavailable room=$roomId');
      await _failStart(
        s,
        'Звонки сейчас недоступны: MatrixRTC signaling не запущен',
      );
      return;
    }
    try {
      await voip.enterCall(roomId, ring: _initiator, video: video);
    } catch (e) {
      OrexLog.d('Call', 'signaling failed room=$roomId', e);
      await _failStart(s, 'Не удалось запустить сигналинг звонка');
      return;
    }
    if (generation != _lifecycleGeneration || _session != s) {
      await voip.leaveCurrent();
      return;
    }

    var systemRegistered = systemCallPrepared == true;
    if (_isSystemCallEligible(room) && systemCallPrepared != false) {
      if (!systemRegistered) {
        if (_systemCallId != roomId) {
          _systemCallId = roomId;
          _systemMutedByTelecom = false;
          _systemActiveByTelecom = true;
        }
        systemRegistered = systemIncoming
            ? await _systemCalls.reportIncomingCall(
                callId: roomId,
                displayName: room!.getLocalizedDisplayname(),
                video: video,
              )
            : await _systemCalls.reportOutgoingCall(
                callId: roomId,
                displayName: room!.getLocalizedDisplayname(),
                video: video,
              );
        if (!systemRegistered && _systemCallId == roomId) {
          _clearSystemCallState();
        }
      }
      if (systemRegistered) _systemCallId = roomId;
    }

    // Регистрация в Android Telecom может занять несколько секунд. За это
    // время пользователь уже мог завершить звонок или открыть другой — тогда
    // запрещаем запоздалой операции оживлять старую медиа-сессию.
    if (generation != _lifecycleGeneration || _session != s) {
      if (systemRegistered && _systemCallId == roomId) {
        await _systemCalls.endCall(roomId);
        _clearSystemCallState();
      }
      await voip.leaveCurrent();
      return;
    }

    await s.connect(video: video);
    if (generation != _lifecycleGeneration || _session != s) {
      await voip.leaveCurrent();
      return;
    }
    if (s.status != CallStatus.connected) {
      final message = s.error?.trim().isNotEmpty == true
          ? s.error!.trim()
          : 'Не удалось подключиться к медиа звонка';
      OrexLog.d(
        'Call',
        'media connect failed room=$roomId status=${s.status} error=$message',
      );
      await _failStart(s, message, leaveSignaling: true);
      return;
    }
    if (s.status == CallStatus.connected) {
      if (systemRegistered && _systemCallId == roomId) {
        await s.setSystemMuted(_systemMutedByTelecom);
        await s.setSystemActive(_systemActiveByTelecom);
        if (_systemActiveByTelecom) await _systemCalls.setActive(roomId);
      }
      await matrix.audio.playVoiceJoin();
    }
  }

  Future<void> _failStart(
    CallSession session,
    String message, {
    bool leaveSignaling = false,
  }) async {
    lastError = message;
    unawaited(matrix.push.notifyCallEnded(session.matrixRoomId));
    session.removeListener(notifyListeners);
    await session.hangUp();
    session.dispose();
    if (leaveSignaling) {
      try {
        await matrix.voip?.leaveCurrent();
      } catch (e) {
        OrexLog.d('Call', 'leave failed after start rollback', e);
      }
    }
    final failedSystemCallId = _systemCallId;
    if (_session == session) {
      _session = null;
      minimized = false;
      roomId = null;
      video = false;
      listenOnly = false;
      _initiator = false;
      _start = null;
      focusedParticipantIdentity = null;
      _clearSystemCallState();
      _lifecycleGeneration++;
    }
    if (failedSystemCallId != null) {
      await _systemCalls.endCall(failedSystemCallId, reason: 'error');
    }
    notifyListeners();
  }

  void minimize() {
    if (_session == null) return;
    minimized = true;
    notifyListeners();
  }

  void expand() {
    minimized = false;
    notifyListeners();
  }

  Future<void> hangUp({bool fromSystem = false}) async {
    _lifecycleGeneration++;
    final s = _session;
    final rid = roomId;
    final systemCallId = _systemCallId;
    final initiator = _initiator;
    final start = _start;
    final sawRemote = s?.sawRemote ?? false;
    _session = null;
    minimized = false;
    roomId = null;
    video = false;
    listenOnly = false;
    _initiator = false;
    _start = null;
    focusedParticipantIdentity = null;
    _clearSystemCallState();
    if (rid != null) unawaited(matrix.push.notifyCallEnded(rid));
    notifyListeners();
    if (s != null) {
      s.removeListener(notifyListeners);
      await s.hangUp();
      s.dispose();
    }
    await matrix.voip?.leaveCurrent();
    if (!fromSystem && systemCallId != null) {
      await _systemCalls.endCall(systemCallId);
    }
    // Итоговое сообщение о звонке постит ТОЛЬКО инициатор — без дублей.
    if (initiator && rid != null) {
      await _postCallSummary(rid, sawRemote, start);
    }
  }

  void _clearSystemCallState() {
    _systemCallId = null;
    _systemMutedByTelecom = false;
    _systemActiveByTelecom = true;
  }

  Future<void> _postCallSummary(
    String roomId,
    bool answered,
    DateTime? start,
  ) async {
    final room = matrix.client.getRoomById(roomId);
    if (room == null || matrix.roomKind(room) == OrexRoomKind.channel) return;
    String outcome;
    String text;
    if (answered) {
      outcome = 'answered';
      final secs = start != null
          ? DateTime.now().difference(start).inSeconds
          : 0;
      text = secs > 0 ? '📞 Звонок · ${_fmtDur(secs)}' : '📞 Звонок';
    } else if (matrix.voip?.wasRejected(roomId) ?? false) {
      outcome = 'rejected';
      text = '📞 Отклонённый вызов';
    } else {
      outcome = 'missed';
      text = '📞 Пропущенный вызов';
    }
    matrix.voip?.clearRejected(roomId);
    try {
      await room.sendEvent({
        'msgtype': 'm.notice',
        'body': text,
        'com.orex.call_outcome': outcome,
      });
    } catch (e) {
      OrexLog.d('Call', 'post call summary failed room=$roomId', e);
    }
  }

  String _fmtDur(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return m > 0 ? '$m мин ${s.toString().padLeft(2, '0')} с' : '$s с';
  }

  @override
  void dispose() {
    matrix.audio.removeListener(_onAudioSettingsChanged);
    final systemCallId = _systemCallId;
    if (systemCallId != null) {
      unawaited(_systemCalls.endCall(systemCallId, reason: 'local'));
    }
    _clearSystemCallState();
    _systemCalls.clearActionHandler(this);
    _incomingDismissSub?.cancel();
    _systemIncomingAccepted.close();
    _session?.removeListener(notifyListeners);
    _session?.dispose();
    super.dispose();
  }
}
