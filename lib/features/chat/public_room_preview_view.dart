import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../core/matrix/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../widgets/mxc_avatar.dart';
import '../../widgets/room_icon.dart';

class PublicRoomPreviewView extends StatefulWidget {
  const PublicRoomPreviewView({
    super.key,
    required this.matrix,
    required this.preview,
    required this.onJoined,
    this.onBack,
    this.parentSpace,
    this.supergroupChildren = const <OrexRoomPreview>[],
    this.onSupergroupChildSelected,
  });

  final MatrixService matrix;
  final OrexRoomPreview preview;
  final ValueChanged<String> onJoined;
  final VoidCallback? onBack;
  final Room? parentSpace;
  final List<OrexRoomPreview> supergroupChildren;
  final ValueChanged<String>? onSupergroupChildSelected;

  @override
  State<PublicRoomPreviewView> createState() => _PublicRoomPreviewViewState();
}

class _PublicRoomPreviewViewState extends State<PublicRoomPreviewView> {
  late Future<List<MatrixEvent>> _events = _loadEvents();
  bool _joining = false;

  @override
  void didUpdateWidget(PublicRoomPreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview.roomId != widget.preview.roomId) {
      _events = _loadEvents();
    }
  }

  Future<List<MatrixEvent>> _loadEvents() async {
    try {
      final res = await widget.matrix.client.getRoomEvents(
        widget.preview.roomId,
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
      final roomId = await widget.matrix.joinRoomPreview(widget.preview);
      if (mounted) widget.onJoined(roomId);
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
    final preview = widget.preview;
    final parent = widget.parentSpace;
    final children = widget.supergroupChildren;
    final title = parent?.getLocalizedDisplayname() ?? preview.name;
    final avatar = parent?.avatar ?? preview.avatar;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
          child: Row(
            children: [
              if (widget.onBack != null)
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
              MxcAvatar(
                matrix: widget.matrix,
                name: title,
                mxc: avatar,
                size: 42,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (parent != null && children.isNotEmpty)
                      _PreviewChildPicker(
                        matrix: widget.matrix,
                        value: preview.roomId,
                        children: children,
                        onChanged: widget.onSupergroupChildSelected,
                      )
                    else
                      Text(
                        _subtitle(preview),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: OrexColors.copper.withValues(alpha: 0.12)),
        _PreviewHeader(
          matrix: widget.matrix,
          preview: preview,
          parentSpace: parent,
        ),
        Expanded(
          child: FutureBuilder<List<MatrixEvent>>(
            future: _events,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(
                  child: CircularProgressIndicator(color: OrexColors.copper),
                );
              }
              final events = snap.data ?? const <MatrixEvent>[];
              if (events.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      preview.isSupergroupChild
                          ? 'История этого чата будет доступна после входа.'
                          : 'В этом публичном чате пока нет доступной истории.',
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
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
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
    );
  }

  String _subtitle(OrexRoomPreview preview) {
    final members = preview.memberCount;
    final memberLine = members == null ? null : '$members участников';
    final alias = preview.alias;
    return alias?.isNotEmpty == true
        ? [alias, memberLine].whereType<String>().join(' · ')
        : memberLine ?? preview.roomId;
  }
}

class _PreviewChildPicker extends StatelessWidget {
  const _PreviewChildPicker({
    required this.matrix,
    required this.value,
    required this.children,
    required this.onChanged,
  });

  final MatrixService matrix;
  final String value;
  final List<OrexRoomPreview> children;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: children.any((child) => child.roomId == value)
            ? value
            : children.first.roomId,
        isDense: true,
        isExpanded: true,
        iconSize: 18,
        items: children
            .map(
              (child) => DropdownMenuItem(
                value: child.roomId,
                child: Row(
                  children: [
                    Icon(_icon(child), size: 16, color: OrexColors.copper),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        child.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
        onChanged: (next) {
          if (next == null || next == value) return;
          onChanged?.call(next);
        },
      ),
    );
  }

  IconData _icon(OrexRoomPreview child) {
    final local = matrix.client.getRoomById(child.roomId);
    if (local == null) return Icons.forum;
    return orexRoomIconData(matrix.roomIconKey(local));
  }
}

class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({
    required this.matrix,
    required this.preview,
    required this.parentSpace,
  });

  final MatrixService matrix;
  final OrexRoomPreview preview;
  final Room? parentSpace;

  @override
  Widget build(BuildContext context) {
    final topic = preview.topic;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: GlassPanel(
        borderRadius: 20,
        opacity: 0.26,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              MxcAvatar(
                matrix: matrix,
                name: preview.name,
                mxc: preview.avatar,
                size: 54,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preview.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      parentSpace == null
                          ? 'Публичная комната'
                          : 'Чат внутри супергруппы',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (topic != null && topic.isNotEmpty)
                      Text(
                        topic,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
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
          color: isDark ? OrexColors.darkBubbleIn : OrexColors.lightBubbleIn,
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
