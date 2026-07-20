part of 'matrix_service.dart';

extension MatrixRoomAdminApi on MatrixService {
  /// Принять приглашение (войти в комнату).
  Future<void> acceptInvite(Room room) async {
    await room.join();
    _emitChange();
  }

  /// Отклонить приглашение (покинуть комнату).
  Future<void> rejectInvite(Room room) async {
    await room.leave();
    _emitChange();
  }

  /// Удалить чат у себя: выйти из комнаты и «забыть» её.
  Future<void> deleteRoom(Room room) async {
    if (room.isSpace) {
      final children = List<Room>.of(supergroupChildren(room));
      for (final child in children) {
        await deleteRoom(child);
      }
    }
    await _releaseRoomAlias(room);
    try {
      if (room.membership != Membership.leave) await room.leave();
    } catch (_) {}
    try {
      await room.forget();
    } catch (_) {}
    _emitChange();
  }

  /// Закрывает комнату для участников и удаляет её из локального списка.
  ///
  /// Matrix не предоставляет клиенту универсальную операцию физического
  /// удаления серверной истории. Поэтому этот метод сначала fail-closed
  /// закрывает дальнейший доступ, затем удаляет участников и только после
  /// успешного завершения выходит сам.
  Future<void> closeRoomForEveryone(Room room) async {
    if (!canFullyDeleteRoom(room)) {
      throw StateError('Only the owner can close this room for everyone');
    }
    if (room.isSpace) {
      final children = List<Room>.of(supergroupChildren(room));
      final uncontrolledChildren = children
          .where((child) => !canFullyDeleteRoom(child))
          .toList();
      if (uncontrolledChildren.isNotEmpty) {
        throw StateError(
          'Нельзя закрыть супергруппу для всех: нет полного контроля над '
          '${uncontrolledChildren.length} дочерней комнатой(ами)',
        );
      }
      for (final child in children) {
        await closeRoomForEveryone(child);
      }
    }

    await _applyRoomVisibility(room, false);

    final ownId = client.userID;
    final users = await room.requestParticipants(
      const [Membership.join, Membership.invite],
    );
    final failedUsers = <String>[];
    for (final user in users) {
      if (user.id == ownId) continue;
      try {
        await room.kick(user.id);
      } catch (e) {
        failedUsers.add(user.id);
        _log('Rooms', 'close room kick failed room=${room.id} user=${user.id}', e);
      }
    }
    if (failedUsers.isNotEmpty) {
      throw StateError(
        'Не удалось удалить ${failedUsers.length} участник(ов); '
        'комната уже закрыта, повторите операцию',
      );
    }

    if (room.membership != Membership.leave) await room.leave();
    await room.forget();
    _roomPublicOverrides.remove(room.id);
    _emitChange();
  }

  /// Совместимость со старыми call-site. Название исторически неточное:
  /// серверная история Matrix этим действием не уничтожается.
  @Deprecated('Use closeRoomForEveryone; Matrix history is not physically deleted')
  Future<void> deleteRoomForEveryone(Room room) => closeRoomForEveryone(room);

  Future<void> _setRoomJoinRule(Room room, bool public) async {
    try {
      await room.setJoinRules(public ? JoinRules.public : JoinRules.invite);
    } catch (e) {
      _log('Rooms', 'set join rule via Room API failed, trying raw state room=${room.id}', e);
      await client.setRoomStateWithKey(
        room.id,
        EventTypes.RoomJoinRules,
        '',
        {'join_rule': public ? 'public' : 'invite'},
      );
    }
  }

  Future<bool> _roomHasEncryptionState(Room room) async {
    try {
      await client.getRoomStateWithKey(
        room.id,
        'm.room.encryption',
        '',
      );
      return true;
    } on MatrixException catch (e) {
      if (e.errcode == 'M_NOT_FOUND') return false;
      rethrow;
    }
  }

  Future<void> _ensureRoomEncrypted(Room room) async {
    if (room.isSpace || await _roomHasEncryptionState(room)) return;
    await room.enableEncryption();
    if (!await _roomHasEncryptionState(room)) {
      throw StateError('Homeserver did not persist m.room.encryption');
    }
  }

