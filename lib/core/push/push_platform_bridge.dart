import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

String? _nonEmpty(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}

/// Результат запроса системного разрешения на уведомления.
enum OrexPushPermissionStatus { authorized, denied, notSupported }

/// Данные, с которыми пользователь открыл Orex из push-уведомления.
///
/// Payload намеренно остаётся строковым: он приходит из нативной push-доставки
/// и должен безопасно сериализоваться между платформой и Flutter без потери
/// значений и без зависимости от Firebase/APNs SDK в Dart-слое.
class OrexPushOpen {
  const OrexPushOpen(this.data);

  final Map<String, String> data;

  String? get roomId => _nonEmpty(data['room_id']);
  String? get eventId => _nonEmpty(data['event_id']);
  String? get ringEventId => eventId;
  String get kind => _nonEmpty(data['orex_kind']) ?? 'matrix_event';
  String? get deliveryId => _nonEmpty(data['orex_delivery_id']);
  String? get action => _nonEmpty(data['orex_action']);
  bool get fromSystem => data['orex_from_system'] == 'true';
  bool get video => data['orex_video'] == 'true';

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

/// Стабильная Matrix/native-push identity конкретной push-платформы.
///
/// Android и будущий APNs adapter используют один lifecycle pusher, меняя
/// только эти значения и нативную доставку.
class OrexPushPlatformIdentity {
  const OrexPushPlatformIdentity({
    required this.appId,
    required this.platform,
    required this.deviceLabel,
  });

  final String appId;
  final String platform;
  final String deviceLabel;
}

/// Источник push-токена и событий открытия уведомлений.
///
/// Отдельный интерфейс позволяет тестировать регистрацию Matrix pusher без
/// Android/Firebase и не тащит platform channel внутрь Matrix API.
abstract interface class OrexPushPlatform {
  OrexPushPlatformIdentity? get identity;

  Future<void> initialize();

  Future<bool> isSupported();

  Future<String?> currentToken();

  Stream<String> get tokenChanges;

  Stream<OrexPushOpen> get notificationOpens;

  /// Visibility changes from the Windows host window. Other platforms expose
  /// an empty stream, so native notification policy can distinguish a hidden
  /// tray host from a still-visible selected conversation.
  Stream<bool> get desktopWindowVisibilityChanges;

  Future<OrexPushOpen?> takeInitialNotification();

  Future<void> acknowledgeNotification(OrexPushOpen open);

  /// Немедленно переводит native presentation в состояние Answering. Повторные
  /// ring push после нажатия «Ответить» больше не могут заново поднять звонок.
  Future<void> notifyCallAnswering(String callId, {String? ringEventId});

  /// Подтверждает, что расширенный CallScreen уже открыт и звонок активен.
  Future<void> notifyCallUiReady(String callId, {String? ringEventId});

  /// Сбрасывает native dedup-state после завершения, отклонения или ошибки.
  Future<void> notifyCallEnded(String callId, {String? ringEventId});

  /// Совместимость со старыми call UI lifecycle-вызовами.
  Future<void> notifyCallUiHidden();

  /// Показывает privacy-safe системное уведомление для события, которое уже
  /// обнаружил живой Matrix sync, пока Flutter UI находится в фоне.
  Future<void> showLocalMatrixNotification(Map<String, String> payload);

  /// Высокоприоритетное Windows-уведомление о входящем звонке. Пока оно
  /// активно, обычные сообщения не имеют права заменить его старым balloon.
  Future<void> showIncomingCallNotification(Map<String, String> payload);

  /// Убирает только совпадающий входящий вызов.
  Future<void> dismissIncomingCallNotification(
    String roomId, {
    String? ringEventId,
  });

  /// Убирает системные уведомления конкретной комнаты, не затрагивая другие
  /// conversation notifications и активный звонок.
  Future<void> dismissRoomNotifications(String roomId);

  /// Обновляет badge/dot и tooltip иконки Windows tray.
  Future<void> updateDesktopUnreadCount(int count);

