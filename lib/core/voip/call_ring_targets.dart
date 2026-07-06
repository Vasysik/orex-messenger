/// Resolves the Matrix users that should receive a targeted personal-call ring.
///
/// The joined-member list is preferred because it reflects the room state that
/// will also carry the MatrixRTC membership. A direct-chat Matrix id is only a
/// fallback for partially hydrated member lists.
Set<String> orexResolveCallRingTargets({
  required String? localUserId,
  required Iterable<String> joinedUserIds,
  String? directChatMatrixId,
}) {
  final local = localUserId?.trim();
  final targets = joinedUserIds
      .map((userId) => userId.trim())
      .where(
        (userId) =>
            userId.isNotEmpty && (local == null || userId != local),
      )
      .toSet();

  if (targets.isEmpty) {
    final direct = directChatMatrixId?.trim();
    if (direct != null &&
        direct.isNotEmpty &&
        (local == null || direct != local)) {
      targets.add(direct);
    }
  }

  return targets;
}
