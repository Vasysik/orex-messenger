import 'dart:convert';

final BigInt _fnv64Mask = (BigInt.one << 64) - BigInt.one;
final BigInt _fnv64OffsetBasis = BigInt.parse('cbf29ce484222325', radix: 16);
final BigInt _fnv64Prime = BigInt.parse('100000001b3', radix: 16);

/// Stable unsigned 64-bit FNV-1a key used by both Dart and native Android.
///
/// Dart VM integers are signed, and web integers have different runtime
/// semantics. BigInt keeps the multiplication and 64-bit mask identical on
/// every supported platform and byte-for-byte compatible with Kotlin's
/// Long.toUnsignedString().
String orexStableCacheKey(String value) {
  var hash = _fnv64OffsetBasis;
  for (final byte in utf8.encode(value)) {
    hash ^= BigInt.from(byte);
    hash = (hash * _fnv64Prime) & _fnv64Mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Stable cache key for an MXC URI.
String orexAvatarCacheKey(Uri mxc) => orexStableCacheKey(mxc.toString());
