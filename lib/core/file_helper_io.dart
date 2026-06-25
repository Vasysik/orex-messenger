import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:open_app_file/open_app_file.dart';

class FileHelper {
  static Future<void> saveAndOpenFile(String filename, Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(bytes);
    await OpenAppFile.open(file.path);
  }
}
