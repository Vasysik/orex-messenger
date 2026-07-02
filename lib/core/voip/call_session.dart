import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart';

import '../config/orex_config.dart';
import '../logging/orex_logger.dart';

enum CallStatus { connecting, connected, failed, ended }

/// Нативный звонок на стеке Element Call (MatrixRTC): мы используем ВАШ
/// LiveKit + lk-jwt-service и рисуем СВОЙ интерфейс — без встраивания
/// call.element.io.
///
/// Два клиента Orex, нажавшие звонок в одной Matrix-комнате, получают от
/// lk-jwt-service одну и ту же LiveKit-комнату (она выводится из roomId),
/// поэтому встречаются в одном звонке.
class CallSession extends ChangeNotifier {
  CallSession({
    required this.client,
    required this.matrixRoomId,
    this.initialMicOn = true,
    this.canUseMic = true,
    this.listenOnly = false,
    this.canUseMicNow,
    this.audioInputDeviceIdProvider,
  });

  final Client client;
  final String matrixRoomId;
  final bool initialMicOn;
  bool canUseMic;
  bool listenOnly;
  final bool Function()? canUseMicNow;
  final String? Function()? audioInputDeviceIdProvider;

  CallStatus status = CallStatus.connecting;
  String? error;
  String? cameraError; // камера не запустилась (звонок при этом идёт со звуком)
  lk.Room? _room;
  lk.Room? get room => _room;
  bool _disposed = false;
  bool screenShareOn = false;
  bool _screenShareBusy = false;
  lk.LocalVideoTrack? _screenShareTrack;
  bool handRaised = false;
  final Map<String, VoiceParticipantState> _voiceStates = <String, VoiceParticipantState>{};
  Timer? _reactionClearTimer;
  Timer? _voiceStateRefreshTimer;

  VoiceParticipantState voiceStateForUser(String userId) {
    final cached = _voiceStates[userId];
    if (cached != null) return cached;
    final content =
        client.getRoomById(matrixRoomId)?.getState('ru.orex.voice.participant', userId)?.content;
    return VoiceParticipantState.fromContent(content);
  }

  VoiceParticipantState get localVoiceState =>
      voiceStateForUser(client.userID ?? '');

  /// Подключался ли хоть кто-то ещё (для итогового сообщения «ответили/пропущен»).
  bool sawRemote = false;

  bool get micOn => _room?.localParticipant?.isMicrophoneEnabled() ?? false;
  bool get camOn => _room?.localParticipant?.isCameraEnabled() ?? false;
  bool get canPublishMedia => canUseMic && !listenOnly;

  List<lk.Participant> get participants => [
        if (_room?.localParticipant != null) _room!.localParticipant!,
        ...?_room?.remoteParticipants.values,
      ];

  Future<void> connect({required bool video}) async {
    status = CallStatus.connecting;
    error = null;
    notifyListeners();
    try {
      final creds = await _fetchCredentials();
      final room = lk.Room(
        roomOptions: const lk.RoomOptions(adaptiveStream: true, dynacast: true),
      );
      await room.prepareConnection(creds.url, creds.jwt);
      await room.connect(creds.url, creds.jwt);
      if (initialMicOn) {
        await room.localParticipant?.setMicrophoneEnabled(
          true,
          audioCaptureOptions: _audioCaptureOptions(),
        );
      } else {
        await room.localParticipant?.setMicrophoneEnabled(false);
      }
      if (video) {
        // Камера может быть недоступна (занята другим окном/приложением —
        // NotReadableError). Не валим весь звонок: продолжаем со звуком.
        try {
          await room.localParticipant?.setCameraEnabled(true);
        } catch (e) {
          cameraError = '$e';
        }
      }

      if (_disposed) {
        // Сессию закрыли, пока подключались — сворачиваем комнату.
        await room.disconnect();
        await room.dispose();
        return;
      }
      _room = room;
      room.addListener(_onRoom);
      _startVoiceStateRefresh();
      status = CallStatus.connected;
      notifyListeners();
    } catch (e) {
      if (_disposed) return;
      error = '$e';
      status = CallStatus.failed;
      notifyListeners();
    }
  }

  void _onRoom() {
    // Livekit при teardown комнаты шлёт события уже после dispose() — иначе
    // получаем «CallSession used after being disposed».
    if (_disposed) return;
    if (_room?.remoteParticipants.isNotEmpty ?? false) sawRemote = true;
    notifyListeners();
  }


