import 'package:flutter/material.dart';

import '../../core/matrix/matrix_service.dart';
import '../theme/orex_theme.dart';
import 'mxc_avatar.dart';

/// Shared visual used anywhere a call participant has no active video track.
///
/// Keeping the surface in one widget prevents PiP from drifting away from the
/// normal call tile: both use the same copper gradient and the same Matrix
/// avatar/initial fallback.
class OrexCallNoMediaSurface extends StatelessWidget {
  const OrexCallNoMediaSurface({
    super.key,
    required this.matrix,
    required this.name,
    required this.avatarSize,
    this.mxc,
  });

  final MatrixService matrix;
  final String name;
  final Uri? mxc;
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: OrexColors.copperGradient),
      alignment: Alignment.center,
      child: MxcAvatar(
        matrix: matrix,
        name: name,
        mxc: mxc,
        size: avatarSize,
      ),
    );
  }
}
