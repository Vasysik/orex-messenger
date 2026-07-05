import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/matrix/matrix_service.dart';
import '../../core/voip/call_controller.dart';
import '../../core/voip/call_session.dart';
import 'call_media_actions.dart';
import 'call_voice_actions.dart';

class OrexCallUiActions {
  const OrexCallUiActions({
    required this.context,
    required this.matrix,
    required this.call,
    required this.reactionButtonKey,
    required this.isMounted,
    this.reactionEmojiSize = 30,
  });

  final BuildContext context;
  final MatrixService matrix;
  final CallController call;
  final GlobalKey reactionButtonKey;
  final bool Function() isMounted;
  final double reactionEmojiSize;

  bool canGrantVoice(Room? room, String userId) =>
      orexCanGrantVoice(matrix, room, userId);

  bool canRevokeVoice(Room? room, String userId) =>
      orexCanRevokeVoice(matrix, room, userId);

  Future<void> hangUp() => call.hangUp();

  Future<void> showReactions(CallSession session) {
    return orexShowCallReaction(
      context: context,
      anchorKey: reactionButtonKey,
      matrix: matrix,
      session: session,
      emojiSize: reactionEmojiSize,
    );
  }

  Future<void> toggleScreenShare(CallSession session) {
    return orexToggleScreenShare(
      context: context,
      session: session,
      isMounted: isMounted,
    );
  }

  Future<void> cycleCamera(CallSession session) => orexCycleCamera(session);

  Future<void> grantVoice(Room room, String userId) async {
    await orexGrantVoice(
      matrix: matrix,
      call: call,
      room: room,
      userId: userId,
    );
    _showSnack('Голос выдан');
  }

  Future<void> revokeVoice(Room room, String userId) async {
    await orexRevokeVoice(
      matrix: matrix,
      call: call,
      room: room,
      userId: userId,
    );
    _showSnack('Голос забран');
  }

  void _showSnack(String message) {
    if (!isMounted()) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
