part of 'matrix_service.dart';

extension MatrixSupergroupApi on MatrixService {
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
}
