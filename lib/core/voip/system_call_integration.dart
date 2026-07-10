import 'package:flutter/services.dart';

import '../audio/audio_device_utils.dart';
import '../logging/orex_logger.dart';

enum OrexSystemCallActionType {
  answer,
  reject,
  disconnect,
  setActive,
  setInactive,
  muteChanged,
  toggleMic,
  toggleAudio,
}

class OrexSystemCallAction {
  const OrexSystemCallAction({
    required this.type,
    required this.callId,
    this.video,
    this.muted,
  });

  final OrexSystemCallActionType type;
  final String callId;
  final bool? video;
  final bool? muted;

  static OrexSystemCallAction? fromNative(String method, Object? arguments) {
    if (method != 'systemCallAction' || arguments is! Map) return null;
    final callId = arguments['callId']?.toString().trim() ?? '';
    final action = arguments['action']?.toString().trim() ?? '';
    if (callId.isEmpty || action.isEmpty) return null;

    final type = switch (action) {
      'answer' => OrexSystemCallActionType.answer,
      'reject' => OrexSystemCallActionType.reject,
      'disconnect' => OrexSystemCallActionType.disconnect,
      'setActive' => OrexSystemCallActionType.setActive,
      'setInactive' => OrexSystemCallActionType.setInactive,
      'muteChanged' => OrexSystemCallActionType.muteChanged,
      'toggleMic' => OrexSystemCallActionType.toggleMic,
      'toggleAudio' => OrexSystemCallActionType.toggleAudio,
      _ => null,
    };
    if (type == null) return null;

    return OrexSystemCallAction(
      type: type,
      callId: callId,
      video: arguments['video'] is bool ? arguments['video'] as bool : null,
      muted: arguments['muted'] is bool ? arguments['muted'] as bool : null,
    );
  }
}

class OrexRecoverableSystemCall {
  const OrexRecoverableSystemCall({
    required this.callId,
    required this.displayName,
    required this.incoming,
    required this.video,
    required this.answered,
    required this.startedAt,
    required this.micEnabled,
    required this.audioEnabled,
    required this.cameraEnabled,
    required this.updatedAt,
  });

  final String callId;
  final String displayName;
  final bool incoming;
  final bool video;
  final bool answered;
  final DateTime startedAt;
  final bool micEnabled;
  final bool audioEnabled;
  final bool cameraEnabled;
  final DateTime updatedAt;

  static OrexRecoverableSystemCall? fromNative(Object? raw) {
    if (raw is! Map) return null;
    final callId = raw['callId']?.toString().trim() ?? '';
    final displayName = raw['displayName']?.toString().trim() ?? '';
    final updatedAtMs = switch (raw['updatedAt']) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value),
      _ => null,
    };
    if (callId.isEmpty || displayName.isEmpty || updatedAtMs == null) {
      return null;
    }
    final startedAtMs = switch (raw['startedAt']) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value),
      _ => updatedAtMs,
    } ?? updatedAtMs;
    final video = raw['video'] == true;
    return OrexRecoverableSystemCall(
      callId: callId,
      displayName: displayName,
      incoming: raw['incoming'] == true,
      video: video,
      answered: raw['answered'] == true,
      startedAt: DateTime.fromMillisecondsSinceEpoch(startedAtMs),
      micEnabled: raw['micEnabled'] != false,
      audioEnabled: raw['audioEnabled'] != false,
      cameraEnabled: raw.containsKey('cameraEnabled')
          ? raw['cameraEnabled'] == true
          : video,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
    );
  }
}

