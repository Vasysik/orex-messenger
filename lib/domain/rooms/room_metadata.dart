import 'package:matrix/matrix.dart';

enum OrexRoomKind { direct, group, channel, supergroup }

enum OrexConversationPreviewKind { publicRoom, supergroupChild, direct }

final class OrexRoomAlias {
  const OrexRoomAlias._();

  static String? normalizeLocalpart(String? alias) {
    var value = alias?.trim() ?? '';
    if (value.isEmpty) return null;
    if (value.startsWith('#')) value = value.substring(1);
    if (value.contains(':')) value = value.split(':').first;
    value = value
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'[^a-z0-9._=-]'), '-')
        .replaceAll(RegExp(r'-{2,}'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return value.isEmpty ? null : value;
  }

  static String? fullAlias(String? localAlias, String? serverName) {
    final localpart = normalizeLocalpart(localAlias);
    if (localpart == null || serverName == null || serverName.isEmpty) {
      return null;
    }
    return '#$localpart:$serverName';
  }

  static String displayAlias(String? alias) {
    final value = alias?.trim() ?? '';
    if (value.isEmpty) return '';
    if (!value.startsWith('#')) return value;
    final localpart = value.substring(1).split(':').first.trim();
    return localpart.isEmpty ? value : '#$localpart';
  }

  static String displayUserId(String? userId) {
    final value = userId?.trim() ?? '';
    if (value.isEmpty) return '';
    if (!value.startsWith('@')) return value;
    final localpart = value.substring(1).split(':').first.trim();
    return localpart.isEmpty ? value : '@$localpart';
  }

  static String localpartFromRoom(Room room) {
    final alias = room.canonicalAlias;
    if (!alias.startsWith('#')) return '';
    return alias.substring(1).split(':').first;
  }
}

final class OrexRoomPreview {
  const OrexRoomPreview({
    required this.roomId,
    required this.name,
    this.alias,
    this.avatar,
    this.topic,
    this.memberCount,
    this.iconKey,
    this.via = const <String>[],
    this.parentSpaceId,
  });

  factory OrexRoomPreview.fromPublicRoom(PublishedRoomsChunk room) {
    final displayAlias = OrexRoomAlias.displayAlias(room.canonicalAlias);
    final name =
        room.name ?? (displayAlias.isNotEmpty ? displayAlias : room.roomId);
    return OrexRoomPreview(
      roomId: room.roomId,
      name: name,
      alias: room.canonicalAlias,
      avatar: room.avatarUrl,
      topic: room.topic,
      memberCount: room.numJoinedMembers,
    );
  }

  final String roomId;
  final String name;
  final String? alias;
  final Uri? avatar;
  final String? topic;
  final int? memberCount;
  final String? iconKey;
  final List<String>? via;
  final String? parentSpaceId;

  String get idOrAlias => alias?.isNotEmpty == true ? alias! : roomId;
  bool get isSupergroupChild => parentSpaceId != null;
}

final class OrexConversationPreview {
  const OrexConversationPreview._({
    required this.kind,
    required this.id,
    required this.title,
    required this.actionLabel,
    required this.progressLabel,
    required this.emptyBody,
    this.subtitle,
    this.avatar,
    this.topic,
    this.memberCount,
    this.iconKey,
    this.roomPreview,
    this.userId,
    this.historyRoomId,
  });

  factory OrexConversationPreview.fromRoom(OrexRoomPreview preview) {
    final alias = OrexRoomAlias.displayAlias(preview.alias);
    final memberLine = preview.memberCount == null
        ? null
        : '${preview.memberCount} участников';
    final subtitle = alias.isNotEmpty
        ? [alias, memberLine].whereType<String>().join(' · ')
        : memberLine ?? preview.roomId;
    final isChild = preview.isSupergroupChild;

    return OrexConversationPreview._(
      kind: isChild
          ? OrexConversationPreviewKind.supergroupChild
          : OrexConversationPreviewKind.publicRoom,
      id: preview.roomId,
      title: preview.name,
      subtitle: subtitle,
      avatar: preview.avatar,
      topic: preview.topic,
      memberCount: preview.memberCount,
      iconKey: preview.iconKey,
      roomPreview: preview,
      historyRoomId: preview.roomId,
      actionLabel: 'Войти в чат',
      progressLabel: 'Входим...',
      emptyBody: isChild
          ? 'История этого чата будет доступна после входа.'
          : 'В этом публичном чате пока нет доступной истории.',
    );
  }

  factory OrexConversationPreview.direct(
    Profile profile, {
    required String compactUserId,
  }) {
    final displayName = profile.displayName?.trim();
    final fallbackName = compactUserId.trim().isEmpty
        ? profile.userId
        : compactUserId.trim();
    final title = displayName == null || displayName.isEmpty
        ? fallbackName
        : displayName;

    return OrexConversationPreview._(
      kind: OrexConversationPreviewKind.direct,
      id: profile.userId,
      title: title,
      subtitle: fallbackName,
      avatar: profile.avatarUrl,
      userId: profile.userId,
      actionLabel: 'Войти в личный чат',
      progressLabel: 'Открываем...',
      emptyBody:
          'Личный чат будет создан только после входа. История появится после первого сообщения.',
    );
  }

  final OrexConversationPreviewKind kind;
  final String id;
  final String title;
  final String? subtitle;
  final Uri? avatar;
  final String? topic;
  final int? memberCount;
  final String? iconKey;
  final OrexRoomPreview? roomPreview;
  final String? userId;
  final String? historyRoomId;
  final String actionLabel;
  final String progressLabel;
  final String emptyBody;

  String get key => '${kind.name}:$id';
}
