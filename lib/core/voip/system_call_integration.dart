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
  }) => _invokeBool('reportIncomingCall', {
    'callId': callId,
    'displayName': displayName,
    'video': video,
  });

  Future<bool> reportOutgoingCall({
    required String callId,
    required String displayName,
    required bool video,
  }) => _invokeBool('reportOutgoingCall', {
    'callId': callId,
    'displayName': displayName,
    'video': video,
  });

  Future<bool> answerCall(String callId, {required bool video}) =>
      _invokeBool('answerCall', {'callId': callId, 'video': video});

  Future<bool> setActive(String callId) =>
      _invokeBool('setActive', {'callId': callId});

  Future<bool> rejectCall(String callId) =>
      _invokeBool('rejectCall', {'callId': callId});

  Future<bool> endCall(
    String callId, {
    String reason = 'local',
  }) => _invokeBool('endCall', {'callId': callId, 'reason': reason});

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
