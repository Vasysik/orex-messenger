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
      case 'voice':
        return OrexRoomKind.voice;
      case 'group':
        return OrexRoomKind.group;
    }

    if (room.isSpace) return OrexRoomKind.supergroup;
    if (_isBroadcastByPowerLevels(room)) return OrexRoomKind.channel;
    return OrexRoomKind.group;
  }

  bool isChannel(Room room) => roomKind(room) == OrexRoomKind.channel;
  bool isSupergroup(Room room) => roomKind(room) == OrexRoomKind.supergroup;
  bool isVoiceRoom(Room room) => roomKind(room) == OrexRoomKind.voice;

  bool isPublicRoom(Room room) =>
      _roomPublicOverrides[room.id] ?? room.joinRules == JoinRules.public;

  String roomIconKey(Room room) {
    final explicitIcon =
        room.getState(_orexRoomIconEvent)?.content['icon']?.toString().trim();
    if (explicitIcon != null && explicitIcon.isNotEmpty) return explicitIcon;
    if (isVoiceRoom(room)) return 'voice';
    if (isChannel(room)) return 'announce';
    return 'chat';
  }

  bool canManageRoomSettings(Room room) {
    if (canFullyDeleteRoom(room)) return true;
    return room.canInvite ||
        room.canKick ||
        room.canChangeJoinRules ||
        room.canChangeHistoryVisibility ||
        room.canChangeStateEvent(EventTypes.RoomName) ||
        room.canChangeStateEvent(EventTypes.RoomTopic) ||
        room.canChangeStateEvent(EventTypes.RoomAvatar) ||
        room.canChangeStateEvent(_orexRoomIconEvent) ||
        (room.isSpace && room.canChangeStateEvent(EventTypes.SpaceChild));
  }

  bool isSupergroupChild(Room room) {
    if (room.isSpace) return false;
    return room.spaceParents.any((parent) {
      final parentId = parent.roomId;
      if (parentId == null) return false;
      return client.getRoomById(parentId)?.isSpace == true;
    });
  }

  List<Room> supergroupChildren(Room space) {
    if (!space.isSpace) return const [];
    return space.spaceChildren
        .map((child) => child.roomId)
        .whereType<String>()
        .map(client.getRoomById)
        .whereType<Room>()
        .where((room) => room.membership != Membership.leave)
        .toList();
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

  Future<void> sendText(Room room, String text) =>
      room.sendTextEvent(text.trim());

  // ---------------------------------------------------------------------------
  // Приглашения в чаты
  // ---------------------------------------------------------------------------

  bool isInvite(Room room) => room.membership == Membership.invite;

  /// В комнате идёт звонок (учитываем и личные чаты).
  bool roomHasActiveCall(Room room) {
    final v = voip?.voip;
    if (v == null) return false;
    return room.hasActiveGroupCall(v, ignoreDirectChats: false);
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

  bool canFullyDeleteRoom(Room room) =>
      room.ownPowerLevel.level >= PowerLevel.defaultAdminLevel;

  bool isOwnerPowerLevel(PowerLevel powerLevel) =>
      powerLevel.level >= PowerLevel.defaultAdminLevel;

  Future<void> deleteRoomForEveryone(Room room) async {
    if (!canFullyDeleteRoom(room)) {
      throw StateError('Only the owner can delete this room for everyone');
    }
    if (room.isSpace) {
      final children = List<Room>.of(supergroupChildren(room));
      for (final child in children) {
        if (canFullyDeleteRoom(child)) {
          await deleteRoomForEveryone(child);
        } else {
          await deleteRoom(child);
        }
      }
    }
    await _releaseRoomAlias(room);
    try {
      await client.setRoomVisibilityOnDirectory(
        room.id,
        visibility: Visibility.private,
      );
    } catch (_) {}

    final ownId = client.userID;
    final users = await room.requestParticipants(
      const [Membership.join, Membership.invite],
    );
    for (final user in users) {
      if (user.id == ownId) continue;
      try {
        await room.kick(user.id);
      } catch (_) {}
    }
    try {
      if (room.membership != Membership.leave) await room.leave();
    } catch (_) {}
    try {
      await room.forget();
    } catch (_) {}
    _emitChange();
  }



  // ---------------------------------------------------------------------------
  // Поиск людей и создание чатов
  // ---------------------------------------------------------------------------

  /// Поиск пользователей: директория сервера + прямое разрешение по MXID.
  ///
  /// Директория (`searchUserDirectory`) на свежем Synapse возвращает только тех,
  /// с кем уже есть общая комната/публичные комнаты — поэтому новых знакомых не
  /// найти. Дополнительно пробуем точный MXID (`@localpart:server`) через
  /// профиль, чтобы можно было найти любого по имени.
  Future<List<Profile>> searchUsers(
    String query, {
    bool includeMxidFallback = false,
  }) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final byId = <String, Profile>{};
    try {
      final res = await client.searchUserDirectory(q, limit: 30);
      for (final p in res.results) {
        byId[p.userId] = p;
      }
    } catch (_) {
      // директория может быть выключена/недоступна — не критично
    }

    final normalizedDirectoryQuery = _directoryQuery(q);
    if (normalizedDirectoryQuery != q) {
      try {
        final res = await client.searchUserDirectory(normalizedDirectoryQuery,
            limit: 30);
        for (final p in res.results) {
          byId[p.userId] = p;
        }
      } catch (_) {
        // Directory may be unavailable; exact MXID fallback below can still work.
      }
    }

    final candidates =
        includeMxidFallback ? _mxidCandidates(q) : const <String>[];
    for (final candidate in candidates) {
      if (byId.containsKey(candidate)) continue;
      try {
        final prof = await client.getUserProfile(candidate);
        byId[candidate] = Profile(
          userId: candidate,
          displayName: prof.displayname,
          avatarUrl: prof.avatarUrl,
        );
      } catch (_) {
        // Нет такого пользователя или сервер не разрешил профиль — не добавляем.
      }
    }
    return byId.values.toList();
  }

  Future<List<PublishedRoomsChunk>> searchPublicRooms(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    try {
      final res = await client.queryPublicRooms(
        limit: 30,
        includeAllNetworks: false,
        filter: PublicRoomQueryFilter(genericSearchTerm: q),
      );
      return res.chunk;
    } catch (_) {
      return const [];
    }
  }

  Future<String> joinPublicRoom(PublishedRoomsChunk room) async {
    final idOrAlias = (room.canonicalAlias?.isNotEmpty ?? false)
        ? room.canonicalAlias!
        : room.roomId;
    final roomId = await client.joinRoom(idOrAlias);
    if (client.getRoomById(roomId) == null) {
      await client.waitForRoomInSync(roomId, join: true);
    }
    final joined = client.getRoomById(roomId);
    if (joined?.isSpace == true) {
      await _joinVisibleSpaceChildren(joined!);
    }
    _emitChange();
    return roomId;
  }

  Future<void> _joinVisibleSpaceChildren(Room space) async {
    for (final child in space.spaceChildren) {
      final childId = child.roomId;
      if (childId == null || childId.isEmpty) continue;
      final local = client.getRoomById(childId);
      if (local?.membership == Membership.join) continue;
      try {
        final joinedId = await client.joinRoom(childId, via: child.via);
        if (client.getRoomById(joinedId) == null) {
          await client.waitForRoomInSync(joinedId, join: true);
        }
      } catch (_) {
        // Private or not-yet-visible child rooms are skipped; public spaces keep working.
      }
    }
  }

  /// Прямые MXID-кандидаты для точного поиска: полный `@user:server`,
  /// короткий `@user` или просто `user` на текущем homeserver.
  String _directoryQuery(String q) {
    var localpart = q;
    if (localpart.startsWith('@')) localpart = localpart.substring(1);
    if (localpart.contains(':')) localpart = localpart.split(':').first;
    return localpart.isEmpty ? q : localpart;
  }

  String? get _localServerName {
    final userId = client.userID;
    if (userId != null && userId.contains(':')) {
      return userId.split(':').last;
    }
    return homeserver.host.isEmpty ? null : homeserver.host;
  }

  String compactUserId(String userId) {
    final server = _localServerName;
    if (server == null || !userId.endsWith(':$server')) return userId;
    return userId.substring(0, userId.length - server.length - 1);
  }

  String normalizeLocalUserId(String input) {
    final q = input.trim();
    if (q.isEmpty) return q;
    if (q.startsWith('@') && q.contains(':')) return q;

    var localpart = q.startsWith('@') ? q.substring(1) : q;
    if (localpart.contains(':')) return q.startsWith('@') ? q : '@$q';

    final server = _localServerName;
    if (server == null || server.isEmpty) {
      return q.startsWith('@') ? q : '@$q';
    }
    return '@$localpart:$server';
  }

  List<String> _mxidCandidates(String q) {
    if (q.contains(' ')) return const [];
    if (q.startsWith('@') && q.contains(':')) return [q];

    final localpart = q.startsWith('@') ? q.substring(1) : q;
    if (localpart.isEmpty || localpart.contains(':')) return const [];

    final server = _localServerName;
    if (server == null || server.isEmpty) return const [];
    return ['@$localpart:$server'];
  }

  /// Личный чат (создаёт или возвращает существующий).
  Future<String> startDirectChat(String userId) =>
      client.startDirectChat(userId);

  /// Создать группу.
  StateEvent _kindState(OrexRoomKind kind) => StateEvent(
        type: _orexRoomKindEvent,
        content: {'kind': kind.name, 'version': 1},
      );

  StateEvent _iconState(String icon) => StateEvent(
        type: _orexRoomIconEvent,
        content: {'icon': icon, 'version': 1},
      );

  Future<void> _setRoomKind(Room room, OrexRoomKind kind) async {
    await client.setRoomStateWithKey(
      room.id,
      _orexRoomKindEvent,
      '',
      {'kind': kind.name, 'version': 1},
    );
  }

  String? _roomAliasLocalpart(String? alias) {
    return OrexRoomAlias.normalizeLocalpart(alias);
  }

  String? _fullRoomAlias(String? localAlias) {
    return OrexRoomAlias.fullAlias(localAlias, _localServerName);
  }

  String roomAliasLocalpart(Room room) {
    return OrexRoomAlias.localpartFromRoom(room);
  }

  Future<void> setRoomLocalAlias(Room room, String? localAlias) async {
    final alias = _fullRoomAlias(localAlias);
    if (alias == null) return;
    final oldAlias = room.canonicalAlias;
    if (oldAlias.isNotEmpty && oldAlias != alias) {
      try {
        await client.deleteRoomAlias(oldAlias);
      } catch (_) {}
    }
    await room.setCanonicalAlias(alias);
    _emitChange();
  }

  Future<void> clearRoomLocalAlias(Room room) async {
    await _releaseRoomAlias(room);
    _emitChange();
  }

  Future<void> _releaseRoomAlias(Room room) async {
    final alias = room.canonicalAlias;
    if (alias.isEmpty) return;
    try {
      await client.deleteRoomAlias(alias);
    } catch (_) {}
    try {
      await client.setRoomStateWithKey(
        room.id,
        EventTypes.RoomCanonicalAlias,
        '',
        <String, Object?>{},
      );
    } catch (_) {}
  }

  Future<void> _applyRoomVisibility(Room room, bool public) async {
    try {
      await room.setJoinRules(public ? JoinRules.public : JoinRules.invite);
    } catch (_) {
      await client.setRoomStateWithKey(
        room.id,
        EventTypes.RoomJoinRules,
        '',
        {'join_rule': public ? JoinRules.public.text : JoinRules.invite.text},
      );
    }
    try {
      await client.setRoomVisibilityOnDirectory(
        room.id,
        visibility: public ? Visibility.public : Visibility.private,
      );
    } catch (_) {
      // Some homeservers allow changing join rules but restrict directory writes.
    }
    try {
      await room.setGuestAccess(GuestAccess.forbidden);
    } catch (_) {}
    if (!public) {
      await _releaseRoomAlias(room);
    }
    _roomPublicOverrides[room.id] = public;
  }

  Future<void> setRoomHistoryVisibility(
    Room room,
    HistoryVisibility visibility,
  ) async {
    await room.setHistoryVisibility(visibility);
    if (room.isSpace) {
      for (final child in supergroupChildren(room)) {
        try {
          await child.setHistoryVisibility(visibility);
        } catch (_) {}
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

  Future<String> createGroup(
    String name, {
    bool public = false,
    String? localAlias,
    List<String> invite = const [],
  }) async {
    final roomId = await client.createGroupChat(
      groupName: name,
      invite: invite,
      groupCall: true,
      preset:
          public ? CreateRoomPreset.publicChat : CreateRoomPreset.privateChat,
      visibility: public ? Visibility.public : Visibility.private,
      historyVisibility:
          public ? HistoryVisibility.worldReadable : HistoryVisibility.shared,
      enableEncryption: !public,
      initialState: [_kindState(OrexRoomKind.group)],
    );
    final room = client.getRoomById(roomId);
    if (room != null) {
      await _applyRoomVisibility(room, public);
      if (public) await setRoomLocalAlias(room, localAlias);
    }
    _emitChange();
    return roomId;
  }

  /// Создать канал: группа, где обычные участники не могут писать
  /// (events_default поднят) — совпадает с эвристикой папки «Каналы».
  Future<String> createChannel(
    String name, {
    bool public = false,
    String? localAlias,
    List<String> invite = const [],
  }) async {
    final roomId = await client.createGroupChat(
      groupName: name,
      invite: invite,
      preset:
          public ? CreateRoomPreset.publicChat : CreateRoomPreset.privateChat,
      visibility: public ? Visibility.public : Visibility.private,
      historyVisibility:
          public ? HistoryVisibility.worldReadable : HistoryVisibility.shared,
      enableEncryption: !public,
      initialState: [_kindState(OrexRoomKind.channel)],
      powerLevelContentOverride: const {'events_default': 50},
    );
    final room = client.getRoomById(roomId);
    if (room != null) {
      await _applyRoomVisibility(room, public);
      if (public) await setRoomLocalAlias(room, localAlias);
    }
    _emitChange();
    return roomId;
  }

  Future<String> createSupergroup(
    String name, {
    bool public = false,
    String? localAlias,
    List<String> invite = const [],
  }) async {
    final spaceId = await client.createSpace(
      name: name,
      visibility: public ? Visibility.public : Visibility.private,
      spaceAliasName: public ? _roomAliasLocalpart(localAlias) : null,
      invite: invite,
      waitForSync: true,
    );
    final space = client.getRoomById(spaceId);
    if (space != null) {
      await _setRoomKind(space, OrexRoomKind.supergroup);
      await _applyRoomVisibility(space, public);
      if (public) await setRoomLocalAlias(space, localAlias);
      await createSupergroupChild(
        space,
        'Основной чат',
        public: public,
        invite: invite,
      );
    }
    _emitChange();
    return spaceId;
  }

  Future<String> createSupergroupChild(
    Room space,
    String name, {
    bool voice = false,
    String icon = 'chat',
    bool public = false,
    List<String> invite = const [],
  }) async {
    if (!space.isSpace) throw StateError('Room is not a supergroup space');
    final currentMemberIds = await _supergroupMemberIds(space);
    final effectiveInvite = {
      ...invite.map(normalizeLocalUserId),
      ...currentMemberIds,
    }..remove(client.userID);
    final roomId = await client.createGroupChat(
      groupName: name,
      invite: effectiveInvite.where((id) => id.isNotEmpty).toList(),
      groupCall: true,
      preset:
          public ? CreateRoomPreset.publicChat : CreateRoomPreset.privateChat,
      visibility: public ? Visibility.public : Visibility.private,
      historyVisibility:
          public ? HistoryVisibility.worldReadable : HistoryVisibility.shared,
      enableEncryption: !public,
      initialState: [
        _kindState(voice ? OrexRoomKind.voice : OrexRoomKind.group),
        _iconState(voice ? 'voice' : icon),
      ],
    );
    final childRoom = client.getRoomById(roomId);
    if (childRoom != null) {
      await _applyRoomVisibility(childRoom, public);
    }
    final order = supergroupChildren(space).length.toString().padLeft(3, '0');
    await space.setSpaceChild(roomId, order: order, suggested: !voice);
    _emitChange();
    return roomId;
  }

  Future<Set<String>> _supergroupMemberIds(Room space) async {
    try {
      final users = await space.requestParticipants(
        const [Membership.join, Membership.invite],
      );
      return users.map((user) => user.id).toSet();
    } catch (_) {
      return space
          .getParticipants(const [Membership.join, Membership.invite])
          .map((user) => user.id)
          .toSet();
    }
  }

  Future<void> removeSupergroupChild(Room space, Room child) async {
    if (!space.isSpace) throw StateError('Room is not a supergroup space');
    try {
      await space.removeSpaceChild(child.id);
    } catch (_) {}
    if (canFullyDeleteRoom(child)) {
      await deleteRoomForEveryone(child);
    } else {
      await deleteRoom(child);
    }
    _emitChange();
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

  Future<void> inviteUsers(Room room, Iterable<String> userIds) async {
    final ids = userIds
        .map(normalizeLocalUserId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    for (final id in ids) {
      await room.invite(id);
      if (room.isSpace) {
        for (final child in supergroupChildren(room)) {
          if (child.canInvite) await child.invite(id);
        }
      }
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
      final alias = room.canonicalAlias;
      final idLine = alias.isEmpty ? '' : '\nID: $alias';
      await dm.sendTextEvent(
        'Приглашение в «${room.getLocalizedDisplayname()}».$idLine\n'
        'Откройте приглашения, чтобы войти.',
      );
    } catch (_) {}
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
        await _applyRoomVisibility(child, public);
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
    _mediaCache.clear();
    _emitChange();
  }

  Future<void> removeRoomAvatar(Room room) async {
    await room.setAvatar(null);
    _mediaCache.clear();
    _emitChange();
  }


}
