part of 'matrix_service.dart';

const _orexQrScheme = 'orex';
const _orexQrHost = 'login';
const _orexQrPath = '/v1';
const _orexQrTokenType = 'token';
const _orexQrRendezvousType = 'rendezvous';
const _orexQrRequestKind = 'request';
const _orexQrResponseKind = 'response';
const _orexQrRequestTimeout = Duration(seconds: 20);
const _orexQrSessionLifetime = Duration(minutes: 2);

/// Разобранный QR Orex.
///
/// Два поддерживаемых вида:
/// - [isLoginToken] — старое устройство показывает одноразовый Matrix token;
/// - [isRendezvous] — новое устройство показывает зашифрованный запрос, а
///   авторизованное устройство возвращает token через временный relay.
class OrexQrLoginPayload {
  const OrexQrLoginPayload._({
    required this.type,
    required this.homeserver,
    this.loginToken,
    this.expiresAt,
    this.rendezvousUri,
    this.secret,
    this.challenge,
  });

  final String type;
  final Uri homeserver;
  final String? loginToken;
  final DateTime? expiresAt;
  final Uri? rendezvousUri;
  final Uint8List? secret;
  final String? challenge;

  bool get isLoginToken => type == _orexQrTokenType;
  bool get isRendezvous => type == _orexQrRendezvousType;

  factory OrexQrLoginPayload.loginToken({
    required Uri homeserver,
    required String loginToken,
    required DateTime expiresAt,
  }) =>
      OrexQrLoginPayload._(
        type: _orexQrTokenType,
        homeserver: homeserver,
        loginToken: loginToken,
        expiresAt: expiresAt.toUtc(),
      );

  factory OrexQrLoginPayload.rendezvous({
    required Uri homeserver,
    required Uri rendezvousUri,
    required Uint8List secret,
    required String challenge,
    required DateTime expiresAt,
  }) =>
      OrexQrLoginPayload._(
        type: _orexQrRendezvousType,
        homeserver: homeserver,
        rendezvousUri: rendezvousUri,
        secret: Uint8List.fromList(secret),
        challenge: challenge,
        expiresAt: expiresAt.toUtc(),
      );

  String encode() {
    final params = <String, String>{
      'type': type,
      'hs': homeserver.toString(),
      if (expiresAt != null)
        'expires': expiresAt!.millisecondsSinceEpoch.toString(),
      'token': ?loginToken,
      if (rendezvousUri != null) 'url': rendezvousUri.toString(),
      if (secret != null) 'secret': _orexBase64Url(secret!),
      'challenge': ?challenge,
    };
    return Uri(
      scheme: _orexQrScheme,
      host: _orexQrHost,
      path: _orexQrPath,
      queryParameters: params,
    ).toString();
  }

  static OrexQrLoginPayload parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 4096) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_INVALID',
        message: 'QR-код повреждён или имеет неизвестный формат',
      );
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != _orexQrScheme ||
        uri.host != _orexQrHost ||
        uri.path != _orexQrPath) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_INVALID',
        message: 'Это не QR-код входа Orex',
      );
    }

    final type = uri.queryParameters['type'];
    final homeserver = Uri.tryParse(uri.queryParameters['hs'] ?? '');
    final expiresMs = int.tryParse(uri.queryParameters['expires'] ?? '');
    if (homeserver == null ||
        homeserver.scheme != 'https' ||
        homeserver.host.isEmpty ||
        expiresMs == null) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_INVALID',
        message: 'QR-код повреждён или имеет неизвестный формат',
      );
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      expiresMs,
      isUtc: true,
    );
    final now = DateTime.now().toUtc();
    if (!now.isBefore(expiresAt)) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_EXPIRED',
        message: 'Срок действия QR-кода истёк',
      );
    }
    if (expiresAt.difference(now) > const Duration(minutes: 5)) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_INVALID',
        message: 'QR-код имеет недопустимый срок действия',
      );
    }

    if (type == _orexQrTokenType) {
      final token = uri.queryParameters['token']?.trim();
      if (token == null || token.isEmpty) {
        throw const OrexAuthProtocolException(
          code: 'OREX_QR_INVALID',
          message: 'В QR-коде отсутствует токен входа',
        );
      }
      return OrexQrLoginPayload.loginToken(
        homeserver: homeserver,
        loginToken: token,
        expiresAt: expiresAt,
      );
    }

    if (type == _orexQrRendezvousType) {
      final rendezvousUri = Uri.tryParse(uri.queryParameters['url'] ?? '');
      final challenge = uri.queryParameters['challenge']?.trim();
      Uint8List secret;
      try {
        secret = _orexBase64UrlDecode(uri.queryParameters['secret'] ?? '');
      } catch (_) {
        throw const OrexAuthProtocolException(
          code: 'OREX_QR_INVALID',
          message: 'Ключ QR-кода повреждён',
        );
      }
      if (rendezvousUri == null ||
          rendezvousUri.scheme != 'https' ||
          rendezvousUri.host.isEmpty ||
          challenge == null ||
          challenge.isEmpty ||
          secret.length != 32) {
        throw const OrexAuthProtocolException(
          code: 'OREX_QR_INVALID',
          message: 'QR-код запроса входа повреждён',
        );
      }
      return OrexQrLoginPayload.rendezvous(
        homeserver: homeserver,
        rendezvousUri: rendezvousUri,
        secret: secret,
        challenge: challenge,
        expiresAt: expiresAt,
      );
    }

    throw const OrexAuthProtocolException(
      code: 'OREX_QR_UNSUPPORTED',
      message: 'Эта версия QR-кода не поддерживается',
    );
  }
}

