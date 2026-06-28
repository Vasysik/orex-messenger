part of 'matrix_service.dart';

extension MatrixMediaApi on MatrixService {
  // ---------------------------------------------------------------------------
  // Медиа (аутентифицированные): качаем байты с токеном и кэшируем
  // ---------------------------------------------------------------------------


  /// Скачивает содержимое mxc:// через аутентифицированный эндпоинт.
  /// Обычный <img>/NetworkImage на новых Synapse даёт 404, т.к. требуется
  /// заголовок авторизации — поэтому грузим сами.
  Future<Uint8List?> downloadMxc(Uri mxc) async {
    if (mxc.scheme != 'mxc') return null;
    final key = mxc.toString();
    final cached = _mediaCache[key];
    if (cached != null) return cached;

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
    try {
      final serverName = mxc.host;
      final mediaId = mxc.pathSegments.isNotEmpty ? mxc.pathSegments.last : '';
      final res = await client.getContent(serverName, mediaId);
      _mediaCache[key] = res.data;
      return res.data;
    } catch (_) {
      return null;
    }
  }


}
