import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../logging/orex_logger.dart';
import 'native_audio_devices.dart';

const _androidOutputPrefix = 'orex://android/audio-output/';

bool get orexIsAndroidNativePlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool get orexIsMobileNativePlatform {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

bool get orexCanUseNativeAudioDevices {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.windows;
}

bool orexIsAndroidOutputDeviceId(String? id) =>
    id != null && id.startsWith(_androidOutputPrefix);

bool orexIsMobileRouteId(String? id) => orexIsAndroidOutputDeviceId(id);

bool orexIsAndroidSpeakerOutputDeviceId(String? id) =>
    _isAndroidOutputType(id, 2);

bool orexIsAndroidEarpieceOutputDeviceId(String? id) =>
    _isAndroidOutputType(id, 1);

bool _isAndroidOutputType(String? id, int type) {
  if (!orexIsAndroidOutputDeviceId(id)) return false;
  final route = id!.substring(_androidOutputPrefix.length);
  return route.startsWith('audio:$type:') || route.startsWith('$type:');
}

class OrexAudioDevice {
  const OrexAudioDevice({
    required this.id,
    required this.kind,
    required this.label,
    this.category = '',
  });

  final String id;
  final String kind;
  final String label;
  final String category;

  bool get isInput => kind == 'audioinput';
  bool get isOutput => kind == 'audiooutput';

  bool get isBluetooth => category == 'bluetooth';
  bool get isHeadphones =>
      isBluetooth || category == 'headphones' || category == 'usb';
}

List<OrexAudioDevice> _lastNonEmptyDevices = const [];
List<OrexAudioDevice> _lastNonEmptyCallDevices = const [];

/// Returns audio devices that are actually useful to the settings UI.
///
/// WebRTC is still the primary source for input devices. Android output routes
/// and Windows output endpoints are read natively because flutter_webrtc can
/// return an empty output list until a call is active on these platforms.
Future<List<OrexAudioDevice>> enumerateOrexAudioDevices({
  bool requestPermission = false,
  bool includeCallRoutes = false,
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
    final rawDevices = await _enumerateWebRtcDevices();
    final nativeDevices = orexCanUseNativeAudioDevices
        ? _nativeDevicesFromMaps(
            await OrexNativeAudioDevices.enumerate(
              includeCallRoutes: includeCallRoutes,
            ),
          )
        : const <OrexAudioDevice>[];
    final byKey = <String, OrexAudioDevice>{};
    final seenLabels = <String>{};
    final hasNativeMobileOutputs = orexIsMobileNativePlatform &&
        nativeDevices.any((device) => device.isOutput);

    void addDevice(OrexAudioDevice device) {
      if (!_shouldShowDevice(device)) return;
      if (hasNativeMobileOutputs &&
          device.isOutput &&
          !orexIsAndroidOutputDeviceId(device.id)) {
        return;
      }
      final labelKey = '${device.kind}|${device.label.toLowerCase()}';
      final key = '${device.kind}|${device.id}';

      // Android WebRTC often exposes noisy low-level entries. Native routes are
      // cleaner and update when a headset/Bluetooth device appears.
      if (orexIsMobileNativePlatform &&
          seenLabels.contains(labelKey) &&
          !orexIsAndroidOutputDeviceId(device.id)) {
        return;
      }

      byKey[key] = device;
      seenLabels.add(labelKey);
    }

    for (final raw in rawDevices) {
      final device = _fromRawDevice(raw);
      if (device != null) addDevice(device);
    }
    for (final device in nativeDevices) {
      addDevice(device);
    }

    final result = byKey.values.toList()
      ..sort((a, b) {
        final byKind = a.kind.compareTo(b.kind);
        if (byKind != 0) return byKind;
        final byRank = _deviceSortRank(a).compareTo(_deviceSortRank(b));
        if (byRank != 0) return byRank;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

    final cachedDevices = includeCallRoutes
        ? _lastNonEmptyCallDevices
        : _lastNonEmptyDevices;
    if (result.isNotEmpty) {
      if (includeCallRoutes) {
        _lastNonEmptyCallDevices = result;
      } else {
        _lastNonEmptyDevices = result;
      }
    }
    final finalResult = result.isEmpty ? cachedDevices : result;

    OrexLog.d(
      'AudioDevices',
      'enumerated total=${finalResult.length} inputs=${finalResult.where((d) => d.isInput).length} outputs=${finalResult.where((d) => d.isOutput).length} webrtc=${rawDevices.length} native=${nativeDevices.length} permission=$requestPermission includeCallRoutes=$includeCallRoutes mobile=$orexIsMobileNativePlatform',
    );
    return finalResult;
  } catch (e) {
    OrexLog.d('AudioDevices', 'enumerate failed', e);
    return includeCallRoutes ? _lastNonEmptyCallDevices : _lastNonEmptyDevices;
  } finally {
    for (final track in permissionStream?.getTracks() ?? <dynamic>[]) {
      try {
        track.stop();
      } catch (_) {}
    }
  }
}

Future<List<dynamic>> _enumerateWebRtcDevices() async {
  try {
    return await rtc.navigator.mediaDevices.enumerateDevices();
  } catch (e) {
    OrexLog.d('AudioDevices', 'navigator.mediaDevices enumerate failed', e);
    return const [];
  }
}


List<OrexAudioDevice> _nativeDevicesFromMaps(List<Map<String, String>> raw) => [
      for (final item in raw)
        OrexAudioDevice(
          id: item['id'] ?? '',
          kind: item['kind'] ?? '',
          label: item['label'] ?? '',
          category: (item['category'] ?? '').isNotEmpty
              ? item['category']!
              : _inferCategory(
                  id: item['id'] ?? '',
                  kind: item['kind'] ?? '',
                  label: item['label'] ?? '',
                ),
        ),
    ];

OrexAudioDevice? _fromRawDevice(dynamic raw) {
  final id = _readString(raw, 'deviceId').trim();
  final kind = _normalizeKind(_readString(raw, 'kind'));
  if (id.isEmpty || kind == null) return null;

  final rawLabel = _cleanLabel(_readString(raw, 'label'));
  final label = _friendlyLabel(id: id, kind: kind, label: rawLabel);
  return OrexAudioDevice(
    id: id,
    kind: kind,
    label: label,
    category: _inferCategory(id: id, kind: kind, label: label),
  );
}

bool _shouldShowDevice(OrexAudioDevice device) {
  final id = device.id.trim().toLowerCase();
  if (id.isEmpty || id == 'default' || id == 'communications') return false;

  final label = device.label.trim();
  if (label.isEmpty) return false;

  if (orexIsMobileNativePlatform &&
      !orexIsAndroidOutputDeviceId(device.id) &&
      _looksLikeAndroidHardwareCode(label)) {
    return false;
  }

  return true;
}

int _deviceSortRank(OrexAudioDevice device) {
  if (!device.isOutput) return 0;
  return switch (device.category) {
    'bluetooth' => 0,
    'headphones' || 'usb' => 1,
    'speaker' => 8,
    'earpiece' => 9,
    _ => 5,
  };
}

String _inferCategory({
  required String id,
  required String kind,
  required String label,
}) {
  final value = '$id $label'.toLowerCase();
  final bluetooth = value.contains('bluetooth') ||
      value.contains('bt-') ||
      value.contains('airpods') ||
      value.contains('hands-free') ||
      value.contains('handsfree');
  if (bluetooth) return 'bluetooth';
  if (value.contains('usb')) return 'usb';

  final looksLikeHeadset = value.contains('headphone') ||
      value.contains('headphones') ||
      value.contains('headset') ||
      value.contains('earbud') ||
      value.contains('earbuds') ||
      value.contains('earphone') ||
      value.contains('earphones') ||
      value.contains('науш') ||
      value.contains('гарнитур');
  if (looksLikeHeadset) return 'headphones';

  if (kind == 'audioinput') return 'mic';
  if (kind != 'audiooutput') return '';

  if (value.contains('earpiece') || value.contains('разговор')) return 'earpiece';
  if (value.contains('speaker') ||
      value.contains('speakers') ||
      value.contains('динамик') ||
      value.contains('динамики')) {
    return 'speaker';
  }
  return '';
}

String _friendlyLabel({
  required String id,
  required String kind,
  required String label,
}) {
  if (!orexIsAndroidNativePlatform || kind != 'audioinput') return label;
  final value = '$id $label'.toLowerCase();
  if (value.contains('bottom')) return 'Нижний микрофон телефона';
  if (value.contains('back') || value.contains('rear')) {
    return 'Задний микрофон телефона';
  }
  if (value.contains('front')) return 'Передний микрофон телефона';
  if (value == 'microphone' || value.endsWith(' microphone')) {
    return 'Микрофон телефона';
  }
  return label;
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
