part of 'chat_list_panel.dart';

class _FolderManager extends StatefulWidget {
  const _FolderManager({required this.initial, required this.matrix});

  final List<OrexChatFolder> initial;
  final MatrixService matrix;

  @override
  State<_FolderManager> createState() => _FolderManagerState();
}

class _FolderManagerState extends State<_FolderManager> {
  late List<OrexChatFolder> _folders = List.of(widget.initial);

  Future<void> _addFolder() async {
    final folder = await _editFolder();
    if (folder == null) return;
    setState(() => _folders.add(folder));
  }

  Future<void> _editAt(int index) async {
    final folder = await _editFolder(folder: _folders[index]);
    if (folder == null) return;
    setState(() => _folders[index] = folder);
  }

  Future<OrexChatFolder?> _editFolder({OrexChatFolder? folder}) async {
    final controller = TextEditingController(text: folder?.label ?? '');
    var filter = folder?.filter ?? OrexFolderFilter.all;
    var roomIds = List<String>.of(folder?.roomIds ?? const []);
    final result = await showDialog<OrexChatFolder>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          Future<void> pickRooms() async {
            final selected = await showDialog<List<String>>(
              context: ctx,
              builder: (_) => _RoomPickerDialog(
                matrix: widget.matrix,
                initialRoomIds: roomIds,
              ),
            );
            if (selected != null) {
              setDialogState(() => roomIds = selected);
            }
          }

          return AlertDialog(
            title: Text(folder == null ? 'Новая папка' : 'Папка'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Название'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<OrexFolderFilter>(
                    initialValue: filter,
                    decoration: const InputDecoration(
                      labelText: 'Что показывать',
                    ),
                    items: OrexFolderFilter.values
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(value.label),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() => filter = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_copy_outlined),
                    title: Text(
                      filter == OrexFolderFilter.custom
                          ? 'Состав папки'
                          : 'Дополнительные чаты',
                    ),
                    subtitle: Text(
                      roomIds.isEmpty
                          ? 'Не выбрано'
                          : 'Выбрано: ${roomIds.length}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: pickRooms,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  final label = controller.text.trim();
                  Navigator.pop(
                    ctx,
                    OrexChatFolder(
                      id: folder?.id ??
                          DateTime.now().microsecondsSinceEpoch.toString(),
                      label: label.isEmpty ? filter.label : label,
                      filter: filter,
                      roomIds: roomIds,
                    ),
                  );
                },
                child: const Text('Готово'),
              ),
            ],
          );
        },
      ),
    );
    controller.dispose();
    return result;
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex--;
      final folder = _folders.removeAt(oldIndex);
      _folders.insert(newIndex, folder);
    });
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.72,
      minChildSize: 0.45,
      maxChildSize: 0.92,
      builder: (context, controller) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: GlassPanel(
              borderRadius: 24,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 14, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Папки чатов',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Сбросить',
                          onPressed: () => setState(
                            () => _folders = List.of(OrexChatFolder.defaults),
                          ),
                          icon: const Icon(Icons.restart_alt),
                        ),
                        IconButton(
                          tooltip: 'Добавить',
                          onPressed: _addFolder,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ReorderableListView.builder(
                      scrollController: controller,
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      itemCount: _folders.length,
                      onReorder: _reorder,
                      itemBuilder: (context, index) {
                        final folder = _folders[index];
                        return _FolderManagerTile(
                          key: ValueKey(folder.id),
                          index: index,
                          folder: folder,
                          onEdit: () => _editAt(index),
                          onDelete: _folders.length == 1
                              ? null
                              : () => setState(
                                    () => _folders.removeAt(index),
                                  ),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Отмена'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton(
                            onPressed: () => Navigator.pop(context, _folders),
                            child: const Text('Сохранить'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _FolderManagerTile extends StatelessWidget {
  const _FolderManagerTile({
    super.key,
    required this.index,
    required this.folder,
    required this.onEdit,
    required this.onDelete,
  });

  final int index;
  final OrexChatFolder folder;
  final VoidCallback onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: ReorderableDragStartListener(
        index: index,
        child: const Icon(Icons.drag_indicator),
      ),
      title: Text(folder.label),
      subtitle: Text(
        folder.roomIds.isEmpty
            ? folder.filter.label
            : '${folder.filter.label} · ${folder.roomIds.length} выбрано',
      ),
      trailing: Wrap(
        spacing: 2,
        children: [
          IconButton(
            tooltip: 'Изменить',
            onPressed: onEdit,
            icon: const Icon(Icons.edit),
          ),
          IconButton(
            tooltip: 'Удалить',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }
}

class _RoomPickerDialog extends StatefulWidget {
  const _RoomPickerDialog({
    required this.matrix,
    required this.initialRoomIds,
  });

  final MatrixService matrix;
  final List<String> initialRoomIds;

  @override
  State<_RoomPickerDialog> createState() => _RoomPickerDialogState();
}

class _RoomPickerDialogState extends State<_RoomPickerDialog> {
  late final Set<String> _selected = widget.initialRoomIds.toSet();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final rooms = widget.matrix.rooms.where((room) {
      if (q.isEmpty) return true;
      return _matchesLocalRoomSearch(widget.matrix, room, q);
    }).toList();

    return AlertDialog(
      title: const Text('Выбрать чаты'),
      content: SizedBox(
        width: 460,
        height: 520,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Поиск по локальным чатам',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: rooms.isEmpty
                  ? const Center(child: Text('Ничего не найдено'))
                  : ListView.builder(
                      itemCount: rooms.length,
                      itemBuilder: (context, index) {
                        final room = rooms[index];
                        final checked = _selected.contains(room.id);
                        final name = room.getLocalizedDisplayname();
                        return CheckboxListTile(
                          value: checked,
                          onChanged: (value) {
                            setState(() {
                              if (value == true) {
                                _selected.add(room.id);
                              } else {
                                _selected.remove(room.id);
                              }
                            });
                          },
                          secondary: MxcAvatar(
                            matrix: widget.matrix,
                            name: name,
                            mxc: room.avatar,
                            size: 38,
                          ),
                          title: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(_kindLabel(widget.matrix, room)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected.toList()),
          child: const Text('Готово'),
        ),
      ],
    );
  }

  String _kindLabel(MatrixService matrix, Room room) =>
      switch (matrix.roomKind(room)) {
        OrexRoomKind.direct => 'Личный чат',
        OrexRoomKind.group =>
          matrix.isPublicRoom(room) ? 'Публичная группа' : 'Группа',
        OrexRoomKind.channel =>
          matrix.isPublicRoom(room) ? 'Публичный канал' : 'Канал',
        OrexRoomKind.supergroup => 'Супергруппа',
      };
}

