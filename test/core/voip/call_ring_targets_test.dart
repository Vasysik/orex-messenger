import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_ring_targets.dart';

void main() {
  group('orexResolveCallRingTargets', () {
    test('excludes local, empty and duplicate member ids', () {
      final targets = orexResolveCallRingTargets(
        localUserId: '@me:example.org',
        joinedUserIds: const <String>[
          '@me:example.org',
          '@alice:example.org',
          ' @alice:example.org ',
          '',
          '   ',
        ],
      );

      expect(targets, <String>{'@alice:example.org'});
    });

    test('uses direct-chat target when member list is not hydrated yet', () {
      final targets = orexResolveCallRingTargets(
        localUserId: '@me:example.org',
        joinedUserIds: const <String>['@me:example.org'],
        directChatMatrixId: ' @alice:example.org ',
      );

      expect(targets, <String>{'@alice:example.org'});
    });

    test('never rings the local user through the direct-chat fallback', () {
      final targets = orexResolveCallRingTargets(
        localUserId: '@me:example.org',
        joinedUserIds: const <String>[],
        directChatMatrixId: '@me:example.org',
      );

      expect(targets, isEmpty);
    });
  });
}
