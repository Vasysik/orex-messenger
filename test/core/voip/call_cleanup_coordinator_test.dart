import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_cleanup_coordinator.dart';

void main() {
  test('releases SDK and key backend before removing Matrix membership', () async {
    final order = <String>[];

    final result = await const OrexCallCleanupCoordinator().cleanup(
      sessions: [
        OrexCallCleanupSession(
          label: 'old-call',
          leave: () async { order.add('leave'); },
          disposeBackend: () async { order.add('backend'); },
        ),
      ],
      removeMembership: () async { order.add('membership'); },
    );

    expect(order, ['leave', 'backend', 'membership']);
    expect(result.membershipRemoved, isTrue);
    expect(result.failures, isEmpty);
  });

  test('still removes membership when stale SDK leave fails', () async {
    final order = <String>[];

    final result = await const OrexCallCleanupCoordinator().cleanup(
      sessions: [
        OrexCallCleanupSession(
          label: 'old-call',
          leave: () async {
            order.add('leave');
            throw StateError('offline');
          },
          disposeBackend: () async { order.add('backend'); },
        ),
      ],
      removeMembership: () async { order.add('membership'); },
    );

    expect(order, ['leave', 'backend', 'membership']);
    expect(result.membershipRemoved, isTrue);
    expect(result.failures.single.step, 'old-call:leave');
  });

  test('a stuck SDK leave cannot block backend and membership cleanup', () async {
    final order = <String>[];
    final stuck = Completer<void>();

    final result = await const OrexCallCleanupCoordinator().cleanup(
      stepTimeout: const Duration(milliseconds: 10),
      sessions: [
        OrexCallCleanupSession(
          label: 'orphan',
          leave: () {
            order.add('leave');
            return stuck.future;
          },
          disposeBackend: () async { order.add('backend'); },
        ),
      ],
      removeMembership: () async { order.add('membership'); },
    );

    expect(order, ['leave', 'backend', 'membership']);
    expect(result.membershipRemoved, isTrue);
    expect(result.failures.single.step, 'orphan:leave');

    stuck.complete();
    await stuck.future;
  });

  test('reports membership failure so caller can retry after sync', () async {
    final result = await const OrexCallCleanupCoordinator().cleanup(
      sessions: const <OrexCallCleanupSession>[],
      removeMembership: () async => throw StateError('server unavailable'),
    );

    expect(result.membershipRemoved, isFalse);
    expect(result.failures.single.step, 'membership');
  });
}
