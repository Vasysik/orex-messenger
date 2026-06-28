import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../../core/matrix/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/orex_theme.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/squirrel_mascot.dart';
import '../call/call_screen.dart';
import '../call/minimized_call_panel.dart';
import '../chat/chat_view.dart';
import '../chat_list/chat_folder_controller.dart';
import '../chat_list/chat_list_panel.dart';
import '../new_chat/new_chat_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/verify_session_screen.dart';

/// Главный экран. На широком экране (web/desktop) — две панели рядом,
/// как в Telegram Desktop. На узком (телефон) — стек с навигацией.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.matrix,
    required this.theme,
  });

  final MatrixService matrix;
  final ThemeController theme;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String? _selectedRoomId;
  bool _verifyBannerDismissed = false;
  double _chatListWidth = 360; // ширина левой колонки (можно тянуть мышью)
  late final ChatFolderController _folders;
  bool _appliedSavedChatListWidth = false;

  static const double _wideBreakpoint = 900;

  @override
  void initState() {
    super.initState();
    _folders = ChatFolderController(matrix: widget.matrix)
      ..addListener(_onFolderPrefsChanged);
    _folders.load();
    widget.matrix.addListener(_onMatrixChanged);
  }

  void _onFolderPrefsChanged() {
    final savedWidth = _folders.savedChatListWidth;
    if (!_appliedSavedChatListWidth && savedWidth != null && mounted) {
      _appliedSavedChatListWidth = true;
      setState(() {
        _chatListWidth = savedWidth.clamp(260.0, 560.0);
      });
    }
  }

  void _onMatrixChanged() {
    final roomId = _selectedRoomId;
    if (roomId == null || !mounted) return;
    final room = widget.matrix.client.getRoomById(roomId);
    if (room == null || room.membership == Membership.leave) {
      setState(() => _selectedRoomId = null);
    }
  }

  @override
  void dispose() {
    _folders
      ..removeListener(_onFolderPrefsChanged)
      ..dispose();
    widget.matrix.removeListener(_onMatrixChanged);
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            SettingsScreen(matrix: widget.matrix, theme: widget.theme),
      ),
    );
  }

  Future<void> _openNewChat() async {
    final roomId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => NewChatScreen(matrix: widget.matrix),
      ),
    );
    if (roomId != null && mounted) setState(() => _selectedRoomId = roomId);
  }

  void _openVerifySession() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VerifySessionScreen(matrix: widget.matrix),
      ),
    );
  }

  /// Развернуть звонок на весь экран (кнопка «развернуть» в панели).
  void _openCallFullScreen() {
    widget.matrix.call.expand();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CallScreen(matrix: widget.matrix)),
    );
  }

  /// Начать/присоединиться к звонку. На десктопе показываем сразу свёрнутой
  /// панелью над чатом (не на весь экран); на узком экране — полноэкранно.
  void _startCall(String roomId, bool video) {
    widget.matrix.call.start(roomId, video: video);
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    if (isWide) {
      widget.matrix.call.minimize();
    } else {
      _openCallFullScreen();
    }
  }

  /// Панель звонка над областью разговора: активный звонок (плитки+управление)
  /// или «Идёт звонок · Войти» для звонка в открытой комнате, куда мы не вошли.
  Widget _callArea() {
    final call = widget.matrix.call;
    if (call.isActive) {
      return MinimizedCallPanel(call: call, onExpand: _openCallFullScreen);
    }
    final roomId = _selectedRoomId;
    if (roomId != null) {
      final room = widget.matrix.client.getRoomById(roomId);
      if (room != null && widget.matrix.roomHasActiveCall(room)) {
        return JoinCallPanel(
          matrix: widget.matrix,
          room: room,
          onJoin: () => _startCall(roomId, false),
        );
      }
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return PopScope(
      canPop: _selectedRoomId == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectedRoomId != null) {
          setState(() => _selectedRoomId = null);
        }
      },
      child: AmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: ListenableBuilder(
              listenable: widget.matrix.call,
              builder: (context, _) {
                return Column(
                  children: [
                    if (widget.matrix.needsSessionVerification &&
                        !_verifyBannerDismissed)
                      _VerifyBanner(
                        onTap: _openVerifySession,
                        onClose: () =>
                            setState(() => _verifyBannerDismissed = true),
                      ),
                    Expanded(child: isWide ? _buildWide() : _buildNarrow()),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Перетаскиваемая граница между списком чатов и правым блоком (12px-зазор).
  Widget _columnResizer() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) {
          setState(() {
            _chatListWidth = (_chatListWidth + d.delta.dx).clamp(260.0, 560.0);
          });
        },
        onHorizontalDragEnd: (_) => _folders.saveChatListWidth(_chatListWidth),
        child: Center(
          child: Container(
            width: 4,
            height: 44,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: OrexColors.copper.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chatList({required bool showSelection}) => ChatListPanel(
        matrix: widget.matrix,
        selectedRoomId: showSelection ? _selectedRoomId : null,
        onSelect: (id) => setState(() => _selectedRoomId = id),
        onOpenSettings: _openSettings,
        onNewChat: _openNewChat,
        folders: _folders,
      );

  Widget _buildWide() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: _chatListWidth,
            child: GlassPanel(
              borderRadius: 24,
              child: _chatList(showSelection: true),
            ),
          ),
          _columnResizer(),
          Expanded(
            child: Column(
              children: [
                _callArea(),
                Expanded(
                  child: GlassPanel(
                    borderRadius: 24,
                    child: _selectedRoomId == null
                        ? const _EmptyConversation()
                        : ChatView(
                            key: ValueKey(_selectedRoomId),
                            matrix: widget.matrix,
                            roomId: _selectedRoomId!,
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNarrow() {
    if (_selectedRoomId == null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            _callArea(),
            Expanded(
              child: GlassPanel(
                borderRadius: 24,
                child: _chatList(showSelection: false),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          _callArea(),
          Expanded(
            child: GlassPanel(
              borderRadius: 24,
              child: ChatView(
                matrix: widget.matrix,
                roomId: _selectedRoomId!,
                onBack: () => setState(() => _selectedRoomId = null),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Полоска-предупреждение: эта сессия ещё не подтверждена кросс-подписью,
/// поэтому другие клиенты считают владельца непроверенным.
class _VerifyBanner extends StatelessWidget {
  const _VerifyBanner({required this.onTap, required this.onClose});
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              gradient: OrexColors.copperGradient,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                const Icon(Icons.gpp_maybe, color: OrexColors.cream),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Сессия не подтверждена',
                          style: TextStyle(
                              color: OrexColors.cream,
                              fontWeight: FontWeight.w700)),
                      Text('Нажмите, чтобы подтвердить с другого устройства',
                          style:
                              TextStyle(color: OrexColors.cream, fontSize: 12)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: OrexColors.cream),
                IconButton(
                  tooltip: 'Скрыть',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: const Icon(Icons.close,
                      color: OrexColors.cream, size: 18),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SquirrelMascot(
        caption: 'Выберите чат слева,\nи Белочка принесёт ваши сообщения',
      ),
    );
  }
}
