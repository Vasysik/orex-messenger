import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../logging/orex_logger.dart';
import 'native_audio_devices.dart';

const _androidOutputPrefix = 'orex://android/audio-output/';

bool get orexIsAndroidNativePlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

bool get orexIsWindowsNativePlatform =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

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

  bool get isBluetooth =>
      category == 'bluetooth' || category == 'bluetooth_hands_free';
  bool get isBluetoothHandsFree => category == 'bluetooth_hands_free';
  bool get isHeadphones =>
      isBluetooth || category == 'headphones' || category == 'usb';
}

List<OrexAudioDevice> _lastNonEmptyDevices = const [];
List<OrexAudioDevice> _lastNonEmptyCallDevices = const [];
List<OrexAudioDevice> _lastEnumeratedWebDevices = const [];
String? _lastWebDefaultAudioOutputLabel;

/// Returns audio devices that are actually useful to the settings UI.
///
/// WebRTC is still the primary source for input devices. Android output routes
/// and Windows output endpoints are read natively because flutter_webrtc can
/// return an empty output list until a call is active on these platforms.
Future<List<OrexAudioDevice>> enumerateOrexAudioDevices({
  bool requestPermission = false,
  bool includeCallRoutes = false,
  String? preferredInputDeviceId,
}) async {
  rtc.MediaStream? permissionStream;

  try {
    var rawDevices = await _enumerateWebRtcDevices();

    // On web, opening an unconstrained default input can open a Bluetooth
    // headset's Hands-Free endpoint even when the call itself uses another
    // microphone. That makes Windows switch the headset from stereo/A2DP to
    // HFP. Device labels remain available after permission has been granted,
    // so do not make a second default capture merely to enumerate them.
    final needsPermissionCapture = orexShouldRequestAudioPermission(
      requestPermission: requestPermission,
      isWeb: kIsWeb,
      rawDevices: rawDevices,
    );
    if (needsPermissionCapture) {
      try {
        permissionStream = await rtc.navigator.mediaDevices.getUserMedia({
          'audio': orexAudioPermissionConstraint(preferredInputDeviceId),
          'video': false,
        });
        rawDevices = await _enumerateWebRtcDevices();
      } catch (e) {
        OrexLog.d('AudioDevices', 'permission unlock failed', e);
      }
    }
    if (kIsWeb) {
      _lastWebDefaultAudioOutputLabel = orexDefaultAudioOutputLabel(rawDevices);
    }

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

    final allDevices = byKey.values.toList();
    if (kIsWeb && allDevices.isNotEmpty) {
      _lastEnumeratedWebDevices = allDevices;
    }
    final result = (kIsWeb
            ? orexFilterRedundantWebHandsFreeOutputs(allDevices)
            : allDevices)
        .toList()
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

/// Whether browser device enumeration already exposes a usable microphone
/// label. Once this is true, another permission-only getUserMedia call is
/// unnecessary and may activate a Bluetooth headset's Hands-Free profile.
@visibleForTesting
bool orexHasReadableAudioInputLabels(List<dynamic> rawDevices) {
  for (final raw in rawDevices) {
    if (_normalizeKind(_readString(raw, 'kind')) != 'audioinput') continue;
    if (_cleanLabel(_readString(raw, 'label')).isNotEmpty) return true;
  }
  return false;
}

/// Decides whether the label-unlock stream is needed. Native platforms retain
/// their established permission-request behavior; web avoids reopening a
/// default input after access was already granted.
@visibleForTesting
bool orexShouldRequestAudioPermission({
  required bool requestPermission,
  required bool isWeb,
  required List<dynamic> rawDevices,
}) {
  return requestPermission &&
      (!isWeb || !orexHasReadableAudioInputLabels(rawDevices));
}

/// Constraints used only for the short permission/label-unlock stream.
///
/// A selected web microphone must be mandatory here: merely preferring it
/// allows the browser to pick the Bluetooth Hands-Free microphone instead.
@visibleForTesting
dynamic orexAudioPermissionConstraint(
  String? preferredInputDeviceId, {
  bool? isWeb,
}) {
  final normalized = preferredInputDeviceId?.trim();
  if (!(isWeb ?? kIsWeb) ||
      normalized == null ||
      normalized.isEmpty ||
      normalized == 'default') {
    return true;
  }

  // Do not silently fall back to a Bluetooth/default microphone. A stale
  // persisted device id fails the short label-unlock request safely; the user
  // can then choose a currently available input.
  return <String, dynamic>{
    'deviceId': <String, String>{'exact': normalized},
  };
}

String? orexResolveCurrentDeviceId(
  List<OrexAudioDevice> devices, {
  required String? selectedId,
}) {
  final normalized = selectedId?.trim();
  if (normalized != null && normalized.isNotEmpty && normalized != 'default') {
    for (final device in devices) {
      if (device.id == normalized) return device.id;
    }
    if (orexIsAndroidSpeakerOutputDeviceId(normalized)) {
      for (final device in devices) {
        if (orexIsAndroidSpeakerOutputDeviceId(device.id) ||
            device.category == 'speaker') {
          return device.id;
        }
      }
    }
    if (orexIsAndroidEarpieceOutputDeviceId(normalized)) {
      for (final device in devices) {
        if (orexIsAndroidEarpieceOutputDeviceId(device.id) ||
            device.category == 'earpiece') {
          return device.id;
        }
      }
    }
  }

  final sorted = devices.toList()
    ..sort((a, b) {
      final byRank = _currentDefaultRank(a).compareTo(_currentDefaultRank(b));
      if (byRank != 0) return byRank;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
  return sorted.isEmpty ? null : sorted.first.id;
}

int _currentDefaultRank(OrexAudioDevice device) {
  if (device.isOutput && orexIsAndroidNativePlatform) {
    if (device.category == 'speaker' || orexIsAndroidSpeakerOutputDeviceId(device.id)) {
      return 0;
    }
    return _deviceSortRank(device) + 10;
  }

  return switch (device.category) {
    'bluetooth' => 0,
    'bluetooth_hands_free' => 6,
    'headphones' || 'usb' => 1,
    'front_camera' => 0,
    'back_camera' => 1,
    'webcam' => 2,
    _ => 5,
  };
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
    'bluetooth_hands_free' => 7,
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
  if (kind == 'audiooutput' && orexLooksLikeBluetoothHandsFreeOutput(value)) {
    return 'bluetooth_hands_free';
  }
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

/// Identifies the low-bandwidth Windows Bluetooth telephony endpoint.
///
/// Browsers expose the stereo/A2DP and Hands-Free/HFP endpoints as separate
/// output devices. Selecting the latter forces the headset into a mono call
/// profile even when another microphone is used.
@visibleForTesting
bool orexLooksLikeBluetoothHandsFreeOutput(String value) {
  final normalized = value.toLowerCase();
  return normalized.contains('hands-free') ||
      normalized.contains('handsfree') ||
      normalized.contains('hands free') ||
      normalized.contains('ag audio') ||
      RegExp(r'(^|[^a-z0-9])hfp([^a-z0-9]|$)').hasMatch(normalized) ||
      normalized.contains('headset earphone');
}

/// Hides a Hands-Free output only when the same Bluetooth headset also has a
/// stereo endpoint. A standalone HFP device remains visible so routing is not
/// silently broken on hardware that exposes no A2DP alternative.
@visibleForTesting
List<OrexAudioDevice> orexFilterRedundantWebHandsFreeOutputs(
  List<OrexAudioDevice> devices,
) {
  final stereoFingerprints = <String>{
    for (final device in devices)
      if (device.isOutput &&
          device.isHeadphones &&
          !device.isBluetoothHandsFree)
        _bluetoothEndpointFingerprint(device.label),
  }..remove('');

  return <OrexAudioDevice>[
    for (final device in devices)
      if (!device.isOutput ||
          !device.isBluetoothHandsFree ||
          !stereoFingerprints.contains(
            _bluetoothEndpointFingerprint(device.label),
          ))
        device,
  ];
}

/// Replaces a persisted HFP endpoint with the matching stereo endpoint.
///
/// This is intentionally conservative: no match means the original id is
/// retained instead of guessing another physical output device.
@visibleForTesting
String? orexResolvePreferredWebAudioOutputId(
  List<OrexAudioDevice> devices, {
  required String? selectedId,
  String? defaultOutputLabel,
}) {
  final normalized = selectedId?.trim();
  if (normalized == null || normalized.isEmpty || normalized == 'default') {
    final defaultFingerprint = _bluetoothEndpointFingerprint(
      defaultOutputLabel ?? '',
    );
    if (defaultFingerprint.isEmpty) return null;
    OrexAudioDevice? handsFreeFallback;
    for (final device in devices) {
      if (!device.isOutput || !device.isHeadphones) continue;
      if (_bluetoothEndpointFingerprint(device.label) != defaultFingerprint) {
        continue;
      }
      if (!device.isBluetoothHandsFree) return device.id;
      handsFreeFallback = device;
    }
    return handsFreeFallback?.id;
  }

  OrexAudioDevice? selected;
  for (final device in devices) {
    if (device.isOutput && device.id == normalized) {
      selected = device;
      break;
    }
  }
  if (selected == null || !selected.isBluetoothHandsFree) return normalized;

  final fingerprint = _bluetoothEndpointFingerprint(selected.label);
  if (fingerprint.isEmpty) return normalized;
  for (final device in devices) {
    if (!device.isOutput ||
        !device.isHeadphones ||
        device.isBluetoothHandsFree) {
      continue;
    }
    if (_bluetoothEndpointFingerprint(device.label) == fingerprint) {
      return device.id;
    }
  }
  return normalized;
}

String? orexPreferredWebAudioOutputDeviceId(String? selectedId) {
  final normalized = selectedId?.trim();
  if (!kIsWeb) {
    return normalized == null || normalized.isEmpty || normalized == 'default'
        ? null
        : normalized;
  }
  return orexResolvePreferredWebAudioOutputId(
    _lastEnumeratedWebDevices,
    selectedId: normalized,
    defaultOutputLabel: _lastWebDefaultAudioOutputLabel,
  );
}

@visibleForTesting
String? orexDefaultAudioOutputLabel(List<dynamic> rawDevices) {
  for (final raw in rawDevices) {
    if (_normalizeKind(_readString(raw, 'kind')) != 'audiooutput') continue;
    if (_readString(raw, 'deviceId').trim().toLowerCase() != 'default') {
      continue;
    }
    final label = _cleanLabel(_readString(raw, 'label'));
    if (label.isNotEmpty) return label;
  }
  return null;
}

String _bluetoothEndpointFingerprint(String label) {
  var value = label.toLowerCase();
  for (final token in const <String>[
    'hands-free',
    'handsfree',
    'hands free',
    'ag audio',
    'hfp',
    'stereo',
    'bluetooth',
    'headphones',
    'headphone',
    'headset',
    'earphones',
    'earphone',
    'speakers',
    'speaker',
    'audio',
    'наушники',
    'наушник',
    'гарнитура',
    'стерео',
    'аудио',
    'default',
    'communications',
    'по умолчанию',
  ]) {
    value = value.replaceAll(token, ' ');
  }
  return value
      .replaceAll(RegExp(r'[^a-zа-яё0-9]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
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

Future<List<OrexAudioDevice>> enumerateOrexCameraDevices({
  bool requestPermission = false,
}) async {
  rtc.MediaStream? permissionStream;
  if (requestPermission) {
    try {
      permissionStream = await rtc.navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': true,
      });
    } catch (e) {
      OrexLog.d('AudioDevices', 'camera permission unlock failed', e);
    }
  }

  try {
    final rawDevices = await _enumerateWebRtcDevices();
    final result = <OrexAudioDevice>[];
    final seen = <String>{};
    for (final raw in rawDevices) {
      final id = _readString(raw, 'deviceId').trim();
      if (id.isEmpty || _normalizeVideoKind(_readString(raw, 'kind')) != 'videoinput') {
        continue;
      }
      final rawLabel = _cleanLabel(_readString(raw, 'label'));
      final label = rawLabel.isEmpty ? 'Камера' : rawLabel;
      final category = _inferCameraCategory(id: id, label: label);
      final key = '$id|${label.toLowerCase()}';
      if (!seen.add(key)) continue;
      result.add(OrexAudioDevice(
        id: id,
        kind: 'videoinput',
        label: label,
        category: category,
      ));
    }
    result.sort((a, b) {
      final byRank = _cameraSortRank(a).compareTo(_cameraSortRank(b));
      if (byRank != 0) return byRank;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return result;
  } finally {
    for (final track in permissionStream?.getTracks() ?? <dynamic>[]) {
      try {
        track.stop();
      } catch (_) {}
    }
  }
}

String? _normalizeVideoKind(String raw) {
  final value = raw.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (value.contains('videoinput')) return 'videoinput';
  return null;
}

String _inferCameraCategory({required String id, required String label}) {
  final value = '$id $label'.toLowerCase();
  if (value.contains('front') || value.contains('фронт')) return 'front_camera';
  if (value.contains('back') ||
      value.contains('rear') ||
      value.contains('environment') ||
      value.contains('зад')) {
    return 'back_camera';
  }
  if (value.contains('usb') || value.contains('webcam') || value.contains('web cam')) {
    return 'webcam';
  }
  return 'camera';
}

int _cameraSortRank(OrexAudioDevice device) => switch (device.category) {
      'front_camera' => 0,
      'back_camera' => 1,
      'webcam' => 2,
      _ => 5,
    };

IconData orexInputDeviceIcon(OrexAudioDevice device) {
  return switch (device.category) {
    'bluetooth' || 'bluetooth_hands_free' => Icons.headset_mic,
    'headphones' => Icons.headset_mic,
    'usb' => Icons.usb,
    _ => Icons.mic,
  };
}

IconData orexOutputDeviceIcon(OrexAudioDevice device) {
  return switch (device.category) {
    'bluetooth' || 'bluetooth_hands_free' => Icons.headset_mic,
    'headphones' => Icons.headphones,
    'usb' => Icons.usb,
    'earpiece' => Icons.phone_in_talk,
    _ => Icons.speaker,
  };
}

IconData orexCameraDeviceIcon(OrexAudioDevice device) {
  return switch (device.category) {
    'front_camera' => Icons.camera_front,
    'back_camera' => Icons.camera_rear,
    'webcam' => Icons.videocam,
    _ => Icons.photo_camera,
  };
}