  Future<void> _verifyRoomVisibility(Room room, bool public) async {
    final joinState = await client.getRoomStateWithKey(
      room.id,
      EventTypes.RoomJoinRules,
      '',
    );
    final joinRule = joinState['join_rule']?.toString();
    final directoryVisibility =
        await client.getRoomVisibilityOnDirectory(room.id);
    final guestState = await client.getRoomStateWithKey(
      room.id,
      'm.room.guest_access',
      '',
    );
    final guestAccess = guestState['guest_access']?.toString();

    if (public) {
      if (joinRule != 'public' ||
          directoryVisibility != Visibility.public ||
          guestAccess != 'forbidden') {
        throw StateError('Homeserver did not persist public room access policy');
      }
      return;
    }

    if (joinRule == 'public' ||
        directoryVisibility == Visibility.public ||
        guestAccess != 'forbidden') {
      throw StateError('Homeserver did not persist private room access policy');
    }

    if (!room.isSpace) {
      final historyState = await client.getRoomStateWithKey(
        room.id,
        'm.room.history_visibility',
        '',
      );
      if (historyState['history_visibility']?.toString() ==
          'world_readable') {
        throw StateError('Private room history is still world-readable');
      }
      if (!await _roomHasEncryptionState(room)) {
        throw StateError('Private room is not encrypted');
      }
    }
  }

  Future<void> _applyRoomVisibility(Room room, bool public) async {
    // При закрытии комнаты порядок намеренно fail-closed: сначала прекращаем
    // публикацию новой открытой истории и включаем необратимое E2EE, только
    // затем меняем правила входа. Уже опубликованную world-readable историю
    // Matrix задним числом секретной не делает.
    if (!public && !room.isSpace) {
      await room.setHistoryVisibility(HistoryVisibility.shared);
      await _ensureRoomEncrypted(room);
    }

    await room.setGuestAccess(GuestAccess.forbidden);
    await _setRoomJoinRule(room, public);
    await client.setRoomVisibilityOnDirectory(
      room.id,
      visibility: public ? Visibility.public : Visibility.private,
    );
    if (!public) await _releaseRoomAlias(room);

    await _verifyRoomVisibility(room, public);
    _roomPublicOverrides[room.id] = public;
  }

  Future<void> setRoomHistoryVisibility(
    Room room,
    HistoryVisibility visibility,
  ) async {
    if (visibility == HistoryVisibility.worldReadable && room.isSpace) {
      throw StateError(
        'World-readable history is not allowed for spaces with child rooms',
      );
    }
    if (visibility == HistoryVisibility.worldReadable &&
        (!isPublicRoom(room) || await _roomHasEncryptionState(room))) {
      throw StateError(
        'World-readable history is allowed only for public unencrypted rooms',
      );
    }

    await room.setHistoryVisibility(visibility);
    if (room.isSpace) {
      for (final child in supergroupChildren(room)) {
        await child.setHistoryVisibility(visibility);
      }
    }
    _emitChange();
  }

  Future<void> setRoomIcon(Room room, String icon) async {
    await client.setRoomStateWithKey(
      room.id,
      _orexRoomIconEvent,
      '',
      {'icon': icon, 'version': 1},
    );
    _emitChange();
  }

  Future<Room?> _createdRoom(String roomId) async {
    var room = client.getRoomById(roomId);
    if (room != null) return room;
    try {
      await client.waitForRoomInSync(roomId, join: true);
    } catch (_) {}
    return client.getRoomById(roomId);
  }

  Future<void> _applyChannelPowerLevels(Room room) async {
    final current = Map<String, Object?>.from(
      room.getState(EventTypes.RoomPowerLevels)?.content ?? const <String, Object?>{},
    );
    final rawEvents = current['events'];
    final events = rawEvents is Map
        ? Map<String, Object?>.from(
            rawEvents.map((key, value) => MapEntry(key.toString(), value)),
          )
        : <String, Object?>{};
    events[EventTypes.Message] = 50;
    events[EventTypes.Encrypted] = 50;
    // Голосовые реакции/поднятая рука — не сообщения и не настройки комнаты.
    // Обычным участникам канала можно обновлять только свой voice-state,
    // иначе listen-only пользователь не сможет попросить голос или отправить
    // реакцию без права писать в чат.
    events[_orexVoiceParticipantEvent] = 0;
    events[_orexVoicePermissionsEvent] = 50;
    final rawUsers = current['users'];
    final users = rawUsers is Map
        ? Map<String, Object?>.from(
            rawUsers.map((key, value) => MapEntry(key.toString(), value)),
          )
        : <String, Object?>{};
    final ownId = client.userID;
    if (ownId != null && ownId.isNotEmpty) {
      users[ownId] = 100;
    }

    events[EventTypes.RoomName] = 50;
    events[EventTypes.RoomTopic] = 50;
    events[EventTypes.RoomAvatar] = 50;
    events[EventTypes.RoomCanonicalAlias] = 50;
    events[EventTypes.RoomPowerLevels] = 100;

    current['events'] = events;
    current['users'] = users;
    current['events_default'] = 50;
    current['state_default'] = 50;
    current['users_default'] = 0;
    current['invite'] = 50;
    current['kick'] = 50;
    current['ban'] = 50;
    current['redact'] = 50;
    _log('Rooms', 'apply channel power levels room=${room.id} own=$ownId');
    await client.setRoomStateWithKey(
      room.id,
      EventTypes.RoomPowerLevels,
      '',
      current,
    );
  }

