part of 'matrix_service.dart';

final class MatrixVoicePermissionsService {
  MatrixVoicePermissionsService(this._matrix);

  final MatrixService _matrix;

  bool canSpeak(Room room, String? userId) {
    if (!_matrix.isChannel(room)) return true;
    if (userId == null || userId.isEmpty) return false;
    if (userId == _matrix.client.userID &&
        _matrix.canManageRoomSettings(room)) {
      return true;
    }
    return isUserAllowedByContent(
      room.getState(_orexVoicePermissionsEvent)?.content,
      userId,
    );
  }

  Future<void> ensureParticipantStatePowerLevels(Room room) async {
    if (!_matrix.isChannel(room) || !_matrix.canManageRoomSettings(room)) {
      return;
    }
    try {
      await _matrix._applyChannelPowerLevels(room);
    } catch (e) {
      _matrix._log(
        'Rooms',
        'ensure voice state power levels failed room=${room.id}',
        e,
      );
    }
  }

  Future<void> grant(Room room, String userId) =>
      _setPermission(room, userId, allowed: true);

  Future<void> revoke(Room room, String userId) =>
      _setPermission(room, userId, allowed: false);

  Future<void> _setPermission(
    Room room,
    String userId, {
    required bool allowed,
  }) async {
    if (!_matrix.isChannel(room) || !_matrix.canManageRoomSettings(room)) {
      return;
    }
    final current = Map<String, Object?>.from(
      room.getState(_orexVoicePermissionsEvent)?.content ??
          const <String, Object?>{},
    );
    final users = Map<String, Object?>.from(
      (current['users'] as Map?) ?? const <String, Object?>{},
    );
    if (allowed) {
      users[userId] = true;
    } else {
      users.remove(userId);
    }
    current['users'] = users;
    await _matrix.client.setRoomStateWithKey(
      room.id,
      _orexVoicePermissionsEvent,
      '',
      current,
    );
    _matrix._log(
      'Rooms',
      '${allowed ? 'grant' : 'revoke'} voice room=${room.id} user=$userId',
    );
    _matrix._emitChange();
  }

  static bool isUserAllowedByContent(
    Map<dynamic, dynamic>? content,
    String userId,
  ) {
    final users = content?['users'];
    return users is Map && users[userId] == true;
  }
}
