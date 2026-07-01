import 'dart:io';
import 'dart:typed_data';

import 'package:open_app_file/open_app_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FileHelper {
  static Future<void> saveAndOpenFile(String filename, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final safeName = _safeFilename(filename);
    final file = File(p.join(dir.path, safeName));
    await file.writeAsBytes(bytes, flush: true);
    await OpenAppFile.open(file.path);
  }

  static String _safeFilename(String filename) {
    var name = filename.trim().replaceAll('\\', '/').split('/').last;
    name = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (name.isEmpty || name == '.' || name == '..') return 'download.bin';
    if (name.length <= 120) return name;

    final ext = p.extension(name);
    final base = p.basenameWithoutExtension(name);
    final maxBase = (120 - ext.length).clamp(16, 120).toInt();
    final trimmedBase = base.length > maxBase ? base.substring(0, maxBase) : base;
    if (trimmedBase.isEmpty) return name.substring(0, 120);
    return '$trimmedBase$ext';
  }
}
