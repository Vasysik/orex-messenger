import 'dart:js_interop';
import 'dart:typed_data';
import 'package:web/web.dart' as web;

class FileHelper {
  static Future<void> saveAndOpenFile(String filename, Uint8List bytes) async {
    // Конвертируем Uint8List в JavaScript TypedArray
    final blob = web.Blob([bytes.toJS].toJS);
    final url = web.URL.createObjectURL(blob);
    final anchor = web.document.createElement('a') as web.HTMLAnchorElement
      ..href = url
      ..download = filename;
    anchor.style.setProperty('display', 'none');
    web.document.body?.appendChild(anchor);
    anchor.click();
    web.document.body?.removeChild(anchor);
    web.URL.revokeObjectURL(url);
  }
}
