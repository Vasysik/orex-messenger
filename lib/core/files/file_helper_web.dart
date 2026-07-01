import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class FileHelper {
  static Future<void> saveAndOpenFile(String filename, Uint8List bytes) async {
    final safeName = _safeFilename(filename);
    final blob = web.Blob([bytes.toJS].toJS);
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = safeName;
    anchor.style.setProperty('display', 'none');
    web.document.body?.appendChild(anchor);
    anchor.click();
    web.document.body?.removeChild(anchor);
    web.URL.revokeObjectURL(url);
  }

  static String _safeFilename(String filename) {
    var name = filename.trim().replaceAll('\\', '/').split('/').last;
    name = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.isEmpty || name == '.' || name == '..') return 'download.bin';
    if (name.length <= 120) return name;
    return name.substring(0, 120);
  }
}
