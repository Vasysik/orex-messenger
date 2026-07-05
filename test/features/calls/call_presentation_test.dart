import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/features/calls/call_presentation.dart';

void main() {
  group('OrexCallPresentation', () {
    test('keeps every visible item when no participant is focused', () {
      final visible = OrexCallPresentation.visibleItems<String>(
        items: ['alice', 'bob'],
        focusedIdentity: null,
        identityOf: (id) => id,
      );

      expect(visible, ['alice', 'bob']);
    });

    test('filters visible items to the focused identity', () {
      final visible = OrexCallPresentation.visibleItems<String>(
        items: ['alice', 'bob', 'carol'],
        focusedIdentity: 'bob',
        identityOf: (id) => id,
      );

      expect(visible, ['bob']);
    });

    test('builds notices in stable UI order', () {
      final notices = OrexCallPresentation.noticesForState(
        hasCameraError: true,
        error: 'network hiccup',
        canPublishMedia: false,
      );

      expect(notices.map((notice) => notice.kind), [
        OrexCallNoticeKind.camera,
        OrexCallNoticeKind.error,
        OrexCallNoticeKind.listenOnly,
      ]);
      expect(notices[1].message, 'network hiccup');
    });

    test('maps call title from listen-only state', () {
      expect(
        OrexCallPresentation.titleFor(listenOnly: true),
        'Голосовой канал · просмотр',
      );
      expect(OrexCallPresentation.titleFor(listenOnly: false), 'Звонок');
    });
  });

  group('OrexCallVideoPreferences', () {
    test('prefers screen share by default and toggles by identity', () {
      final preferences = OrexCallVideoPreferences();

      expect(preferences.prefersScreenShare('alice'), isTrue);
      preferences.toggle('alice');
      expect(preferences.prefersScreenShare('alice'), isFalse);
      preferences.toggle('alice');
      expect(preferences.prefersScreenShare('alice'), isTrue);
      expect(preferences.prefersScreenShare('bob'), isTrue);
    });
  });
}
