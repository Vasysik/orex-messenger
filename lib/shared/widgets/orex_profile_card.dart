import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
import '../theme/glass.dart';
import '../theme/orex_theme.dart';
import 'mxc_avatar.dart';

class OrexProfileCard extends StatelessWidget {
  const OrexProfileCard({
    super.key,
    required this.matrix,
    required this.name,
    required this.subtitle,
    this.avatar,
    this.busy = false,
    this.onAvatar,
    this.onEdit,
    this.onRemoveAvatar,
    this.removeAvatarTooltip = 'Убрать аватар',
  });

  final MatrixService matrix;
  final String name;
  final String subtitle;
  final Uri? avatar;
  final bool busy;
  final VoidCallback? onAvatar;
  final VoidCallback? onEdit;
  final VoidCallback? onRemoveAvatar;
  final String removeAvatarTooltip;

  @override
  Widget build(BuildContext context) {
    final canChangeAvatar = onAvatar != null && !busy;

    return GlassPanel(
      borderRadius: 22,
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          GestureDetector(
            onTap: canChangeAvatar ? onAvatar : null,
            child: Stack(
              alignment: Alignment.center,
              children: [
                MxcAvatar(matrix: matrix, name: name, mxc: avatar, size: 72),
                if (busy)
                  const CircularProgressIndicator(color: OrexColors.cream),
                if (canChangeAvatar)
                  const Positioned(
                    right: 0,
                    bottom: 0,
                    child: _AvatarEditBadge(),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontSize: 18),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (onRemoveAvatar != null)
            IconButton(
              tooltip: removeAvatarTooltip,
              onPressed: onRemoveAvatar,
              icon: const Icon(
                Icons.no_photography_outlined,
                color: OrexColors.copper,
              ),
            )
          else if (onEdit != null)
            IconButton(
              onPressed: onEdit,
              icon: const Icon(Icons.edit, color: OrexColors.copper),
            ),
        ],
      ),
    );
  }
}

class _AvatarEditBadge extends StatelessWidget {
  const _AvatarEditBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: OrexColors.walnutDeep,
      ),
      child: const Icon(Icons.photo_camera, size: 14, color: OrexColors.cream),
    );
  }
}
