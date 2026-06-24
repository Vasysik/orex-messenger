import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../../core/matrix_service.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import '../../widgets/squirrel_mascot.dart';

/// Левая колонка: поиск, вкладки-папки и список чатов.
class ChatListPanel extends StatefulWidget {
  const ChatListPanel({
    super.key,
    required this.matrix,
    required this.selectedRoomId,
    required this.onSelect,
    required this.onOpenSettings,
    required this.onNewChat,
  });

  final MatrixService matrix;
  final String? selectedRoomId;
  final ValueChanged<String> onSelect;
  final VoidCallback onOpenSettings;
  final VoidCallback onNewChat;

  @override
  State<ChatListPanel> createState() => _ChatListPanelState();
}

class _ChatListPanelState extends State<ChatListPanel> {
  OrexFolder _folder = OrexFolder.all;
  String _query = '';

  void _handleTap(Room room) {
    if (widget.matrix.isInvite(room)) {
      _showInviteDialog(room);
    } else {
      widget.onSelect(room.id);
    }
  }

  Future<void> _showInviteDialog(Room room) async {
    final from = room.unsafeGetUserFromMemoryOrFallback(
      room.directChatMatrixID ?? '',
    );
    final who = from.calcDisplayname();
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Приглашение в чат'),
        content: Text('$who приглашает вас в «${room.getLocalizedDisplayname()}».'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'reject'),
            child: const Text('Отклонить'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: OrexColors.copper),
            onPressed: () => Navigator.pop(ctx, 'accept'),
            child: const Text('Принять'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'accept') {
      await widget.matrix.acceptInvite(room);
      if (mounted) widget.onSelect(room.id);
    } else if (action == 'reject') {
      await widget.matrix.rejectInvite(room);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.matrix,
      builder: (context, _) {
        var rooms = widget.matrix.roomsForFolder(_folder);
        if (_query.isNotEmpty) {
          final q = _query.toLowerCase();
          rooms = rooms
              .where((r) => r.getLocalizedDisplayname().toLowerCase().contains(q))
              .toList();
        }

        return Column(
          children: [
            _Header(
              onSearch: (v) => setState(() => _query = v),
              onOpenSettings: widget.onOpenSettings,
              onNewChat: widget.onNewChat,
            ),
            _FolderTabs(
              selected: _folder,
              onChanged: (f) => setState(() => _folder = f),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: rooms.isEmpty
                  ? const Center(
                      child: SquirrelMascot(
                        size: 110,
                        caption: 'Здесь пока пусто',
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: rooms.length,
                      itemBuilder: (_, i) => _ChatTile(
                        matrix: widget.matrix,
                        room: rooms[i],
                        selected: rooms[i].id == widget.selectedRoomId,
                        onTap: () => _handleTap(rooms[i]),
                      ),
                    ),
            ),
          ],
        );
      },
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
                  Icon(Icons.search,
                      size: 20,
                      color: OrexColors.copper.withValues(alpha: 0.9)),
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
  const _FolderTabs({required this.selected, required this.onChanged});
  final OrexFolder selected;
  final ValueChanged<OrexFolder> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: OrexFolder.values.map((f) {
          final active = f == selected;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: GestureDetector(
              onTap: () => onChanged(f),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: active ? OrexColors.copperGradient : null,
                  color: active
                      ? null
                      : OrexColors.walnut.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  f.label,
                  style: TextStyle(
                    color: active ? OrexColors.cream : null,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.matrix,
    required this.room,
    required this.selected,
    required this.onTap,
  });

  final MatrixService matrix;
  final Room room;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    final isInvite = matrix.isInvite(room);
    final lastEvent = room.lastEvent;
    final preview = isInvite
        ? '✉️ Приглашение — нажмите, чтобы принять'
        : (lastEvent == null
            ? ''
            : (lastEvent.type == EventTypes.GroupCallMember
                ? '📞 Звонок'
                : lastEvent.calcLocalizedBodyFallback(
                    const MatrixDefaultLocalizations(),
                  )));
    final unread = room.notificationCount;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
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
              MxcAvatar(matrix: matrix, name: name, mxc: room.avatar, size: 48),
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
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
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
