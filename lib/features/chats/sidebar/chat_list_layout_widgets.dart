part of 'chat_list_panel.dart';

class _RoomListPage extends StatelessWidget {
  const _RoomListPage({
    required this.matrix,
    required this.rooms,
    required this.selectedRoomId,
    required this.globalItemCount,
    required this.globalItemBuilder,
    required this.onSelect,
    required this.onDelete,
  });

  final MatrixService matrix;
  final List<Room> rooms;
  final String? selectedRoomId;
  final int globalItemCount;
  final Widget Function(int index) globalItemBuilder;
  final ValueChanged<String> onSelect;
  final ValueChanged<Room> onDelete;

  @override
  Widget build(BuildContext context) {
    final visibleRooms = rooms
        .where((room) => !matrix.isSupergroupChild(room))
        .toList();
    if (visibleRooms.isEmpty && globalItemCount == 0) {
      return const Center(
        child: SquirrelMascot(
          size: 110,
          caption: 'Здесь пока пусто',
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: visibleRooms.length + globalItemCount,
      itemBuilder: (_, i) {
        if (i < visibleRooms.length) {
          final room = visibleRooms[i];
          return _ChatTile(
            matrix: matrix,
            room: room,
            selected: room.id == selectedRoomId,
            onTap: () => onSelect(room.id),
            onLongPress: () => onDelete(room),
          );
        }

        return globalItemBuilder(i - visibleRooms.length);
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
      child: Text(
        title,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: OrexColors.copper,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.onSearch,
    required this.onOpenSettings,
    required this.onNewChat,
  });
  final ValueChanged<String> onSearch;
  final VoidCallback onOpenSettings;
  final VoidCallback onNewChat;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 42,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: (isDark ? Colors.black : Colors.white)
                    .withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: OrexColors.copper.withValues(alpha: 0.25),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search,
                    size: 20,
                    color: OrexColors.copper.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      onChanged: onSearch,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Поиск',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            onPressed: onNewChat,
            icon: const Icon(Icons.edit_square),
            color: OrexColors.copper,
            tooltip: 'Новый чат',
          ),
          IconButton(
            onPressed: onOpenSettings,
            icon: const Icon(Icons.settings),
            color: OrexColors.copper,
            tooltip: 'Настройки',
          ),
        ],
      ),
    );
  }
}

class _FolderTabs extends StatelessWidget {
  const _FolderTabs({
    required this.folders,
    required this.selectedIndex,
    required this.controller,
    required this.onChanged,
    required this.onManage,
  });

  final List<OrexChatFolder> folders;
  final int selectedIndex;
  final ScrollController controller;
  final ValueChanged<int> onChanged;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42,
      child: Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent || !controller.hasClients) return;
          final delta = event.scrollDelta.dy.abs() >= event.scrollDelta.dx.abs()
              ? event.scrollDelta.dy
              : event.scrollDelta.dx;
          final target = (controller.offset + delta)
              .clamp(
                controller.position.minScrollExtent,
                controller.position.maxScrollExtent,
              )
              .toDouble();
          controller.jumpTo(target);
        },
        child: ListView.builder(
          controller: controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: folders.length + 1,
          itemBuilder: (context, index) {
            if (index == folders.length) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  tooltip: 'Настроить папки',
                  onPressed: onManage,
                  icon: const Icon(Icons.tune),
                  color: OrexColors.copper,
                ),
              );
            }

            final folder = folders[index];
            final active = index == selectedIndex;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => onChanged(index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  height: 36,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    gradient: active ? OrexColors.copperGradient : null,
                    color: active
                        ? null
                        : OrexColors.walnut.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: active
                          ? Colors.transparent
                          : OrexColors.copper.withValues(alpha: 0.14),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _folderIcon(folder.filter),
                        size: 16,
                        color: active ? OrexColors.cream : OrexColors.copper,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        folder.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: active ? OrexColors.cream : null,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  IconData _folderIcon(OrexFolderFilter filter) => switch (filter) {
        OrexFolderFilter.all => Icons.all_inbox,
        OrexFolderFilter.direct => Icons.person,
        OrexFolderFilter.groups => Icons.group,
        OrexFolderFilter.channels => Icons.campaign,
        OrexFolderFilter.invites => Icons.mark_email_unread,
        OrexFolderFilter.custom => Icons.folder_special,
      };
}

