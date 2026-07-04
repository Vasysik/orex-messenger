import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_controller.dart';

bool orexCanManageVoice(MatrixService matrix, Room? room, String userId) {
  if (room == null || userId == matrix.client.userID) return false;
  return matrix.isChannel(room) && matrix.canManageRoomSettings(room);
}

bool orexCanGrantVoice(MatrixService matrix, Room? room, String userId) {
  return orexCanManageVoice(matrix, room, userId) &&
      !matrix.voicePermissions.canSpeak(room!, userId);
}

bool orexCanRevokeVoice(MatrixService matrix, Room? room, String userId) {
  return orexCanManageVoice(matrix, room, userId) &&
      matrix.voicePermissions.canSpeak(room!, userId);
}

Future<void> orexGrantVoice({
  required MatrixService matrix,
  required CallController call,
  required Room room,
  required String userId,
}) async {
  await matrix.voicePermissions.grant(room, userId);
  await call.refreshVoicePermissions();
}

Future<void> orexRevokeVoice({
  required MatrixService matrix,
  required CallController call,
  required Room room,
  required String userId,
}) async {
  await matrix.voicePermissions.revoke(room, userId);
  await call.refreshVoicePermissions();
}
