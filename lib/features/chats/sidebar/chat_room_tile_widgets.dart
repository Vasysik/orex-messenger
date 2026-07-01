part of 'chat_list_panel.dart';

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.matrix,
    required this.room,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final MatrixService matrix;
  final Room room;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    final isInvite = matrix.isInvite(room);
    final lastEvent = room.lastEvent;
    final membershipNotice = lastEvent == null
        ? null
        : OrexMembershipNotices.fromEvent(lastEvent);
    final preview = isInvite
        ? 'Приглашение · нажмите, чтобы принять'
        : (membershipNotice?.text ??
            (lastEvent == null
            ? ''
            : (lastEvent.type == EventTypes.GroupCallMember
                ? 'Звонок'
                : lastEvent.type == EventTypes.Encrypted
                    ? 'Зашифровано'
                    : lastEvent.calcLocalizedBodyFallback(
                        const MatrixDefaultLocalizations(),
                        hideReply: true,
                        hideEdit: true,
                      ))));
    final unread = room.notificationCount;

    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          onLongPress: onLongPress,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: selected
                  ? OrexColors.copper.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                MxcAvatar(
                  matrix: matrix,
                  name: name,
                  mxc: room.avatar,
                  size: 48,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          Text(
                            _time(lastEvent?.originServerTs),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              preview,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: isInvite ? OrexColors.copper : null,
                                    fontWeight:
                                        isInvite ? FontWeight.w600 : null,
                                  ),
                            ),
                          ),
                          if (unread > 0) _UnreadBadge(count: unread),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _time(DateTime? ts) {
    if (ts == null) return '';
    final now = DateTime.now();
    if (ts.year == now.year && ts.month == now.month && ts.day == now.day) {
      return '${ts.hour.toString().padLeft(2, '0')}:'
          '${ts.minute.toString().padLeft(2, '0')}';
    }
    return '${ts.day.toString().padLeft(2, '0')}.'
        '${ts.month.toString().padLeft(2, '0')}';
  }
}

class _GlobalPublicRoomTile extends StatelessWidget {
  const _GlobalPublicRoomTile({
    required this.matrix,
    required this.preview,
    required this.onTap,
  });

  final MatrixService matrix;
  final OrexRoomPreview preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final displayAlias = OrexRoomAlias.displayAlias(preview.alias);
    final subtitle = displayAlias.isNotEmpty
        ? displayAlias
        : preview.topic?.isNotEmpty == true
            ? preview.topic!
            : preview.roomId;
    return ListTile(
      leading: MxcAvatar(
        matrix: matrix,
        name: preview.name,
        mxc: preview.avatar,
        size: 44,
      ),
      title: Text(preview.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right, color: OrexColors.copper),
      onTap: onTap,
    );
  }
}

class _GlobalUserTile extends StatelessWidget {
  const _GlobalUserTile({
    required this.matrix,
    required this.profile,
    required this.enabled,
    required this.onTap,
  });

  final MatrixService matrix;
  final Profile profile;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final compactId = matrix.compactUserId(profile.userId);
    final name = profile.displayName ?? compactId;
    return RepaintBoundary(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                MxcAvatar(
                  matrix: matrix,
                  name: name,
                  mxc: profile.avatarUrl,
                  size: 48,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        compactId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: OrexColors.copperBright,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: OrexColors.unread,
        borderRadius: BorderRadius.circular(12),
      ),
      constraints: const BoxConstraints(minWidth: 22),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          color: OrexColors.cream,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
