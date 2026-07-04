import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_session.dart';
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
  }

  final MatrixService matrix;

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

  /// Начать/присоединиться к звонку в комнате.
  Future<void> start(
    String roomId, {
    required bool video,
    bool? initialMicOn,
  }) async {
    if (_session != null) await hangUp();
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
      await voip.enterCall(roomId);
    } catch (e) {
      OrexLog.d('Call', 'signaling failed room=$roomId', e);
      await _failStart(s, 'Не удалось запустить сигналинг звонка');
      return;
    }
    await s.connect(video: video);
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
      await matrix.audio.playVoiceJoin();
    }
  }

  Future<void> _failStart(
    CallSession session,
    String message, {
    bool leaveSignaling = false,
  }) async {
    lastError = message;
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
    if (_session == session) {
      _session = null;
      minimized = false;
      roomId = null;
      video = false;
      listenOnly = false;
      _initiator = false;
      _start = null;
      focusedParticipantIdentity = null;
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

  Future<void> hangUp() async {
    final s = _session;
    final rid = roomId;
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
    notifyListeners();
    if (s != null) {
      s.removeListener(notifyListeners);
      await s.hangUp();
      s.dispose();
    }
    await matrix.voip?.leaveCurrent();
    // Итоговое сообщение о звонке постит ТОЛЬКО инициатор — без дублей.
    if (initiator && rid != null) {
      await _postCallSummary(rid, sawRemote, start);
    }
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
    _session?.removeListener(notifyListeners);
    _session?.dispose();
    super.dispose();
  }
}
