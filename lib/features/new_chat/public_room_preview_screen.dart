import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';

class PublicRoomPreviewScreen extends StatefulWidget {
  const PublicRoomPreviewScreen({
    super.key,
    required this.matrix,
    required this.room,
  });

  final MatrixService matrix;
  final PublishedRoomsChunk room;

  @override
  State<PublicRoomPreviewScreen> createState() =>
      _PublicRoomPreviewScreenState();
}

class _PublicRoomPreviewScreenState extends State<PublicRoomPreviewScreen> {
  late final Future<List<MatrixEvent>> _events = _loadEvents();
  bool _joining = false;

  Future<List<MatrixEvent>> _loadEvents() async {
    try {
      final res = await widget.matrix.client.getRoomEvents(
        widget.room.roomId,
        Direction.b,
        limit: 30,
      );
      return res.chunk
          .where((event) => event.type == EventTypes.Message)
          .where((event) => event.content['body'] is String)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _join() async {
    if (_joining) return;
    setState(() => _joining = true);
    try {
      final roomId = await widget.matrix.joinPublicRoom(widget.room);
      if (mounted) Navigator.pop(context, roomId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось вступить: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final name = room.name ?? room.canonicalAlias ?? room.roomId;
    final topic = room.topic;
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: const Text('Предпросмотр'),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: GlassPanel(
                borderRadius: 18,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      MxcAvatar(
                        matrix: widget.matrix,
                        name: name,
                        mxc: room.avatarUrl,
                        size: 58,
                      ),
                      const SizedBox(width: 14),
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
                            const SizedBox(height: 4),
                            Text(
                              '${room.numJoinedMembers} участников',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            if (topic != null && topic.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                topic,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<List<MatrixEvent>>(
                future: _events,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: OrexColors.copper,
                      ),
                    );
                  }
                  final events = snap.data ?? const <MatrixEvent>[];
                  if (events.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          room.worldReadable
                              ? 'История пока пустая или сервер не отдал предпросмотр.'
                              : 'История будет доступна после вступления.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    itemCount: events.length,
                    itemBuilder: (context, index) {
                      final event = events[index];
                      final body = event.content['body']?.toString() ?? '';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GlassPanel(
                          borderRadius: 14,
                          opacity: 0.32,
                          child: ListTile(
                            title: Text(
                              widget.matrix.compactUserId(event.senderId),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            subtitle: Text(body),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: OrexColors.copper,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _joining ? null : _join,
                  icon: _joining
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: OrexColors.cream,
                          ),
                        )
                      : const Icon(Icons.login),
                  label: Text(_joining ? 'Вступаем...' : 'Вступить'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
