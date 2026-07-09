part of 'matrix_service.dart';

extension MatrixMediaApi on MatrixService {
  // ---------------------------------------------------------------------------
  // Медиа (аутентифицированные): качаем байты с токеном и кэшируем
  // ---------------------------------------------------------------------------

  /// Мгновенно отдаёт уже скачанные байты без Future-прыжка. Это важно для
  /// списков чатов: при rebuild аватар не должен сначала превращаться в букву,
  /// а потом снова в картинку.
  Uint8List? cachedMxc(Uri mxc) {
    if (mxc.scheme != 'mxc') return null;
    final key = mxc.toString();
    final cached = _mediaCache[key];
    if (cached == null) return null;

    final cachedAt = _mediaCachedAt[key];
    if (cachedAt == null) return cached;
    if (DateTime.now().difference(cachedAt) > MatrixService._mediaCacheTtl) {
      _removeMxcCache(key);
      return null;
    }
    // Touch entry to keep recently used avatars/media alive when trimming.
    _mediaCache.remove(key);
    _mediaCache[key] = cached;
    return cached;
  }

  /// Скачивает содержимое mxc:// через аутентифицированный эндпоинт.
  /// Обычный <img>/NetworkImage на новых Synapse даёт 404, т.к. требуется
  /// заголовок авторизации — поэтому грузим сами.
  Future<Uint8List?> downloadMxc(Uri mxc) async {
    if (mxc.scheme != 'mxc') return null;
    final cached = cachedMxc(mxc);
    if (cached != null) return cached;

    final key = mxc.toString();
    final inflight = _mediaInflight[key];
    if (inflight != null) return inflight;

    final request = _downloadMxcUncached(mxc, key);
    _mediaInflight[key] = request;
    try {
      return await request;
    } finally {
      _mediaInflight.remove(key);
    }
  }

  Future<Uint8List?> _downloadMxcUncached(Uri mxc, String key) async {
    final persisted = await OrexAvatarCache.read(mxc);
    if (persisted != null) {
      _putMxcCache(key, persisted);
      return persisted;
    }

    try {
      final serverName = mxc.host;
      final mediaId = mxc.pathSegments.isNotEmpty ? mxc.pathSegments.last : '';
      final res = await client.getContent(serverName, mediaId);
      _putMxcCache(key, res.data);
      return res.data;
    } catch (_) {
      return null;
    }
  }

  /// Возвращает детерминированный ключ файла, который понимает Android.
  String avatarCacheKey(Uri mxc) => OrexAvatarCache.keyFor(mxc);

  /// Загружает именно аватар и сохраняет его в общем Flutter/native disk-cache.
  /// Обычные вложения и медиа сообщений никогда не пишутся в этот cache.
  Future<Uint8List?> downloadAvatarMxc(Uri mxc) async {
    if (mxc.scheme != 'mxc') return null;
    final bytes = await downloadMxc(mxc);
    if (bytes == null) return null;
    await OrexAvatarCache.write(mxc, bytes);
    return bytes;
  }

  /// Гарантирует, что аватар лежит в общем Flutter/native disk-cache.
  Future<String?> ensureAvatarCached(Uri? mxc) async {
    if (mxc == null || mxc.scheme != 'mxc') return null;
    if (await OrexAvatarCache.contains(mxc)) {
      return OrexAvatarCache.keyFor(mxc);
    }
    final bytes = await downloadMxc(mxc);
    if (bytes == null) return null;
    return await OrexAvatarCache.write(mxc, bytes);
  }

  void _putMxcCache(String key, Uint8List bytes) {
    if (bytes.lengthInBytes > MatrixService._mediaCacheMaxBytes) return;
    _removeMxcCache(key);
    _mediaCache[key] = bytes;
    _mediaCachedAt[key] = DateTime.now();
    _mediaCacheBytes += bytes.lengthInBytes;
    _trimMxcCache();
  }

  void _trimMxcCache() {
    while (_mediaCacheBytes > MatrixService._mediaCacheMaxBytes && _mediaCache.isNotEmpty) {
      _removeMxcCache(_mediaCache.keys.first);
    }
  }

  void _removeMxcCache(String key) {
    final removed = _mediaCache.remove(key);
    if (removed != null) {
      _mediaCacheBytes -= removed.lengthInBytes;
      if (_mediaCacheBytes < 0) _mediaCacheBytes = 0;
    }
    _mediaCachedAt.remove(key);
  }

  void _clearMxcCache([Uri? mxc]) {
    if (mxc == null) {
      _mediaCache.clear();
      _mediaCachedAt.clear();
      _mediaCacheBytes = 0;
      return;
    }
    _removeMxcCache(mxc.toString());
  }
}
