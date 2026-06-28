import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';

enum _NewRoomKind { group, channel, supergroup }

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key, required this.matrix});
  final MatrixService matrix;

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<Profile> _people = [];
  List<PublishedRoomsChunk> _publicRooms = [];
  bool _loading = false;
  bool _busy = false;

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(q));
  }

  Future<void> _run(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _people = [];
        _publicRooms = [];
        _loading = false;
      });
      return;
    }

    setState(() => _loading = true);
    final peopleFuture =
        widget.matrix.searchUsers(query, includeMxidFallback: true);
    final roomsFuture = widget.matrix.searchPublicRooms(query);
    final people = await peopleFuture;
    final rooms = await roomsFuture;
    if (!mounted || _search.text.trim() != query) return;
    setState(() {
      _people = people;
      _publicRooms = rooms;
      _loading = false;
    });
  }

  Future<void> _openDirect(String userId) async {
    setState(() => _busy = true);
    try {
      final roomId = await widget.matrix.startDirectChat(userId);
      if (mounted) Navigator.of(context).pop(roomId);
    } catch (e) {
      _snack('Не удалось открыть чат: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinPublicRoom(PublishedRoomsChunk room) async {
    setState(() => _busy = true);
    try {
      final roomId = await widget.matrix.joinPublicRoom(room);
      if (mounted) Navigator.of(context).pop(roomId);
    } catch (e) {
      _snack('Не удалось войти: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create(_NewRoomKind kind) async {
    final config = await _askRoom(kind);
    if (config == null || config.name.isEmpty) return;
    setState(() => _busy = true);
    try {
      final roomId = switch (kind) {
        _NewRoomKind.group => await widget.matrix.createGroup(
            config.name,
            public: config.public,
            localAlias: config.localAlias,
          ),
        _NewRoomKind.channel => await widget.matrix.createChannel(
            config.name,
            public: config.public,
            localAlias: config.localAlias,
          ),
        _NewRoomKind.supergroup => await widget.matrix.createSupergroup(
            config.name,
            public: config.public,
            localAlias: config.localAlias,
          ),
      };
      if (mounted) Navigator.of(context).pop(roomId);
    } catch (e) {
      _snack('Не удалось создать: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<({String name, bool public, String? localAlias})?> _askRoom(
    _NewRoomKind kind,
  ) {
    final name = TextEditingController();
    final alias = TextEditingController();
    var public = false;
    return showDialog<({String name, bool public, String? localAlias})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(_dialogTitle(kind)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: public,
                  title: const Text('Публичная'),
                  subtitle: Text(
                    public ? 'Вход по ID' : 'Только по приглашению',
                  ),
                  onChanged: (value) => setDialogState(() => public = value),
                ),
                TextField(
                  controller: alias,
                  enabled: public,
                  decoration: const InputDecoration(
                    labelText: 'ID',
                    hintText: 'team-news',
                    prefixIcon: Icon(Icons.tag),
                  ),
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
                final roomName = name.text.trim();
                if (roomName.isEmpty) return;
                Navigator.pop(
                  ctx,
                  (
                    name: roomName,
                    public: public,
                    localAlias: public ? alias.text.trim() : null,
                  ),
                );
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }

  String _dialogTitle(_NewRoomKind kind) => switch (kind) {
        _NewRoomKind.group => 'Новая группа',
        _NewRoomKind.channel => 'Новый канал',
        _NewRoomKind.supergroup => 'Новая супергруппа',
      };

  void _snack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Новый чат'),
        ),
        body: AbsorbPointer(
          absorbing: _busy,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _action(
                icon: Icons.group_add,
                label: 'Новая группа',
                onTap: () => _create(_NewRoomKind.group),
              ),
              const SizedBox(height: 10),
              _action(
                icon: Icons.campaign,
                label: 'Новый канал',
                onTap: () => _create(_NewRoomKind.channel),
              ),
              const SizedBox(height: 10),
              _action(
                icon: Icons.hub,
                label: 'Новая супергруппа',
                onTap: () => _create(_NewRoomKind.supergroup),
              ),
              const SizedBox(height: 20),
              _sectionTitle(context, 'ПОИСК'),
              const SizedBox(height: 8),
              TextField(
                controller: _search,
                onChanged: _onQuery,
                decoration: InputDecoration(
                  hintText: 'Имя, @user или публичный ID',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: Colors.white.withValues(alpha: 0.10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                if (_publicRooms.isNotEmpty) ...[
                  _sectionTitle(context, 'ПУБЛИЧНЫЕ КОМНАТЫ'),
                  const SizedBox(height: 4),
                  ..._publicRooms.map(_publicRoomTile),
                  const SizedBox(height: 10),
                ],
                if (_people.isNotEmpty) ...[
                  _sectionTitle(context, 'ЛЮДИ'),
                  const SizedBox(height: 4),
                  ..._people.map(_userTile),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) {
    return Text(
      title,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
            letterSpacing: 1.1,
            color: OrexColors.copper,
            fontWeight: FontWeight.w700,
          ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      GlassPanel(
        borderRadius: 16,
        child: ListTile(
          leading: Icon(icon, color: OrexColors.copper),
          title: Text(label),
          onTap: onTap,
        ),
      );

  Widget _publicRoomTile(PublishedRoomsChunk room) {
    final name = room.name ?? room.canonicalAlias ?? room.roomId;
    final subtitle = room.canonicalAlias ?? room.topic ?? room.roomId;
    return ListTile(
      leading: MxcAvatar(
        matrix: widget.matrix,
        name: name,
        mxc: room.avatarUrl,
        size: 44,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.login, color: OrexColors.copper),
      onTap: () => _joinPublicRoom(room),
    );
  }

  Widget _userTile(Profile p) {
    final compactId = widget.matrix.compactUserId(p.userId);
    final name = p.displayName ?? compactId;
    return ListTile(
      leading: MxcAvatar(
        matrix: widget.matrix,
        name: name,
        mxc: p.avatarUrl,
        size: 44,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(compactId, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _openDirect(p.userId),
    );
  }
}
