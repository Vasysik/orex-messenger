import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/audio/audio_device_utils.dart';
import '../../core/voip/call_session.dart';
import '../../core/voip/screen_share_controller.dart';
import 'call_controls.dart';
import 'screen_source_picker.dart';

Future<void> orexShowCallReaction({
  required BuildContext context,
  required GlobalKey anchorKey,
  required CallSession session,
  double emojiSize = 30,
}) async {
  final emoji = await showOrexCallReactionMenu(
    context,
    anchorKey,
    emojiSize: emojiSize,
  );
  if (emoji == null) return;
  await session.sendVoiceReaction(emoji);
}

Future<void> orexToggleScreenShare({
  required BuildContext context,
  required CallSession session,
  required bool Function() isMounted,
}) async {
  if (!OrexScreenShareController.isSupported) return;
  if (session.screenShareOn) {
    await session.toggleScreenShare();
    return;
  }
  if (defaultTargetPlatform == TargetPlatform.android) {
    await session.toggleScreenShare();
    return;
  }

  OrexScreenSource? source;
  if (orexNeedsScreenSourcePicker) {
    source = await showOrexScreenSourcePicker(context);
    if (source == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!isMounted()) return;
  }

  await session.toggleScreenShare(
    sourceId: source?.id,
    sourceName: source?.name,
    sourceType: source?.type,
  );
}

Future<void> orexCycleCamera(CallSession session) async {
  final cameras = await enumerateOrexCameraDevices();
  if (cameras.isEmpty) return;
  await session.cycleCameraDevice(cameras);
}
