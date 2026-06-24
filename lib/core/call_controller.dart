import 'package:flutter/foundation.dart';

import '../features/call/call_session.dart';
import 'matrix_service.dart';

/// Долгоживущий «активный звонок»: владеет медиа-сессией ([CallSession]) и
/// сигналингом ([VoipService]), чтобы звонок переживал сворачивание экрана.
///
/// Раньше [CallSession] жил внутри экрана звонка и умирал при выходе. Теперь
/// экран — лишь «вид» на этот контроллер: свернуть = выйти с экрана, не вешая
/// трубку; над чатом показывается мини-панель управления.
class CallController extends ChangeNotifier {
  CallController(this.matrix);
  final MatrixService matrix;

  CallSession? _session;
  CallSession? get session => _session;

  String? roomId;
  bool video = false;
  bool minimized = false;

  bool get isActive => _session != null;

  /// Начать/присоединиться к звонку в комнате.
  Future<void> start(String roomId, {required bool video}) async {
    if (_session != null) await hangUp();
    this.roomId = roomId;
    this.video = video;
    minimized = false;
    final s = CallSession(client: matrix.client, matrixRoomId: roomId);
    _session = s;
    s.addListener(notifyListeners);
    notifyListeners();
    // Сигналинг (membership) — чтобы у собеседника зазвонило.
    try {
      await matrix.voip?.enterCall(roomId);
    } catch (e) {
      debugPrint('Сигналинг звонка не удался: $e');
    }
    await s.connect(video: video);
  }

  void minimize() {
    if (_session == null) return;
    minimized = true;
    notifyListeners();
  }

  void expand() {
    minimized = false;
    notifyListeners();
  }

  Future<void> hangUp() async {
    final s = _session;
    _session = null;
    minimized = false;
    roomId = null;
    notifyListeners();
    if (s != null) {
      s.removeListener(notifyListeners);
      await s.hangUp();
      s.dispose();
    }
    await matrix.voip?.leaveCurrent();
  }

  @override
  void dispose() {
    _session?.removeListener(notifyListeners);
    _session?.dispose();
    super.dispose();
  }
}
