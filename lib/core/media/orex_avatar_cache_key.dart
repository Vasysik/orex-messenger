import 'dart:convert';

/// Stable 64-bit FNV-1a key used by both Dart and the native Android layer.
String orexStableCacheKey(String value) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(value)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Stable cache key for an MXC URI.
String orexAvatarCacheKey(Uri mxc) => orexStableCacheKey(mxc.toString());