/// Узкая граница между CallController и Android Telecom.
///
/// MatrixRTC/LiveKit ничего не знают о платформенном call UI. На Android 8+
/// нативный адаптер регистрирует только личные звонки в Core-Telecom; на других
/// платформах методы становятся безопасным no-op и не влияют на звонок.
class OrexSystemCallIntegration {
  OrexSystemCallIntegration._() {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static final OrexSystemCallIntegration instance =
      OrexSystemCallIntegration._();

  static const MethodChannel _channel = MethodChannel('orex/system_calls');
  Object? _actionHandlerOwner;
  Future<bool> Function(OrexSystemCallAction action)? _actionHandler;

  /// Регистрирует единственного владельца системных call actions.
  ///
  /// Android Telecom ждёт подтверждение callback, поэтому broadcast-stream
  /// здесь недостаточен: результат обработки должен вернуться в native layer.
  void setActionHandler(
    Object owner,
    Future<bool> Function(OrexSystemCallAction action) handler,
  ) {
    _actionHandlerOwner = owner;
    _actionHandler = handler;
  }

  void clearActionHandler(Object owner) {
    if (!identical(_actionHandlerOwner, owner)) return;
    _actionHandlerOwner = null;
    _actionHandler = null;
  }

  Future<bool> _handleNativeCall(MethodCall call) async {
    final action = OrexSystemCallAction.fromNative(call.method, call.arguments);
    if (action == null) return false;
    final handler = _actionHandler;
    if (handler == null) return false;
    try {
      return await handler(action);
    } catch (e) {
      OrexLog.d('SystemCall', 'native action ${action.type.name} failed', e);
      return false;
    }
  }

  Future<bool> reportIncomingCall({
    required String callId,
    required String displayName,
    required bool video,
    String? avatarCacheKey,
    DateTime? startedAt,
    bool? micEnabled,
    bool? audioEnabled,
    bool? cameraEnabled,
  }) => _invokeBool('reportIncomingCall', {
    'callId': callId,
    'displayName': displayName,
    'video': video,
    'avatarCacheKey': ?avatarCacheKey,
    'startedAt': ?startedAt?.millisecondsSinceEpoch,
    'micEnabled': ?micEnabled,
    'audioEnabled': ?audioEnabled,
    'cameraEnabled': ?cameraEnabled,
  });

  Future<bool> reportOutgoingCall({
    required String callId,
    required String displayName,
    required bool video,
    String? avatarCacheKey,
    DateTime? startedAt,
    bool? micEnabled,
    bool? audioEnabled,
    bool? cameraEnabled,
  }) => _invokeBool('reportOutgoingCall', {
    'callId': callId,
    'displayName': displayName,
    'video': video,
    'avatarCacheKey': ?avatarCacheKey,
    'startedAt': ?startedAt?.millisecondsSinceEpoch,
    'micEnabled': ?micEnabled,
    'audioEnabled': ?audioEnabled,
    'cameraEnabled': ?cameraEnabled,
  });

  Future<bool> answerCall(String callId, {required bool video}) =>
      _invokeBool('answerCall', {'callId': callId, 'video': video});

  Future<bool> setActive(String callId) =>
      _invokeBool('setActive', {'callId': callId});

  Future<bool> updateControls(
    String callId, {
    required bool micEnabled,
    required bool audioEnabled,
    required bool cameraEnabled,
  }) => _invokeBool('updateControls', {
    'callId': callId,
    'micEnabled': micEnabled,
    'audioEnabled': audioEnabled,
    'cameraEnabled': cameraEnabled,
  });

  /// Обновляет Android foreground owner реальной media-сессии.
  ///
  /// Этот lifecycle намеренно не зависит от Core-Telecom: системная регистрация
  /// может быть недоступна, а активный LiveKit-звонок всё равно обязан оставаться
  /// foreground work с recoverable descriptor и постоянным уведомлением.
  Future<bool> updateForegroundCall({
    required String callId,
    required String displayName,
    required bool incoming,
    required bool video,
    required bool answered,
    required DateTime startedAt,
    required bool micEnabled,
    required bool audioEnabled,
    required bool cameraEnabled,
  }) => _invokeBool('updateForegroundCall', {
    'callId': callId,
    'displayName': displayName,
    'incoming': incoming,
    'video': video,
    'answered': answered,
    'startedAt': startedAt.millisecondsSinceEpoch,
    'micEnabled': micEnabled,
    'audioEnabled': audioEnabled,
    'cameraEnabled': cameraEnabled,
  });

  Future<bool> stopForegroundCall(String callId) =>
      _invokeBool('stopForegroundCall', {'callId': callId});

  Future<bool> rejectCall(String callId) =>
      _invokeBool('rejectCall', {'callId': callId});

  Future<bool> endCall(
    String callId, {
    String reason = 'local',
  }) => _invokeBool('endCall', {'callId': callId, 'reason': reason});

  Future<OrexRecoverableSystemCall?> recoverableCall() async {
    if (!orexIsAndroidNativePlatform) return null;
    try {
      final raw = await _channel.invokeMethod<Object?>('getRecoverableCall');
      return OrexRecoverableSystemCall.fromNative(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      OrexLog.d('SystemCall', 'getRecoverableCall failed code=${e.code}');
      return null;
    } catch (e) {
      OrexLog.d('SystemCall', 'getRecoverableCall failed', e);
      return null;
    }
  }

  Future<bool> clearRecoverableCall(String callId) =>
      _invokeBool('clearRecoverableCall', {'callId': callId});

  Future<bool> _invokeBool(String method, Map<String, Object?> arguments) async {
    if (!orexIsAndroidNativePlatform) return false;
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      OrexLog.d(
        'SystemCall',
        '$method failed code=${e.code} message=${e.message}',
      );
      return false;
    } catch (e) {
      OrexLog.d('SystemCall', '$method failed', e);
      return false;
    }
  }
}
