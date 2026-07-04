part of 'matrix_service.dart';

extension OrexProfilePreviewMapper on Profile {
  OrexUserPreview toOrexUserPreview({required String compactUserId}) {
    return OrexUserPreview(
      userId: userId,
      compactUserId: compactUserId,
      displayName: displayName,
      avatar: avatarUrl,
    );
  }
}

extension OrexPublicRoomPreviewMapper on PublishedRoomsChunk {
  OrexRoomPreview toOrexRoomPreview() {
    final displayAlias = OrexRoomAlias.displayAlias(canonicalAlias);
    final title = name ?? (displayAlias.isNotEmpty ? displayAlias : roomId);
    return OrexRoomPreview(
      roomId: roomId,
      name: title,
      alias: canonicalAlias,
      avatar: avatarUrl,
      topic: topic,
      memberCount: numJoinedMembers,
    );
  }
}

extension OrexMatrixRoomAliasMapper on Room {
  String get orexAliasLocalpart {
    final alias = canonicalAlias;
    if (!alias.startsWith('#')) return '';
    return alias.substring(1).split(':').first;
  }
}
