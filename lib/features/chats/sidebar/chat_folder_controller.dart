import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/matrix/matrix_service.dart';

enum OrexFolderFilter { all, direct, groups, channels, invites, custom }

extension OrexFolderFilterLabel on OrexFolderFilter {
  String get label => switch (this) {
        OrexFolderFilter.all => 'Все',
        OrexFolderFilter.direct => 'Личные',
        OrexFolderFilter.groups => 'Группы',
        OrexFolderFilter.channels => 'Каналы',
        OrexFolderFilter.invites => 'Приглашения',
        OrexFolderFilter.custom => 'Выбранные чаты',
      };
}

class OrexChatFolder {
  const OrexChatFolder({
    required this.id,
    required this.label,
    required this.filter,
    this.roomIds = const [],
  });

  final String id;
  final String label;
  final OrexFolderFilter filter;
  final List<String> roomIds;

  static const defaults = [
    OrexChatFolder(
      id: 'all',
      label: 'Все',
      filter: OrexFolderFilter.all,
    ),
    OrexChatFolder(
      id: 'direct',
      label: 'Личные',
      filter: OrexFolderFilter.direct,
    ),
    OrexChatFolder(
      id: 'groups',
      label: 'Группы',
      filter: OrexFolderFilter.groups,
    ),
    OrexChatFolder(
      id: 'channels',
      label: 'Каналы',
      filter: OrexFolderFilter.channels,
    ),
    OrexChatFolder(
      id: 'invites',
      label: 'Приглашения',
      filter: OrexFolderFilter.invites,
    ),
  ];

  OrexChatFolder copyWith({
    String? id,
    String? label,
    OrexFolderFilter? filter,
    List<String>? roomIds,
  }) =>
      OrexChatFolder(
        id: id ?? this.id,
        label: label ?? this.label,
        filter: filter ?? this.filter,
        roomIds: roomIds ?? this.roomIds,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'filter': filter.name,
        'roomIds': roomIds,
      };

  factory OrexChatFolder.fromJson(Map<String, Object?> json) {
    final filterName = json['filter']?.toString();
    final filter = OrexFolderFilter.values.firstWhere(
      (value) => value.name == filterName,
      orElse: () => OrexFolderFilter.all,
    );
    return OrexChatFolder(
      id: json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      label: json['label']?.toString() ?? filter.label,
      filter: filter,
      roomIds: (json['roomIds'] as List<dynamic>?)
              ?.map((id) => id.toString())
              .where((id) => id.isNotEmpty)
              .toList() ??
          const [],
    );
  }
}

class ChatFolderController extends ChangeNotifier {
  ChatFolderController({required this.matrix});

  static const _chatFoldersPrefsKey = 'orex.chat_folders.v2';
  static const _legacyChatFoldersPrefsKey = 'orex.chat_folders.v1';
  static const _chatListWidthPrefsKey = 'orex.chat_list_width.v1';

  final MatrixService matrix;

  List<OrexChatFolder> _folders = OrexChatFolder.defaults;
  double? _savedChatListWidth;
  bool _loaded = false;

  List<OrexChatFolder> get folders => List.unmodifiable(_folders);
  double? get savedChatListWidth => _savedChatListWidth;
  bool get loaded => _loaded;

  String _scopedPrefsKey(String key) {
    final scope = matrix.client.userID ?? matrix.homeserver.host;
    return '$key.$scope';
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _savedChatListWidth =
        prefs.getDouble(_scopedPrefsKey(_chatListWidthPrefsKey));

    final raw = prefs.getString(_scopedPrefsKey(_chatFoldersPrefsKey)) ??
        prefs.getString(_scopedPrefsKey(_legacyChatFoldersPrefsKey));
    if (raw == null || raw.isEmpty) {
      _folders = OrexChatFolder.defaults;
    } else {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        final folders = decoded
            .whereType<Map>()
            .map((json) => OrexChatFolder.fromJson(
                  Map<String, Object?>.from(json),
                ))
            .where((folder) => folder.label.trim().isNotEmpty)
            .toList();
        _folders = folders.isEmpty ? OrexChatFolder.defaults : folders;
      } catch (_) {
        _folders = OrexChatFolder.defaults;
      }
    }

    _loaded = true;
    notifyListeners();
  }

  Future<void> saveFolders(List<OrexChatFolder> folders) async {
    _folders = folders.isEmpty ? OrexChatFolder.defaults : List.of(folders);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _scopedPrefsKey(_chatFoldersPrefsKey),
      jsonEncode(_folders.map((folder) => folder.toJson()).toList()),
    );
    notifyListeners();
  }

  Future<void> saveChatListWidth(double width) async {
    _savedChatListWidth = width;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_scopedPrefsKey(_chatListWidthPrefsKey), width);
  }

  List<Room> roomsForFolder(OrexChatFolder folder) {
    final manual = _manualRooms(folder);
    if (folder.filter == OrexFolderFilter.custom) return manual;

    final automatic = switch (folder.filter) {
      OrexFolderFilter.all => matrix.rooms,
      OrexFolderFilter.direct => matrix.rooms
          .where((room) => matrix.roomKind(room) == OrexRoomKind.direct)
          .toList(),
      OrexFolderFilter.groups => matrix.rooms.where((room) {
          final kind = matrix.roomKind(room);
          return kind == OrexRoomKind.group || kind == OrexRoomKind.supergroup;
        }).toList(),
      OrexFolderFilter.channels =>
        matrix.rooms.where(matrix.isChannel).toList(),
      OrexFolderFilter.invites => matrix.rooms.where(matrix.isInvite).toList(),
      OrexFolderFilter.custom => <Room>[],
    };

    final byId = <String, Room>{
      for (final room in automatic) room.id: room,
      for (final room in manual) room.id: room,
    };
    return byId.values.toList()
      ..sort((a, b) =>
          b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime));
  }

  List<Room> _manualRooms(OrexChatFolder folder) {
    return folder.roomIds
        .map(matrix.client.getRoomById)
        .whereType<Room>()
        .where((room) => room.membership != Membership.leave)
        .where((room) => !matrix.isSupergroupChild(room))
        .toList();
  }
}
