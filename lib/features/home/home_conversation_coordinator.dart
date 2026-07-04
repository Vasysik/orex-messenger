import 'package:flutter/foundation.dart';

import '../../domain/rooms/room_metadata.dart';

typedef OrexForegroundRoomSetter = void Function(String? roomId);

class OrexHomeConversationCoordinator extends ChangeNotifier {
  OrexHomeConversationCoordinator({
    required OrexForegroundRoomSetter onForegroundRoomIdChanged,
  }) : _setForegroundRoomId = onForegroundRoomIdChanged;

  final OrexForegroundRoomSetter _setForegroundRoomId;
  final Map<String, String> _visibleSupergroupChildBySpace = <String, String>{};

  String? selectedRoomId;
  OrexConversationPreview? previewTarget;

  bool get canPop => selectedRoomId == null && previewTarget == null;

  bool get hasConversationTarget => !canPop;

  String? selectedSupergroupChildId(String spaceId) {
    return _visibleSupergroupChildBySpace[spaceId];
  }

  void syncForeground() {
    _setForegroundRoomId(selectedRoomId);
  }

  void selectRoom(String roomId) {
    if (selectedRoomId == roomId && previewTarget == null) {
      _setForegroundRoomId(roomId);
      return;
    }
    previewTarget = null;
    selectedRoomId = roomId;
    _setForegroundRoomId(roomId);
    notifyListeners();
  }

  void openPreview(OrexConversationPreview preview) {
    if (selectedRoomId == null && previewTarget?.key == preview.key) {
      _setForegroundRoomId(null);
      return;
    }
    selectedRoomId = null;
    previewTarget = preview;
    _setForegroundRoomId(null);
    notifyListeners();
  }

  void enterPreview(String roomId) {
    selectRoom(roomId);
  }

  bool clearPreview() {
    if (previewTarget == null) return false;
    previewTarget = null;
    _setForegroundRoomId(selectedRoomId);
    notifyListeners();
    return true;
  }

  bool clearSelection() {
    if (selectedRoomId == null && previewTarget == null) return false;
    selectedRoomId = null;
    previewTarget = null;
    _setForegroundRoomId(null);
    notifyListeners();
    return true;
  }

  bool showSupergroupChild(String spaceId, String childId) {
    if (_visibleSupergroupChildBySpace[spaceId] == childId) return false;
    _visibleSupergroupChildBySpace[spaceId] = childId;
    _setForegroundRoomId(childId);
    notifyListeners();
    return true;
  }
}
