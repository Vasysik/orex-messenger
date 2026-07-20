import 'package:flutter/foundation.dart';

import '../config/orex_config.dart';

/// Единая точка dev-логов Orex.
///
/// Не разбрасываем прямые [debugPrint] по продуктовой логике: так проще
/// выключить шум в release/dev-preview и включить подробную диагностику при
/// разработке Matrix-flow рядом с логами SDK. В release вывод возможен только
/// при явном `OREX_DEBUG_LOGS=true`.
class OrexLog {
  OrexLog._();

  static void d(
    String area,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (!_isEnabled) return;
    final suffix = error == null ? '' : ' | $error';
    debugPrint('[Orex][$area] $message$suffix');
    if (stackTrace != null) {
      debugPrint('[Orex][$area] $stackTrace');
    }
  }

  static bool get _isEnabled {
    try {
      return OrexConfig.debugLogs;
    } catch (_) {
      // Неверные dart-define тоже должны быть видны при локальной отладке.
      return kDebugMode;
    }
  }
}
