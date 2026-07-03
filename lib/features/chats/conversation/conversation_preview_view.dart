import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../../core/matrix/matrix_service.dart';
import '../../../shared/theme/glass.dart';
import '../../../shared/theme/orex_theme.dart';
import '../../../shared/widgets/mxc_avatar.dart';
import 'supergroup_child_picker.dart';

class ConversationPreviewView extends StatefulWidget {
  const ConversationPreviewView({
    super.key,
    required this.matrix,
    required this.preview,
    required this.onEnter,
    required this.onEntered,
    this.onBack,
    this.parentSpace,
    this.supergroupChildren = const <OrexRoomPreview>[],
    this.onSupergroupChildSelected,
  });

  final MatrixService matrix;
  final OrexConversationPreview preview;
  final Future<String> Function(OrexConversationPreview preview) onEnter;
  final ValueChanged<String> onEntered;
  final VoidCallback? onBack;
  final Room? parentSpace;
  final List<OrexRoomPreview> supergroupChildren;
  final ValueChanged<String>? onSupergroupChildSelected;

  @override
  State<ConversationPreviewView> createState() =>
      _ConversationPreviewViewState();
}

class _ConversationPreviewViewState extends State<ConversationPreviewView> {
  late Future<List<MatrixEvent>> _events = _loadEvents();
  bool _entering = false;

  @override
  void didUpdateWidget(ConversationPreviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preview.key != widget.preview.key) {
      _events = _loadEvents();
    }
  }

  Future<List<MatrixEvent>> _loadEvents() async {
    final roomId = widget.preview.historyRoomId;
    if (roomId == null || roomId.isEmpty) return const [];
    try {
      final res = await widget.matrix.client.getRoomEvents(
        roomId,
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

  Future<void> _enter() async {
    if (_entering) return;
    setState(() => _entering = true);
    try {
      final roomId = await widget.onEnter(widget.preview);
      if (mounted) widget.onEntered(roomId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не удалось войти: $e')));
      }
    } finally {
      if (mounted) setState(() => _entering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final parent = widget.parentSpace;
    final children = widget.supergroupChildren;
    final title = parent?.getLocalizedDisplayname() ?? preview.title;
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
                      OrexSupergroupChildPicker(
                        matrix: widget.matrix,
                        value: preview.id,
                        children: children,
                        onChanged: widget.onSupergroupChildSelected,
                      )
                    else if (preview.subtitle != null)
                      Text(
                        preview.subtitle!,
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
        if ((preview.topic ?? '').isNotEmpty)
          _PreviewTopicPanel(topic: preview.topic!),
        Expanded(
          child: _PreviewBody(
            matrix: widget.matrix,
            preview: preview,
            events: _events,
          ),
        ),
        _EnterPreviewBar(
          entering: _entering,
          label: preview.actionLabel,
          progressLabel: preview.progressLabel,
          onEnter: _enter,
        ),
      ],
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.matrix,
    required this.preview,
    required this.events,
  });

  final MatrixService matrix;
  final OrexConversationPreview preview;
  final Future<List<MatrixEvent>> events;

  @override
  Widget build(BuildContext context) {
    if (preview.historyRoomId == null) {
      return _PreviewEmptyState(
        icon: Icons.person_add_alt,
        text: preview.emptyBody,
      );
    }

    return FutureBuilder<List<MatrixEvent>>(
      future: events,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(color: OrexColors.copper),
          );
        }
        final loadedEvents = snap.data ?? const <MatrixEvent>[];
        if (loadedEvents.isEmpty) {
          return _PreviewEmptyState(
            icon: Icons.forum_outlined,
            text: preview.emptyBody,
          );
        }
        return ListView.builder(
          reverse: true,
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          itemCount: loadedEvents.length,
          itemBuilder: (context, index) =>
              _PreviewBubble(matrix: matrix, event: loadedEvents[index]),
        );
      },
    );
  }
}

class _PreviewEmptyState extends StatelessWidget {
  const _PreviewEmptyState({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: OrexColors.copper),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewTopicPanel extends StatelessWidget {
  const _PreviewTopicPanel({required this.topic});

  final String topic;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: GlassPanel(
        borderRadius: 18,
        opacity: 0.22,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              const Icon(Icons.notes, color: OrexColors.copper, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  topic,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.matrix, required this.event});

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

class _EnterPreviewBar extends StatelessWidget {
  const _EnterPreviewBar({
    required this.entering,
    required this.label,
    required this.progressLabel,
    required this.onEnter,
  });

  final bool entering;
  final String label;
  final String progressLabel;
  final VoidCallback onEnter;

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
              onPressed: entering ? null : onEnter,
              icon: entering
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: OrexColors.cream,
                      ),
                    )
                  : const Icon(Icons.login),
              label: Text(entering ? progressLabel : label),
            ),
          ),
        ),
      ),
    );
  }
}
