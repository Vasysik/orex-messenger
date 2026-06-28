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
    if (_isKnownSupergroupChildId(room.id)) return true;
    return room.spaceParents.any((parent) {
      final parentId = parent.roomId;
      if (parentId == null) return false;
      return client.getRoomById(parentId)?.isSpace == true;
    });
  }

  bool _isKnownSupergroupChildId(String roomId) {
    if (roomId.isEmpty) return false;
    for (final space in client.rooms.where((room) => room.isSpace)) {
      if (_supergroupChildIds(space).contains(roomId)) return true;
    }
    return false;
  }

  String? roomIdForReference(String reference) {
    final ref = reference.trim();
    if (ref.isEmpty) return null;
    final byId = client.getRoomById(ref);
    if (byId != null && byId.membership != Membership.leave) return byId.id;

    for (final room in client.rooms) {
      if (room.membership == Membership.leave) continue;
      if (room.id == ref) return room.id;
      if (room.canonicalAlias == ref) return room.id;
      final aliasState = room.getState(EventTypes.RoomCanonicalAlias)?.content;
      final altAliases = aliasState?['alt_aliases'];
      if (altAliases is List && altAliases.map((e) => e.toString()).contains(ref)) {
        return room.id;
      }
    }
    return null;
  }

  OrexRoomPreview? localPreviewForReference(String reference) {
    final ref = reference.trim();
    if (ref.isEmpty) return null;

    for (final space in client.rooms.where((room) => room.isSpace)) {
      for (final preview in supergroupChildPreviews(space)) {
        if (preview.roomId == ref || preview.alias == ref) return preview;
      }
    }

    final roomId = roomIdForReference(ref);
    final room = roomId == null ? null : client.getRoomById(roomId);
    if (room == null) return null;
    return OrexRoomPreview(
      roomId: room.id,
      name: room.getLocalizedDisplayname(),
      alias: room.canonicalAlias.isEmpty ? null : room.canonicalAlias,
      avatar: room.avatar,
      topic: room.topic,
      memberCount: room.summary.mJoinedMemberCount,
      iconKey: roomIconKey(room),
    );
  }

  Future<OrexRoomPreview?> publicPreviewForReference(String reference) async {
    final ref = reference.trim();
    if (ref.isEmpty) return null;

    final queries = <String>[ref];
    if (ref.startsWith('#')) {
      queries.add(ref.substring(1).split(':').first);
    } else if (ref.startsWith('!')) {
      queries.add(ref.substring(1).split(':').first);
    }

    for (final query in queries.where((q) => q.trim().isNotEmpty)) {
      final rooms = await searchPublicRooms(query);
      for (final room in rooms) {
        if (room.roomId == ref || room.canonicalAlias == ref) {
          return OrexRoomPreview.fromPublicRoom(room);
        }
      }
      if (rooms.length == 1) {
        return OrexRoomPreview.fromPublicRoom(rooms.single);
      }
    }
    return null;
  }

  Future<String> joinRoomReference(String reference) async {
    final ref = reference.trim();
    if (ref.isEmpty) throw ArgumentError('Empty room reference');
    final roomId = await client.joinRoom(ref);
    if (client.getRoomById(roomId) == null) {
      await client.waitForRoomInSync(roomId, join: true);
    }
    _emitChange();
    return roomId;
  }

  List<Room> supergroupChildren(Room space) {
    if (!space.isSpace) return const [];
    return _supergroupChildIds(space)
        .map(client.getRoomById)
        .whereType<Room>()
        .where((room) => room.membership != Membership.leave)
        .toList();
  }

  List<String> _supergroupChildIds(Room space) {
    final ids = <String>[];
    for (final child in space.spaceChildren) {
      final childId = child.roomId;
      if (childId != null && childId.isNotEmpty && !ids.contains(childId)) {
        ids.add(childId);
      }
    }
    for (final childId in _spaceChildOrderOverrides[space.id] ?? const <String>[]) {
      if (childId.isNotEmpty && !ids.contains(childId)) ids.add(childId);
    }
    return ids;
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
    final terms = _publicRoomSearchTerms(query);
    if (terms.isEmpty) return const [];

    final byId = <String, PublishedRoomsChunk>{};
    for (final term in terms) {
      try {
        _log('Rooms', 'search public rooms term=$term');
        final res = await client.queryPublicRooms(
          limit: 30,
          includeAllNetworks: false,
          filter: PublicRoomQueryFilter(genericSearchTerm: term),
        );
        for (final room in res.chunk) {
          byId.putIfAbsent(room.roomId, () => room);
        }
      } catch (e) {
        _log('Rooms', 'search public rooms failed term=$term', e);
      }
    }
    return byId.values.toList();
  }

  List<String> _publicRoomSearchTerms(String query) {
    final q = query.trim();
    if (q.isEmpty) return const [];

    final terms = <String>[q];

    // Synapse public-room directory часто ищет alias по localpart, но не по
    // строке с ведущим '#'. Поэтому глобальный поиск '#orex' должен дополнительно
    // искать 'orex', иначе комната '#orex:server' находится только без решётки.
    var aliasLike = q;
    if (aliasLike.startsWith('#')) aliasLike = aliasLike.substring(1);
    if (aliasLike.contains(':')) aliasLike = aliasLike.split(':').first;
    aliasLike = aliasLike.trim();
    if (aliasLike.isNotEmpty && aliasLike != q) terms.add(aliasLike);

    return terms
        .map((term) => term.trim())
        .where((term) => term.isNotEmpty)
        .toSet()
        .toList();
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
    final byId = <String, dynamic>{};
    for (final child in space.spaceChildren) {
      final childId = child.roomId;
      if (childId != null && childId.isNotEmpty) byId[childId] = child;
    }

    return _supergroupChildIds(space)
        .map((childId) {
          final child = byId[childId];
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
              via: child?.via,
              parentSpaceId: space.id,
            );
          }
          return OrexRoomPreview(
            roomId: childId,
            name: metaName?.isNotEmpty == true ? metaName! : childId,
            avatar: _parseMxc(metaAvatar),
            topic: metaTopic?.isNotEmpty == true ? metaTopic : null,
            iconKey: metaIcon?.isNotEmpty == true ? metaIcon : 'chat',
            via: child?.via,
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
    final optimistic = _spaceChildPreviewOverrides[space.id]?[childId];
    if (optimistic != null) return optimistic;

    // Primary persisted source: metadata embedded directly into m.space.child.
    // This is what the UI already has while rendering space children, so names
    // and icons are available before the user joins the child room and even if
    // a separate custom state event is not indexed by the SDK yet.
    final embedded = _embeddedSpaceChildPreviewContent(space, childId);
    if (embedded != null) return embedded;

    // Compatibility with previous builds that stored preview in a separate
    // custom state event keyed by child room id.
    try {
      final content =
          space.getState(_orexSpaceChildPreviewEvent, childId)?.content;
      if (content == null) return null;
      return Map<String, Object?>.from(content);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?>? _embeddedSpaceChildPreviewContent(
    Room space,
    String childId,
  ) {
    try {
      final content = space.getState(EventTypes.SpaceChild, childId)?.content;
      if (content == null) return null;
      final rawPreview = content['ru.orex.preview'];
      if (rawPreview is Map) {
        return Map<String, Object?>.from(
          rawPreview.map((key, value) => MapEntry(key.toString(), value)),
        );
      }
      final name = content['ru.orex.name'] ?? content['name'];
      final icon = content['ru.orex.icon'] ?? content['icon'];
      final avatar = content['ru.orex.avatar_url'] ?? content['avatar_url'];
      final topic = content['ru.orex.topic'] ?? content['topic'];
      if (name == null && icon == null && avatar == null && topic == null) {
        return null;
      }
      return <String, Object?>{
        if (name != null) 'name': name,
        if (icon != null) 'icon': icon,
        if (avatar != null) 'avatar_url': avatar,
        if (topic != null) 'topic': topic,
        'version': 1,
      };
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _rememberSupergroupChildPreview(
    Room space, {
    required String childId,
    required String name,
    required String icon,
    Uri? avatar,
    String? topic,
  }) {
    final content = <String, Object?>{
      'name': name,
      'icon': icon,
      'version': 1,
      if (avatar != null) 'avatar_url': avatar.toString(),
      if (topic != null && topic.isNotEmpty) 'topic': topic,
    };
    _spaceChildPreviewOverrides
        .putIfAbsent(space.id, () => <String, Map<String, Object?>>{})[childId] =
        content;
    final order = _spaceChildOrderOverrides.putIfAbsent(
      space.id,
      () => <String>[],
    );
    if (!order.contains(childId)) order.add(childId);
    return content;
  }

  String? _serverNameFromRoomId(String roomId) {
    final idx = roomId.indexOf(':');
    if (idx < 0 || idx == roomId.length - 1) return null;
    return roomId.substring(idx + 1);
  }

  List<String> _viaForChild(String childId) {
    final servers = <String>{
      if (_localServerName != null) _localServerName!,
      if (_serverNameFromRoomId(childId) != null) _serverNameFromRoomId(childId)!,
    };
    return servers.where((server) => server.isNotEmpty).toList();
  }

  Future<void> _attachSupergroupChild(
    Room space, {
    required String childId,
    required String order,
    required Map<String, Object?> preview,
  }) async {
    final name = preview['name']?.toString();
    final icon = preview['icon']?.toString();
    final avatar = preview['avatar_url']?.toString();
    final topic = preview['topic']?.toString();
    await client.setRoomStateWithKey(
      space.id,
      EventTypes.SpaceChild,
      childId,
      <String, Object?>{
        'via': _viaForChild(childId),
        'order': order,
        'suggested': true,
        // Кастомные поля дублируют отдельный preview-event, чтобы UI мог
        // показать название/иконку child-чата из m.space.child сразу, без
        // ожидания вступления в сам child-room.
        if (name != null && name.isNotEmpty) 'name': name,
        if (icon != null && icon.isNotEmpty) 'icon': icon,
        if (name != null && name.isNotEmpty) 'ru.orex.name': name,
        if (icon != null && icon.isNotEmpty) 'ru.orex.icon': icon,
        if (avatar != null && avatar.isNotEmpty) 'ru.orex.avatar_url': avatar,
        if (topic != null && topic.isNotEmpty) 'ru.orex.topic': topic,
        'ru.orex.preview': preview,
      },
    );
  }

  void _forgetSupergroupChildPreview(Room space, String childId) {
    _spaceChildPreviewOverrides[space.id]?.remove(childId);
    _spaceChildOrderOverrides[space.id]?.remove(childId);
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
    final content = _rememberSupergroupChildPreview(
      space,
      childId: childId,
      name: name,
      icon: icon,
      avatar: avatar,
      topic: topic,
    );
    _emitChange();
    _log(
      'Rooms',
      'set child preview space=${space.id} child=$childId name=$name icon=$icon',
    );
    final index = _supergroupChildIds(space).indexOf(childId);
    if (index >= 0) {
      try {
        await _attachSupergroupChild(
          space,
          childId: childId,
          order: index.toString().padLeft(3, '0'),
          preview: content,
        );
      } catch (e) {
        _log('Rooms', 'persist embedded child preview failed child=$childId', e);
      }
    }
    await client.setRoomStateWithKey(
      space.id,
      _orexSpaceChildPreviewEvent,
      childId,
      content,
    );
  }

  Future<String> createGroup(
    String name, {
    bool public = false,
    String? localAlias,
    List<String> invite = const [],
  }) async {
    _log('Rooms', 'create group name=$name public=$public invite=${invite.length}');
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
    _log('Rooms', 'create channel name=$name public=$public invite=${invite.length}');
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
      try {
        await _setRoomKind(room, OrexRoomKind.channel);
      } catch (e) {
        _log('Rooms', 'set channel kind failed room=$roomId', e);
      }
      try {
        await _applyChannelPowerLevels(room);
      } catch (e) {
        _log('Rooms', 'apply channel power levels failed room=$roomId', e);
      }
      try {
        await _applyRoomVisibility(room, public);
        if (public) await setRoomLocalAlias(room, localAlias);
      } catch (e) {
        _log('Rooms', 'apply channel visibility/alias failed room=$roomId', e);
      }
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
    _log('Rooms', 'create supergroup name=$name public=$public invite=${invite.length}');
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
      _log('Rooms', 'created supergroup without default child space=$spaceId');
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
    _log('Rooms', 'create supergroup child space=${space.id} name=$name icon=$icon public=$public');
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
    final order = _supergroupChildIds(space).length.toString().padLeft(3, '0');
    final preview = _rememberSupergroupChildPreview(
      space,
      childId: roomId,
      name: name,
      icon: icon,
      avatar: childRoom?.avatar,
      topic: childRoom?.topic,
    );
    _emitChange();
    try {
      await _attachSupergroupChild(
        space,
        childId: roomId,
        order: order,
        preview: preview,
      );
      _log('Rooms', 'attached child room=$roomId to space=${space.id} order=$order');
    } catch (e) {
      _forgetSupergroupChildPreview(space, roomId);
      _emitChange();
      _log('Rooms', 'attach child failed room=$roomId space=${space.id}', e);
      rethrow;
    }
    try {
      await client.setRoomStateWithKey(
        space.id,
        _orexSpaceChildPreviewEvent,
        roomId,
        preview,
      );
    } catch (e) {
      _log('Rooms', 'persist child preview compatibility event failed child=$roomId', e);
    }
    _emitChange();
    return roomId;
  }

  Future<void> ensureSupergroupChildrenAccess(Room space) async {
    if (!space.isSpace) return;
    var changed = false;
    for (final child in supergroupChildren(space)) {
      await _applySupergroupChildAccess(space, child);
      final existing = _supergroupChildPreviewContent(space, child.id);
      final existingName = existing?['name']?.toString().trim();
      final existingIcon = existing?['icon']?.toString().trim();
      if (existingName?.isNotEmpty == true && existingIcon?.isNotEmpty == true) {
        continue;
      }
      final name = child.getLocalizedDisplayname();
      final icon = roomIconKey(child);
      final preview = _rememberSupergroupChildPreview(
        space,
        childId: child.id,
        name: name == child.id ? (existingName ?? name) : name,
        icon: icon,
        avatar: child.avatar,
        topic: child.topic,
      );
      try {
        await _attachSupergroupChild(
          space,
          childId: child.id,
          order: _supergroupChildIds(space)
              .indexOf(child.id)
              .clamp(0, 999)
              .toString()
              .padLeft(3, '0'),
          preview: preview,
        );
      } catch (e) {
        _log('Rooms', 'repair child preview failed child=${child.id}', e);
      }
      changed = true;
    }
    if (changed) _emitChange();
  }

  Future<void> removeSupergroupChild(Room space, Room child) async {
    if (!space.isSpace) throw StateError('Room is not a supergroup space');
    try {
      await space.removeSpaceChild(child.id);
    } catch (_) {}
    _forgetSupergroupChildPreview(space, child.id);
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
