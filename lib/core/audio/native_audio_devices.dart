import 'package:flutter/services.dart';

import '../logging/orex_logger.dart';

class OrexNativeAudioDevices {
  static const MethodChannel _channel = MethodChannel('orex/audio_devices');

  static Future<List<Map<String, String>>> enumerate() async {
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listAudioDevices');
      if (raw == null || raw.isEmpty) return const [];
      final result = <Map<String, String>>[];
      for (final item in raw) {
        if (item is! Map) continue;
        final id = '${item['id'] ?? ''}'.trim();
        final kind = '${item['kind'] ?? ''}'.trim();
        final label = '${item['label'] ?? ''}'.trim();
        if (id.isEmpty || kind.isEmpty || label.isEmpty) continue;
        if (kind != 'audioinput' && kind != 'audiooutput') continue;
        final category = '${item['category'] ?? ''}'.trim();
        result.add({
          'id': id,
          'kind': kind,
          'label': label,
          if (category.isNotEmpty) 'category': category,
        });
      }
      return result;
    } on MissingPluginException {
      return const [];
    } catch (e) {
      OrexLog.d('AudioDevices', 'native enumerate failed', e);
      return const [];
    }
  }

  static Future<bool> selectOutput(String? id) async {
    try {
      return await _channel.invokeMethod<bool>('selectAudioOutput', {'id': id}) ??
          false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      OrexLog.d('AudioDevices', 'native select output failed id=$id', e);
      return false;
    }
  }
}
