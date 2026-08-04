import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../../core/logging/orex_logger.dart';
import '../../../core/matrix/matrix_service.dart';
import '../../../core/matrix/message_forwarding_service.dart';
import '../../../shared/theme/orex_theme.dart';
import '../../../shared/widgets/mxc_avatar.dart';

Future<List<Room>?> showOrexForwardRoomPicker(
  BuildContext context, {
  required MatrixService matrix,
  required String sourceRoomId,
}) {
  return showDialog<List<Room>>(
    context: context,
    builder: (_) => _ForwardRoomPickerDialog(
      matrix: matrix,
      sourceRoomId: sourceRoomId,
    ),
  );
}

Future<OrexForwardResult?> showOrexForwardProgressDialog(
  BuildContext context, {
  required MatrixService matrix,
  required List<Event> events,
  required Timeline? timeline,
  required List<Room> targets,
}) {
  return showDialog<OrexForwardResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ForwardProgressDialog(
      matrix: matrix,
      events: events,
      timeline: timeline,
      targets: targets,
    ),
  );
}

class _ForwardRoomPickerDialog extends StatefulWidget {
  const _ForwardRoomPickerDialog({
    required this.matrix,
    required this.sourceRoomId,
  });

  final MatrixService matrix;
  final String sourceRoomId;

  @override
  State<_ForwardRoomPickerDialog> createState() =>
      _ForwardRoomPickerDialogState();
}

class _ForwardRoomPickerDialogState extends State<_ForwardRoomPickerDialog> {
  final Set<String> _selected = <String>{};
  String _query = '';
  String? _limitMessage;

  List<Room> get _availableRooms => widget.matrix.rooms.where((room) {
    if (room.id == widget.sourceRoomId ||
        room.membership != Membership.join ||
        room.isSpace ||
        !widget.matrix.canSendMessages(room)) {
      return false;
    }
    final query = _query.trim().toLowerCase();
    return query.isEmpty ||
        room.getLocalizedDisplayname().toLowerCase().contains(query);
  }).toList(growable: false);

  void _toggle(Room room, bool selected) {
    setState(() {
      _limitMessage = null;
      if (selected) {
        if (_selected.length >= orexForwardMaxTargetsPerOperation) {
          _limitMessage = 'Можно выбрать не больше '
              '$orexForwardMaxTargetsPerOperation чатов.';
          return;
        }
        _selected.add(room.id);
      } else {
        _selected.remove(room.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rooms = _availableRooms;
    final mediaQuery = MediaQuery.of(context);
    final viewport = mediaQuery.size;
    final availableHeight = viewport.height - mediaQuery.viewInsets.bottom;
    final rawWidth = viewport.width - 128;
    final rawHeight = availableHeight - 220;
    final contentWidth = rawWidth.clamp(160.0, 460.0).toDouble();
    final contentHeight = rawHeight.clamp(120.0, 520.0).toDouble();
    return AlertDialog(
      title: const Text('Переслать сообщение'),
      content: SizedBox(
        width: contentWidth,
        height: contentHeight,
        child: Column(
          children: [
            TextField(
              autofocus: viewport.width >= 600,
              decoration: const InputDecoration(
                hintText: 'Поиск по чатам',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            if (_limitMessage != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _limitMessage!,
                  style: const TextStyle(color: Color(0xFFCF6679)),
                ),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: rooms.isEmpty
                  ? const Center(child: Text('Нет доступных чатов'))
                  : ListView.builder(
                      itemCount: rooms.length,
                      itemBuilder: (context, index) {
                        final room = rooms[index];
                        final name = room.getLocalizedDisplayname();
                        return CheckboxListTile(
                          value: _selected.contains(room.id),
                          onChanged: (value) => _toggle(room, value == true),
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
                          subtitle: Text(_roomKindLabel(room)),
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
        FilledButton.icon(
          onPressed: _selected.isEmpty
              ? null
              : () {
                  final selectedRooms = widget.matrix.rooms
                      .where((room) => _selected.contains(room.id))
                      .toList(growable: false);
                  Navigator.pop(context, selectedRooms);
                },
          icon: const Icon(Icons.forward),
          label: Text(
            _selected.isEmpty ? 'Переслать' : 'Переслать (${_selected.length})',
          ),
        ),
      ],
    );
  }

  String _roomKindLabel(Room room) => switch (widget.matrix.roomKind(room)) {
    OrexRoomKind.direct => 'Личный чат',
    OrexRoomKind.group => 'Группа',
    OrexRoomKind.channel => 'Канал',
    OrexRoomKind.supergroup => 'Супергруппа',
  };
}

class _ForwardProgressDialog extends StatefulWidget {
  const _ForwardProgressDialog({
    required this.matrix,
    required this.events,
    required this.timeline,
    required this.targets,
  });

  final MatrixService matrix;
  final List<Event> events;
  final Timeline? timeline;
  final List<Room> targets;

  @override
  State<_ForwardProgressDialog> createState() => _ForwardProgressDialogState();
}

class _ForwardProgressDialogState extends State<_ForwardProgressDialog> {
  final OrexForwardCancellation _cancellation = OrexForwardCancellation();
  var _completed = 0;
  var _total = 0;
  String _roomName = '';
  bool _cancelling = false;

  @override
  void initState() {
    super.initState();
    _total = widget.events.length * widget.targets.length;
    scheduleMicrotask(() => unawaited(_run()));
  }

  Future<void> _run() async {
    late final OrexForwardResult result;
    try {
      result = await OrexMessageForwarder(widget.matrix).forward(
        events: widget.events,
        timeline: widget.timeline,
        targets: widget.targets,
        cancellation: _cancellation,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _completed = progress.completed;
            _total = progress.total;
            _roomName = progress.roomName;
          });
        },
      );
    } catch (error, stackTrace) {
      OrexLog.d('Forward', 'unexpected forwarding failure', error, stackTrace);
      result = const OrexForwardResult(
        sentMessages: 0,
        completedRooms: 0,
        failures: <OrexForwardFailure>[],
        cancelled: false,
        fatalError: 'Не удалось завершить пересылку.',
      );
    }
    if (mounted) Navigator.pop(context, result);
  }

  void _cancel() {
    _cancellation.cancel();
    setState(() => _cancelling = true);
  }

  @override
  void dispose() {
    _cancellation.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total <= 0
        ? null
        : (_completed / _total).clamp(0.0, 1.0).toDouble();
    final dialogWidth = (MediaQuery.sizeOf(context).width - 128)
        .clamp(160.0, 380.0)
        .toDouble();
    final String status;
    if (_cancelling) {
      status = 'Текущая короткая отправка завершится, '
          'новые чаты обрабатываться не будут.';
    } else if (_roomName.isEmpty) {
      status = 'Подготовка сообщения…';
    } else {
      status = 'Отправка в «$_roomName»';
    }
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(_cancelling ? 'Останавливаем пересылку' : 'Пересылка'),
        content: SizedBox(
          width: dialogWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(
                value: progress,
                color: OrexColors.copper,
              ),
              const SizedBox(height: 14),
              Text(status),
              const SizedBox(height: 6),
              Text(
                '$_completed из $_total',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _cancelling ? null : _cancel,
            child: const Text('Отменить'),
          ),
        ],
      ),
    );
  }
}