  /// Restores and focuses the desktop host before presenting incoming-call UI.
  Future<void> activateIncomingCallWindow();

  Future<OrexPushPermissionStatus> requestPermission();

  void dispose();
}

/// Android bridge. На остальных платформах методы безопасно возвращают
/// `notSupported`, поэтому MatrixService может владеть одним push-сервисом.
class OrexNativePushPlatform implements OrexPushPlatform {
  OrexNativePushPlatform({
    MethodChannel? channel,
    Future<Map<String, String>?> Function(Map<String, String> payload)?
    resolvePush,
  }) : _channel = channel ?? const MethodChannel(_channelName),
       _pushResolver = resolvePush;

  static const _channelName = 'orex/push';
  static const androidAppId = 'ru.vasys.orex_messenger';
  static const _androidIdentity = OrexPushPlatformIdentity(
    appId: androidAppId,
    platform: 'android',
    deviceLabel: 'Android',
  );

  final MethodChannel _channel;
  final Future<Map<String, String>?> Function(Map<String, String> payload)?
  _pushResolver;
  final StreamController<String> _tokenChanges =
      StreamController<String>.broadcast();
  final StreamController<OrexPushOpen> _notificationOpens =
      StreamController<OrexPushOpen>.broadcast();
  final StreamController<bool> _desktopWindowVisibilityChanges =
      StreamController<bool>.broadcast();
  bool _initialized = false;
  bool _disposed = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get _isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  bool get _hasNativeBridge => _isAndroid || _isWindows;

  @override
  OrexPushPlatformIdentity? get identity =>
      _isAndroid ? _androidIdentity : null;

  @override
  Stream<String> get tokenChanges => _tokenChanges.stream;

  @override
  Stream<OrexPushOpen> get notificationOpens => _notificationOpens.stream;

  @override
  Stream<bool> get desktopWindowVisibilityChanges =>
      _desktopWindowVisibilityChanges.stream;

  @override
  Future<void> initialize() async {
    if (_initialized || _disposed || !_hasNativeBridge) return;
    _initialized = true;
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    if (_disposed) return null;
    switch (call.method) {
      case 'onTokenRefresh':
        final token = call.arguments is String
            ? (call.arguments as String).trim()
            : '';
        if (token.isNotEmpty) _tokenChanges.add(token);
        return true;
      case 'onNotificationOpened':
        final data = _stringMap(call.arguments);
        if (data.isNotEmpty) _notificationOpens.add(OrexPushOpen(data));
        return true;
      case 'onDesktopWindowVisibilityChanged':
        final visible = call.arguments;
        if (visible is bool) _desktopWindowVisibilityChanges.add(visible);
        return true;
      case 'resolvePush':
        final resolver = _pushResolver;
        final data = _stringMap(call.arguments);
        if (resolver == null || data.isEmpty) return null;
        return resolver(data);
      default:
        return null;
    }
  }

