import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';

enum _NewRoomKind { group, channel, supergroup }

/// Экран «Новый чат»: поиск людей, создание группы, канала и супергруппы.
/// Возвращает roomId выбранного/созданного чата через Navigator.pop.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key, required this.matrix});
  final MatrixService matrix;

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<Profile> _results = [];
  bool _loading = false;
  bool _busy = false;

  void _onQuery(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(q));
  }

  Future<void> _run(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    final res = await widget.matrix.searchUsers(q, includeMxidFallback: true);
    if (mounted) {
      setState(() {
        _results = res;
        _loading = false;
      });
    }
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

  Future<void> _create(_NewRoomKind kind) async {
    final channelConfig =
        kind == _NewRoomKind.channel ? await _askChannel() : null;
    if (kind == _NewRoomKind.channel && channelConfig == null) return;
    final name = channelConfig?.name ??
        await _askName(kind == _NewRoomKind.supergroup
            ? 'Название супергруппы'
            : 'Название группы');
    if (name == null || name.isEmpty) return;
    setState(() => _busy = true);
    try {
      final roomId = switch (kind) {
        _NewRoomKind.group => await widget.matrix.createGroup(name),
        _NewRoomKind.channel => await widget.matrix.createChannel(
            name,
            public: channelConfig?.public ?? false,
          ),
        _NewRoomKind.supergroup => await widget.matrix.createSupergroup(name),
      };
      if (mounted) Navigator.of(context).pop(roomId);
    } catch (e) {
      _snack('Не удалось создать: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askName(String title) {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
  }

  Future<({String name, bool public})?> _askChannel() {
    final c = TextEditingController();
    var public = false;
    return showDialog<({String name, bool public})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Новый канал'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: c,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Название'),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: public,
                title: const Text('Публичный канал'),
                subtitle: Text(
                  public ? 'Открыт для входа' : 'Вход только по приглашению',
                ),
                onChanged: (value) => setDialogState(() => public = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final name = c.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx, (name: name, public: public));
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
  }

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
              Text('НАЙТИ ЧЕЛОВЕКА',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        letterSpacing: 1.1,
                        color: OrexColors.copper,
                        fontWeight: FontWeight.w700,
                      )),
              const SizedBox(height: 8),
              TextField(
                controller: _search,
                onChanged: _onQuery,
                decoration: InputDecoration(
                  hintText: 'Имя или @user:vasys.ru',
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
              else
                ..._results.map(_userTile),
            ],
          ),
        ),
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

  Widget _userTile(Profile p) {
    final name = p.displayName ?? p.userId;
    return ListTile(
      leading: MxcAvatar(
        matrix: widget.matrix,
        name: name,
        mxc: p.avatarUrl,
        size: 44,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(p.userId, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _openDirect(p.userId),
    );
  }
}
