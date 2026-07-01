import 'package:flutter/foundation.dart';

import '../config/orex_config.dart';

/// Единая точка dev-логов Orex.
///
/// Не разбрасываем прямые [debugPrint] по продуктовой логике: так проще
/// выключить шум в release/dev-preview и включить подробную диагностику при
/// разработке Matrix-flow рядом с логами SDK.
class OrexLog {
  OrexLog._();

  static void d(String area, String message, [Object? error]) {
    if (!kDebugMode || !OrexConfig.debugLogs) return;
    final suffix = error == null ? '' : ' | $error';
    debugPrint('[Orex][$area] $message$suffix');
  }
}
