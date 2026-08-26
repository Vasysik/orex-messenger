import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'safe_filename.dart';

class FileHelper {
  static Future<void> saveAndOpenFile(String filename, Uint8List bytes) async {
    final safeName = orexSafeFilename(filename);
    final blob = web.Blob([bytes.toJS].toJS);
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = safeName;
    anchor.style.setProperty('display', 'none');
    web.document.body?.appendChild(anchor);
    anchor.click();
    web.document.body?.removeChild(anchor);
    Timer(const Duration(seconds: 1), () => web.URL.revokeObjectURL(url));
  }

  static Future<void> cleanupTemporaryFiles() async {}
}
