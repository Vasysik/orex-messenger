import 'package:flutter/material.dart';
import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../theme/theme_controller.dart';
import '../../widgets/squirrel_mascot.dart';
import '../chat/chat_view.dart';
import '../chat_list/chat_list_panel.dart';
import '../new_chat/new_chat_screen.dart';
import '../settings/settings_screen.dart';

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

  static const double _wideBreakpoint = 900;

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(matrix: widget.matrix, theme: widget.theme),
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

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(child: isWide ? _buildWide() : _buildNarrow()),
      ),
    );
  }

  Widget _chatList({required bool showSelection}) => ChatListPanel(
        matrix: widget.matrix,
        selectedRoomId: showSelection ? _selectedRoomId : null,
        onSelect: (id) => setState(() => _selectedRoomId = id),
        onOpenSettings: _openSettings,
        onNewChat: _openNewChat,
      );

  Widget _buildWide() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: 360,
            child: GlassPanel(
              borderRadius: 24,
              child: _chatList(showSelection: true),
            ),
          ),
          const SizedBox(width: 12),
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
    );
  }

  Widget _buildNarrow() {
    if (_selectedRoomId == null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: GlassPanel(
          borderRadius: 24,
          child: _chatList(showSelection: false),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GlassPanel(
        borderRadius: 24,
        child: ChatView(
          matrix: widget.matrix,
          roomId: _selectedRoomId!,
          onBack: () => setState(() => _selectedRoomId = null),
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
