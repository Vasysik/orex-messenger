part of 'matrix_service.dart';

extension MatrixConversationIdentityApi on MatrixService {
  /// Remote peer for a personal room. Explicit channels/supergroups never
  /// become pseudo-DMs merely because they currently contain two members.
  User? conversationPeer(Room room) {
    if (!_canUsePeerAvatarFallback(room)) return null;
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

  bool _canUsePeerAvatarFallback(Room room) {
    final kind = roomKind(room);
    if (kind == OrexRoomKind.channel ||
        kind == OrexRoomKind.supergroup ||
        room.isSpace) {
      return false;
    }

    // Avatar identity must be conservative. A two-member group is still a
    // group; using its only peer as a fallback is exactly how foreign cached
    // pictures leaked into avatar-less rooms. Wait for m.direct/account-data
    // instead of guessing from member count.
    return room.isDirectChat || room.directChatMatrixID != null;
  }

  /// Room avatar for groups/channels; peer avatar fallback only for personal
  /// conversations. A channel without its own avatar deliberately returns null.
  Uri? conversationAvatar(Room room) {
    final roomAvatar = room.avatar;
    if (roomAvatar != null) return roomAvatar;
    return conversationPeer(room)?.avatarUrl;
  }

  /// Persists strict room/user bindings used by native killed-process UI.
  ///
  /// `room:*` and `user:*` are intentionally independent. A sender without an
  /// avatar must never inherit the room image, and a channel without an image
  /// must never inherit the avatar of its only current participant.
  Future<String?> ensureConversationAvatarCached(Room room) async {
    final roomIdentity = 'room:${room.id}';
    final peer = conversationPeer(room);
    final peerAvatar = peer?.avatarUrl;

    String? peerKey;
    if (peer != null) {
      peerKey = await _ensureIdentityAvatarCached(
        'user:${peer.id}',
        peerAvatar,
      );
    }

    final roomAvatar = room.avatar;
    if (roomAvatar != null) {
      return _ensureIdentityAvatarCached(roomIdentity, roomAvatar);
    }

    if (peer != null) {
      if (peerKey == null || peerAvatar == null) {
        await OrexAvatarCache.markIdentityWithoutAvatar(roomIdentity);
        return null;
      }
      await OrexAvatarCache.bindIdentity(roomIdentity, peerAvatar);
      return peerKey;
    }

    await OrexAvatarCache.markIdentityWithoutAvatar(roomIdentity);
    return null;
  }

  Future<String?> _ensureIdentityAvatarCached(
    String identity,
    Uri? avatar,
  ) async {
    if (avatar == null || avatar.scheme != 'mxc') {
      await OrexAvatarCache.markIdentityWithoutAvatar(identity);
      return null;
    }

    final key = await ensureAvatarCached(avatar);
    if (key == null) {
      // Do not keep showing a previous avatar when Matrix already points at a
      // new image that failed to download. A future warmup can bind it again.
      await OrexAvatarCache.markIdentityWithoutAvatar(identity);
      return null;
    }
    await OrexAvatarCache.bindIdentity(identity, avatar);
    return key;
  }
}
