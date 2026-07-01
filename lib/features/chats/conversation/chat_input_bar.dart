part of 'chat_view.dart';

class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.canSend,
    required this.onSend,
    this.editing = false,
    this.onCancelEdit,
    this.replyTo,
    this.onCancelReply,
    required this.onPickEmoji,
    required this.onAttach,
    required this.attachedFiles,
    required this.onCancelAttachment,
    required this.showEmojiPicker,
    required this.onToggleEmojiPicker,
    required this.onTapInput, // Колбек нажатия на поле ввода
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool canSend;
  final VoidCallback onSend;
  final bool editing;
  final VoidCallback? onCancelEdit;
  final Event? replyTo;
  final VoidCallback? onCancelReply;
  final void Function(String emoji) onPickEmoji;
  final VoidCallback onAttach;
  final List<PlatformFile> attachedFiles;
  final ValueChanged<int> onCancelAttachment;
  final bool showEmojiPicker;
  final VoidCallback onToggleEmojiPicker;
  final VoidCallback onTapInput;

  // ИСПРАВЛЕНИЕ: Сделали массив смайликов публичным для доступа препроцессора
  static const emojis = [
    '😀',
    '😁',
    '😂',
    '🤣',
    '😊',
    '😍',
    '😘',
    '😎',
    '🤩',
    '🥳',
    '🤔',
    '😴',
    '😭',
    '😡',
    '👍',
    '👎',
    '🙏',
    '👏',
    '🔥',
    '❤️',
    '🎉',
    '✨',
    '💯',
    '✅',
    '❌',
    '⚡',
    '🌟',
    '😅',
    '😉',
    '🙃',
    '🤝',
    '💪',
    '👀',
    '🍀',
    '☕',
    '🚀',
    '🐿️',
    '💜',
    '😇',
    '🤗',
  ];

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final reply = replyTo;
    final files = attachedFiles;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (editing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
            child: Row(
              children: [
                const Icon(Icons.edit, size: 16, color: OrexColors.copper),
                const SizedBox(width: 8),
                const Expanded(child: Text('Редактирование сообщения')),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onCancelEdit,
                ),
              ],
            ),
          ),
        if (reply != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
            child: Row(
              children: [
                const Icon(Icons.reply, size: 16, color: OrexColors.copper),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ответ: ${reply.calcLocalizedBodyFallback(const MatrixDefaultLocalizations(), hideReply: true, hideEdit: true)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: onCancelReply,
                ),
              ],
            ),
          ),
        if (files.isNotEmpty)
          Container(
            height: 80,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: files.length,
              itemBuilder: (context, idx) {
                final f = files[idx];
                final isImg = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp']
                    .contains((f.extension ?? '').toLowerCase());
                return Container(
                  key: ValueKey(f.name + f.size.toString()),
                  width: 72,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: OrexColors.copper.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: isImg && f.bytes != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(9),
                                child: Image.memory(
                                  f.bytes!,
                                  fit: BoxFit.cover,
                                  width: 72,
                                  height: 72,
                                ),
                              )
                            : const Icon(Icons.insert_drive_file,
                                color: OrexColors.copper),
                      ),
                      Positioned(
                        right: 2,
                        top: 2,
                        child: GestureDetector(
                          onTap: () => onCancelAttachment(idx),
                          child: Container(
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black54,
                            ),
                            padding: const EdgeInsets.all(2),
                            child: const Icon(Icons.close,
                                size: 12, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
          child: Row(
            children: [
              IconButton(
                onPressed: canSend ? onAttach : null,
                icon: const Icon(Icons.attach_file),
                color: OrexColors.copper,
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: (isDark ? Colors.black : Colors.white)
                        .withValues(alpha: 0.28),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: OrexColors.copper.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: controller,
                          focusNode: focusNode,
                          readOnly: !canSend,
                          onTap: canSend ? onTapInput : null,
                          minLines: 1,
                          maxLines: 5,
                          textInputAction: TextInputAction.send,
                          onSubmitted: canSend ? (_) => onSend() : null,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: canSend
                                ? (files.isNotEmpty
                                    ? 'Добавить подпись…'
                                    : 'Сообщение')
                                : 'Только чтение',
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: canSend ? onToggleEmojiPicker : null,
                        child: Icon(
                          showEmojiPicker
                              ? Icons.keyboard_hide_outlined
                              : Icons.emoji_emotions_outlined,
                          color: OrexColors.copper
                              .withValues(alpha: canSend ? 0.8 : 0.32),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: canSend ? onSend : null,
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: canSend ? OrexColors.copperGradient : null,
                    color: canSend
                        ? null
                        : OrexColors.walnut.withValues(alpha: 0.18),
                  ),
                  child: Icon(
                    Icons.send,
                    color: canSend
                        ? OrexColors.cream
                        : OrexColors.copper.withValues(alpha: 0.36),
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
