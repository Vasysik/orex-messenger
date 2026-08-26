import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/features/chats/conversation/message_composer_controller.dart';

void main() {
  group('OrexMessageComposerController', () {
    test('startEdit clears reply, attachments and emoji picker state', () {
      final composer = OrexMessageComposerController<String>();
      composer.startReply('reply-event');
      composer.showEmojiPickerAfterKeyboardHide();
      composer.queueAttachments([_file('photo.jpg')]);

      composer.startEdit('edit-event');

      expect(composer.editing, 'edit-event');
      expect(composer.replyTo, isNull);
      expect(composer.attachments.files, isEmpty);
      expect(composer.showEmojiPicker, isFalse);
    });

    test('startReply clears editing and keeps queued attachments', () {
      final composer = OrexMessageComposerController<String>();
      composer.startEdit('edit-event');
      composer.queueAttachments([_file('photo.jpg')]);

      composer.startReply('reply-event');

      expect(composer.editing, isNull);
      expect(composer.replyTo, 'reply-event');
      expect(composer.attachments.files, hasLength(1));
    });

    test('queueAttachments clears editing only when a file is accepted', () {
      final composer = OrexMessageComposerController<String>();
      composer.startEdit('edit-event');

      final rejected = composer.queueAttachments([
        PlatformFile(name: 'missing-bytes.txt', size: 1),
      ]);

      expect(rejected.hasAccepted, isFalse);
      expect(composer.editing, 'edit-event');

      final accepted = composer.queueAttachments([_file('photo.jpg')]);

      expect(accepted.hasAccepted, isTrue);
      expect(composer.editing, isNull);
    });

    test('clearAfterAttachmentSend clears draft state and queued files', () {
      final composer = OrexMessageComposerController<String>();
      composer.startReply('reply-event');
      composer.queueAttachments([_file('photo.jpg')]);
      composer.showEmojiPickerAfterKeyboardHide();

      composer.clearAfterAttachmentSend();

      expect(composer.replyTo, isNull);
      expect(composer.editing, isNull);
      expect(composer.attachments.files, isEmpty);
      expect(composer.showEmojiPicker, isFalse);
    });

    test(
      'clearAfterTextSend clears edit/reply state without touching files',
      () {
        final composer = OrexMessageComposerController<String>();
        composer.startReply('reply-event');
        composer.queueAttachments([_file('photo.jpg')]);

        composer.clearAfterTextSend();

        expect(composer.replyTo, isNull);
        expect(composer.editing, isNull);
        expect(composer.attachments.files, hasLength(1));
      },
    );

    test('emoji panel owns input without requesting Android IME focus', () {
      final composer = OrexMessageComposerController<String>();

      expect(composer.shouldRefocusTextInputAfterEmoji, isTrue);

      composer.showEmojiPickerAfterKeyboardHide();
      expect(composer.shouldRefocusTextInputAfterEmoji, isFalse);

      composer.hideEmojiPicker();
      expect(composer.shouldRefocusTextInputAfterEmoji, isTrue);
    });
  });
}

PlatformFile _file(String name) {
  return PlatformFile(name: name, size: 1, bytes: Uint8List(1));
}
