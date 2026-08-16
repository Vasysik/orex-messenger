import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'orex_avatar_cache_key.dart';

/// Persistent Web avatar cache.
///
/// Matrix media needs an Authorization header, so browser `<img>` caching cannot
/// be used for MXC avatars directly. CacheStorage keeps the already authenticated
/// bytes across page reloads without persisting Matrix credentials or access
/// tokens. The synthetic request URL contains only a stable hash of the MXC URI.
class OrexAvatarCache {
  const OrexAvatarCache._();

  static const String _cacheName = 'orex-avatar-cache-v2';
  static const int _maxFileBytes = 8 * 1024 * 1024;

  static String keyFor(Uri mxc) => orexAvatarCacheKey(mxc);

  static Future<String?> pathForKey(String? rawKey) async => null;

  static Future<Uint8List?> read(Uri mxc) async {
    if (mxc.scheme != 'mxc') return null;
    try {
      final cache = await web.window.caches.open(_cacheName).toDart;
      final response = await cache.match(_requestFor(mxc)).toDart;
      if (response == null) return null;
      final buffer = await response.arrayBuffer().toDart;
      final bytes = buffer.toDart.asUint8List();
      if (bytes.isEmpty || bytes.lengthInBytes > _maxFileBytes) return null;
      return Uint8List.fromList(bytes);
    } catch (_) {
      // CacheStorage can be unavailable in private browsing or on an insecure
      // origin. Avatar loading must then transparently fall back to Matrix.
      return null;
    }
  }

  static Future<String?> write(Uri mxc, Uint8List bytes) async {
    if (mxc.scheme != 'mxc' ||
        bytes.isEmpty ||
        bytes.lengthInBytes > _maxFileBytes) {
      return null;
    }
    try {
      final cache = await web.window.caches.open(_cacheName).toDart;
      final response = web.Response(bytes.toJS);
      await cache.put(_requestFor(mxc), response).toDart;
      return keyFor(mxc);
    } catch (_) {
      return null;
    }
  }

  // Native identity bindings are used by Android/Windows notification shells.
  // A browser has no native notification process that needs a filesystem path.
  static Future<void> bindIdentity(String identity, Uri mxc) async {}

  static Future<void> markIdentityWithoutAvatar(String identity) async {}

  static Future<void> clearIdentity(String identity) async {}

  static Future<bool> contains(Uri mxc) async {
    if (mxc.scheme != 'mxc') return false;
    try {
      final cache = await web.window.caches.open(_cacheName).toDart;
      return await cache.match(_requestFor(mxc)).toDart != null;
    } catch (_) {
      return false;
    }
  }

  static web.Request _requestFor(Uri mxc) {
    final key = keyFor(mxc);
    final url = '${web.window.location.origin}/__orex_avatar_cache__/$key';
    return web.Request(url.toJS);
  }
}