  Future<void> updateRoomDetails(
    Room room, {
    required String name,
    required String topic,
  }) async {
    final newName = name.trim();
    final newTopic = topic.trim();
    if (newName.isNotEmpty && newName != room.getLocalizedDisplayname()) {
      await room.setName(newName);
    }
    if (newTopic != room.topic) {
      await room.setDescription(newTopic);
    }
    _emitChange();
  }

  Future<void> removeUserFromRoom(Room room, User user) =>
      removeUserFromRoomById(room, user.id);

  Future<void> removeUserFromRoomById(Room room, String userId) async {
    final normalized = normalizeLocalUserId(userId);
    if (normalized.isEmpty) return;

    if (room.isSpace) {
      for (final child in supergroupChildren(room)) {
        if (!child.canKick) continue;
        try {
          await child.kick(normalized);
        } catch (_) {}
      }
    }

    if (room.canKick) {
      await room.kick(normalized);
    }
    _emitChange();
  }

  Future<void> inviteUsers(Room room, Iterable<String> userIds) async {
    final ids = userIds
        .map(normalizeLocalUserId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    for (final id in ids) {
      await room.invite(id);
      // Для супергруппы инвайтим только в сам space. Дочерние чаты не должны
      // прилетать отдельными приглашениями: участник сам увидит их внутри
      // супергруппы и зайдёт в нужные.
      await _sendInviteNotice(room, id);
    }
    _emitChange();
  }

  Future<void> _sendInviteNotice(Room room, String userId) async {
    if (userId == client.userID) return;
    try {
      final dmId = await client.startDirectChat(userId);
      final dm = client.getRoomById(dmId);
      if (dm == null) return;
      final alias = OrexRoomAlias.displayAlias(room.canonicalAlias);
      final aliasLine = alias.isEmpty ? '' : '\nAlias: $alias';
      await dm.sendTextEvent(
        'Приглашение в «${room.getLocalizedDisplayname()}»\n'
        'Комната: ${room.id}$aliasLine\n'
        'Нажмите на карточку, чтобы открыть.',
      );
      _log('Rooms', 'sent invite notice room=${room.id} to=$userId');
    } catch (e) {
      _log('Rooms', 'send invite notice failed room=${room.id} to=$userId', e);
    }
  }

  Future<void> setRoomPublic(Room room, bool public) async {
    if (isChannel(room)) {
      await _setRoomKind(room, OrexRoomKind.channel);
    } else if (isSupergroup(room)) {
      await _setRoomKind(room, OrexRoomKind.supergroup);
    } else if (!room.isDirectChat) {
      await _setRoomKind(room, OrexRoomKind.group);
    }
    await _applyRoomVisibility(room, public);
    if (room.isSpace) {
      for (final child in supergroupChildren(room)) {
        await _applySupergroupChildAccess(room, child);
      }
    }
    _emitChange();
  }

  Future<void> setChannelPublic(Room room, bool public) =>
      setRoomPublic(room, public);

  Future<void> setRoomAvatarBytes(
    Room room,
    List<int> bytes,
    String filename,
  ) async {
    await room.setAvatar(
      MatrixFile(bytes: Uint8List.fromList(bytes), name: filename),
    );
    _clearMxcCache();
    _emitChange();
  }

  Future<void> removeRoomAvatar(Room room) async {
    await room.setAvatar(null);
    _clearMxcCache();
    _emitChange();
  }
}
