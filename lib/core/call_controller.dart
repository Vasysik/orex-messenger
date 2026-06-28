import 'package:flutter/foundation.dart';

import '../features/call/call_session.dart';
import 'matrix/matrix_service.dart';
import 'orex_logger.dart';

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
  bool _initiator = false; // мы начали этот звонок (а не присоединились)
  DateTime? _start;

  bool get isActive => _session != null;

  /// Начать/присоединиться к звонку в комнате.
  Future<void> start(String roomId, {required bool video}) async {
    if (_session != null) await hangUp();
    this.roomId = roomId;
    this.video = video;
    minimized = false;
    // Инициатор = в комнате ещё не было активного звонка до нас.
    final room = matrix.client.getRoomById(roomId);
    _initiator = room != null && !matrix.roomHasActiveCall(room);
    _start = DateTime.now();
    final s = CallSession(client: matrix.client, matrixRoomId: roomId);
    _session = s;
    s.addListener(notifyListeners);
    notifyListeners();
    // Сигналинг (membership) — чтобы у собеседника зазвонило.
    try {
      await matrix.voip?.enterCall(roomId);
    } catch (e) {
      OrexLog.d('Call', 'signaling failed room=$roomId', e);
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
    final rid = roomId;
    final initiator = _initiator;
    final start = _start;
    final sawRemote = s?.sawRemote ?? false;
    _session = null;
    minimized = false;
    roomId = null;
    _initiator = false;
    _start = null;
    notifyListeners();
    if (s != null) {
      s.removeListener(notifyListeners);
      await s.hangUp();
      s.dispose();
    }
    await matrix.voip?.leaveCurrent();
    // Итоговое сообщение о звонке постит ТОЛЬКО инициатор — без дублей.
    if (initiator && rid != null) {
      await _postCallSummary(rid, sawRemote, start);
    }
  }

  Future<void> _postCallSummary(
      String roomId, bool answered, DateTime? start) async {
    final room = matrix.client.getRoomById(roomId);
    if (room == null) return;
    String outcome;
    String text;
    if (answered) {
      outcome = 'answered';
      final secs =
          start != null ? DateTime.now().difference(start).inSeconds : 0;
      text = secs > 0 ? '📞 Звонок · ${_fmtDur(secs)}' : '📞 Звонок';
    } else if (matrix.voip?.wasRejected(roomId) ?? false) {
      outcome = 'rejected';
      text = '📞 Отклонённый вызов';
    } else {
      outcome = 'missed';
      text = '📞 Пропущенный вызов';
    }
    matrix.voip?.clearRejected(roomId);
    try {
      await room.sendEvent({
        'msgtype': 'm.notice',
        'body': text,
        'com.orex.call_outcome': outcome,
      });
    } catch (e) {
      OrexLog.d('Call', 'post call summary failed room=$roomId', e);
    }
  }

  String _fmtDur(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return m > 0 ? '$m мин ${s.toString().padLeft(2, '0')} с' : '$s с';
  }

  @override
  void dispose() {
    _session?.removeListener(notifyListeners);
    _session?.dispose();
    super.dispose();
  }
}
