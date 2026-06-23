import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'element_call_url.dart';

/// Native: открываем Element Call в системном браузере.
Future<void> openElementCall(
  BuildContext context, {
  required String roomId,
  bool video = true,
}) async {
  final url = Uri.parse(buildElementCallUrl(roomId: roomId, video: video));
  final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Не удалось открыть Element Call')),
    );
  }
}
