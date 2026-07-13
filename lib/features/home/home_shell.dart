import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../../core/matrix/matrix_service.dart';
import '../../core/config/app_version.dart';
import '../../core/logging/orex_logger.dart';
import '../../shared/theme/glass.dart';
import '../../shared/theme/orex_theme.dart';
import '../../shared/theme/theme_controller.dart';
import '../../shared/widgets/orex_loading_overlay.dart';
import '../../shared/widgets/orex_choice_sheet.dart';
import '../../shared/widgets/orex_dialogs.dart';
import '../../shared/widgets/squirrel_mascot.dart';
import '../calls/call_screen.dart';
import '../calls/call_launch_coordinator.dart';
import '../calls/minimized_call_panel.dart';
import '../chats/conversation/chat_view.dart';
import '../chats/conversation/conversation_preview_view.dart';
import '../chats/sidebar/chat_folder_controller.dart';
import '../chats/sidebar/chat_list_panel.dart';
import '../settings/settings_screen.dart';
import '../settings/verify_session_screen.dart';
import 'home_conversation_coordinator.dart';

/// Главный экран. На широком экране (web/desktop) — две панели рядом,
/// как в Telegram Desktop. На узком (телефон) — стек с навигацией.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.matrix,
    required this.theme,
    required this.version,
    this.pushRoomId,
    this.pushOpenGeneration = 0,
  });

  final MatrixService matrix;
  final ThemeController theme;
  final OrexAppVersion version;
  final String? pushRoomId;
  final int pushOpenGeneration;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

enum _CreateRoomKind { group, channel, supergroup }

class _HomeShellState extends State<HomeShell> {
  bool _verifyBannerDismissed = false;
  double _chatListWidth = 360; // ширина левой колонки (можно тянуть мышью)
  late final ChatFolderController _folders;
  late final OrexHomeConversationCoordinator _conversation;
  bool _appliedSavedChatListWidth = false;
  bool _creatingRoom = false;
  int _lastPushOpenGeneration = -1;

  static const double _wideBreakpoint = 900;

