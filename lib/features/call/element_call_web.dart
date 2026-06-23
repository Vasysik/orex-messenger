import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../../theme/orex_theme.dart';
import 'element_call_url.dart';

int _viewCounter = 0;

/// Web: встраиваем Element Call в <iframe> на отдельном полноэкранном экране.
Future<void> openElementCall(
  BuildContext context, {
  required String roomId,
  bool video = true,
}) async {
  final url = buildElementCallUrl(roomId: roomId, video: video);
  final viewType = 'element-call-${_viewCounter++}';

  // Регистрируем фабрику <iframe> с разрешениями на камеру/микрофон.
  ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
    final iframe = web.HTMLIFrameElement()
      ..src = url
      ..allow = 'camera; microphone; fullscreen; display-capture; autoplay';
    iframe.style.setProperty('border', 'none');
    iframe.style.setProperty('width', '100%');
    iframe.style.setProperty('height', '100%');
    return iframe;
  });

  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _CallScaffold(viewType: viewType),
    ),
  );
}

class _CallScaffold extends StatelessWidget {
  const _CallScaffold({required this.viewType});
  final String viewType;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OrexColors.darkBg,
      appBar: AppBar(
        backgroundColor: OrexColors.darkBg,
        title: const Text('Звонок'),
        leading: IconButton(
          icon: const Icon(Icons.call_end, color: Color(0xFFCF6679)),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: HtmlElementView(viewType: viewType),
    );
  }
}
