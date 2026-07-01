import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Управляет темой приложения (системная / светлая / тёмная) и сохраняет выбор.
class ThemeController extends ChangeNotifier {
  ThemeController._(this._mode);

  static const _key = 'orex_theme_mode';

  ThemeMode _mode;
  ThemeMode get mode => _mode;

  /// Создаёт контроллер, подняв сохранённое значение.
  static Future<ThemeController> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_key);
    final mode = switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.dark, // «тёплая тёмная» по умолчанию
    };
    return ThemeController._(mode);
  }

  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, mode.name);
  }

  String get label => switch (_mode) {
        ThemeMode.system => 'Системная',
        ThemeMode.light => 'Светлая',
        ThemeMode.dark => 'Тёмная',
      };
}
