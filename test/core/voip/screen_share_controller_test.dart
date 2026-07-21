import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/screen_share_controller.dart';

void main() {
  group('OrexScreenShareController', () {
    test('builds desktop screen capture candidates with fallbacks', () {
      final candidates = OrexScreenShareController.candidateIds(
        sourceId: 'display-2',
        sourceType: 'screen',
        sourceName: 'Screen 2',
      );

      expect(candidates, [
        'display-2',
        'screen:1:0',
        'screen:display-2:0',
        null,
      ]);
    });

    test('does not fall back from window sources to entire screen', () {
      final candidates = OrexScreenShareController.candidateIds(
        sourceId: 'window-7',
        sourceType: 'window',
        sourceName: 'Editor',
      );

      expect(candidates, ['window-7']);
    });

    test('deduplicates normalized source ids', () {
      final candidates = OrexScreenShareController.candidateIds(
        sourceId: ' screen:0:0 ',
        sourceType: 'screen',
        sourceName: 'Screen 1',
      );

      expect(candidates, ['screen:0:0', null]);
    });

    test('extracts zero-based screen indices from display names', () {
      expect(OrexScreenShareController.screenIndexFromName('Screen 1'), 0);
      expect(OrexScreenShareController.screenIndexFromName('Display 3'), 2);
      expect(OrexScreenShareController.screenIndexFromName('Primary'), isNull);
    });

    test('treats null source type as a desktop screen source', () {
      expect(OrexScreenShareController.isDesktopScreenSource(null), isTrue);
      expect(OrexScreenShareController.isDesktopScreenSource('screen'), isTrue);
      expect(
        OrexScreenShareController.isDesktopScreenSource('window'),
        isFalse,
      );
    });

    test('enables Android sharing without a desktop source picker', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
      });

      expect(OrexScreenShareController.isSupported, isTrue);
      expect(OrexScreenShareController.desktopNeedsExplicitSource, isFalse);
    });
  });
}
