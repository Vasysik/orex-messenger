import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
import 'call_screen.dart';

/// Owns the presentation order for a user-initiated call.
///
/// On phones the expanded route is pushed in the same event turn as the start
/// request, so the first visible state is the full-screen "connecting" view.
/// Desktop keeps the non-blocking inline panel behavior.
Future<void> launchOrexCall(
  BuildContext context, {
  required MatrixService matrix,
  required String roomId,
  required bool video,
  double wideBreakpoint = 900,
}) async {
  final call = matrix.call;
  final isWide = MediaQuery.sizeOf(context).width >= wideBreakpoint;

  if (call.isActive && call.roomId == roomId) {
    if (isWide) {
      call.minimize();
    } else {
      call.expand();
      unawaited(
        Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => CallScreen(matrix: matrix)),
        ),
      );
    }
    return;
  }

  final start = call.start(roomId, video: video);
  if (!isWide) {
    call.expand();
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => CallScreen(matrix: matrix)),
      ),
    );
  }

  try {
    await start;
  } catch (_) {
    // CallController keeps the user-facing failure in lastError and performs
    // scoped signaling/media rollback.
  }
  if (!context.mounted) return;

  if (!call.isActive) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(call.lastError ?? 'Не удалось начать звонок')),
    );
    return;
  }

  if (isWide) call.minimize();
}
