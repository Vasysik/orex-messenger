part of 'matrix_service.dart';

extension MatrixRoomCreationApi on MatrixService {
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
}
