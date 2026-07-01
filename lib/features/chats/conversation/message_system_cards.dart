part of 'message_bubble.dart';

class _MembershipNoticeCard extends StatelessWidget {
  const _MembershipNoticeCard({required this.data});

  final OrexMembershipNotice data;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final icon = switch (data.kind) {
      OrexMembershipNoticeKind.joined => Icons.login,
      OrexMembershipNoticeKind.left => Icons.logout,
      OrexMembershipNoticeKind.invited => Icons.person_add_alt_1,
      OrexMembershipNoticeKind.removed => Icons.person_remove_alt_1,
      OrexMembershipNoticeKind.banned => Icons.block,
    };
    final color = switch (data.kind) {
      OrexMembershipNoticeKind.joined => OrexColors.online,
      OrexMembershipNoticeKind.left => OrexColors.ochre,
      OrexMembershipNoticeKind.invited => OrexColors.copper,
      OrexMembershipNoticeKind.removed => const Color(0xFFCF6679),
      OrexMembershipNoticeKind.banned => const Color(0xFFCF6679),
    };

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 7, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                data.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.78),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label, this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? OrexColors.copper;
    return Row(
      children: [
        Icon(icon, color: c, size: 20),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}


class _InviteNoticeData {
  const _InviteNoticeData({
    required this.title,
    this.roomId,
    this.alias,
  });

  final String title;
  final String? roomId;
  final String? alias;

  String? get reference => alias ?? roomId;

  static _InviteNoticeData? tryParse(String body) {
    final normalized = body.trim();
    if (!normalized.startsWith('Приглашение в «')) return null;

    final titleMatch = RegExp(r'Приглашение в «([^»]+)»').firstMatch(normalized);
    final roomMatch = RegExp(r'Комната:\s*(!\S+:\S+)').firstMatch(normalized);
    final aliasMatch = RegExp(r'Alias:\s*(#\S+)').firstMatch(normalized);
    final rawAlias = aliasMatch?.group(1);
    final alias = rawAlias == null || rawAlias.contains(':')
        ? rawAlias
        : '$rawAlias:${OrexConfig.homeserverHost}';

    return _InviteNoticeData(
      title: titleMatch?.group(1) ?? 'Комната',
      roomId: roomMatch?.group(1),
      alias: alias,
    );
  }
}

class _InviteNoticeCard extends StatelessWidget {
  const _InviteNoticeCard({
    required this.data,
    required this.textColor,
    required this.onTap,
  });

  final _InviteNoticeData data;
  final Color textColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final displayAlias = OrexRoomAlias.displayAlias(data.alias);
    final subtitle = displayAlias.isNotEmpty
        ? displayAlias
        : data.roomId ?? 'Откройте приглашение';
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 240, maxWidth: 330),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: OrexColors.copper.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: OrexColors.copper.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                gradient: OrexColors.copperGradient,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mark_email_unread, color: OrexColors.cream, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Приглашение',
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.72),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor.withValues(alpha: 0.65),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, color: OrexColors.copper.withValues(alpha: 0.9)),
          ],
        ),
      ),
    );
  }
}

class _ReactionInfo {
  int count = 0;
  String? myReactionId;
}