class OrexQrRendezvousSession {
  OrexQrRendezvousSession({
    required this.sessionUri,
    required this.secret,
    required this.challenge,
    required this.expiresAt,
    required this.qrData,
    required this.etag,
  });

  final Uri sessionUri;
  final Uint8List secret;
  final String challenge;
  final DateTime expiresAt;
  final String qrData;
  String etag;

  bool get isExpired => !DateTime.now().toUtc().isBefore(expiresAt);
}

extension MatrixQrLoginApi on MatrixService {
  /// Создаёт QR, который сканирует новое устройство.
  Future<String> createDirectQrLogin() async {
    final response = await _orexGenerateLoginToken();
    final payload = OrexQrLoginPayload.loginToken(
      homeserver: homeserver,
      loginToken: response.loginToken,
      expiresAt: DateTime.now().toUtc().add(
            Duration(milliseconds: response.expiresInMs),
          ),
    );
    return payload.encode();
  }

  /// Выполняет вход на новом устройстве по прямому одноразовому QR-токену.
  Future<void> loginWithQrData(String qrData) async {
    final payload = OrexQrLoginPayload.parse(qrData);
    if (!payload.isLoginToken) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_WRONG_MODE',
        message: 'Этот QR нужно сканировать уже авторизованным устройством',
      );
    }
    _orexValidateQrHomeserver(payload.homeserver);
    await client.checkHomeserver(homeserver);
    await client.login(
      'm.login.token',
      token: payload.loginToken,
      initialDeviceDisplayName: 'Orex QR',
      refreshToken: true,
    );
    voip?.resumeStaleMembershipCleanupForLoggedInAccount();
  }

  /// Создаёт зашифрованный rendezvous-запрос для нового desktop/web-клиента.
  Future<OrexQrRendezvousSession> createQrRendezvous() async {
    final secret = _orexSecureRandomBytes(32);
    final challenge = _orexBase64Url(_orexSecureRandomBytes(18));
    final expiresAt = DateTime.now().toUtc().add(_orexQrSessionLifetime);
    final request = <String, Object?>{
      'v': 1,
      'kind': _orexQrRequestKind,
      'challenge': challenge,
      'homeserver': homeserver.toString(),
      'device_name': 'Orex',
      'expires': expiresAt.millisecondsSinceEpoch,
    };
    final encrypted = _orexEncryptQrEnvelope(
      jsonEncode(request),
      secret: secret,
      challenge: challenge,
    );

    final base = OrexConfig.qrRendezvousUri;
    final response = await http
        .post(
          base,
          headers: const {
            'Content-Type': 'application/octet-stream',
            'Cache-Control': 'no-store',
          },
          body: encrypted,
        )
        .timeout(_orexQrRequestTimeout);
    if (response.statusCode != 201) {
      final message = response.statusCode == 404
          ? 'Rendezvous endpoint не найден. Проверьте, что Synapse-модуль '
                'загружен и prefix совпадает с OREX_QR_RENDEZVOUS_URL.'
          : 'Сервер не создал временную QR-сессию';
      throw OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_CREATE',
        statusCode: response.statusCode,
        message: message,
      );
    }

    final location = response.headers['location'];
    final etag = response.headers['etag'];
    if (location == null || location.isEmpty || etag == null || etag.isEmpty) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Rendezvous-сервер вернул неполный ответ',
      );
    }
    final sessionUri = base.resolve(location);
    _orexValidateRendezvousOrigin(sessionUri);
    final qrData = OrexQrLoginPayload.rendezvous(
      homeserver: homeserver,
      rendezvousUri: sessionUri,
      secret: secret,
      challenge: challenge,
      expiresAt: expiresAt,
    ).encode();
    return OrexQrRendezvousSession(
      sessionUri: sessionUri,
      secret: secret,
      challenge: challenge,
      expiresAt: expiresAt,
      qrData: qrData,
      etag: etag,
    );
  }

  /// Один poll desktop/web-сессии. Возвращает true после успешного входа.
  Future<bool> pollQrRendezvous(OrexQrRendezvousSession session) async {
    if (session.isExpired) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_EXPIRED',
        message: 'Срок действия QR-кода истёк',
      );
    }
    _orexValidateRendezvousOrigin(session.sessionUri);
    final response = await http
        .get(
          session.sessionUri,
          headers: {
            'If-None-Match': session.etag,
            'Cache-Control': 'no-store',
          },
        )
        .timeout(_orexQrRequestTimeout);
    if (response.statusCode == 304) return false;
    if (response.statusCode != 200) {
      throw OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_POLL',
        statusCode: response.statusCode,
        message: 'Не удалось проверить QR-сессию',
      );
    }
    final newEtag = response.headers['etag'];
    if (newEtag != null && newEtag.isNotEmpty) session.etag = newEtag;
    final decoded = _orexDecodeQrEnvelope(
      response.body,
      secret: session.secret,
      challenge: session.challenge,
    );
    if (decoded['kind'] == _orexQrRequestKind) return false;
    if (decoded['kind'] != _orexQrResponseKind ||
        decoded['challenge'] != session.challenge) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Получен неверный ответ на QR-запрос',
      );
    }
    final token = decoded['login_token'];
    final expires = decoded['expires'];
    if (token is! String || token.isEmpty || expires is! int) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'В QR-ответе отсутствует токен входа',
      );
    }
    final payload = OrexQrLoginPayload.loginToken(
      homeserver: homeserver,
      loginToken: token,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
    );
    await loginWithQrData(payload.encode());
    unawaited(_orexDeleteRendezvous(session.sessionUri));
    return true;
  }

  /// Авторизованное устройство подтверждает QR, показанный новым клиентом.
  Future<void> approveQrRendezvous({required String qrData}) async {
    final payload = OrexQrLoginPayload.parse(qrData);
    if (!payload.isRendezvous) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_WRONG_MODE',
        message: 'Этот QR предназначен для входа на новом устройстве',
      );
    }
    _orexValidateQrHomeserver(payload.homeserver);
    final sessionUri = payload.rendezvousUri!;
    _orexValidateRendezvousOrigin(sessionUri);

    final current = await http
        .get(sessionUri, headers: const {'Cache-Control': 'no-store'})
        .timeout(_orexQrRequestTimeout);
    if (current.statusCode != 200) {
      throw OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_READ',
        statusCode: current.statusCode,
        message: 'Не удалось открыть QR-сессию',
      );
    }
    final etag = current.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Rendezvous-сервер не вернул ETag',
      );
    }
    final request = _orexDecodeQrEnvelope(
      current.body,
      secret: payload.secret!,
      challenge: payload.challenge!,
    );
    final requestExpires = request['expires'];
    if (request['kind'] != _orexQrRequestKind ||
        request['challenge'] != payload.challenge ||
        request['homeserver'] != homeserver.toString() ||
        requestExpires is! int ||
        requestExpires != payload.expiresAt!.millisecondsSinceEpoch) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Запрос QR-входа не прошёл проверку',
      );
    }

    final token = await _orexGenerateLoginToken();
    final responseEnvelope = <String, Object?>{
      'v': 1,
      'kind': _orexQrResponseKind,
      'challenge': payload.challenge,
      'login_token': token.loginToken,
      'expires': DateTime.now()
          .toUtc()
          .add(Duration(milliseconds: token.expiresInMs))
          .millisecondsSinceEpoch,
    };
    final encrypted = _orexEncryptQrEnvelope(
      jsonEncode(responseEnvelope),
      secret: payload.secret!,
      challenge: payload.challenge!,
    );
    final response = await http
        .put(
          sessionUri,
          headers: {
            'Content-Type': 'application/octet-stream',
            'Cache-Control': 'no-store',
            'If-Match': etag,
          },
          body: encrypted,
        )
        .timeout(_orexQrRequestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_WRITE',
        statusCode: response.statusCode,
        message: 'Не удалось подтвердить QR-вход',
      );
    }
  }

  Future<GenerateLoginTokenResponse> _orexGenerateLoginToken() async {
    final userId = client.userID;
    if (userId == null || userId.isEmpty) {
      throw StateError('Нет активной Matrix-сессии');
    }
    try {
      return await client.generateLoginToken();
    } on MatrixException catch (error) {
      if (!error.requireAdditionalAuthentication) rethrow;
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_UIA_REQUIRED',
        message: 'Сервер требует пароль для QR-входа. Установите '
            'login_via_existing_session.require_ui_auth: false и '
            'перезапустите Synapse.',
      );
    }
  }

  void _orexValidateQrHomeserver(Uri qrHomeserver) {
    Uri normalized(Uri value) => value.replace(
          path: value.path == '/' ? '' : value.path.replaceAll(RegExp(r'/+$'), ''),
          query: null,
          fragment: null,
        );
    if (normalized(qrHomeserver) != normalized(homeserver)) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_HOMESERVER_MISMATCH',
        message: 'QR-код создан для другого сервера',
      );
    }
  }

  void _orexValidateRendezvousOrigin(Uri sessionUri) {
    final configured = OrexConfig.qrRendezvousUri;
    final configuredPath = configured.path.replaceAll(RegExp(r'/+$'), '');
    final sessionPath = sessionUri.path.replaceAll(RegExp(r'/+$'), '');
    final isSessionPath = sessionPath.startsWith('$configuredPath/');
    if (sessionUri.scheme != configured.scheme ||
        sessionUri.host != configured.host ||
        sessionUri.port != configured.port ||
        sessionUri.userInfo.isNotEmpty ||
        sessionUri.hasQuery ||
        sessionUri.hasFragment ||
        !isSessionPath) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_ORIGIN',
        message: 'QR-код ссылается на недоверенный rendezvous-сервер',
      );
    }
  }

  Future<void> _orexDeleteRendezvous(Uri sessionUri) async {
    try {
      await http.delete(sessionUri).timeout(const Duration(seconds: 5));
    } catch (_) {
      // Сессия и так короткоживущая; ошибка очистки не ломает успешный вход.
    }
  }
}

