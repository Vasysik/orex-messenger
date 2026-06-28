/// Адреса и security-политика бэкенда Orex.
class OrexConfig {
  OrexConfig._();

  static const String homeserver = 'https://vasys.ru';
  static const String jwtService = 'https://jwt.vasys.ru';

  /// В продовом режиме приложение не должно стартовать без vodozemac:
  /// иначе приватные Matrix-комнаты могут внезапно стать фактически без E2EE.
  /// Для локальной отладки можно временно поставить false, но не коммитить так.
  static const bool requireVodozemac = true;

  // LiveKit (wss://lk.vasys.ru) бэкенд возвращает сам через lk-jwt-service.

  /// Базовый адрес Element Call.
  ///
  /// По умолчанию — публичный call.element.io. Если вы поднимаете свой
  /// Element Call (рекомендуется, он будет ходить в ваш LiveKit+lk-jwt-service),
  /// укажите его адрес, например 'https://call.vasys.ru'.
  static const String elementCallBase = 'https://call.element.io';

  static Uri get homeserverUri => _httpsUri(homeserver, 'homeserver');
  static Uri get jwtServiceUri => _httpsUri(jwtService, 'jwtService');

  /// Хост homeserver без схемы (нужен Element Call для авторизации).
  static String get homeserverHost => homeserverUri.host;

  /// Быстрая проверка security-инвариантов конфигурации на старте.
  static void validateSecurity() {
    homeserverUri;
    jwtServiceUri;
    _httpsUri(elementCallBase, 'elementCallBase');
  }

  static Uri _httpsUri(String value, String name) {
    final uri = Uri.parse(value);
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError('$name must be an absolute https:// URL');
    }
    return uri;
  }
}
