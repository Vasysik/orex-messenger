import 'package:flutter/material.dart';

import '../../core/audio/audio_device_utils.dart';
import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_session.dart';
import '../../shared/widgets/orex_choice_sheet.dart';

Future<void> showOrexInputQuickSheet(
  BuildContext context, {
  required MatrixService matrix,
}) async {
  final devices = (await enumerateOrexAudioDevices(
    requestPermission: true,
    includeCallRoutes: true,
  ))
      .where((d) => d.isInput)
      .toList();
  if (!context.mounted) return;
  final selectedId = orexResolveCurrentDeviceId(
    devices,
    selectedId: matrix.audio.inputDeviceId,
  );
  final picked = await showOrexChoiceSheet<String>(
    context,
    title: 'Микрофон',
    emptyText: 'Микрофоны сейчас не найдены. Проверьте разрешение на микрофон.',
    options: [
      for (final device in devices)
        OrexChoiceSheetOption<String>(
          value: device.id,
          icon: orexInputDeviceIcon(device),
          title: device.label,
          selected: selectedId == device.id,
        ),
    ],
  );
  if (picked == null) return;
  await matrix.audio.setInputDeviceId(picked);
}

Future<void> showOrexOutputQuickSheet(
  BuildContext context, {
  required MatrixService matrix,
}) async {
  final devices = (await enumerateOrexAudioDevices(includeCallRoutes: true))
      .where((d) => d.isOutput)
      .toList();
  if (!context.mounted) return;
  final selectedId = orexResolveCurrentDeviceId(
    devices,
    selectedId: matrix.audio.outputDeviceId,
  );
  final picked = await showOrexChoiceSheet<String>(
    context,
    title: 'Вывод звука',
    emptyText: 'Устройства вывода сейчас не найдены.',
    options: [
      for (final device in devices)
        OrexChoiceSheetOption<String>(
          value: device.id,
          icon: orexOutputDeviceIcon(device),
          title: device.label,
          selected: selectedId == device.id,
        ),
    ],
  );
  if (picked == null) return;

  // На Android speaker = дефолтный режим звонка. Не сохраняем конкретный
  // route-id динамика, иначе после перезагрузки устройства id может устареть.
  await matrix.audio.setOutputDeviceId(
    orexIsAndroidSpeakerOutputDeviceId(picked) ? null : picked,
  );
}

Future<void> showOrexCameraQuickSheet(
  BuildContext context, {
  required MatrixService matrix,
  CallSession? session,
}) async {
  final devices = await enumerateOrexCameraDevices(requestPermission: true);
  if (!context.mounted) return;
  final selectedId = orexResolveCurrentDeviceId(
    devices,
    selectedId: matrix.audio.cameraDeviceId,
  );
  final picked = await showOrexChoiceSheet<String>(
    context,
    title: 'Камера',
    emptyText: 'Камеры сейчас не найдены. Проверьте разрешение на камеру.',
    options: [
      for (final device in devices)
        OrexChoiceSheetOption<String>(
          value: device.id,
          icon: orexCameraDeviceIcon(device),
          title: device.label,
          selected: selectedId == device.id,
        ),
    ],
  );
  if (picked == null) return;
  if (session != null) {
    await session.selectCameraDevice(picked);
  } else {
    await matrix.audio.setCameraDeviceId(picked);
  }
}
