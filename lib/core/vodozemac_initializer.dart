import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;

/// Инициализирует обязательную E2EE-библиотеку с реалистичным бюджетом времени.
///
/// Web сначала скачивает JavaScript-обвязку и WASM (~0.8 MB). Шесть секунд
/// давали ложный отказ на холодном кэше или медленном соединении, поэтому Web
/// получает больший бюджет. На native-бинарник уже лежит в пакете, но тайм-аут
/// всё равно защищает фоновый процесс от бесконечного ожидания.
Future<void> initializeOrexVodozemac() => vod.init().timeout(
  kIsWeb ? const Duration(seconds: 30) : const Duration(seconds: 12),
);
