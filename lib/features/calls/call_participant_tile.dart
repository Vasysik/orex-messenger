import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:matrix/matrix.dart' hide CallSession;

import '../../core/matrix/matrix_service.dart';
import '../../core/voip/voice_participant_state.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/widgets/mxc_avatar.dart';
import 'voice_activity_frame.dart';

String orexMatrixUserIdFromParticipantIdentity(String identity) {
  final match = RegExp(r'@[^:]+:[^:]+').firstMatch(identity);
  return match?.group(0) ?? identity;
}

class OrexCallParticipantTileStyle {
  const OrexCallParticipantTileStyle({
    required this.frameBorderRadius,
    required this.clipBorderRadius,
    required this.activeBlur,
    required this.avatarSize,
    required this.zoomAvatarSize,
    required this.cornerButtonSize,
    required this.cornerButtonRadius,
    required this.cornerButtonIconSize,
    required this.statusBadgeSize,
    required this.statusBadgeRadius,
    required this.statusBadgeIconSize,
    required this.statusBadgeTextSize,
    required this.badgeGap,
    required this.nameFontSize,
    required this.showNameLabel,
  });

  static const full = OrexCallParticipantTileStyle(
    frameBorderRadius: 20,
    clipBorderRadius: 18,
    activeBlur: 18,
    avatarSize: 96,
    zoomAvatarSize: 132,
    cornerButtonSize: 38,
    cornerButtonRadius: 14,
    cornerButtonIconSize: 18,
    statusBadgeSize: 38,
    statusBadgeRadius: 14,
    statusBadgeIconSize: 18,
    statusBadgeTextSize: 21,
    badgeGap: 6,
    nameFontSize: 12,
    showNameLabel: true,
  );

  static const minimized = OrexCallParticipantTileStyle(
    frameBorderRadius: 14,
    clipBorderRadius: 12,
    activeBlur: 14,
    avatarSize: 44,
    zoomAvatarSize: 72,
    cornerButtonSize: 34,
    cornerButtonRadius: 12,
    cornerButtonIconSize: 17,
    statusBadgeSize: 34,
    statusBadgeRadius: 12,
    statusBadgeIconSize: 17,
    statusBadgeTextSize: 19,
    badgeGap: 5,
    nameFontSize: 12,
    showNameLabel: false,
  );

  final double frameBorderRadius;
  final double clipBorderRadius;
  final double activeBlur;
  final double avatarSize;
  final double zoomAvatarSize;
  final double cornerButtonSize;
  final double cornerButtonRadius;
  final double cornerButtonIconSize;
  final double statusBadgeSize;
  final double statusBadgeRadius;
  final double statusBadgeIconSize;
  final double statusBadgeTextSize;
  final double badgeGap;
  final double nameFontSize;
  final bool showNameLabel;

  double get cameraButtonBottomStep => statusBadgeSize + badgeGap;
}

class OrexCallParticipantTile extends StatelessWidget {
  const OrexCallParticipantTile({
    super.key,
    required this.participant,
    required this.matrix,
    required this.room,
    required this.voiceState,
    required this.preferScreenShare,
    required this.style,
    this.zoomable = false,
    this.onTap,
    this.cornerIcon,
    this.cornerTooltip,
    this.onCornerTap,
    this.onSwitchVideoSource,
    this.onCycleCamera,
    this.onGrantVoice,
    this.onRevokeVoice,
  });

  final lk.Participant participant;
  final MatrixService matrix;
  final Room? room;
  final VoiceParticipantState voiceState;
  final bool preferScreenShare;
  final OrexCallParticipantTileStyle style;
  final bool zoomable;
  final VoidCallback? onTap;
  final IconData? cornerIcon;
  final String? cornerTooltip;
  final VoidCallback? onCornerTap;
  final VoidCallback? onSwitchVideoSource;
  final VoidCallback? onCycleCamera;
  final VoidCallback? onGrantVoice;
  final VoidCallback? onRevokeVoice;

