import 'dart:typed_data';

import 'orex_avatar_cache_key.dart';

class OrexAvatarCache {
  const OrexAvatarCache._();

  static String keyFor(Uri mxc) => orexAvatarCacheKey(mxc);

  static Future<Uint8List?> read(Uri mxc) async => null;

  static Future<String?> write(Uri mxc, Uint8List bytes) async => null;

  static Future<void> bindIdentity(String identity, Uri mxc) async {}

  static Future<void> markIdentityWithoutAvatar(String identity) async {}

  static Future<void> clearIdentity(String identity) async {}

  static Future<bool> contains(Uri mxc) async => false;
}
