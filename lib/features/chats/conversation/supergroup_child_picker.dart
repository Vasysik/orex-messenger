import 'package:flutter/material.dart';

import '../../../core/matrix/matrix_service.dart';
import '../../../shared/theme/orex_theme.dart';
import '../../../shared/widgets/room_icon.dart';

class OrexSupergroupChildPicker extends StatelessWidget {
  const OrexSupergroupChildPicker({
    super.key,
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
    final selectedValue = children.any((child) => child.roomId == value)
        ? value
        : children.first.roomId;

    return DropdownButtonHideUnderline(
      child: DropdownButton<String>(
        value: selectedValue,
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
                    if (_hasCall(child)) ...[
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.call,
                        size: 14,
                        color: OrexColors.online,
                      ),
                    ],
                  ],
                ),
              ),
            )
            .toList(),
        onChanged: (next) {
          if (next == null || next == selectedValue) return;
          onChanged?.call(next);
        },
      ),
    );
  }

  IconData _icon(OrexRoomPreview child) {
    final previewIcon = child.iconKey;
    if (previewIcon != null && previewIcon.isNotEmpty) {
      return orexRoomIconData(previewIcon);
    }
    final local = matrix.client.getRoomById(child.roomId);
    if (local == null) return orexRoomIconData('chat');
    return orexRoomIconData(matrix.roomIconKey(local));
  }

  bool _hasCall(OrexRoomPreview child) {
    final local = matrix.client.getRoomById(child.roomId);
    return local != null && matrix.roomHasActiveCall(local);
  }
}
