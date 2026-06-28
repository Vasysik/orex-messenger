import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../core/orex_logger.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import '../../widgets/orex_loading_overlay.dart';
import '../../widgets/orex_settings_components.dart';
import '../../widgets/room_icon.dart';

part 'room_settings_components.dart';

class RoomSettingsScreen extends StatefulWidget {
  const RoomSettingsScreen({
    super.key,
    required this.matrix,
    required this.room,
  });

  final MatrixService matrix;
  final Room room;

  @override
  State<RoomSettingsScreen> createState() => _RoomSettingsScreenState();
}

class _RoomSettingsScreenState extends State<RoomSettingsScreen> {
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
      OrexLog.d('RoomSettings', 'action failed room=${widget.room.id}', e);
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
          final canChangeName =
              widget.room.canChangeStateEvent(EventTypes.RoomName);
          final canChangeTopic =
              widget.room.canChangeStateEvent(EventTypes.RoomTopic);
          if (canChangeName || canChangeTopic) {
            await widget.matrix.updateRoomDetails(
              widget.room,
              name: canChangeName
                  ? _name.text
                  : widget.room.getLocalizedDisplayname(),
              topic: canChangeTopic ? _topic.text : widget.room.topic,
            );
          }

          final canChangeAccess = _canShowAccess(
                widget.matrix.roomKind(widget.room),
              ) &&
              widget.room.canChangeJoinRules;
          if (canChangeAccess) {
            await widget.matrix.setRoomPublic(widget.room, _public);
            if (_public && _alias.text.trim().isNotEmpty) {
              await widget.matrix.setRoomLocalAlias(widget.room, _alias.text);
            }
          }
          if (widget.room.canChangeHistoryVisibility) {
            await widget.matrix.setRoomHistoryVisibility(
              widget.room,
              _historyVisibility,
            );
          }
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
      OrexLog.d('RoomSettings', 'action failed room=${widget.room.id}', e);
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

  Future<void> _removeParticipant(User user) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить участника?'),
        content: Text(
          widget.room.isSpace
              ? 'Убрать ${user.calcDisplayname()} из супергруппы и всех её чатов?'
              : 'Убрать ${user.calcDisplayname()} из комнаты?',
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
    await _guard(() => widget.matrix.removeUserFromRoom(widget.room, user));
    if (mounted) setState(() {});
  }

  Future<void> _createChild() async {
    final details = await _askChildDetails();
    if (details == null || details.name.isEmpty) return;
    OrexLog.d('RoomSettings', 'create child name=${details.name} icon=${details.icon} space=${widget.room.id}');
    await _guard(
      () => widget.matrix
          .createSupergroupChild(
            widget.room,
            details.name,
            icon: details.icon,
            public: _public,
          )
          .then((_) {}),
    );
    if (mounted) setState(() {});
  }

