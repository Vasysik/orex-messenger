import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  Future<OrexPushOpen?> takeInitialNotification();

  Future<void> acknowledgeNotification(OrexPushOpen open);

  /// Показывает privacy-safe системное уведомление для события, которое уже
  /// обнаружил живой Matrix sync, пока Flutter UI находится в фоне.
  Future<void> showLocalMatrixNotification({
    required String roomId,
    String? eventId,
  });

  Future<OrexPushPermissionStatus> requestPermission();

  void dispose();
}

/// Android bridge. На остальных платформах методы безопасно возвращают
/// `notSupported`, поэтому MatrixService может владеть одним push-сервисом.
class OrexNativePushPlatform implements OrexPushPlatform {
  OrexNativePushPlatform({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const _channelName = 'orex/push';
  static const androidAppId = 'ru.vasys.orex_messenger';
  static const _androidIdentity = OrexPushPlatformIdentity(
    appId: androidAppId,
    platform: 'android',
    deviceLabel: 'Android',
  );

  final MethodChannel _channel;
  final StreamController<String> _tokenChanges =
      StreamController<String>.broadcast();
  final StreamController<OrexPushOpen> _notificationOpens =
      StreamController<OrexPushOpen>.broadcast();
  bool _initialized = false;
  bool _disposed = false;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  OrexPushPlatformIdentity? get identity =>
      _isAndroid ? _androidIdentity : null;

  @override
  Stream<String> get tokenChanges => _tokenChanges.stream;

  @override
  Stream<OrexPushOpen> get notificationOpens => _notificationOpens.stream;

  @override
  Future<void> initialize() async {
    if (_initialized || _disposed || !_isAndroid) return;
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
      final raw = await _channel.invokeMethod<Object?>('takeInitialNotification');
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
  Future<void> showLocalMatrixNotification({
    required String roomId,
    String? eventId,
  }) async {
    if (!_isAndroid) return;
    final normalizedRoomId = roomId.trim();
    if (normalizedRoomId.isEmpty) return;
    await initialize();
    try {
      await _channel.invokeMethod<void>(
        'showLocalMatrixNotification',
        <String, Object?>{
          'roomId': normalizedRoomId,
          if (eventId != null && eventId.trim().isNotEmpty)
            'eventId': eventId.trim(),
        },
      );
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
    if (_initialized && _isAndroid) {
      _channel.setMethodCallHandler(null);
    }
    unawaited(_tokenChanges.close());
    unawaited(_notificationOpens.close());
  }
}
