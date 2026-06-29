import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../core/member_event_text.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import '../../widgets/squirrel_mascot.dart';
import 'chat_folder_controller.dart';

/// Левая колонка: поиск, папки и список чатов.
class ChatListPanel extends StatefulWidget {
  const ChatListPanel({
    super.key,
    required this.matrix,
    required this.selectedRoomId,
    required this.onSelect,
    required this.onOpenPublicRoomPreview,
    required this.onOpenSettings,
    required this.onNewChat,
    required this.folders,
  });

  final MatrixService matrix;
  final String? selectedRoomId;
  final ValueChanged<String> onSelect;
  final ValueChanged<OrexRoomPreview> onOpenPublicRoomPreview;
  final VoidCallback onOpenSettings;
  final VoidCallback onNewChat;
  final ChatFolderController folders;

  @override
  State<ChatListPanel> createState() => _ChatListPanelState();
}

class _ChatListPanelState extends State<ChatListPanel> {
  final _pageController = PageController();
  final _tabsScroll = ScrollController();
  int _folderIndex = 0;
  String _query = '';
  Timer? _searchDebounce;
  List<Profile> _globalPeople = [];
  List<OrexRoomPreview> _globalPublicRooms = [];
  bool _globalLoading = false;
  bool _openingGlobal = false;
  int _searchRun = 0;

