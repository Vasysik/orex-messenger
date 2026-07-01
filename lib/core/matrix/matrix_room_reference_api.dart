part of 'matrix_service.dart';

extension MatrixRoomReferenceApi on MatrixService {
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
}
