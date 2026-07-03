part of 'matrix_service.dart';

extension MatrixRoomDiscoveryApi on MatrixService {
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
        final res = await client.searchUserDirectory(
          normalizedDirectoryQuery,
          limit: 30,
        );
        for (final p in res.results) {
          byId[p.userId] = p;
        }
      } catch (_) {
        // Directory may be unavailable; exact MXID fallback below can still work.
      }
    }

    final candidates = includeMxidFallback
        ? _mxidCandidates(q)
        : const <String>[];
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

  Future<String> enterConversationPreview(
    OrexConversationPreview preview,
  ) async {
    switch (preview.kind) {
      case OrexConversationPreviewKind.publicRoom:
      case OrexConversationPreviewKind.supergroupChild:
        final roomPreview = preview.roomPreview;
        if (roomPreview == null) {
          throw StateError('Room preview is missing');
        }
        return joinRoomPreview(roomPreview);
      case OrexConversationPreviewKind.direct:
        final userId = preview.userId;
        if (userId == null || userId.isEmpty) {
          throw StateError('User id is missing');
        }
        return startDirectChat(userId);
    }
  }

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
}