  @override
  void initState() {
    super.initState();
    _conversation = OrexHomeConversationCoordinator(
      onForegroundRoomIdChanged: widget.matrix.setForegroundRoomId,
    )..addListener(_onConversationChanged);
    _folders = ChatFolderController(matrix: widget.matrix)
      ..addListener(_onFolderPrefsChanged);
    _folders.load();
    widget.matrix.addListener(_onMatrixChanged);
    _conversation.syncForeground();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryApplyPushOpen());
  }

  @override
  void didUpdateWidget(covariant HomeShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pushOpenGeneration != widget.pushOpenGeneration ||
        oldWidget.pushRoomId != widget.pushRoomId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryApplyPushOpen());
    }
  }

  void _onConversationChanged() {
    if (mounted) setState(() {});
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
    _tryApplyPushOpen();
    final roomId = _conversation.selectedRoomId;
    if (roomId == null || !mounted) return;
    final room = widget.matrix.client.getRoomById(roomId);
    if (room == null || room.membership == Membership.leave) {
      _conversation.clearSelection();
    }
  }

  void _tryApplyPushOpen() {
    if (!mounted ||
        widget.pushOpenGeneration <= _lastPushOpenGeneration) {
      return;
    }
    final roomId = widget.pushRoomId?.trim();
    if (roomId == null || roomId.isEmpty) {
      _lastPushOpenGeneration = widget.pushOpenGeneration;
      return;
    }

    final room = widget.matrix.client.getRoomById(roomId);
    if (room == null) {
      // Cold start: sync может ещё не восстановить комнату. Оставляем событие
      // pending и повторяем на следующем Matrix change.
      return;
    }
    _lastPushOpenGeneration = widget.pushOpenGeneration;
    if (room.membership == Membership.leave) return;
    _selectRoom(roomId, source: 'push-notification');
  }

  @override
  void dispose() {
    _folders
      ..removeListener(_onFolderPrefsChanged)
      ..dispose();
    _conversation
      ..removeListener(_onConversationChanged)
      ..dispose();
    widget.matrix.setForegroundRoomId(null);
    widget.matrix.removeListener(_onMatrixChanged);
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          matrix: widget.matrix,
          theme: widget.theme,
          version: widget.version,
        ),
      ),
    );
  }

  Future<void> _openNewChat() async {
    final kind = await showOrexChoiceSheet<_CreateRoomKind>(
      context,
      options: const [
        OrexChoiceSheetOption<_CreateRoomKind>(
          value: _CreateRoomKind.group,
          icon: Icons.group_add,
          title: 'Новая группа',
          subtitle: 'Обычный чат с участниками и звонком',
        ),
        OrexChoiceSheetOption<_CreateRoomKind>(
          value: _CreateRoomKind.channel,
          icon: Icons.campaign,
          title: 'Новый канал',
          subtitle: 'Комната, где пишут админы',
        ),
        OrexChoiceSheetOption<_CreateRoomKind>(
          value: _CreateRoomKind.supergroup,
          icon: Icons.hub,
          title: 'Новая супергруппа',
          subtitle: 'Space с внутренними чатами',
        ),
      ],
    );
    if (kind == null || !mounted) return;
    await _createRoom(kind);
  }

  Future<void> _createRoom(_CreateRoomKind kind) async {
    final config = await _askRoom(kind);
    if (config == null || config.name.isEmpty) return;
    if (mounted) setState(() => _creatingRoom = true);
    OrexLog.d(
      'Home',
      'create room kind=$kind name=${config.name} public=${config.public} alias=${config.localAlias}',
    );
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
        _conversation.selectRoom(roomId);
      }
    } catch (e) {
      OrexLog.d('Home', 'create room failed kind=$kind name=${config.name}', e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось создать комнату')),
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
    return showOrexStatefulFormDialog<
          ({String name, bool public, String? localAlias})
        >(
          context,
          title: _createDialogTitle(kind),
          confirmLabel: '\u0421\u043e\u0437\u0434\u0430\u0442\u044c',
          contentBuilder: (ctx, setDialogState) => Column(
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
                  public
                      ? 'Видна в публичных комнатах'
                      : 'Только по приглашению',
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
          onSubmit: () {
            final roomName = name.text.trim();
            if (roomName.isEmpty) return null;
            return (
              name: roomName,
              public: public,
              localAlias: public ? alias.text.trim() : null,
            );
          },
        )
        .whenComplete(() {
          name.dispose();
          alias.dispose();
        });
  }

  String _createDialogTitle(_CreateRoomKind kind) => switch (kind) {
    _CreateRoomKind.group => 'Новая группа',
    _CreateRoomKind.channel => 'Новый канал',
    _CreateRoomKind.supergroup => 'Новая супергруппа',
  };

  void _openConversationPreview(OrexConversationPreview preview) {
    OrexLog.d(
      'Home',
      'open conversation preview kind=${preview.kind.name} id=${preview.id} title=${preview.title}',
    );
    _conversation.openPreview(preview);
  }

  void _selectRoom(String roomId, {String source = 'unknown'}) {
    OrexLog.d('Home', 'select room source=$source room=$roomId');
    _conversation.selectRoom(roomId);
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
      _openConversationPreview(OrexConversationPreview.fromRoom(localPreview));
      return;
    }

    try {
      final publicPreview = await widget.matrix.publicPreviewForReference(ref);
      if (!mounted) return;
      if (publicPreview != null) {
        _openConversationPreview(
          OrexConversationPreview.fromRoom(publicPreview),
        );
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
        const SnackBar(content: Text('Не удалось открыть приглашение')),
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

  /// Начать/присоединиться к звонку. Presentation order централизован в
  /// [launchOrexCall], чтобы мобильный экран открывался до сетевого ожидания.
  Future<void> _startCall(String roomId, bool video) async {
    OrexLog.d('Home', 'start/join call room=$roomId video=$video');
    await launchOrexCall(
      context,
      matrix: widget.matrix,
      roomId: roomId,
      video: video,
      wideBreakpoint: _wideBreakpoint,
    );
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
    final roomId = _conversation.selectedRoomId;
    if (roomId == null) return null;
    final room = widget.matrix.client.getRoomById(roomId);
    if (room == null) return null;

    if (room.isSpace) {
      final visibleChildId = _conversation.selectedSupergroupChildId(room.id);
      if (visibleChildId == null) return null;
      final visibleChild = widget.matrix.client.getRoomById(visibleChildId);
      if (visibleChild == null) return null;
      return widget.matrix.roomHasActiveCall(visibleChild)
          ? visibleChild
          : null;
    }

    return widget.matrix.roomHasActiveCall(room) ? room : null;
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return PopScope(
      canPop: _conversation.canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_conversation.clearPreview()) return;
        _conversation.clearSelection();
      },
      child: AmbientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              SafeArea(
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    widget.matrix,
                    widget.matrix.call,
                  ]),
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
    selectedRoomId: showSelection ? _conversation.selectedRoomId : null,
    onSelect: (id) => _selectRoom(id, source: 'chat-list'),
    onOpenPreview: _openConversationPreview,
    onOpenSettings: _openSettings,
    onNewChat: _openNewChat,
    folders: _folders,
  );

  void _onVisibleSupergroupChildChanged(String spaceId, String childId) {
    if (!mounted) return;
    final changed = _conversation.showSupergroupChild(spaceId, childId);
    if (!changed) return;
    OrexLog.d('Home', 'visible supergroup child space=$spaceId child=$childId');
  }

  Widget _conversationPane({VoidCallback? onBack}) {
    final preview = _conversation.previewTarget;
    if (preview != null) {
      return ConversationPreviewView(
        key: ValueKey('preview-${preview.key}'),
        matrix: widget.matrix,
        preview: preview,
        onEnter: widget.matrix.enterConversationPreview,
        onBack: onBack,
        onEntered: (roomId) {
          if (!mounted) return;
          _conversation.enterPreview(roomId);
        },
      );
    }

    final roomId = _conversation.selectedRoomId;
    if (roomId == null) return const _EmptyConversation();
    return ChatView(
      key: ValueKey(roomId),
      matrix: widget.matrix,
      roomId: roomId,
      onBack: onBack,
      selectedSupergroupChildId: _conversation.selectedSupergroupChildId(
        roomId,
      ),
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
    if (_conversation.canPop) {
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
                onBack: () {
                  _conversation.clearSelection();
                },
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
                      Text(
                        'Сессия не подтверждена',
                        style: TextStyle(
                          color: OrexColors.cream,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Нажмите, чтобы подтвердить с другого устройства',
                        style: TextStyle(color: OrexColors.cream, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: OrexColors.cream),
                IconButton(
                  tooltip: 'Скрыть',
                  visualDensity: VisualDensity.compact,
                  onPressed: onClose,
                  icon: const Icon(
                    Icons.close,
                    color: OrexColors.cream,
                    size: 18,
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
