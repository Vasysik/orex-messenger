part of 'matrix_service.dart';

extension MatrixConversationIdentityApi on MatrixService {
  /// Remote peer for a personal room. This intentionally doesn't rely solely
  /// on `m.direct`: old/imported accounts can receive member state before the
  /// direct-chat account-data flag reaches a fresh device.
  User? conversationPeer(Room room) {
    final myId = client.userID;
    final peers = room
        .getParticipants([Membership.join])
        .where((user) => user.id.isNotEmpty && user.id != myId)
        .toList(growable: false);
    if (peers.length == 1) return peers.single;

    final directId = room.directChatMatrixID;
    if (directId == null) return null;
    for (final user in peers) {
      if (user.id == directId) return user;
    }
    return null;
  }

  /// Room avatar for groups, peer avatar for 1:1 chats without `m.room.avatar`.
  Uri? conversationAvatar(Room room) =>
      room.avatar ?? conversationPeer(room)?.avatarUrl;

  /// Persists the avatar and native lookup bindings used by killed-process
  /// notifications. The bytes are keyed by MXC URI; bindings are only aliases.
  Future<String?> ensureConversationAvatarCached(Room room) async {
    final peer = conversationPeer(room);
    final avatar = room.avatar ?? peer?.avatarUrl;
    final roomIdentity = 'room:${room.id}';
    final userIdentity = peer == null ? null : 'user:${peer.id}';

    if (avatar == null) {
      await Future.wait<void>([
        OrexAvatarCache.clearIdentity(roomIdentity),
        if (userIdentity != null) OrexAvatarCache.clearIdentity(userIdentity),
      ]);
      return null;
    }

    final key = await ensureAvatarCached(avatar);
    if (key == null) return null;
    await Future.wait<void>([
      OrexAvatarCache.bindIdentity(roomIdentity, avatar),
      if (userIdentity != null)
        OrexAvatarCache.bindIdentity(userIdentity, avatar),
    ]);
    return key;
  }
}
