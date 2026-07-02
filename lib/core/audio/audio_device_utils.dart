import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../logging/orex_logger.dart';

class OrexAudioDevice {
  const OrexAudioDevice({
    required this.id,
    required this.kind,
    required this.label,
  });

  final String id;
  final String kind;
  final String label;

  bool get isInput => kind == 'audioinput';
  bool get isOutput => kind == 'audiooutput';
}

Future<List<OrexAudioDevice>> enumerateOrexAudioDevices({
  bool requestPermission = false,
}) async {
  rtc.MediaStream? permissionStream;
  if (requestPermission) {
    try {
      permissionStream = await rtc.navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
    } catch (e) {
      OrexLog.d('AudioDevices', 'permission unlock failed', e);
    }
  }

  try {
    final merged = <String, OrexAudioDevice>{};

    Future<void> addAll(Future<List<dynamic>> Function() loader, String source) async {
      try {
        final devices = await loader();
        for (final raw in devices) {
          final device = _fromRawDevice(raw);
          if (device == null) continue;
          final key = '${device.kind}|${device.id}|${device.label}';
          merged[key] = device;
        }
      } catch (e) {
        OrexLog.d('AudioDevices', '$source enumerate failed', e);
      }
    }

    // navigator.mediaDevices is the WebRTC-standard path. Helper is the
    // flutter_webrtc native helper; on desktop it can expose audio routes even
    // when navigator.enumerateDevices() only returns defaults before a call.
    await addAll(
      () async => await rtc.navigator.mediaDevices.enumerateDevices(),
      'navigator.mediaDevices',
    );
    await addAll(
      () async => await rtc.Helper.enumerateDevices('audioinput'),
      'Helper.audioinput',
    );
    await addAll(
      () async => await rtc.Helper.enumerateDevices('audiooutput'),
      'Helper.audiooutput',
    );
    await addAll(
      () async => await rtc.Helper.audiooutputs,
      'Helper.audiooutputs',
    );

    final result = merged.values.toList()
      ..sort((a, b) {
        final byKind = a.kind.compareTo(b.kind);
        if (byKind != 0) return byKind;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
    OrexLog.d(
      'AudioDevices',
      'enumerated total=${result.length} inputs=${result.where((d) => d.isInput).length} outputs=${result.where((d) => d.isOutput).length} permission=$requestPermission',
    );
    return result;
  } finally {
    for (final track in permissionStream?.getTracks() ?? <dynamic>[]) {
      try {
        track.stop();
      } catch (_) {}
    }
  }
}

OrexAudioDevice? _fromRawDevice(dynamic raw) {
  final id = _readString(raw, 'deviceId').trim();
  final kind = _normalizeKind(_readString(raw, 'kind'));
  if (kind == null) return null;
  final rawLabel = _readString(raw, 'label').trim();
  final label = rawLabel.isEmpty ? _fallbackLabel(kind, id) : rawLabel;
  return OrexAudioDevice(
    id: id.isEmpty ? 'default' : id,
    kind: kind,
    label: label,
  );
}

String _readString(dynamic raw, String field) {
  try {
    final value = switch (field) {
      'deviceId' => raw.deviceId,
      'kind' => raw.kind,
      'label' => raw.label,
      _ => '',
    };
    return '$value';
  } catch (_) {
    return '';
  }
}

String? _normalizeKind(String raw) {
  final value = raw.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (value.contains('audioinput')) return 'audioinput';
  if (value.contains('audiooutput')) return 'audiooutput';
  return null;
}

String _fallbackLabel(String kind, String id) {
  final suffix = id.isEmpty || id == 'default' ? '' : ' · ${id.substring(0, id.length < 6 ? id.length : 6)}';
  if (kind == 'audioinput') return 'Микрофон$suffix';
  return 'Динамики / наушники$suffix';
}
