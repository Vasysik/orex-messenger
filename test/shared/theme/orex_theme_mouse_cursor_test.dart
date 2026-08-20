import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/shared/theme/orex_theme.dart';

void main() {
  test('material button themes use click cursor only while enabled', () {
    final theme = OrexTheme.dark;
    final enabled = <WidgetState>{};
    final disabled = <WidgetState>{WidgetState.disabled};

    final cursors = [
      theme.iconButtonTheme.style?.mouseCursor,
      theme.textButtonTheme.style?.mouseCursor,
      theme.filledButtonTheme.style?.mouseCursor,
      theme.elevatedButtonTheme.style?.mouseCursor,
      theme.outlinedButtonTheme.style?.mouseCursor,
    ];

    for (final cursor in cursors) {
      expect(cursor, isNotNull);
      expect(cursor!.resolve(enabled), SystemMouseCursors.click);
      expect(cursor.resolve(disabled), SystemMouseCursors.basic);
    }
  });
}
