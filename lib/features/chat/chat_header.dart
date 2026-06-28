part of 'chat_view.dart';

class _InviteView extends StatelessWidget {
  const _InviteView({
    required this.matrix,
    required this.room,
    required this.onAccept,
    required this.onReject,
    this.onBack,
  });

  final MatrixService matrix;
  final Room room;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
          child: Row(
            children: [
              if (onBack != null)
                IconButton(
                    onPressed: onBack, icon: const Icon(Icons.arrow_back)),
              MxcAvatar(matrix: matrix, name: name, mxc: room.avatar, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MxcAvatar(
                        matrix: matrix, name: name, mxc: room.avatar, size: 88),
                    const SizedBox(height: 16),
                    Text('Вас пригласили в «$name»',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: onReject,
                            child: const Text('Отклонить'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                                backgroundColor: OrexColors.copper),
                            onPressed: onAccept,
                            child: const Text('Принять'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ChatHeader extends StatelessWidget {
  const _ChatHeader({
    required this.matrix,
    required this.room,
    required this.onCall,
    required this.onSettings,
    this.onBack,
    this.supergroupSpaceId,
    this.supergroupChildIds,
    this.onSupergroupChildSelected,
  });

  final MatrixService matrix;
  final Room room;
  final ValueChanged<bool> onCall;
  final ValueChanged<Room> onSettings;
  final VoidCallback? onBack;
  final String? supergroupSpaceId;
  final List<String>? supergroupChildIds;
  final ValueChanged<String>? onSupergroupChildSelected;

  @override
  Widget build(BuildContext context) {
    final spaceId = supergroupSpaceId;
    final space = spaceId == null ? null : matrix.client.getRoomById(spaceId);
    final childIds = supergroupChildIds ?? const <String>[];
    final childRooms =
        childIds.map(matrix.client.getRoomById).whereType<Room>().toList();
    final inSupergroup = space != null && childRooms.isNotEmpty;
    final titleRoom = inSupergroup ? space : room;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
            ),
          MxcAvatar(
            matrix: matrix,
            name: titleRoom.getLocalizedDisplayname(),
            mxc: titleRoom.avatar,
            size: 42,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titleRoom.getLocalizedDisplayname(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (inSupergroup)
                  _SupergroupChildPicker(
                    matrix: matrix,
                    room: room,
                    children: childRooms,
                    onChanged: onSupergroupChildSelected,
                  )
                else
                  _PresenceLine(room: room),
              ],
            ),
          ),
          if (space != null && matrix.canManageRoomSettings(space))
            IconButton(
              tooltip: 'Настройки супергруппы',
              onPressed: () => onSettings(space),
              icon: const Icon(Icons.hub),
              color: OrexColors.copper,
            ),
          if (space == null && matrix.canManageRoomSettings(room))
            IconButton(
              tooltip: 'Настройки чата',
              onPressed: () => onSettings(room),
              icon: const Icon(Icons.info_outline),
              color: OrexColors.copper,
            ),
          if (!room.isSpace) ...[
            IconButton(
              tooltip: 'Аудиозвонок',
              onPressed: () => onCall(false),
              icon: const Icon(Icons.call),
              color: OrexColors.copper,
            ),
            IconButton(
              tooltip: 'Видеозвонок',
              onPressed: () => onCall(true),
              icon: const Icon(Icons.videocam),
              color: OrexColors.copper,
            ),
          ],
        ],
      ),
    );
  }
}

class _SupergroupChildPicker extends StatelessWidget {
  const _SupergroupChildPicker({
    required this.matrix,
    required this.room,
    required this.children,
    required this.onChanged,
  });

  final MatrixService matrix;
  final Room room;
  final List<Room> children;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: room.id,
        isDense: true,
        isExpanded: true,
        iconSize: 18,
        items: children
            .map(
              (child) => DropdownMenuItem(
                value: child.id,
                child: Row(
                  children: [
                    Icon(
                      orexRoomIconData(matrix.roomIconKey(child)),
                      size: 16,
                      color: OrexColors.copper,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        child.getLocalizedDisplayname(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
        onChanged: (value) {
          if (value == null || value == room.id) return;
          onChanged?.call(value);
        },
      ),
    );
  }
}

class _PresenceLine extends StatelessWidget {
  const _PresenceLine({required this.room});
  final Room room;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final dmId = room.directChatMatrixID;

    if (dmId == null) {
      return Text('${room.summary.mJoinedMemberCount ?? 0} участников',
          style: style);
    }

    return FutureBuilder<CachedPresence>(
      future: room.client.fetchCurrentPresence(dmId),
      builder: (context, snap) {
        final p = snap.data;
        final text = switch (p?.presence) {
          PresenceType.online => 'в сети',
          PresenceType.unavailable => 'был(а) недавно',
          _ => p?.lastActiveTimestamp != null ? 'был(а) недавно' : 'не в сети',
        };
        return Text(text, style: style);
      },
    );
  }
}
