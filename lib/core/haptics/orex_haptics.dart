import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum OrexHapticKind { selection, action, confirm, destructive }

/// Единая семантическая политика haptics. UI выбирает смысл действия, а не
/// конкретную силу вибрации; на desktop/web вызовы остаются безопасным no-op.
abstract final class OrexHaptics {
  static Future<void> trigger(OrexHapticKind kind) async {
    if (!_isSupported) return;
    try {
      await switch (kind) {
        OrexHapticKind.selection => HapticFeedback.selectionClick(),
        OrexHapticKind.action => HapticFeedback.lightImpact(),
        OrexHapticKind.confirm => HapticFeedback.mediumImpact(),
        OrexHapticKind.destructive => HapticFeedback.heavyImpact(),
      };
    } catch (_) {
      // Haptics are supplementary feedback and must never block the action.
    }
  }

  static bool get _isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }
}