  @override
  Widget build(BuildContext context) {
    final track = orexSelectVideoTrack(
      participant,
      preferScreenShare: preferScreenShare,
    );
    final micMuted = orexParticipantMicMuted(participant);
    final soundMuted = voiceState.speakerMuted;
    final statusBadgeCount = (micMuted ? 1 : 0) + (soundMuted ? 1 : 0);
    final cameraButtonBottom = statusBadgeCount == 0
        ? 8.0
        : 8.0 + statusBadgeCount * style.cameraButtonBottomStep;

    final userId = orexMatrixUserIdFromParticipantIdentity(
      participant.identity,
    );
    final user = room?.unsafeGetUserFromMemoryOrFallback(userId);
    var name = user?.calcDisplayname() ?? userId;
    if (participant is lk.LocalParticipant) name = '$name · вы';

    Widget media;
    if (track != null) {
      media = Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: lk.VideoTrackRenderer(track, fit: lk.VideoViewFit.contain),
      );
      if (zoomable) {
        media = InteractiveViewer(minScale: 1, maxScale: 4, child: media);
      }
    } else {
      media = Container(
        decoration: const BoxDecoration(gradient: OrexColors.copperGradient),
        alignment: Alignment.center,
        child: MxcAvatar(
          matrix: matrix,
          name: user?.calcDisplayname() ?? userId,
          mxc: user?.avatarUrl,
          size: zoomable ? style.zoomAvatarSize : style.avatarSize,
        ),
      );
    }

    return OrexSpeakingFrame(
      participant: participant,
      matrix: matrix,
      borderRadius: style.frameBorderRadius,
      activeBlur: style.activeBlur,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(style.clipBorderRadius),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                media,
                if (style.showNameLabel) _NameLabel(name: name, style: style),
                if ((cornerIcon != null && onCornerTap != null) ||
                    onSwitchVideoSource != null)
                  _TopLeftActions(
                    style: style,
                    cornerIcon: cornerIcon,
                    cornerTooltip: cornerTooltip,
                    onCornerTap: onCornerTap,
                    preferScreenShare: preferScreenShare,
                    onSwitchVideoSource: onSwitchVideoSource,
                  ),
                if (statusBadgeCount > 0)
                  _MediaStatusBadges(
                    style: style,
                    micMuted: micMuted,
                    soundMuted: soundMuted,
                    local: participant is lk.LocalParticipant,
                  ),
                if (track != null && onCycleCamera != null)
                  Positioned(
                    right: 8,
                    bottom: cameraButtonBottom,
                    child: _TileCornerButton(
                      style: style,
                      icon: Icons.cameraswitch,
                      tooltip: 'Переключить камеру',
                      onTap: onCycleCamera!,
                    ),
                  ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: _VoiceStateBadges(
                    style: style,
                    handRaised: voiceState.handRaised,
                    reaction: voiceState.reaction,
                    onGrantVoice: onGrantVoice,
                    onRevokeVoice: onRevokeVoice,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NameLabel extends StatelessWidget {
  const _NameLabel({required this.name, required this.style});

  final String name;
  final OrexCallParticipantTileStyle style;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 8,
      bottom: 8,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          name,
          style: TextStyle(color: Colors.white, fontSize: style.nameFontSize),
        ),
      ),
    );
  }
}

class _TopLeftActions extends StatelessWidget {
  const _TopLeftActions({
    required this.style,
    required this.cornerIcon,
    required this.cornerTooltip,
    required this.onCornerTap,
    required this.preferScreenShare,
    required this.onSwitchVideoSource,
  });

  final OrexCallParticipantTileStyle style;
  final IconData? cornerIcon;
  final String? cornerTooltip;
  final VoidCallback? onCornerTap;
  final bool preferScreenShare;
  final VoidCallback? onSwitchVideoSource;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 8,
      top: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (cornerIcon != null && onCornerTap != null)
            _TileCornerButton(
              style: style,
              icon: cornerIcon!,
              tooltip: cornerTooltip ?? '',
              onTap: onCornerTap!,
            ),
          if (onSwitchVideoSource != null) ...[
            if (cornerIcon != null && onCornerTap != null)
              SizedBox(height: style.badgeGap),
            _TileCornerButton(
              style: style,
              icon: preferScreenShare ? Icons.videocam : Icons.screen_share,
              tooltip: preferScreenShare
                  ? 'Показать камеру участника'
                  : 'Показать демонстрацию участника',
              onTap: onSwitchVideoSource!,
            ),
          ],
        ],
      ),
    );
  }
}

