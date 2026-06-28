part of 'room_settings_screen.dart';

String _historyLabel(HistoryVisibility visibility) => switch (visibility) {
      HistoryVisibility.invited => 'С момента приглашения',
      HistoryVisibility.joined => 'С момента входа',
      HistoryVisibility.shared => 'С общей историей комнаты',
      HistoryVisibility.worldReadable => 'Видна всем',
    };


String _roomKindLabel(OrexRoomKind kind) => switch (kind) {
      OrexRoomKind.direct => 'Личный чат',
      OrexRoomKind.group => 'Групповой чат',
      OrexRoomKind.channel => 'Канал',
      OrexRoomKind.supergroup => 'Супергруппа',
    };

class _RoomProfileCard extends StatelessWidget {
  const _RoomProfileCard({
    required this.matrix,
    required this.room,
    required this.kindLabel,
    required this.busy,
    required this.allowAvatar,
    required this.onAvatar,
    required this.onRemoveAvatar,
  });

  final MatrixService matrix;
  final Room room;
  final String kindLabel;
  final bool busy;
  final bool allowAvatar;
  final VoidCallback onAvatar;
  final VoidCallback? onRemoveAvatar;

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    final alias = room.canonicalAlias;
    final address = alias.isNotEmpty ? alias : room.id;

    return GlassPanel(
      borderRadius: 22,
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          GestureDetector(
            onTap: allowAvatar && !busy ? onAvatar : null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                MxcAvatar(
                  matrix: matrix,
                  name: name,
                  mxc: room.avatar,
                  size: 72,
                ),
                if (busy)
                  const CircularProgressIndicator(color: OrexColors.cream),
                if (allowAvatar && !busy)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: OrexColors.walnutDeep,
                      ),
                      child: const Icon(
                        Icons.photo_camera,
                        size: 14,
                        color: OrexColors.cream,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontSize: 18),
                ),
                const SizedBox(height: 2),
                Text(
                  '$kindLabel · $address',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (allowAvatar && onRemoveAvatar != null)
            IconButton(
              tooltip: 'Убрать аватар',
              onPressed: onRemoveAvatar,
              icon: const Icon(
                Icons.no_photography_outlined,
                color: OrexColors.copper,
              ),
            ),
        ],
      ),
    );
  }
}

class _InvitePicker extends StatelessWidget {
  const _InvitePicker({
    required this.matrix,
    required this.users,
    required this.selectedIds,
    required this.enabled,
    required this.hasQuery,
    required this.onChanged,
  });

  final MatrixService matrix;
  final List<User> users;
  final Set<String> selectedIds;
  final bool enabled;
  final bool hasQuery;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(14, 4, 14, 14),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('У вас нет прав приглашать участников'),
        ),
      );
    }
    if (!hasQuery) return const SizedBox.shrink();
    if (users.isEmpty) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(14, 4, 14, 14),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('Локально никого не найдено'),
        ),
      );
    }
    return Column(
      children: users.map((user) {
        final name = user.calcDisplayname();
        final selected = selectedIds.contains(user.id);
        return CheckboxListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 14),
          value: selected,
          onChanged: (value) {
            if (value == true) {
              selectedIds.add(user.id);
            } else {
              selectedIds.remove(user.id);
            }
            onChanged();
          },
          secondary: MxcAvatar(
            matrix: matrix,
            name: name,
            mxc: user.avatarUrl,
            size: 38,
          ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            matrix.compactUserId(user.id),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
    );
  }
}

class _RoleChip extends StatelessWidget {
  const _RoleChip(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: OrexColors.copper.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: OrexColors.copper.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: OrexColors.copper,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _DangerZone extends StatelessWidget {
  const _DangerZone({required this.onDeleteForEveryone});
  final VoidCallback onDeleteForEveryone;

  @override
  Widget build(BuildContext context) {
    return OrexSettingsSection(
      title: 'Опасная зона',
      children: [
        OrexSettingsTile(
          icon: Icons.delete_forever,
          title: 'Удалить для всех',
          subtitle: 'Доступно владельцу комнаты',
          danger: true,
          onTap: onDeleteForEveryone,
        ),
      ],
    );
  }
}

class _SupergroupRoomsSection extends StatelessWidget {
  const _SupergroupRoomsSection({
    required this.matrix,
    required this.room,
    required this.onAddChat,
    required this.onEditChild,
    required this.onDeleteChild,
  });

  final MatrixService matrix;
  final Room room;
  final VoidCallback onAddChat;
  final ValueChanged<Room> onEditChild;
  final ValueChanged<Room> onDeleteChild;

  @override
  Widget build(BuildContext context) {
    final previews = matrix.supergroupChildPreviews(room);
    return OrexSettingsSection(
      title: 'Чаты супергруппы',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onAddChat,
              icon: const Icon(Icons.forum),
              label: const Text('Добавить чат'),
            ),
          ),
        ),
        if (previews.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 4, 14, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Пока нет отдельных чатов'),
            ),
          )
        else
          ...previews.map((preview) {
            final local = matrix.client.getRoomById(preview.roomId);
            final iconKey = local == null
                ? (preview.iconKey ?? 'chat')
                : matrix.roomIconKey(local);
            final subtitle = local == null
                ? 'Чат супергруппы · предпросмотр'
                : matrix.isPublicRoom(local)
                    ? 'Публичный чат супергруппы'
                    : 'Чат супергруппы';

            return ListTile(
              leading: Icon(
                orexRoomIconData(iconKey),
                color: OrexColors.copper,
              ),
              title: Text(
                preview.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(subtitle),
              trailing: local == null
                  ? const Icon(Icons.visibility_outlined, size: 20)
                  : Wrap(
                      spacing: 2,
                      children: [
                        IconButton(
                          tooltip: 'Переименовать',
                          onPressed: () => onEditChild(local),
                          icon: const Icon(Icons.edit),
                        ),
                        IconButton(
                          tooltip: 'Удалить',
                          onPressed: () => onDeleteChild(local),
                          icon: const Icon(Icons.delete_outline),
                          color: const Color(0xFFCF6679),
                        ),
                      ],
                    ),
            );
          }),
      ],
    );
  }
}
