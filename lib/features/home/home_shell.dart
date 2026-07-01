import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../../core/matrix/matrix_service.dart';
import '../../core/logging/orex_logger.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/theme/theme_controller.dart';
import '../../shared/widgets/orex_loading_overlay.dart';
import '../../shared/widgets/squirrel_mascot.dart';
import '../calls/call_screen.dart';
import '../calls/minimized_call_panel.dart';
import '../chats/conversation/chat_view.dart';
import '../chats/conversation/public_room_preview_view.dart';
import '../chats/sidebar/chat_folder_controller.dart';
import '../chats/sidebar/chat_list_panel.dart';
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

enum _CreateRoomKind { group, channel, supergroup }

class _HomeShellState extends State<HomeShell> {
  String? _selectedRoomId;
  OrexRoomPreview? _previewRoom;
  bool _verifyBannerDismissed = false;
  double _chatListWidth = 360; // ширина левой колонки (можно тянуть мышью)
  late final ChatFolderController _folders;
  bool _appliedSavedChatListWidth = false;
  bool _creatingRoom = false;
  final Map<String, String> _visibleSupergroupChildBySpace = <String, String>{};

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
    final kind = await showModalBottomSheet<_CreateRoomKind>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassPanel(
            borderRadius: 24,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CreateRoomChoice(
                    icon: Icons.group_add,
                    title: 'Новая группа',
                    subtitle: 'Обычный чат с участниками и звонком',
                    onTap: () => Navigator.pop(ctx, _CreateRoomKind.group),
                  ),
                  _CreateRoomChoice(
                    icon: Icons.campaign,
                    title: 'Новый канал',
                    subtitle: 'Комната, где пишут админы',
                    onTap: () => Navigator.pop(ctx, _CreateRoomKind.channel),
                  ),
                  _CreateRoomChoice(
                    icon: Icons.hub,
                    title: 'Новая супергруппа',
                    subtitle: 'Space с внутренними чатами',
                    onTap: () => Navigator.pop(ctx, _CreateRoomKind.supergroup),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (kind == null || !mounted) return;
    await _createRoom(kind);
  }

  Future<void> _createRoom(_CreateRoomKind kind) async {
    final config = await _askRoom(kind);
    if (config == null || config.name.isEmpty) return;
    if (mounted) setState(() => _creatingRoom = true);
    OrexLog.d('Home', 'create room kind=$kind name=${config.name} public=${config.public} alias=${config.localAlias}');
    try {
      final roomId = switch (kind) {
        _CreateRoomKind.group => await widget.matrix.createGroup(
            config.name,
            public: config.public,
            localAlias: config.localAlias,
          ),
        _CreateRoomKind.channel => await widget.matrix.createChannel(
            config.name,
            public: config.public,
            localAlias: config.localAlias,
          ),
        _CreateRoomKind.supergroup => await widget.matrix.createSupergroup(
            config.name,
            public: config.public,
            localAlias: config.localAlias,
          ),
      };
      if (mounted) {
        setState(() {
          _previewRoom = null;
          _selectedRoomId = roomId;
        });
      }
    } catch (e) {
      OrexLog.d('Home', 'create room failed kind=$kind name=${config.name}', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось создать: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _creatingRoom = false);
    }
  }

  Future<({String name, bool public, String? localAlias})?> _askRoom(
    _CreateRoomKind kind,
  ) {
    final name = TextEditingController();
    final alias = TextEditingController();
    var public = false;
    return showDialog<({String name, bool public, String? localAlias})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(_createDialogTitle(kind)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Название'),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: public,
                  title: const Text('Публичная'),
                  subtitle: Text(
                    public ? 'Видна в публичных комнатах' : 'Только по приглашению',
                  ),
                  onChanged: (value) => setDialogState(() => public = value),
                ),
                TextField(
                  controller: alias,
                  enabled: public,
                  decoration: const InputDecoration(
                    labelText: 'ID',
                    hintText: 'team-news',
                    prefixIcon: Icon(Icons.tag),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final roomName = name.text.trim();
                if (roomName.isEmpty) return;
                Navigator.pop(
                  ctx,
                  (
                    name: roomName,
                    public: public,
                    localAlias: public ? alias.text.trim() : null,
                  ),
                );
              },
              child: const Text('Создать'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      name.dispose();
      alias.dispose();
    });
  }

  String _createDialogTitle(_CreateRoomKind kind) => switch (kind) {
        _CreateRoomKind.group => 'Новая группа',
        _CreateRoomKind.channel => 'Новый канал',
        _CreateRoomKind.supergroup => 'Новая супергруппа',
      };

  void _openPublicRoomPreview(OrexRoomPreview preview) {
    OrexLog.d('Home', 'open public preview room=${preview.roomId} name=${preview.name}');
    setState(() {
      _selectedRoomId = null;
      _previewRoom = preview;
    });
  }

  void _selectRoom(String roomId, {String source = 'unknown'}) {
    OrexLog.d('Home', 'select room source=$source room=$roomId');
    setState(() {
      _previewRoom = null;
      _selectedRoomId = roomId;
    });
  }

  void _openRoomReference(String reference) {
    _openRoomReferenceAsync(reference);
  }

  Future<void> _openRoomReferenceAsync(String reference) async {
    final ref = reference.trim();
    if (ref.isEmpty) return;
    OrexLog.d('Home', 'open room reference ref=$ref');

    final localId = widget.matrix.roomIdForReference(ref);
    if (localId != null) {
      _selectRoom(localId, source: 'invite-card-local');
      return;
    }

    final localPreview = widget.matrix.localPreviewForReference(ref);
    if (localPreview != null) {
      _openPublicRoomPreview(localPreview);
      return;
    }

    try {
      final publicPreview = await widget.matrix.publicPreviewForReference(ref);
      if (!mounted) return;
      if (publicPreview != null) {
        _openPublicRoomPreview(publicPreview);
        return;
      }
    } catch (e) {
      OrexLog.d('Home', 'public preview lookup failed ref=$ref', e);
    }

    try {
      final joinedId = await widget.matrix.joinRoomReference(ref);
      if (!mounted) return;
      _selectRoom(joinedId, source: 'invite-card-join');
      return;
    } catch (e) {
      OrexLog.d('Home', 'open room reference failed ref=$ref', e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось открыть приглашение: $e')),
      );
    }
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
    OrexLog.d('Home', 'start/join call room=$roomId video=$video');
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
    final room = _roomWithVisibleCall();
    if (room != null) {
      return JoinCallPanel(
        matrix: widget.matrix,
        room: room,
        onJoin: () => _startCall(room.id, false),
      );
    }
    return const SizedBox.shrink();
  }

  Room? _roomWithVisibleCall() {
    final roomId = _selectedRoomId;
    if (roomId == null) return null;
    final room = widget.matrix.client.getRoomById(roomId);
    if (room == null) return null;

    if (room.isSpace) {
      final visibleChildId = _visibleSupergroupChildBySpace[room.id];
      if (visibleChildId == null) return null;
      final visibleChild = widget.matrix.client.getRoomById(visibleChildId);
      if (visibleChild == null) return null;
      return widget.matrix.roomHasActiveCall(visibleChild) ? visibleChild : null;
    }

    return widget.matrix.roomHasActiveCall(room) ? room : null;
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return PopScope(
      canPop: _selectedRoomId == null && _previewRoom == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_previewRoom != null) {
          setState(() => _previewRoom = null);
        } else if (_selectedRoomId != null) {
          setState(() => _selectedRoomId = null);
        }
      },
      child: AmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              SafeArea(
                child: ListenableBuilder(
                  listenable: Listenable.merge([widget.matrix, widget.matrix.call]),
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
              if (_creatingRoom) const OrexLoadingOverlay(),
            ],
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
        onSelect: (id) => _selectRoom(id, source: 'chat-list'),
        onOpenPublicRoomPreview: _openPublicRoomPreview,
        onOpenSettings: _openSettings,
        onNewChat: _openNewChat,
        folders: _folders,
      );

  void _onVisibleSupergroupChildChanged(String spaceId, String childId) {
    if (!mounted || _visibleSupergroupChildBySpace[spaceId] == childId) return;
    OrexLog.d('Home', 'visible supergroup child space=$spaceId child=$childId');
    setState(() => _visibleSupergroupChildBySpace[spaceId] = childId);
  }

  Widget _conversationPane({VoidCallback? onBack}) {
    final preview = _previewRoom;
    if (preview != null) {
      return PublicRoomPreviewView(
        key: ValueKey('preview-${preview.roomId}'),
        matrix: widget.matrix,
        preview: preview,
        onBack: onBack,
        onJoined: (roomId) {
          if (!mounted) return;
          setState(() {
            _previewRoom = null;
            _selectedRoomId = roomId;
          });
        },
      );
    }

    final roomId = _selectedRoomId;
    if (roomId == null) return const _EmptyConversation();
    return ChatView(
      key: ValueKey(roomId),
      matrix: widget.matrix,
      roomId: roomId,
      onBack: onBack,
      selectedSupergroupChildId: _visibleSupergroupChildBySpace[roomId],
      onSupergroupChildVisibleChanged: _onVisibleSupergroupChildChanged,
      onOpenRoomReference: _openRoomReference,
    );
  }

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
                    child: _conversationPane(onBack: null),
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
    if (_selectedRoomId == null && _previewRoom == null) {
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
              child: _conversationPane(
                onBack: () => setState(() {
                  _previewRoom = null;
                  _selectedRoomId = null;
                }),
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

class _CreateRoomChoice extends StatelessWidget {
  const _CreateRoomChoice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: OrexColors.copper),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
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
