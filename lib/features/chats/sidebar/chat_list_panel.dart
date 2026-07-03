import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../../core/matrix/matrix_service.dart';
import '../../../domain/rooms/member_event_text.dart';
import '../../../shared/theme/glass.dart';
import '../../../shared/theme/orex_theme.dart';
import '../../../shared/widgets/mxc_avatar.dart';
import '../../../shared/widgets/squirrel_mascot.dart';
import 'chat_folder_controller.dart';

part 'chat_list_layout_widgets.dart';
part 'chat_folder_manager_widgets.dart';
part 'chat_room_tile_widgets.dart';

/// Левая колонка: поиск, папки и список чатов.
class ChatListPanel extends StatefulWidget {
  const ChatListPanel({
    super.key,
    required this.matrix,
    required this.selectedRoomId,
    required this.onSelect,
    required this.onOpenPreview,
    required this.onOpenSettings,
    required this.onNewChat,
    required this.folders,
  });

  final MatrixService matrix;
  final String? selectedRoomId;
  final ValueChanged<String> onSelect;
  final ValueChanged<OrexConversationPreview> onOpenPreview;
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
    final peopleFuture = widget.matrix.searchUsers(
      q,
      includeMxidFallback: true,
    );
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
      ..sort(
        (a, b) =>
            b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime),
      );
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
                    globalItemCount: index == selectedIndex
                        ? _globalSectionItemCount
                        : 0,
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
    final sections =
        (_globalPublicRooms.isNotEmpty ? 1 : 0) +
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
          onTap: () =>
              widget.onOpenPreview(OrexConversationPreview.fromRoom(preview)),
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
        onTap: () => widget.onOpenPreview(
          OrexConversationPreview.direct(
            profile,
            compactUserId: widget.matrix.compactUserId(profile.userId),
          ),
        ),
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
  return q.startsWith('#') ||
      q.startsWith('!') ||
      q.startsWith('@') ||
      q.contains(':');
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
