import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/voip/call_disposition_registry.dart';

void main() {
  test('keeps exact attempts distinct inside one room', () {
    final registry = OrexCallDispositionRegistry();
    addTearDown(registry.dispose);

    registry.record('!room:test', ringEventId: r'$ring-a');

    expect(registry.hasExact('!room:test', r'$ring-a'), isTrue);
    expect(registry.hasExact('!room:test', r'$ring-b'), isFalse);
  });

  test('promotes one legacy tombstone to an exact attempt', () {
    final registry = OrexCallDispositionRegistry();
    addTearDown(registry.dispose);
    final timestamp = DateTime(2026, 7, 13, 20);

    registry.record('!room:test', occurredAt: timestamp, cleanupAfter: null);
    registry.promoteLegacy('!room:test', r'$ring-a', cleanupAfter: null);

    expect(registry.hasLegacy('!room:test'), isFalse);
    expect(registry.hasExact('!room:test', r'$ring-a'), isTrue);
  });
}
