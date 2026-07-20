/// Стабильная, безопасная для показа пользователю причина сбоя при запуске.
///
/// Исходные исключения Matrix, IndexedDB и криптографии могут содержать детали
/// окружения. Не показываем их в release UI: код достаточно точен для
/// диагностики, но не раскрывает локальные данные или сетевой контекст.
enum OrexStartupStage {
  configuration(
    code: 'STARTUP_CONFIG',
    userMessage:
        'Не удалось проверить конфигурацию этой сборки. Установите актуальную версию Orex.',
  ),
  crypto(
    code: 'STARTUP_CRYPTO',
    userMessage:
        'Не удалось подготовить модуль шифрования. Обновите страницу или перезапустите Orex.',
  ),
  preferences(
    code: 'STARTUP_PREFERENCES',
    userMessage:
        'Orex не получил доступ к локальным настройкам. Разрешите локальные данные для приложения и перезапустите его.',
  ),
  matrixCache(
    code: 'STARTUP_MATRIX_CACHE',
    userMessage:
        'Не удалось открыть локальный Matrix-кэш. Проверьте разрешение на локальные данные; не очищайте их без резервной фразы.',
  ),
  session(
    code: 'STARTUP_SESSION',
    userMessage:
        'Не удалось восстановить локальную Matrix-сессию. Обновите страницу или перезапустите Orex.',
  ),
  unknown(
    code: 'STARTUP_UNKNOWN',
    userMessage:
        'Не удалось завершить запуск. Обновите страницу или перезапустите Orex.',
  );

  const OrexStartupStage({required this.code, required this.userMessage});

  final String code;
  final String userMessage;
}

class OrexStartupFailure implements Exception {
  const OrexStartupFailure(this.stage);

  final OrexStartupStage stage;

  String get code => stage.code;
  String get userMessage => stage.userMessage;

  @override
  String toString() => code;
}
