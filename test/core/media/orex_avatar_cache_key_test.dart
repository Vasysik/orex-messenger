import 'package:flutter_test/flutter_test.dart';
import 'package:orex_messenger/core/media/orex_avatar_cache_key.dart';

void main() {
  test('avatar cache key is stable and fixed-width', () {
    final mxc = Uri.parse('mxc://example.org/avatar123');

    expect(orexAvatarCacheKey(mxc), '8b68b6f0b003bf67');
    expect(orexAvatarCacheKey(mxc), hasLength(16));
  });

  test('identity bindings use the same deterministic hash function', () {
    expect(
      orexStableCacheKey('user:@alice:example.org'),
      '11e988bef68e4e20',
    );
    expect(
      orexStableCacheKey('room:!abc:example.org'),
      'b2d9506ab4576fe1',
    );
  });
}
