import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
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
  final _invite = TextEditingController();
  bool _busy = false;
  late bool _public = widget.matrix.isPublicRoom(widget.room);

  @override
  void dispose() {
    _name.dispose();
    _topic.dispose();
    _invite.dispose();
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
        () => widget.matrix.updateRoomDetails(
          widget.room,
          name: _name.text,
          topic: _topic.text,
        ),
      );

  Future<void> _inviteUsers() async {
    final ids = _invite.text
        .split(RegExp(r'[\s,;]+'))
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    if (ids.isEmpty) return;
    await _guard(() => widget.matrix.inviteUsers(widget.room, ids));
    _invite.clear();
  }

  Future<void> _setPublic(bool value) => _guard(() async {
        await widget.matrix.setChannelPublic(widget.room, value);
        if (mounted) setState(() => _public = value);
      });

  Future<void> _createChild({required bool voice}) async {
    final name = await _askName(voice ? 'Голосовой канал' : 'Чат');
    if (name == null || name.isEmpty) return;
    await _guard(
      () => widget.matrix
          .createSupergroupChild(
            widget.room,
            name,
            voice: voice,
          )
          .then((_) {}),
    );
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

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final isChannel = widget.matrix.isChannel(room);
    final isSupergroup = widget.matrix.isSupergroup(room);

    return DraggableScrollableSheet(
      initialChildSize: 0.82,
      minChildSize: 0.45,
      maxChildSize: 0.94,
      builder: (context, controller) {
        return Material(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: SafeArea(
            top: false,
            child: AbsorbPointer(
              absorbing: _busy,
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                children: [
                  Row(
                    children: [
                      MxcAvatar(
                        matrix: widget.matrix,
                        name: room.getLocalizedDisplayname(),
                        mxc: room.avatar,
                        size: 52,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          room.getLocalizedDisplayname(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Закрыть',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Название',
                      prefixIcon: Icon(Icons.drive_file_rename_outline),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _topic,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Описание',
                      prefixIcon: Icon(Icons.notes),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _saveDetails,
                    icon: const Icon(Icons.save),
                    label: const Text('Сохранить описание'),
                  ),
                  if (isChannel) ...[
                    const SizedBox(height: 18),
                    SwitchListTile(
                      value: _public,
                      onChanged: _setPublic,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Публичный канал'),
                      subtitle: Text(
                        _public
                            ? 'Можно входить без приглашения'
                            : 'Вход только по приглашению',
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  TextField(
                    controller: _invite,
                    decoration: const InputDecoration(
                      labelText: 'Добавить участников',
                      hintText: '@user:server через пробел или запятую',
                      prefixIcon: Icon(Icons.person_add),
                    ),
                    onSubmitted: (_) => _inviteUsers(),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed:
                        room.canInvite || room.isSpace ? _inviteUsers : null,
                    icon: const Icon(Icons.send),
                    label: const Text('Отправить приглашения'),
                  ),
                  if (isSupergroup) ...[
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _createChild(voice: false),
                            icon: const Icon(Icons.forum),
                            label: const Text('Добавить чат'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _createChild(voice: true),
                            icon: const Icon(Icons.graphic_eq),
                            label: const Text('Голосовой'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 22),
                  Text(
                    'Участники',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: OrexColors.copper,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
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
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
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
                              user.id,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                      );
                    },
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
