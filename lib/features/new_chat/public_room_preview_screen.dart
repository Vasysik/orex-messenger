import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
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
        limit: 50,
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
          SnackBar(content: Text('Не удалось войти: $e')),
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
    final memberCount = room.numJoinedMembers;

    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        body: Column(
          children: [
            _PublicRoomPreviewHeader(
              matrix: widget.matrix,
              name: name,
              avatar: room.avatarUrl,
              topic: topic,
              memberCount: memberCount,
            ),
            Divider(
              height: 1,
              color: OrexColors.copper.withValues(alpha: 0.12),
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
                              ? 'В этом чате пока нет сообщений или сервер не отдал историю.'
                              : 'История будет доступна после входа.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    reverse: true,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 8,
                    ),
                    itemCount: events.length,
                    itemBuilder: (context, index) => _PublicPreviewBubble(
                      matrix: widget.matrix,
                      event: events[index],
                    ),
                  );
                },
              ),
            ),
            _JoinPublicRoomBar(joining: _joining, onJoin: _join),
          ],
        ),
      ),
    );
  }
}

class _PublicRoomPreviewHeader extends StatelessWidget {
  const _PublicRoomPreviewHeader({
    required this.matrix,
    required this.name,
    required this.avatar,
    required this.topic,
    required this.memberCount,
  });

  final MatrixService matrix;
  final String name;
  final Uri? avatar;
  final String? topic;
  final int memberCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
      child: Row(
        children: [
          MxcAvatar(matrix: matrix, name: name, mxc: avatar, size: 42),
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
                Text(
                  '$memberCount участников',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (topic != null && topic!.isNotEmpty)
                  Text(
                    topic!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PublicPreviewBubble extends StatelessWidget {
  const _PublicPreviewBubble({required this.matrix, required this.event});

  final MatrixService matrix;
  final MatrixEvent event;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final body = event.content['body']?.toString() ?? '';
    final textColor = isDark ? OrexColors.darkText : OrexColors.lightText;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
        padding: const EdgeInsets.fromLTRB(14, 9, 12, 7),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.62,
        ),
        decoration: BoxDecoration(
          color: (isDark ? OrexColors.darkBubbleIn : OrexColors.lightBubbleIn),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomLeft: Radius.circular(6),
            bottomRight: Radius.circular(18),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.06),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              matrix.compactUserId(event.senderId),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: OrexColors.copper,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 2),
            Text(body, style: TextStyle(color: textColor, height: 1.3)),
          ],
        ),
      ),
    );
  }
}

class _JoinPublicRoomBar extends StatelessWidget {
  const _JoinPublicRoomBar({required this.joining, required this.onJoin});

  final bool joining;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
        child: GlassPanel(
          borderRadius: 22,
          opacity: 0.34,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: OrexColors.copper,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: joining ? null : onJoin,
              icon: joining
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: OrexColors.cream,
                      ),
                    )
                  : const Icon(Icons.login),
              label: Text(joining ? 'Входим...' : 'Войти в чат'),
            ),
          ),
        ),
      ),
    );
  }
}
