import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/shared/theme/theme_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restores the saved system theme mode', () async {
    SharedPreferences.setMockInitialValues({
      'orex_theme_mode': ThemeMode.system.name,
    });

    final controller = await ThemeController.load();

    expect(controller.mode, ThemeMode.system);
  });
}