  void _onSearch(String value) {
    final q = value.trim();
    setState(() => _query = q);

    _searchDebounce?.cancel();
    if (q.isEmpty) {
      _searchRun++;
      setState(() {
        _globalPeople = [];
        _globalPublicRooms = [];
        _globalLoading = false;
      });
      return;
    }

    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _runGlobalSearch(q),
    );
  }

  Future<void> _runGlobalSearch(String q) async {
    final run = ++_searchRun;
    setState(() => _globalLoading = true);
    final peopleFuture =
        widget.matrix.searchUsers(q, includeMxidFallback: true);
    final roomsFuture = widget.matrix.searchPublicRoomPreviews(q);
    final results = await peopleFuture;
    final publicRooms = await roomsFuture;
    if (!mounted || run != _searchRun) return;

    final knownDirectIds = widget.matrix.rooms
        .where((room) => room.isDirectChat)
        .map((room) => room.directChatMatrixID)
        .whereType<String>()
        .toSet();
    final ownId = widget.matrix.client.userID;

    setState(() {
      _globalPeople = results
          .where((profile) => profile.userId != ownId)
          .where((profile) => !knownDirectIds.contains(profile.userId))
          .toList();
      _globalPublicRooms = publicRooms.where((preview) {
        final local = widget.matrix.client.getRoomById(preview.roomId);
        return local == null || local.membership != Membership.join;
      }).toList();
      _globalLoading = false;
    });
  }

  Future<void> _openGlobalUser(Profile profile) async {
    if (_openingGlobal) return;
    setState(() => _openingGlobal = true);
    try {
      final roomId = await widget.matrix.startDirectChat(profile.userId);
      if (mounted) widget.onSelect(roomId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть чат: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _openingGlobal = false);
    }
  }

  Future<void> _confirmDelete(Room room) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить чат?'),
        content: Text(
          'Чат «${room.getLocalizedDisplayname()}» исчезнет из списка. '
          'Вы выйдете из комнаты.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFCF6679),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.matrix.deleteRoom(room);
    }
  }

  Future<void> _openFolderSettings() async {
    final folders = await showModalBottomSheet<List<OrexChatFolder>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FolderManager(
        initial: widget.folders.folders,
        matrix: widget.matrix,
      ),
    );
    if (folders == null) return;
    await widget.folders.saveFolders(folders);
    if (!mounted) return;
    final nextIndex = _folderIndex.clamp(0, folders.length - 1).toInt();
    _selectFolder(nextIndex, animate: false);
  }

  void _selectFolder(int index, {bool animate = true}) {
    final count = widget.folders.folders.length;
    if (count == 0) return;
    final next = index.clamp(0, count - 1).toInt();
    if (_folderIndex != next) {
      setState(() => _folderIndex = next);
    }

    if (_pageController.hasClients) {
      if (animate) {
        _pageController.animateToPage(
          next,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      } else {
        _pageController.jumpToPage(next);
      }
    }

    _centerFolderTab(next);
  }

  void _centerFolderTab(int index) {
    if (!_tabsScroll.hasClients) return;
    const estimatedTabWidth = 116.0;
    final viewport = _tabsScroll.position.viewportDimension;
    final target =
        (index * estimatedTabWidth - (viewport - estimatedTabWidth) / 2)
            .clamp(
              _tabsScroll.position.minScrollExtent,
              _tabsScroll.position.maxScrollExtent,
            )
            .toDouble();
    _tabsScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  List<Room> _roomsForFolder(OrexChatFolder folder) {
    if (_query.isEmpty) {
      return widget.folders
          .roomsForFolder(folder)
          .where((room) => !widget.matrix.isSupergroupChild(room))
          .toList();
    }

    final q = _query.toLowerCase();
    final byId = <String, Room>{};
    for (final room in widget.matrix.rooms) {
      if (_matchesLocalRoomSearch(widget.matrix, room, q)) {
        byId[room.id] = room;
      }
    }
    final rooms = byId.values.toList()
      ..sort((a, b) =>
          b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime));
    return rooms;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _pageController.dispose();
    _tabsScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.matrix, widget.folders]),
      builder: (context, _) {
        final folders = widget.folders.folders;
        final selectedIndex = folders.isEmpty
            ? 0
            : _folderIndex.clamp(0, folders.length - 1).toInt();
        if (selectedIndex != _folderIndex) {
          _folderIndex = selectedIndex;
        }

        return Column(
          children: [
            _Header(
              onSearch: _onSearch,
              onOpenSettings: widget.onOpenSettings,
              onNewChat: widget.onNewChat,
            ),
            _FolderTabs(
              folders: folders,
              selectedIndex: selectedIndex,
              controller: _tabsScroll,
              onChanged: _selectFolder,
              onManage: _openFolderSettings,
            ),
            const SizedBox(height: 4),
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: folders.length,
                onPageChanged: (index) {
                  setState(() => _folderIndex = index);
                  _centerFolderTab(index);
                },
                itemBuilder: (context, index) {
                  final folder = folders[index];
                  final rooms = _roomsForFolder(folder);
                  return _RoomListPage(
                    matrix: widget.matrix,
                    rooms: rooms,
                    selectedRoomId: widget.selectedRoomId,
                    globalItemCount:
                        index == selectedIndex ? _globalSectionItemCount : 0,
                    globalItemBuilder: _globalSearchItem,
                    onSelect: widget.onSelect,
                    onDelete: _confirmDelete,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  int get _globalSectionItemCount {
    if (_query.isEmpty) return 0;
    if (_globalLoading) return 2;
    final sections = (_globalPublicRooms.isNotEmpty ? 1 : 0) +
        (_globalPeople.isNotEmpty ? 1 : 0);
    return sections + _globalPublicRooms.length + _globalPeople.length;
  }

  Widget _globalSearchItem(int index) {
    if (_globalLoading) {
      if (index == 0) return const _SectionHeader(title: 'Публичные комнаты');
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox.square(
            dimension: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    var i = index;
    if (_globalPublicRooms.isNotEmpty) {
      if (i == 0) return const _SectionHeader(title: 'Публичные комнаты');
      i--;
      if (i < _globalPublicRooms.length) {
        final preview = _globalPublicRooms[i];
        return _GlobalPublicRoomTile(
          matrix: widget.matrix,
          preview: preview,
          onTap: () => widget.onOpenPublicRoomPreview(preview),
        );
      }
      i -= _globalPublicRooms.length;
    }

    if (_globalPeople.isNotEmpty) {
      if (i == 0) return const _SectionHeader(title: 'Люди');
      i--;
      final profile = _globalPeople[i];
      return _GlobalUserTile(
        matrix: widget.matrix,
        profile: profile,
        enabled: !_openingGlobal,
        onTap: () => _openGlobalUser(profile),
      );
    }

    return const SizedBox.shrink();
  }
}


Set<String> _searchForms(String query) {
  final raw = query.trim().toLowerCase();
  if (raw.isEmpty) return const {};

  final forms = <String>{raw};
  var normalized = raw;
  if (normalized.startsWith('#') || normalized.startsWith('@')) {
    normalized = normalized.substring(1);
  }
  if (normalized.isNotEmpty) forms.add(normalized);

  final localpart = normalized.split(':').first;
  if (localpart.isNotEmpty) forms.add(localpart);
  return forms;
}

bool _isStructuredRoomSearch(String query) {
  final q = query.trim().toLowerCase();
  return q.startsWith('#') || q.startsWith('!') || q.startsWith('@') || q.contains(':');
}

bool _matchesLocalRoomSearch(MatrixService matrix, Room room, String query) {
  final needles = _searchForms(query);
  if (needles.isEmpty) return true;

  final terms = _localRoomSearchTerms(
    matrix,
    room,
    includeServerQualifiedTerms: _isStructuredRoomSearch(query),
  );
  return needles.any((needle) => terms.any((term) => term.contains(needle)));
}


String _roomKindSearchLabel(OrexRoomKind kind) => switch (kind) {
      OrexRoomKind.direct => 'личный direct private личка',
      OrexRoomKind.group => 'группа group чат',
      OrexRoomKind.channel => 'канал channel',
      OrexRoomKind.supergroup => 'супергруппа supergroup space',
    };

Set<String> _localRoomSearchTerms(
  MatrixService matrix,
  Room room, {
  required bool includeServerQualifiedTerms,
}) {
  final terms = <String>{
    room.getLocalizedDisplayname(),
    room.topic,
    _roomKindSearchLabel(matrix.roomKind(room)),
  };

  if (includeServerQualifiedTerms) {
    terms.add(room.id);
  }

  void addAlias(String? value) {
    final alias = value?.trim();
    if (alias == null || alias.isEmpty) return;
    if (includeServerQualifiedTerms) terms.add(alias);
    final withoutHash = alias.startsWith('#') ? alias.substring(1) : alias;
    if (includeServerQualifiedTerms) terms.add(withoutHash);
    final localpart = withoutHash.split(':').first;
    if (localpart.isNotEmpty) terms.add(localpart);
  }

  addAlias(room.canonicalAlias);
  final aliasState = room.getState(EventTypes.RoomCanonicalAlias)?.content;
  addAlias(aliasState?['alias']?.toString());
  final altAliases = aliasState?['alt_aliases'];
  if (altAliases is Iterable) {
    for (final alias in altAliases) {
      addAlias(alias?.toString());
    }
  }

  return terms
      .map((term) => term.trim().toLowerCase())
      .where((term) => term.isNotEmpty)
      .toSet();
}

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
    final subtitle = preview.alias?.isNotEmpty == true
        ? preview.alias!
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
