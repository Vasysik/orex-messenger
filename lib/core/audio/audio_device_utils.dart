import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:record/record.dart' as rec;

import 'audio_cue_service.dart';
import '../logging/orex_logger.dart';

class OrexAudioDevice {
  const OrexAudioDevice({
    required this.id,
    required this.kind,
    required this.label,
    this.nativeOnly = false,
  });

  final String id;
  final String kind;
  final String label;

  /// true means the item is a platform route/device discovered outside WebRTC.
  /// It can still be useful for UI/routing, but WebRTC deviceId matching may be
  /// platform-dependent.
  final bool nativeOnly;

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

    void addDevice(OrexAudioDevice device, String source) {
      final id = device.id.trim();
      if (id.isEmpty) return;
      if (device.isOutput && !_isMobileNative) return;
      // We render our own "system default" rows. Keeping default duplicates from
      // WebRTC makes the settings look broken on platforms that hide labels.
      if (id == 'default' || id == 'communications') return;
      final key = '${device.kind}|$id';
      merged[key] = device;
    }

    Future<void> addAll(
      Future<List<dynamic>> Function() loader,
      String source,
    ) async {
      try {
        final devices = await loader();
        for (final raw in devices) {
          final device = _fromRawDevice(raw);
          if (device == null) continue;
          addDevice(device, source);
        }
      } catch (e) {
        OrexLog.d('AudioDevices', '$source enumerate failed', e);
      }
    }

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

    // record has its own native device enumerator. It often sees microphone
    // names even when WebRTC only returns defaults outside an active call.
    rec.AudioRecorder? recorder;
    try {
      recorder = rec.AudioRecorder();
      final inputs = await recorder.listInputDevices();
      for (final input in inputs) {
        addDevice(
          OrexAudioDevice(
            id: input.id,
            kind: 'audioinput',
            label: input.label.trim().isEmpty ? _fallbackLabel('audioinput', input.id) : input.label.trim(),
            nativeOnly: true,
          ),
          'record.listInputDevices',
        );
      }
    } catch (e) {
      OrexLog.d('AudioDevices', 'record.listInputDevices failed', e);
    } finally {
      try {
        await recorder?.dispose();
      } catch (_) {}
    }

    if (_isMobileNative) {
      addDevice(
        const OrexAudioDevice(
          id: AudioCueService.mobileEarpieceOutputId,
          kind: 'audiooutput',
          label: 'Разговорный динамик / гарнитура',
          nativeOnly: true,
        ),
        'mobile.virtual',
      );
      addDevice(
        const OrexAudioDevice(
          id: AudioCueService.mobileSpeakerOutputId,
          kind: 'audiooutput',
          label: 'Громкий динамик',
          nativeOnly: true,
        ),
        'mobile.virtual',
      );
    }

    final result = merged.values.toList()
      ..sort((a, b) {
        final byKind = a.kind.compareTo(b.kind);
        if (byKind != 0) return byKind;
        if (a.nativeOnly != b.nativeOnly) return a.nativeOnly ? 1 : -1;
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

bool get _isMobileNative {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
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

String _fallbackLabel(String kind, String id) {
  final suffix = id.isEmpty || id == 'default'
      ? ''
      : ' · ${id.substring(0, id.length < 6 ? id.length : 6)}';
  if (kind == 'audioinput') return 'Микрофон$suffix';
  return 'Динамики / наушники$suffix';
}