class _MediaStatusBadges extends StatelessWidget {
  const _MediaStatusBadges({
    required this.style,
    required this.micMuted,
    required this.soundMuted,
    required this.local,
  });

  final OrexCallParticipantTileStyle style;
  final bool micMuted;
  final bool soundMuted;
  final bool local;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 8,
      bottom: 8,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (micMuted)
            _TileStatusBadge(
              style: style,
              icon: Icons.mic_off,
              tooltip: 'Микрофон выключен',
            ),
          if (soundMuted) ...[
            if (micMuted) SizedBox(height: style.badgeGap),
            _TileStatusBadge(
              style: style,
              icon: Icons.volume_off,
              tooltip: local
                  ? 'Вы выключили звук звонка у себя'
                  : 'Участник выключил звук звонка у себя',
            ),
          ],
        ],
      ),
    );
  }
}

class _TileCornerButton extends StatelessWidget {
  const _TileCornerButton({
    required this.style,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final OrexCallParticipantTileStyle style;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(style.cornerButtonRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(style.cornerButtonRadius),
        child: Container(
          width: style.cornerButtonSize,
          height: style.cornerButtonSize,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(style.cornerButtonRadius),
            border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          ),
          child: Icon(
            icon,
            size: style.cornerButtonIconSize,
            color: Colors.white,
          ),
        ),
      ),
    );
    return Tooltip(message: tooltip, child: button);
  }
}

class _TileStatusBadge extends StatelessWidget {
  const _TileStatusBadge({
    required this.style,
    required this.tooltip,
    this.icon,
    this.text,
  }) : assert(icon != null || text != null);

  final OrexCallParticipantTileStyle style;
  final IconData? icon;
  final String? text;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Container(
        width: style.statusBadgeSize,
        height: style.statusBadgeSize,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.52),
          borderRadius: BorderRadius.circular(style.statusBadgeRadius),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: icon != null
            ? Icon(icon, size: style.statusBadgeIconSize, color: Colors.white)
            : Text(
                text!,
                style: TextStyle(fontSize: style.statusBadgeTextSize),
              ),
      ),
    );
  }
}

class _VoiceStateBadges extends StatelessWidget {
  const _VoiceStateBadges({
    required this.style,
    required this.handRaised,
    required this.reaction,
    this.onGrantVoice,
    this.onRevokeVoice,
  });

  final OrexCallParticipantTileStyle style;
  final bool handRaised;
  final String? reaction;
  final VoidCallback? onGrantVoice;
  final VoidCallback? onRevokeVoice;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (reaction != null)
          _TileStatusBadge(style: style, text: reaction!, tooltip: 'Реакция'),
        if (handRaised) ...[
          if (reaction != null) SizedBox(width: style.badgeGap),
          _TileStatusBadge(
            style: style,
            icon: Icons.back_hand,
            tooltip: 'Просит голос',
          ),
        ],
        if (onGrantVoice != null) ...[
          if (handRaised || reaction != null) SizedBox(width: style.badgeGap),
          _TileCornerButton(
            style: style,
            icon: Icons.record_voice_over,
            tooltip: 'Дать голос',
            onTap: onGrantVoice!,
          ),
        ],
        if (onRevokeVoice != null) ...[
          if (handRaised || reaction != null || onGrantVoice != null)
            SizedBox(width: style.badgeGap),
          _TileCornerButton(
            style: style,
            icon: Icons.mic_off,
            tooltip: 'Забрать голос',
            onTap: onRevokeVoice!,
          ),
        ],
      ],
    );
  }
}