  void _startVoiceStateRefresh() {
    _voiceStateRefreshTimer?.cancel();
    _voiceStateRefreshTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_disposed || status != CallStatus.connected) return;
      // Voice participant state comes from Matrix room state, not LiveKit
      // media events. Poll lightly so remote hands/reactions appear in the
      // call UI without writing them to the chat timeline. Permission changes
      // are checked here too, so admins can accept a raised-hand request while
      // the listener stays in the current channel call.
      unawaited(refreshVoicePermissions());
      notifyListeners();
    });
  }

  Future<void> refreshVoicePermissions() async {
    final checker = canUseMicNow;
    if (checker == null || _disposed) return;
    final nextCanUseMic = checker();
    if (nextCanUseMic == canUseMic && listenOnly == !nextCanUseMic) return;

    canUseMic = nextCanUseMic;
    listenOnly = !nextCanUseMic;

    final lp = _room?.localParticipant;
    if (!nextCanUseMic && lp != null) {
      try {
        if (lp.isMicrophoneEnabled()) {
          await lp.setMicrophoneEnabled(false);
        }
      } catch (_) {}
      try {
        if (lp.isCameraEnabled()) {
          await lp.setCameraEnabled(false);
        }
      } catch (_) {}
      if (screenShareOn) {
        try {
          await _stopScreenShare(lp: lp);
        } catch (_) {}
      }
    }

    if (nextCanUseMic && handRaised) {
      final userId = client.userID;
      if (userId != null && userId.isNotEmpty) {
        handRaised = false;
        _voiceStates[userId] = localVoiceState.copyWith(handRaised: false);
        await _publishVoiceParticipantState();
      }
    }

    if (nextCanUseMic && error == 'В режиме просмотра трансляция экрана недоступна') {
      error = null;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> toggleMic() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    if (!canPublishMedia) return;
    final next = !lp.isMicrophoneEnabled();
    await lp.setMicrophoneEnabled(
      next,
      audioCaptureOptions: next ? _audioCaptureOptions() : null,
    );
    if (!_disposed) notifyListeners();
  }

  lk.AudioCaptureOptions _audioCaptureOptions() {
    final deviceId = audioInputDeviceIdProvider?.call();
    final normalized = deviceId?.trim();
    return lk.AudioCaptureOptions(
      deviceId: normalized == null || normalized.isEmpty || normalized == 'default'
          ? null
          : normalized,
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
      highPassFilter: true,
    );
  }


  Future<void> toggleScreenShare({
    String? sourceId,
    String? sourceName,
    String? sourceType,
  }) async {
    final lp = _room?.localParticipant;
    if (lp == null || _screenShareBusy) return;
    _screenShareBusy = true;
    try {
      // Android media projection requires native foreground-service wiring
      // outside lib/. До этого не открываем системный picker, чтобы не ловить
      // native crash после выбора экрана.
      if (!canPublishMedia) {
        error = 'В режиме просмотра трансляция экрана недоступна';
        if (!_disposed) notifyListeners();
        return;
      }
      if (defaultTargetPlatform == TargetPlatform.android) {
        error = 'Трансляция экрана на Android будет реализована позже';
        if (!_disposed) notifyListeners();
        return;
      }

      final next = !screenShareOn;
      if (!next) {
        await _stopScreenShare(lp: lp);
        error = null;
        return;
      }

      if (sourceId == null && _desktopNeedsExplicitSource) {
        error = 'Выберите источник экрана';
        if (!_disposed) notifyListeners();
        return;
      }

      final options = sourceId != null
          ? lk.ScreenShareCaptureOptions(
              sourceId: sourceId,
              maxFrameRate: 15.0,
            )
          : const lk.ScreenShareCaptureOptions(maxFrameRate: 15.0);
      final sourceLabel = sourceName?.trim().isNotEmpty == true
          ? sourceName!.trim()
          : sourceId ?? 'default';
      OrexLog.d(
        'Call',
        'screen share start requested sourceId=$sourceId type=$sourceType name=$sourceLabel',
      );

      if (!kIsWeb && _desktopNeedsExplicitSource && sourceId != null) {
        try {
          // Desktop: как в примерах LiveKit, сначала создаём track с выбранным
          // DesktopCapturerSource.id и публикуем его вручную.
          await _publishScreenShareTrack(
            lp: lp,
            options: options,
            sourceId: sourceId,
            sourceType: sourceType,
            sourceLabel: sourceLabel,
          );
        } catch (e, st) {
          OrexLog.d(
            'Call',
            'createScreenShareTrack failed sourceId=$sourceId type=$sourceType name=$sourceLabel stack=$st',
            e,
          );
          await _cleanupScreenShareLocals();

          if (_isDesktopScreenSource(sourceType)) {
            // На части Windows-сборок flutter_webrtc отдаёт screen id в picker-е,
            // но getDisplayMedia потом отвечает "source not found" именно для
            // экранов. Для screen-источника безопасный fallback — весь экран
            // без sourceId. Для окон такого fallback нет, чтобы не расшарить
            // лишнее вместо выбранного окна.
            const fallbackOptions = lk.ScreenShareCaptureOptions(maxFrameRate: 15.0);
            OrexLog.d(
              'Call',
              'retrying screen share without sourceId after screen source lookup failed selectedId=$sourceId',
            );
            await _publishScreenShareTrack(
              lp: lp,
              options: fallbackOptions,
              sourceId: null,
              sourceType: sourceType,
              sourceLabel: 'default screen',
            );
          } else {
            // Fallback с тем же sourceId. Не переключаемся молча на весь экран,
            // чтобы случайно не расшарить больше, чем выбрал пользователь.
            await lp.setScreenShareEnabled(
              true,
              screenShareCaptureOptions: options,
            );
            screenShareOn = true;
            OrexLog.d('Call', 'screen share started via setScreenShareEnabled sourceId=$sourceId');
          }
        }
      } else {
        await lp.setScreenShareEnabled(
          true,
          screenShareCaptureOptions: options,
        );
        screenShareOn = true;
        OrexLog.d('Call', 'screen share started via setScreenShareEnabled sourceId=$sourceId');
      }
      error = null;
    } catch (e, st) {
      await _cleanupScreenShareLocals();
      screenShareOn = false;
      OrexLog.d(
        'Call',
        'screen share failed sourceId=$sourceId type=$sourceType name=${sourceName ?? ''} stack=$st',
        e,
      );
      final sourcePart = sourceName?.trim().isNotEmpty == true
          ? ' для "${sourceName!.trim()}"'
          : '';
      error = 'Не удалось включить трансляцию экрана$sourcePart: $e';
    } finally {
      _screenShareBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> _publishScreenShareTrack({
    required lk.LocalParticipant lp,
    required lk.ScreenShareCaptureOptions options,
    required String? sourceId,
    required String? sourceType,
    required String sourceLabel,
  }) async {
    final track = await lk.LocalVideoTrack.createScreenShareTrack(options);
    await lp.publishVideoTrack(track);
    _screenShareTrack = track;
    screenShareOn = true;
    OrexLog.d(
      'Call',
      'screen share started via createScreenShareTrack sourceId=${sourceId ?? 'default'} type=$sourceType name=$sourceLabel',
    );
  }

  bool _isDesktopScreenSource(String? sourceType) =>
      sourceType == null || sourceType == 'screen';

  Future<void> _stopScreenShare({lk.LocalParticipant? lp}) async {
    final participant = lp ?? _room?.localParticipant;
    // Не используем LocalParticipant.unpublishTrack(): в части версий
    // livekit_client этот метод отсутствует/не экспортируется, из-за чего
    // flutter analyze падает. Для screen-share LiveKit умеет выключать
    // публикацию по TrackSource через setScreenShareEnabled(false), а локальный
    // track ниже дополнительно останавливается и dispose-ится.
    if (participant != null) {
      try {
        await participant.setScreenShareEnabled(false);
      } catch (_) {}
    }

    await _cleanupScreenShareLocals();
    screenShareOn = false;
  }

  Future<void> _cleanupScreenShareLocals() async {
    final track = _screenShareTrack;
    _screenShareTrack = null;
    try {
      await track?.stop();
    } catch (_) {}
    try {
      await track?.dispose();
    } catch (_) {}
  }

  bool get _desktopNeedsExplicitSource {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }

  Future<void> toggleHandRaised({bool? force}) async {
    final userId = client.userID;
    if (userId == null || userId.isEmpty) return;
    final next = force ?? !handRaised;
    if (handRaised == next) return;
    handRaised = next;
    _voiceStates[userId] = localVoiceState.copyWith(handRaised: next);
    await _publishVoiceParticipantState();
    if (!_disposed) notifyListeners();
  }

  Future<void> sendVoiceReaction(String emoji) async {
    final userId = client.userID;
    if (userId == null || userId.isEmpty) return;
    _reactionClearTimer?.cancel();
    _voiceStates[userId] = localVoiceState.copyWith(
      reaction: emoji,
      reactionTs: DateTime.now().millisecondsSinceEpoch,
    );
    await _publishVoiceParticipantState();
    if (!_disposed) notifyListeners();
    _reactionClearTimer = Timer(const Duration(seconds: 4), () async {
      if (_disposed) return;
      _voiceStates[userId] = localVoiceState.copyWith(clearReaction: true);
      await _publishVoiceParticipantState();
      if (!_disposed) notifyListeners();
    });
  }

  Future<void> _publishVoiceParticipantState() async {
    final userId = client.userID;
    if (userId == null || userId.isEmpty) return;
    final state = localVoiceState;
    try {
      await client.setRoomStateWithKey(
        matrixRoomId,
        'ru.orex.voice.participant',
        userId,
        {
          'hand_raised': state.handRaised,
          if (state.reaction != null) 'reaction': state.reaction,
          if (state.reactionTs != null) 'reaction_ts': state.reactionTs,
        },
      );
    } catch (e) {
      error = 'Не удалось обновить состояние голосового канала: $e';
      // Voice participant state is UX-only; failed state publish must not break
      // the media session.
    }
  }

  Future<void> toggleCam() async {
    final lp = _room?.localParticipant;
    if (lp == null) return;
    if (!canPublishMedia) {
      cameraError = 'В режиме просмотра камера недоступна';
      if (!_disposed) notifyListeners();
      return;
    }
    try {
      await lp.setCameraEnabled(!lp.isCameraEnabled());
      cameraError = null;
    } catch (e) {
      cameraError = '$e';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> hangUp() async {
    status = CallStatus.ended;
    _voiceStateRefreshTimer?.cancel();
    _voiceStateRefreshTimer = null;
    final room = _room;
    _room = null;
    if (room != null) {
      // Снимаем слушатель ДО teardown, чтобы события закрытия не дёргали нас.
      room.removeListener(_onRoom);
      try {
        if (screenShareOn) {
          await _stopScreenShare(lp: room.localParticipant);
        }
      } catch (_) {}
      try {
        await room.disconnect();
      } catch (_) {}
      try {
        await room.dispose();
      } catch (_) {}
    }
    if (!_disposed) notifyListeners();
  }

  // OpenID-токен Matrix -> lk-jwt-service /sfu/get -> {url, jwt}
  Future<_Creds> _fetchCredentials() async {
    final userId = client.userID!;

    final openId = await client.requestOpenIdToken(userId, <String, Object?>{});

    final resp = await http
        .post(
          OrexConfig.jwtServiceUri.replace(path: '/sfu/get'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'room': matrixRoomId,
            'openid_token': {
              'access_token': openId.accessToken,
              'token_type': openId.tokenType,
              'matrix_server_name': openId.matrixServerName,
            },
            'device_id': client.deviceID ?? '',
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      // Не добавляем resp.body: backend-ошибки иногда содержат диагностические
      // поля, которые не должны попадать в UI/log вместе с auth-контекстом.
      throw Exception('lk-jwt-service ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = json['url'] as String?;
    final jwt = json['jwt'] as String?;
    if (url == null || jwt == null || jwt.isEmpty) {
      throw StateError('lk-jwt-service вернул неполные credentials');
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'wss' && uri.scheme != 'https')) {
      throw StateError('LiveKit URL должен быть wss:// или https://');
    }
    return _Creds(url: url, jwt: jwt);
  }

  @override
  void dispose() {
    _disposed = true;
    _reactionClearTimer?.cancel();
    _voiceStateRefreshTimer?.cancel();
    _room?.removeListener(_onRoom);
    _room?.dispose();
    _room = null;
    super.dispose();
  }
}

class _Creds {
  _Creds({required this.url, required this.jwt});
  final String url;
  final String jwt;
}


class VoiceParticipantState {
  const VoiceParticipantState({
    this.handRaised = false,
    this.reaction,
    this.reactionTs,
  });

  factory VoiceParticipantState.fromContent(Map<dynamic, dynamic>? content) {
    if (content == null) return const VoiceParticipantState();
    return VoiceParticipantState(
      handRaised: content['hand_raised'] == true,
      reaction: content['reaction']?.toString(),
      reactionTs: content['reaction_ts'] is num
          ? (content['reaction_ts'] as num).toInt()
          : null,
    );
  }

  final bool handRaised;
  final String? reaction;
  final int? reactionTs;

  VoiceParticipantState copyWith({
    bool? handRaised,
    String? reaction,
    int? reactionTs,
    bool clearReaction = false,
  }) {
    return VoiceParticipantState(
      handRaised: handRaised ?? this.handRaised,
      reaction: clearReaction ? null : reaction ?? this.reaction,
      reactionTs: clearReaction ? null : reactionTs ?? this.reactionTs,
    );
  }
}
