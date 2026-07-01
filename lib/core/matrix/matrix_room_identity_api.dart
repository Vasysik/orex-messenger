part of 'matrix_service.dart';

extension MatrixRoomIdentityApi on MatrixService {
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
}
