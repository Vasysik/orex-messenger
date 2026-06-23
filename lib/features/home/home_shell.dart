import 'package:flutter/material.dart';
import '../../core/call_service.dart';
import '../../core/matrix_service.dart';
import '../../theme/glass.dart';
import '../../widgets/squirrel_mascot.dart';
import '../call/call_overlay.dart';
import '../chat/chat_view.dart';
import '../chat_list/chat_list_panel.dart';

/// Главный экран. На широком экране (web/desktop) — две панели рядом,
/// как в Telegram Desktop. На узком (телефон) — стек с навигацией.
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.matrix,
    required this.calls,
  });

  final MatrixService matrix;
  final CallService calls;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  String? _selectedRoomId;

  static const double _wideBreakpoint = 900;

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;

    return AmbientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Stack(
            children: [
              isWide ? _buildWide() : _buildNarrow(),
              // Оверлей звонка поверх всего интерфейса.
              AnimatedBuilder(
                animation: widget.calls,
                builder: (_, __) => widget.calls.inCall
                    ? CallOverlay(calls: widget.calls)
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWide() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: 360,
            child: GlassPanel(
              borderRadius: 24,
              child: ChatListPanel(
                matrix: widget.matrix,
                selectedRoomId: _selectedRoomId,
                onSelect: (id) => setState(() => _selectedRoomId = id),
              ),
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
                      calls: widget.calls,
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
          child: ChatListPanel(
            matrix: widget.matrix,
            selectedRoomId: null,
            onSelect: (id) => setState(() => _selectedRoomId = id),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(8),
      child: GlassPanel(
        borderRadius: 24,
        child: ChatView(
          matrix: widget.matrix,
          calls: widget.calls,
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