  @override
  Future<bool> isSupported() async {
    if (!_isAndroid) return false;
    await initialize();
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String?> currentToken() async {
    if (!_isAndroid) return null;
    await initialize();
    try {
      final token = await _channel.invokeMethod<String>('getToken');
      final normalized = token?.trim();
      return normalized == null || normalized.isEmpty ? null : normalized;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<OrexPushOpen?> takeInitialNotification() async {
    if (!_isAndroid) return null;
    await initialize();
    try {
      final raw = await _channel.invokeMethod<Object?>(
        'takeInitialNotification',
      );
      final data = _stringMap(raw);
      return data.isEmpty ? null : OrexPushOpen(data);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<void> acknowledgeNotification(OrexPushOpen open) async {
    if (!_isAndroid || open.deliveryId == null) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>(
        'ackNotificationOpen',
        <String, Object?>{'deliveryId': open.deliveryId},
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> notifyCallAnswering(String callId, {String? ringEventId}) async {
    if (!_isAndroid) return;
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>('callUiAnswering', <String, Object?>{
        'callId': normalizedCallId,
        'ringEventId': ?_nonEmpty(ringEventId),
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> notifyCallUiReady(String callId, {String? ringEventId}) async {
    if (!_isAndroid) return;
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>('callUiReady', <String, Object?>{
        'callId': normalizedCallId,
        'ringEventId': ?_nonEmpty(ringEventId),
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> notifyCallEnded(String callId, {String? ringEventId}) async {
    if (!_isAndroid) return;
    final normalizedCallId = callId.trim();
    if (normalizedCallId.isEmpty) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>('callUiEnded', <String, Object?>{
        'callId': normalizedCallId,
        'ringEventId': ?_nonEmpty(ringEventId),
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> notifyCallUiHidden() async {
    if (!_isAndroid) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>('callUiHidden');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> showLocalMatrixNotification(Map<String, String> payload) async {
    if (!_hasNativeBridge) return;
    final roomId = payload['room_id']?.trim();
    final title = payload['title']?.trim();
    final body = payload['body']?.trim();
    if (roomId == null ||
        roomId.isEmpty ||
        title == null ||
        title.isEmpty ||
        body == null ||
        body.isEmpty) {
      return;
    }
    await initialize();
    try {
      await _channel.invokeMethod<void>('showLocalMatrixNotification', payload);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> showIncomingCallNotification(
    Map<String, String> payload,
  ) async {
    if (!_isWindows) return;
    final roomId = payload['room_id']?.trim();
    final title = payload['title']?.trim();
    final body = payload['body']?.trim();
    if (roomId == null ||
        roomId.isEmpty ||
        title == null ||
        title.isEmpty ||
        body == null ||
        body.isEmpty) {
      return;
    }
    await initialize();
    try {
      await _channel.invokeMethod<void>('showIncomingCallNotification', payload);
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> dismissIncomingCallNotification(
    String roomId, {
    String? ringEventId,
  }) async {
    if (!_isWindows) return;
    final normalizedRoomId = roomId.trim();
    if (normalizedRoomId.isEmpty) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>(
        'dismissIncomingCallNotification',
        <String, Object?>{
          'roomId': normalizedRoomId,
          'ringEventId': ?_nonEmpty(ringEventId),
        },
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> dismissRoomNotifications(String roomId) async {
    if (!_hasNativeBridge) return;
    final normalizedRoomId = roomId.trim();
    if (normalizedRoomId.isEmpty) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>(
        'dismissRoomNotifications',
        <String, Object?>{'roomId': normalizedRoomId},
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> updateDesktopUnreadCount(int count) async {
    if (!_isWindows) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>(
        'updateTrayUnreadCount',
        <String, Object?>{'count': count < 0 ? 0 : count},
      );
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<void> activateIncomingCallWindow() async {
    if (!_isWindows) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>('activateIncomingCallWindow');
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  @override
  Future<OrexPushPermissionStatus> requestPermission() async {
    if (!_isAndroid) return OrexPushPermissionStatus.notSupported;
    await initialize();
    try {
      final raw = await _channel.invokeMethod<String>('requestPermission');
      return switch (raw) {
        'authorized' => OrexPushPermissionStatus.authorized,
        'denied' => OrexPushPermissionStatus.denied,
        _ => OrexPushPermissionStatus.notSupported,
      };
    } on MissingPluginException {
      return OrexPushPermissionStatus.notSupported;
    } on PlatformException {
      return OrexPushPermissionStatus.denied;
    }
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final key = entry.key?.toString().trim() ?? '';
      final value = entry.value?.toString() ?? '';
      if (key.isNotEmpty) result[key] = value;
    }
    return result;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_initialized && _hasNativeBridge) {
      _channel.setMethodCallHandler(null);
    }
    unawaited(_tokenChanges.close());
    unawaited(_notificationOpens.close());
    unawaited(_desktopWindowVisibilityChanges.close());
  }
}
