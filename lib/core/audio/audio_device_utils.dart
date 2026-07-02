import 'package:flutter/foundation.dart';
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

/// Returns only WebRTC devices that can be used by getUserMedia/LiveKit.
///
/// The settings screen renders its own "system default" rows, so synthetic
/// WebRTC defaults, cached rows, Android AudioDeviceInfo ids and mobile speaker
/// route pseudo-devices are intentionally not exposed here.
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
    final rawDevices = await rtc.navigator.mediaDevices.enumerateDevices();
    final byId = <String, OrexAudioDevice>{};
    final seenLabels = <String>{};

    for (final raw in rawDevices) {
      final device = _fromRawDevice(raw);
      if (device == null) continue;
      if (!_shouldShowDevice(device)) continue;

      final idKey = '${device.kind}|${device.id}';
      final labelKey = '${device.kind}|${device.label.toLowerCase()}';
      if (_isMobileNative && seenLabels.contains(labelKey)) continue;

      byId[idKey] = device;
      seenLabels.add(labelKey);
    }

    final result = byId.values.toList()
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
  } catch (e) {
    OrexLog.d('AudioDevices', 'navigator.mediaDevices enumerate failed', e);
    return const [];
  } finally {
    for (final track in permissionStream?.getTracks() ?? <dynamic>[]) {
      try {
        track.stop();
      } catch (_) {}
    }
  }
}

bool get _isMobileNative {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

OrexAudioDevice? _fromRawDevice(dynamic raw) {
  final id = _readString(raw, 'deviceId').trim();
  final kind = _normalizeKind(_readString(raw, 'kind'));
  if (id.isEmpty || kind == null) return null;

  final label = _cleanLabel(_readString(raw, 'label'));
  return OrexAudioDevice(id: id, kind: kind, label: label);
}

bool _shouldShowDevice(OrexAudioDevice device) {
  final id = device.id.trim().toLowerCase();
  if (id.isEmpty || id == 'default' || id == 'communications') return false;

  final label = device.label.trim();
  // Unlabelled concrete ids are not useful to a user and usually mean the app
  // has not obtained mic permission yet. The system default row remains usable.
  if (label.isEmpty) return false;

  // Android can expose several low-level AudioDeviceInfo entries whose labels
  // are just build/model codes with numeric ids. They are not stable WebRTC
  // deviceIds for LiveKit and make the settings look like a debug dump.
  if (_isMobileNative && _looksLikeAndroidHardwareCode(label)) return false;

  return true;
}

String _readString(dynamic raw, String field) {
  final keys = switch (field) {
    'deviceId' => const ['deviceId', 'device_id', 'id'],
    'kind' => const ['kind', 'type'],
    'label' => const ['label', 'name'],
    _ => const <String>[],
  };

  if (raw is Map) {
    for (final key in keys) {
      final value = raw[key];
      if (value != null && '$value'.trim().isNotEmpty) return '$value';
    }
    return '';
  }

  for (final key in keys) {
    try {
      final value = switch (key) {
        'deviceId' => raw.deviceId,
        'device_id' => raw.deviceId,
        'id' => raw.id,
        'kind' => raw.kind,
        'type' => raw.type,
        'label' => raw.label,
        'name' => raw.name,
        _ => null,
      };
      if (value != null && '$value'.trim().isNotEmpty) return '$value';
    } catch (_) {}
  }
  return '';
}

String? _normalizeKind(String raw) {
  final value = raw.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (value.contains('audioinput') || value == 'input') return 'audioinput';
  if (value.contains('audiooutput') || value == 'output') return 'audiooutput';
  return null;
}

String _cleanLabel(String raw) => raw.replaceAll(RegExp(r'\s+'), ' ').trim();

bool _looksLikeAndroidHardwareCode(String label) {
  final normalized = label.trim();
  if (normalized.contains(' ')) return false;
  if (RegExp(r'^(microphone|mic|speaker|earpiece|headset|bluetooth|usb)',
          caseSensitive: false)
      .hasMatch(normalized)) {
    return false;
  }
  return RegExp(r'^(?=.*\d)[A-Z0-9._-]{5,}$').hasMatch(normalized);
}
