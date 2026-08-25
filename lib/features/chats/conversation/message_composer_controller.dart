import 'package:file_picker/file_picker.dart';

import 'attachment_queue.dart';

final class OrexMessageComposerController<T> {
  OrexMessageComposerController({OrexAttachmentQueue? attachments})
    : attachments = attachments ?? OrexAttachmentQueue();

  final OrexAttachmentQueue attachments;

  T? editing;
  T? replyTo;
  bool showEmojiPicker = false;

  bool get isEditing => editing != null;
  bool get shouldRefocusTextInputAfterEmoji => !showEmojiPicker;

  void startEdit(T event) {
    editing = event;
    replyTo = null;
    attachments.clear();
    showEmojiPicker = false;
  }

  void cancelEdit() {
    editing = null;
  }

  void startReply(T event) {
    replyTo = event;
    editing = null;
    showEmojiPicker = false;
  }

  void cancelReply() {
    replyTo = null;
  }

  OrexAttachmentQueueResult queueAttachments(List<PlatformFile> files) {
    final result = attachments.addAll(files);
    if (result.hasAccepted) {
      editing = null;
    }
    return result;
  }

  List<PlatformFile> attachmentSnapshot() => attachments.snapshot();

  void clearAfterAttachmentSend() {
    attachments.clear();
    replyTo = null;
    editing = null;
    showEmojiPicker = false;
  }

  void clearAfterTextSend() {
    editing = null;
    replyTo = null;
    showEmojiPicker = false;
  }

  void toggleEmojiPicker() {
    showEmojiPicker = !showEmojiPicker;
  }

  void showEmojiPickerAfterKeyboardHide() {
    showEmojiPicker = true;
  }

  void hideEmojiPicker() {
    showEmojiPicker = false;
  }
}