  Future<({String name, String icon})?> _askChildDetails() async {
    final controller = TextEditingController();
    var iconKey = 'chat';
    final result = await showDialog<({String name, String icon})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Новый чат'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: iconKey,
                  decoration: const InputDecoration(
                    labelText: 'Значок',
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  items: orexRoomIconChoices
                      .map(
                        (choice) => DropdownMenuItem(
                          value: choice.key,
                          child: Row(
                            children: [
                              Icon(choice.icon, size: 18),
                              const SizedBox(width: 8),
                              Text(choice.label),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => iconKey = value);
                  },
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
              onPressed: () => Navigator.pop(
                ctx,
                (name: controller.text.trim(), icon: iconKey),
              ),
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
    return result;
  }

  Future<void> _editChild(Room child) async {
    final controller =
        TextEditingController(text: child.getLocalizedDisplayname());
    var iconKey = widget.matrix.roomIconKey(child);
    final result = await showDialog<({String name, String icon})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Редактировать чат'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: iconKey,
                  decoration: const InputDecoration(
                    labelText: 'Значок',
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  items: orexRoomIconChoices
                      .map(
                        (choice) => DropdownMenuItem(
                          value: choice.key,
                          child: Row(
                            children: [
                              Icon(choice.icon, size: 18),
                              const SizedBox(width: 8),
                              Text(choice.label),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setDialogState(() => iconKey = value);
                  },
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
              onPressed: () => Navigator.pop(
                ctx,
                (name: controller.text.trim(), icon: iconKey),
              ),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller.dispose();
    });
    if (result == null || result.name.isEmpty) return;
    await _guard(
      () async {
        await widget.matrix.updateRoomDetails(
          child,
          name: result.name,
          topic: child.topic,
        );
        await widget.matrix.setRoomIcon(child, result.icon);
        await widget.matrix.updateSupergroupChildPreview(
          widget.room,
          child,
          name: result.name,
          icon: result.icon,
        );
      },
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
    final childRoom = widget.matrix.isSupergroupChild(room);
    final canManage = widget.matrix.canManageRoomSettings(room);
    final canChangeName =
        canManage && room.canChangeStateEvent(EventTypes.RoomName);
    final canChangeTopic =
        canManage && room.canChangeStateEvent(EventTypes.RoomTopic);
    final canChangeAvatar =
        canManage && !childRoom && room.canChangeStateEvent(EventTypes.RoomAvatar);
    final canEditProfile =
        !childRoom && (canChangeName || canChangeTopic || canChangeAvatar);
    final canInvite = canManage && room.canInvite;
    final canChangeAccess =
        canManage && _canShowAccess(kind) && room.canChangeJoinRules;
    final showHistory = canManage && room.canChangeHistoryVisibility;
    final showAccess = canChangeAccess || showHistory;
    final showSave = canEditProfile || showAccess || showHistory;
    final canManageSupergroupRooms =
        canManage && isSupergroup && room.canChangeStateEvent(EventTypes.SpaceChild);

    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Настройки чата'),
        ),
        body: Stack(
          children: [
            AbsorbPointer(
              absorbing: _busy,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _RoomProfileCard(
                    matrix: widget.matrix,
                    room: room,
                    kindLabel: _roomKindLabel(kind),
                    busy: _savingAvatar,
                    allowAvatar: canChangeAvatar,
                    onAvatar: _pickAvatar,
                    onRemoveAvatar: room.avatar == null ? null : _removeAvatar,
                  ),
                  if (canEditProfile) ...[
                    const SizedBox(height: 16),
                    OrexSettingsSection(
                      title: 'Профиль',
                      children: [
                        if (canChangeName)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                            child: TextField(
                              controller: _name,
                              decoration: const InputDecoration(
                                labelText: 'Название',
                                prefixIcon:
                                    Icon(Icons.drive_file_rename_outline),
                              ),
                            ),
                          ),
                        if (canChangeTopic)
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
                  ],
                  if (showAccess) ...[
                    const SizedBox(height: 16),
                    OrexSettingsSection(
                      title: 'Доступ',
                      children: [
                        if (canChangeAccess) ...[
                          SwitchListTile(
                            value: _public,
                            onChanged: (value) => setState(() => _public = value),
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
                        if (canChangeAccess && showHistory)
                          const Divider(height: 1),
                        if (showHistory)
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
                  ],
                  if (showSave) ...[
                    const SizedBox(height: 12),
                    OrexSettingsSaveBar(onSave: _saveDetails),
                  ],
                  const SizedBox(height: 16),
                  OrexSettingsSection(
                    title: 'Участники',
                    children: [
                      FutureBuilder<List<User>>(
                        future: room.requestParticipants(
                          const [Membership.join, Membership.invite],
                        ),
                        builder: (context, snap) {
                          final users = snap.data;
                          if (users == null) {
                            return const Padding(
                              padding: EdgeInsets.all(18),
                              child: Center(child: CircularProgressIndicator()),
                            );
                          }
                          return Column(
                            children: users.take(80).map((user) {
                              final name = user.calcDisplayname();
                              final owner = widget.matrix
                                  .isOwnerPowerLevel(user.powerLevel);
                              final canRemove = canManage &&
                                  user.canKick &&
                                  user.id != widget.matrix.client.userID;
                              final trailing = <Widget>[
                                if (owner) const _RoleChip('Владелец'),
                                if (canRemove)
                                  IconButton(
                                    tooltip: 'Удалить участника',
                                    onPressed: () => _removeParticipant(user),
                                    icon: const Icon(Icons.person_remove),
                                    color: const Color(0xFFCF6679),
                                  ),
                              ];
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
                                trailing: trailing.isEmpty
                                    ? null
                                    : Wrap(
                                        spacing: 6,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: trailing,
                                      ),
                              );
                            }).toList(),
                          );
                        },
                      ),
                      if (canInvite) ...[
                        const Divider(height: 1),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
                          child: TextField(
                            controller: _inviteSearch,
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
                          child: SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: _selectedInviteIds.isNotEmpty
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
                        ),
                      ],
                    ],
                  ),
                  if (canManageSupergroupRooms) ...[
                    const SizedBox(height: 16),
                    _SupergroupRoomsSection(
                      matrix: widget.matrix,
                      room: room,
                      onAddChat: _createChild,
                      onEditChild: _editChild,
                      onDeleteChild: _deleteChild,
                    ),
                  ],
                  if (widget.matrix.canFullyDeleteRoom(room)) ...[
                    const SizedBox(height: 16),
                    _DangerZone(onDeleteForEveryone: _deleteForEveryone),
                  ],
                  const SizedBox(height: 24),
                ],
              ),
            ),
            if (_busy) const OrexLoadingOverlay(),
          ],
        ),
      ),
    );
  }
}