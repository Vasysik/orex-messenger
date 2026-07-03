part of 'matrix_service.dart';

extension MatrixRoomsApi on MatrixService {
  /// Список комнат, отсортированный как в Telegram — по последней активности.
  List<Room> get rooms {
    final list =
        client.rooms.where((room) => !isSupergroupChild(room)).toList();
    list.sort((a, b) =>
        b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime));
    return list;
  }

  // Каналы в Matrix — это комнаты, где обычный участник не может писать
  // (events_default поднят выше его power level). Эвристика, уточните под
  // свою модель (например, помечайте каналы кастомным state-event или тегом).
  OrexRoomKind roomKind(Room room) {
    if (room.isDirectChat) return OrexRoomKind.direct;

    final explicitKind =
        room.getState(_orexRoomKindEvent)?.content['kind']?.toString().trim();
    switch (explicitKind) {
      case 'channel':
        return OrexRoomKind.channel;
      case 'supergroup':
        return OrexRoomKind.supergroup;
      case 'group':
        return OrexRoomKind.group;
    }

    if (room.isSpace) return OrexRoomKind.supergroup;
    if (_isBroadcastByPowerLevels(room)) return OrexRoomKind.channel;
    return OrexRoomKind.group;
  }

  bool isChannel(Room room) => roomKind(room) == OrexRoomKind.channel;
  bool isSupergroup(Room room) => roomKind(room) == OrexRoomKind.supergroup;
  bool isPublicRoom(Room room) =>
      _roomPublicOverrides[room.id] ?? room.joinRules == JoinRules.public;

  String roomIconKey(Room room) => matrixRoomIconKey(room, null);

  bool canManageRoomSettings(Room room) {
    // Пока в Orex нет UI-настроек ролей, параметры комнаты редактирует только
    // владелец/админ. Обычные участники могут читать чат и участников, но не
    // видят кнопки управления названием, доступом, участниками и дочерними
    // чатами. Более тонкие права можно будет вернуть отдельной моделью ролей.
    return canFullyDeleteRoom(room);
  }

  bool _isBroadcastByPowerLevels(Room room) {
    final powerLevels = room.getState(EventTypes.RoomPowerLevels)?.content;
    if (powerLevels == null) return false;

    final events = powerLevels['events'];
    final messageLevel = events is Map
        ? _asInt(events[EventTypes.Message]) ??
            _asInt(events[EventTypes.Encrypted])
        : null;
    final eventsDefault = _asInt(powerLevels['events_default']);
    final usersDefault = _asInt(powerLevels['users_default']) ?? 0;
    final requiredLevel = messageLevel ?? eventsDefault;
    return requiredLevel != null && requiredLevel > usersDefault;
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }


  bool canSpeakInVoice(Room room, String? userId) {
    if (!isChannel(room)) return true;
    if (userId == null || userId.isEmpty) return false;
    if (userId == client.userID && canManageRoomSettings(room)) return true;
    final state = room.getState(_orexVoicePermissionsEvent);
    final users = state?.content['users'];
    return users is Map && users[userId] == true;
  }



  Future<void> ensureVoiceParticipantStatePowerLevels(Room room) async {
    if (!isChannel(room) || !canManageRoomSettings(room)) return;
    try {
      await _applyChannelPowerLevels(room);
    } catch (e) {
      _log('Rooms', 'ensure voice state power levels failed room=${room.id}', e);
    }
  }

  Future<void> grantVoiceInChannel(Room room, String userId) =>
      _setVoicePermissionInChannel(room, userId, allowed: true);

  Future<void> revokeVoiceInChannel(Room room, String userId) =>
      _setVoicePermissionInChannel(room, userId, allowed: false);

  Future<void> _setVoicePermissionInChannel(
    Room room,
    String userId, {
    required bool allowed,
  }) async {
    if (!isChannel(room) || !canManageRoomSettings(room)) return;
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
    await client.setRoomStateWithKey(
      room.id,
      _orexVoicePermissionsEvent,
      '',
      current,
    );
    _log(
      'Rooms',
      '${allowed ? 'grant' : 'revoke'} voice room=${room.id} user=$userId',
    );
    _emitChange();
  }

  bool canSendMessages(Room room) {
    if (room.canSendDefaultMessages) return true;
    // После создания канала локальный SDK иногда ещё не успел пересчитать
    // power-levels, хотя сервер уже разрешает писать создателю/админу.
    return isChannel(room) && canManageRoomSettings(room);
  }

  Future<void> ensureCanSendToChannel(Room room) async {
    if (!isChannel(room)) return;
    if (!canManageRoomSettings(room)) return;
    try {
      await _applyChannelPowerLevels(room);
    } catch (e) {
      _log('Rooms', 'ensure channel send rights failed room=${room.id}', e);
    }
  }

  Future<void> sendText(Room room, String text) async {
    await ensureCanSendToChannel(room);
    await room.sendTextEvent(text.trim());
  }

  bool isInvite(Room room) => room.membership == Membership.invite;

  /// В комнате идёт звонок (учитываем и личные чаты).
  bool roomHasActiveCall(Room room) {
    if (voip?.voip == null) return false;
    final myId = client.userID;
    return callMemberIds(room).any((id) => id != myId);
  }

  /// userId участников активного звонка в комнате — для панели «войти».
  List<String> callMemberIds(Room room) {
    final v = voip?.voip;
    if (v == null) return const [];
    final mems = room.getCallMembershipsFromRoom(v).values.expand((e) => e);
    return mems
        .where((m) => !m.isExpired)
        .map((m) => m.userId)
        .toSet()
        .toList();
  }

  bool canFullyDeleteRoom(Room room) =>
      room.ownPowerLevel.level >= PowerLevel.defaultAdminLevel;

  bool isOwnerPowerLevel(PowerLevel powerLevel) =>
      powerLevel.level >= PowerLevel.defaultAdminLevel;

  String matrixRoomIconKey(Room room, String? fallback) {
    final explicit = room.getState(_orexRoomIconEvent)?.content['icon']?.toString().trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (fallback != null && fallback.isNotEmpty) return fallback;
    if (isChannel(room)) return 'announce';
    return 'chat';
  }
}
