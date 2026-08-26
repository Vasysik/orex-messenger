import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Small platform bridge for system-UI changes that Flutter's generic
/// [SystemChrome] API can no longer apply on Android apps targeting API 36+.
///
/// Keep this separate from call/media ownership: the call screen only asks for
/// an immersive presentation while a media tile is fullscreen.
final class OrexSystemUi {
  const OrexSystemUi._();

  static const MethodChannel _androidChannel = MethodChannel('orex/system_ui');

  static Future<bool> setCallMediaFullscreen(bool enabled) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      final applied = await _androidChannel.invokeMethod<bool>(
        'setMediaFullscreen',
        <String, Object?>{'enabled': enabled},
      );
      return applied ?? false;
    } catch (_) {
      // Fullscreen chrome is presentation-only. A missing platform bridge must
      // never break an otherwise healthy call or prevent leaving the screen.
      return false;
    }
  }
}