Map<String, Object?> _orexDecodeQrEnvelope(
  String encoded, {
  required Uint8List secret,
  required String challenge,
}) {
  try {
    final clear = _orexDecryptQrEnvelope(
      encoded,
      secret: secret,
      challenge: challenge,
    );
    final value = jsonDecode(clear);
    if (value is! Map) throw const FormatException('not a map');
    return value.map((key, item) => MapEntry(key.toString(), item));
  } catch (_) {
    throw const OrexAuthProtocolException(
      code: 'OREX_QR_DECRYPT_FAILED',
      message: 'Не удалось проверить зашифрованную QR-сессию',
    );
  }
}

String _orexEncryptQrEnvelope(
  String clear, {
  required Uint8List secret,
  required String challenge,
}) {
  final nonce = _orexSecureRandomBytes(12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      true,
      AEADParameters(
        KeyParameter(secret),
        128,
        nonce,
        Uint8List.fromList(utf8.encode(challenge)),
      ),
    );
  final encrypted = cipher.process(Uint8List.fromList(utf8.encode(clear)));
  return _orexBase64Url(Uint8List.fromList([...nonce, ...encrypted]));
}

String _orexDecryptQrEnvelope(
  String encoded, {
  required Uint8List secret,
  required String challenge,
}) {
  final bytes = _orexBase64UrlDecode(encoded.trim());
  if (bytes.length <= 12 + 16) throw const FormatException('short envelope');
  final nonce = Uint8List.sublistView(bytes, 0, 12);
  final ciphertext = Uint8List.sublistView(bytes, 12);
  final cipher = GCMBlockCipher(AESEngine())
    ..init(
      false,
      AEADParameters(
        KeyParameter(secret),
        128,
        nonce,
        Uint8List.fromList(utf8.encode(challenge)),
      ),
    );
  final clear = cipher.process(ciphertext);
  return utf8.decode(clear);
}

Uint8List _orexSecureRandomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256), growable: false),
  );
}

String _orexBase64Url(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _orexBase64UrlDecode(String value) {
  final padding = (4 - value.length % 4) % 4;
  final normalized = value.padRight(value.length + padding, '=');
  return Uint8List.fromList(base64Url.decode(normalized));
}
