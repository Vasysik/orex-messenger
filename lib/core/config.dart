/// Адреса бэкенда Orex. Меняйте здесь, если домены другие.
class OrexConfig {
  OrexConfig._();

  static const String homeserver = 'https://vasys.ru';
  static const String jwtService = 'https://jwt.vasys.ru';
  // LiveKit (wss://lk.vasys.ru) бэкенд возвращает сам через lk-jwt-service.

  /// Базовый адрес Element Call.
  ///
  /// По умолчанию — публичный call.element.io. Если вы поднимаете свой
  /// Element Call (рекомендуется, он будет ходить в ваш LiveKit+lk-jwt-service),
  /// укажите его адрес, например 'https://call.vasys.ru'.
  static const String elementCallBase = 'https://call.element.io';

  /// Хост homeserver без схемы (нужен Element Call для авторизации).
  static String get homeserverHost => Uri.parse(homeserver).host;
}
