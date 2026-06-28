import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';

class RoomSettingsSheet extends StatefulWidget {
  const RoomSettingsSheet({
    super.key,
    required this.matrix,
    required this.room,
  });

  final MatrixService matrix;
  final Room room;

  @override
  State<RoomSettingsSheet> createState() => _RoomSettingsSheetState();
}

class _RoomSettingsSheetState extends State<RoomSettingsSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.room.getLocalizedDisplayname());
  late final TextEditingController _topic =
      TextEditingController(text: widget.room.topic);
  late final TextEditingController _alias = TextEditingController(
    text: widget.matrix.roomAliasLocalpart(widget.room),
  );
  final _inviteSearch = TextEditingController();
  final Set<String> _selectedInviteIds = {};
  bool _busy = false;
  bool _savingAvatar = false;
  late bool _public = widget.matrix.isPublicRoom(widget.room);
  late HistoryVisibility _historyVisibility =
      widget.room.historyVisibility ?? HistoryVisibility.shared;

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    _alias.dispose();
    _inviteSearch.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сохранено')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось выполнить действие: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveDetails() => _guard(
        () async {
          await widget.matrix.updateRoomDetails(
            widget.room,
            name: _name.text,
            topic: _topic.text,
          );

          final canChangeAccess = _canShowAccess(widget.matrix.roomKind(
            widget.room,
          ));
          if (canChangeAccess) {
            await widget.matrix.setRoomPublic(widget.room, _public);
            if (_public && _alias.text.trim().isNotEmpty) {
              await widget.matrix.setRoomLocalAlias(widget.room, _alias.text);
            }
          }
          await widget.matrix.setRoomHistoryVisibility(
            widget.room,
            _historyVisibility,
          );
        },
      );

  bool _canShowAccess(OrexRoomKind kind) {
    if (widget.matrix.isSupergroupChild(widget.room)) return false;
    return kind == OrexRoomKind.group ||
        kind == OrexRoomKind.channel ||
        kind == OrexRoomKind.supergroup;
  }

  Future<void> _pickAvatar() async {
    if (_savingAvatar) return;
    setState(() => _savingAvatar = true);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      final file = res?.files.single;
      if (file?.bytes == null) return;
      await widget.matrix.setRoomAvatarBytes(
        widget.room,
        file!.bytes!,
        file.name,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Аватар обновлён')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось обновить аватар: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _savingAvatar = false);
    }
  }

  Future<void> _removeAvatar() => _guard(
        () => widget.matrix.removeRoomAvatar(widget.room),
      );

  Future<void> _inviteSelected() async {
    if (_selectedInviteIds.isEmpty) return;
    final ids = _selectedInviteIds.toList();
    await _guard(() => widget.matrix.inviteUsers(widget.room, ids));
    if (mounted) {
      setState(() {
        _selectedInviteIds.clear();
        _inviteSearch.clear();
      });
    }
  }

  Future<void> _createChild({required bool voice}) async {
    final name = await _askName(voice ? 'Голосовой канал' : 'Чат');
    if (name == null || name.isEmpty) return;
    await _guard(
      () => widget.matrix
          .createSupergroupChild(
            widget.room,
            name,
            voice: voice,
            public: _public,
          )
          .then((_) {}),
    );
    if (mounted) setState(() {});
  }

  Future<void> _editChild(Room child) async {
    final controller =
        TextEditingController(text: child.getLocalizedDisplayname());
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Переименовать чат'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Название'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _guard(
      () => widget.matrix.updateRoomDetails(
        child,
        name: name,
        topic: child.topic,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _changeChildAvatar(Room child) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final file = res?.files.single;
    if (file?.bytes == null) return;
    await _guard(
      () => widget.matrix.setRoomAvatarBytes(child, file!.bytes!, file.name),
    );
    if (mounted) setState(() {});
  }

  Future<void> _deleteChild(Room child) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить чат?'),
        content: Text(
            '«${child.getLocalizedDisplayname()}» будет удалён из супергруппы.'),
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
    if (ok != true) return;
    await _guard(() => widget.matrix.removeSupergroupChild(widget.room, child));
    if (mounted) setState(() {});
  }

  Future<void> _deleteForEveryone() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить для всех?'),
        content: const Text(
          'Владелец выйдет из комнаты, остальные участники будут удалены. '
          'Для супергруппы это также затронет её чаты.',
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
    if (ok != true) return;
    await _guard(() => widget.matrix.deleteRoomForEveryone(widget.room));
    if (mounted) Navigator.pop(context);
  }

  Future<String?> _askName(String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Название'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
  }

  List<User> _localInviteCandidates() {
    final q = _inviteSearch.text.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final existing = widget.room
        .getParticipants(const [Membership.join, Membership.invite])
        .map((user) => user.id)
        .toSet();
    final ownId = widget.matrix.client.userID;
    final usersById = <String, User>{};
    for (final room in widget.matrix.client.rooms) {
      for (final user in room.getParticipants(
        const [Membership.join, Membership.invite],
      )) {
        if (user.id == ownId || existing.contains(user.id)) continue;
        usersById[user.id] = user;
      }
    }
    final users = usersById.values.where((user) {
      final name = user.calcDisplayname().toLowerCase();
      final id = widget.matrix.compactUserId(user.id).toLowerCase();
      return name.contains(q) || id.contains(q);
    }).toList()
      ..sort((a, b) => a.calcDisplayname().compareTo(b.calcDisplayname()));
    return users.take(30).toList();
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final kind = widget.matrix.roomKind(room);
    final isSupergroup = kind == OrexRoomKind.supergroup;
    final canInvite = room.canInvite || room.isSpace;
    final showAccess = _canShowAccess(kind);
    final childRoom = widget.matrix.isSupergroupChild(room);

    return DraggableScrollableSheet(
      initialChildSize: 0.86,
      minChildSize: 0.50,
      maxChildSize: 0.95,
      builder: (context, controller) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Material(
              color:
                  Theme.of(context).colorScheme.surface.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(24),
              child: AbsorbPointer(
                absorbing: _busy,
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                  children: [
                    _Header(
                      matrix: widget.matrix,
                      room: room,
                      busy: _savingAvatar,
                      allowAvatar: !childRoom,
                      onPickAvatar: _pickAvatar,
                      onRemoveAvatar:
                          room.avatar == null ? null : _removeAvatar,
                      onClose: () => Navigator.pop(context),
                    ),
                    const SizedBox(height: 18),
                    _SectionCard(
                      title: 'Профиль',
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                          child: TextField(
                            controller: _name,
                            decoration: const InputDecoration(
                              labelText: 'Название',
                              prefixIcon: Icon(Icons.drive_file_rename_outline),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
                          child: TextField(
                            controller: _topic,
                            minLines: 1,
                            maxLines: 3,
                            decoration: const InputDecoration(
                              labelText: 'Описание',
                              prefixIcon: Icon(Icons.notes),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (showAccess) ...[
                      const SizedBox(height: 18),
                      _SectionCard(
                        title: 'Доступ',
                        children: [
                          SwitchListTile(
                            value: _public,
                            onChanged: (value) =>
                                setState(() => _public = value),
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 14),
                            secondary: Icon(
                              _public ? Icons.public : Icons.lock_outline,
                              color: OrexColors.copper,
                            ),
                            title: Text(_public ? 'Публичная' : 'Приватная'),
                            subtitle: Text(
                              _public
                                  ? 'Можно войти по ID'
                                  : 'Вход только по приглашению',
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                            child: TextField(
                              controller: _alias,
                              enabled: _public,
                              decoration: const InputDecoration(
                                labelText: 'ID',
                                hintText: 'naprimer-chat',
                                prefixIcon: Icon(Icons.tag),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),
                    _SectionCard(
                      title: 'История',
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                          child: DropdownButtonFormField<HistoryVisibility>(
                            initialValue: _historyVisibility,
                            decoration: const InputDecoration(
                              labelText: 'Кто видит старые сообщения',
                              prefixIcon: Icon(Icons.history),
                            ),
                            items: HistoryVisibility.values
                                .map(
                                  (value) => DropdownMenuItem(
                                    value: value,
                                    child: Text(_historyLabel(value)),
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              if (value == null) return;
                              setState(() => _historyVisibility = value);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _SaveBar(onSave: _saveDetails),
                    const SizedBox(height: 18),
                    _SectionCard(
                      title: 'Участники',
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                          child: TextField(
                            controller: _inviteSearch,
                            enabled: canInvite,
                            decoration: const InputDecoration(
                              labelText: 'Найти пользователя',
                              prefixIcon: Icon(Icons.person_add),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        _InvitePicker(
                          matrix: widget.matrix,
                          users: _localInviteCandidates(),
                          selectedIds: _selectedInviteIds,
                          enabled: canInvite,
                          hasQuery: _inviteSearch.text.trim().isNotEmpty,
                          onChanged: () => setState(() {}),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                          child: OutlinedButton.icon(
                            onPressed:
                                canInvite && _selectedInviteIds.isNotEmpty
                                    ? _inviteSelected
                                    : null,
                            icon: const Icon(Icons.send),
                            label: Text(
                              _selectedInviteIds.isEmpty
                                  ? 'Выберите участников'
                                  : 'Пригласить: ${_selectedInviteIds.length}',
                            ),
                          ),
                        ),
                        FutureBuilder<List<User>>(
                          future: room.requestParticipants(
                            const [Membership.join, Membership.invite],
                          ),
                          builder: (context, snap) {
                            final users = snap.data;
                            if (users == null) {
                              return const Padding(
                                padding: EdgeInsets.all(18),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                            return Column(
                              children: users.take(80).map((user) {
                                final name = user.calcDisplayname();
                                final owner = widget.matrix
                                    .isOwnerPowerLevel(user.powerLevel);
                                return ListTile(
                                  leading: MxcAvatar(
                                    matrix: widget.matrix,
                                    name: name,
                                    mxc: user.avatarUrl,
                                    size: 38,
                                  ),
                                  title: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    widget.matrix.compactUserId(user.id),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: owner
                                      ? const _RoleChip('Владелец')
                                      : null,
                                );
                              }).toList(),
                            );
                          },
                        ),
                      ],
                    ),
                    if (isSupergroup) ...[
                      const SizedBox(height: 18),
                      _SupergroupRoomsSection(
                        matrix: widget.matrix,
                        room: room,
                        onAddChat: () => _createChild(voice: false),
                        onAddVoice: () => _createChild(voice: true),
                        onEditChild: _editChild,
                        onAvatarChild: _changeChildAvatar,
                        onDeleteChild: _deleteChild,
                      ),
                    ],
                    if (widget.matrix.canFullyDeleteRoom(room)) ...[
                      const SizedBox(height: 18),
                      _DangerZone(onDeleteForEveryone: _deleteForEveryone),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _historyLabel(HistoryVisibility visibility) => switch (visibility) {
      HistoryVisibility.invited => 'С момента приглашения',
      HistoryVisibility.joined => 'С момента входа',
      HistoryVisibility.shared => 'С общей историей комнаты',
      HistoryVisibility.worldReadable => 'Видна всем',
    };

class _Header extends StatelessWidget {
  const _Header({
    required this.matrix,
    required this.room,
    required this.busy,
    required this.allowAvatar,
    required this.onPickAvatar,
    required this.onRemoveAvatar,
    required this.onClose,
  });

  final MatrixService matrix;
  final Room room;
  final bool busy;
  final bool allowAvatar;
  final VoidCallback onPickAvatar;
  final VoidCallback? onRemoveAvatar;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final name = room.getLocalizedDisplayname();
    return Row(
      children: [
        Stack(
          children: [
            MxcAvatar(matrix: matrix, name: name, mxc: room.avatar, size: 64),
            if (allowAvatar)
              Positioned.fill(
                child: Material(
                  color: Colors.black.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: busy ? null : onPickAvatar,
                    child: Center(
                      child: busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.photo_camera_outlined,
                              color: OrexColors.cream,
                            ),
                    ),
                  ),
                ),
              ),
          ],
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
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ],
          ),
        ),
        if (allowAvatar)
          IconButton(
            tooltip: 'Убрать аватар',
            onPressed: onRemoveAvatar,
            icon: const Icon(Icons.no_photography_outlined),
          ),
        IconButton(
          tooltip: 'Закрыть',
          onPressed: onClose,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({required this.onSave});
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: FilledButton.icon(
        onPressed: onSave,
        icon: const Icon(Icons.save),
        label: const Text('Сохранить'),
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
    return _SectionCard(
      title: 'Опасная зона',
      children: [
        ListTile(
          leading: const Icon(
            Icons.delete_forever,
            color: Color(0xFFCF6679),
          ),
          title: const Text(
            'Удалить для всех',
            style: TextStyle(color: Color(0xFFCF6679)),
          ),
          subtitle: const Text('Доступно владельцу комнаты'),
          trailing: const Icon(Icons.chevron_right),
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
    required this.onAddVoice,
    required this.onEditChild,
    required this.onAvatarChild,
    required this.onDeleteChild,
  });

  final MatrixService matrix;
  final Room room;
  final VoidCallback onAddChat;
  final VoidCallback onAddVoice;
  final ValueChanged<Room> onEditChild;
  final ValueChanged<Room> onAvatarChild;
  final ValueChanged<Room> onDeleteChild;

  @override
  Widget build(BuildContext context) {
    final children = matrix.supergroupChildren(room);
    return _SectionCard(
      title: 'Чаты супергруппы',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onAddChat,
                  icon: const Icon(Icons.forum),
                  label: const Text('Добавить чат'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onAddVoice,
                  icon: const Icon(Icons.graphic_eq),
                  label: const Text('Голосовой'),
                ),
              ),
            ],
          ),
        ),
        if (children.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 4, 14, 14),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Пока нет отдельных чатов'),
            ),
          )
        else
          ...children.map(
            (child) => ListTile(
              leading: MxcAvatar(
                matrix: matrix,
                name: child.getLocalizedDisplayname(),
                mxc: child.avatar,
                size: 38,
              ),
              title: Text(
                child.getLocalizedDisplayname(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                matrix.isVoiceRoom(child) ? 'Голосовой канал' : 'Текстовый чат',
              ),
              trailing: Wrap(
                spacing: 2,
                children: [
                  IconButton(
                    tooltip: 'Переименовать',
                    onPressed: () => onEditChild(child),
                    icon: const Icon(Icons.edit),
                  ),
                  IconButton(
                    tooltip: 'Иконка',
                    onPressed: () => onAvatarChild(child),
                    icon: const Icon(Icons.image_outlined),
                  ),
                  IconButton(
                    tooltip: 'Удалить',
                    onPressed: () => onDeleteChild(child),
                    icon: const Icon(Icons.delete_outline),
                    color: const Color(0xFFCF6679),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  letterSpacing: 1.1,
                  color: OrexColors.copper,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        GlassPanel(
          borderRadius: 20,
          child: Column(children: children),
        ),
      ],
    );
  }
}
