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

  Future<List<OrexRoomPreview>> searchPublicRoomPreviews(String query) async {
    final rooms = await searchPublicRooms(query);
    return rooms.map(OrexRoomPreview.fromPublicRoom).toList();
  }

  Future<String> joinPublicRoom(PublishedRoomsChunk room) =>
      joinRoomPreview(OrexRoomPreview.fromPublicRoom(room));

  Future<String> joinRoomPreview(OrexRoomPreview preview) async {
    final parentSpaceId = preview.parentSpaceId;
    if (parentSpaceId != null) {
      final parent = client.getRoomById(parentSpaceId);
      if (parent?.membership != Membership.join) {
        throw StateError('Сначала нужно вступить в супергруппу');
      }
    }

    final roomId = await client.joinRoom(preview.idOrAlias, via: preview.via);
    if (client.getRoomById(roomId) == null) {
      await client.waitForRoomInSync(roomId, join: true);
    }
    _emitChange();
    return roomId;
  }

  List<OrexRoomPreview> supergroupChildPreviews(Room space) {
    if (!space.isSpace) return const [];
    return space.spaceChildren
        .map((child) {
          final childId = child.roomId;
          if (childId == null || childId.isEmpty) return null;
          final meta = _supergroupChildPreviewContent(space, childId);
          final metaName = meta?['name']?.toString().trim();
          final metaIcon = meta?['icon']?.toString().trim();
          final metaTopic = meta?['topic']?.toString().trim();
          final metaAvatar = meta?['avatar_url']?.toString().trim();
          final local = client.getRoomById(childId);
          if (local != null && local.membership != Membership.leave) {
            final localName = local.getLocalizedDisplayname();
            final displayName = (localName == local.id || localName.isEmpty)
                ? (metaName?.isNotEmpty == true ? metaName! : localName)
                : localName;
            return OrexRoomPreview(
              roomId: local.id,
              name: displayName,
              alias: local.canonicalAlias.isEmpty ? null : local.canonicalAlias,
              avatar: local.avatar ?? _parseMxc(metaAvatar),
              topic: local.topic.isEmpty
                  ? (metaTopic?.isNotEmpty == true ? metaTopic : null)
                  : local.topic,
              memberCount: local.summary.mJoinedMemberCount,
              iconKey: matrixRoomIconKey(local, metaIcon),
              via: child.via,
              parentSpaceId: space.id,
            );
          }
          return OrexRoomPreview(
            roomId: childId,
            name: metaName?.isNotEmpty == true ? metaName! : childId,
            avatar: _parseMxc(metaAvatar),
            topic: metaTopic?.isNotEmpty == true ? metaTopic : null,
            iconKey: metaIcon?.isNotEmpty == true ? metaIcon : 'chat',
            via: child.via,
            parentSpaceId: space.id,
          );
        })
        .whereType<OrexRoomPreview>()
        .toList();
  }

  Map<String, Object?>? _supergroupChildPreviewContent(
    Room space,
    String childId,
  ) {
    try {
      final content = space.getState(_orexSpaceChildPreviewEvent, childId)?.content;
      if (content == null) return null;
      return Map<String, Object?>.from(content);
    } catch (_) {
      return null;
    }
  }

  Uri? _parseMxc(String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'mxc') return null;
    return uri;
  }

  String matrixRoomIconKey(Room room, String? fallback) {
    final explicit = room.getState(_orexRoomIconEvent)?.content['icon']?.toString().trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (fallback != null && fallback.isNotEmpty) return fallback;
    if (isChannel(room)) return 'announce';
    return 'chat';
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

  Future<void> _applySupergroupChildAccess(Room space, Room child) async {
    try {
      await client.setRoomStateWithKey(
        child.id,
        EventTypes.RoomJoinRules,
        '',
        {
          'join_rule': 'restricted',
          'allow': [
            {'type': 'm.room_membership', 'room_id': space.id},
          ],
        },
      );
    } catch (_) {
      try {
        await child.setJoinRules(JoinRules.invite);
      } catch (_) {}
    }
    try {
      await client.setRoomVisibilityOnDirectory(
        child.id,
        visibility: Visibility.private,
      );
    } catch (_) {}
    try {
      await child.setGuestAccess(GuestAccess.forbidden);
    } catch (_) {}
    _roomPublicOverrides[child.id] = false;
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
    current['events'] = events;
    current['events_default'] ??= 0;
    current['state_default'] ??= 50;
    current['users_default'] ??= 0;
    await client.setRoomStateWithKey(
      room.id,
      EventTypes.RoomPowerLevels,
      '',
      current,
    );
  }

  Future<void> updateSupergroupChildPreview(
    Room space,
    Room child, {
    String? name,
    String? icon,
  }) async {
    if (!space.isSpace) return;
    await _setSupergroupChildPreview(
      space,
      childId: child.id,
      name: name ?? child.getLocalizedDisplayname(),
      icon: icon ?? roomIconKey(child),
      avatar: child.avatar,
      topic: child.topic,
    );
    _emitChange();
  }

  Future<void> _setSupergroupChildPreview(
    Room space, {
    required String childId,
    required String name,
    required String icon,
    Uri? avatar,
    String? topic,
  }) async {
    await client.setRoomStateWithKey(
      space.id,
      _orexSpaceChildPreviewEvent,
      childId,
      <String, Object?>{
        'name': name,
        'icon': icon,
        'version': 1,
        if (avatar != null) 'avatar_url': avatar.toString(),
        if (topic != null && topic.isNotEmpty) 'topic': topic,
      },
    );
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
    final room = await _createdRoom(roomId);
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
      groupCall: true,
      preset:
          public ? CreateRoomPreset.publicChat : CreateRoomPreset.privateChat,
      visibility: public ? Visibility.public : Visibility.private,
      historyVisibility:
          public ? HistoryVisibility.worldReadable : HistoryVisibility.shared,
      enableEncryption: !public,
      initialState: [_kindState(OrexRoomKind.channel)],
    );
    final room = await _createdRoom(roomId);
    if (room != null) {
      await _setRoomKind(room, OrexRoomKind.channel);
      await _applyChannelPowerLevels(room);
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
    final space = await _createdRoom(spaceId);
    if (space != null) {
      await _setRoomKind(space, OrexRoomKind.supergroup);
      await _applyRoomVisibility(space, public);
      if (public) await setRoomLocalAlias(space, localAlias);
      await createSupergroupChild(
        space,
        'Основной чат',
        public: public,
      );
    }
    _emitChange();
    return spaceId;
  }

  Future<String> createSupergroupChild(
    Room space,
    String name, {
    String icon = 'chat',
    bool public = false,
    List<String> invite = const [],
  }) async {
    if (!space.isSpace) throw StateError('Room is not a supergroup space');
    // Дочерние чаты супергруппы не рассылают инвайты каждому участнику.
    // Участник видит их внутри супергруппы, открывает preview и вступает сам.
    final roomId = await client.createGroupChat(
      groupName: name,
      // Чаты внутри супергруппы не должны присылать отдельные Matrix-инвайты.
      // Доступ контролируется membership в space; вход — осознанной кнопкой
      // из preview. Поэтому invite здесь намеренно не передаём.
      invite: const [],
      groupCall: true,
      preset:
          public ? CreateRoomPreset.publicChat : CreateRoomPreset.privateChat,
      visibility: public ? Visibility.public : Visibility.private,
      historyVisibility:
          public ? HistoryVisibility.worldReadable : HistoryVisibility.shared,
      enableEncryption: !public,
      initialState: [
        _kindState(OrexRoomKind.group),
        _iconState(icon),
      ],
    );
    final childRoom = await _createdRoom(roomId);
    if (childRoom != null) {
      await _applySupergroupChildAccess(space, childRoom);
    }
    final order = supergroupChildren(space).length.toString().padLeft(3, '0');
    await _setSupergroupChildPreview(
      space,
      childId: roomId,
      name: name,
      icon: icon,
      avatar: childRoom?.avatar,
      topic: childRoom?.topic,
    );
    await space.setSpaceChild(roomId, order: order, suggested: true);
    _emitChange();
    return roomId;
  }

  Future<void> ensureSupergroupChildrenAccess(Room space) async {
    if (!space.isSpace) return;
    for (final child in supergroupChildren(space)) {
      await _applySupergroupChildAccess(space, child);
    }
    _emitChange();
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
