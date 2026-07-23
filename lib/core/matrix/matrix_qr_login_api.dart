part of 'matrix_service.dart';

const _orexQrScheme = 'orex';
const _orexQrHost = 'login';
const _orexQrPath = '/v1';
const _orexQrTokenType = 'token';
const _orexQrRendezvousType = 'rendezvous';
const _orexQrRequestKind = 'request';
const _orexQrOfferKind = 'offer';
const _orexQrClaimKind = 'claim';
const _orexQrResponseKind = 'response';
const _orexQrConsumedKind = 'consumed';
const _orexQrRejectedKind = 'rejected';
const _orexQrRequestTimeout = Duration(seconds: 20);
const _orexQrSessionLifetime = Duration(minutes: 2);

/// Разобранный QR Orex.
///
/// Новые версии Orex создают только [isRendezvous] QR-коды. Поддержка
/// [isLoginToken] сохранена исключительно для распознавания старых кодов;
/// интерфейс больше не генерирует и не принимает прямой token QR.
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

enum OrexQrRendezvousPollState {
  waiting,
  approvalRequested,
  loggedIn,
  used,
  rejected,
}

class OrexQrRendezvousPollResult {
  const OrexQrRendezvousPollResult(this.state, {this.deviceName});

  final OrexQrRendezvousPollState state;
  final String? deviceName;
}

class OrexQrRendezvousSession {
  OrexQrRendezvousSession({
    required this.sessionUri,
    required this.secret,
    required this.challenge,
    required this.expiresAt,
    required this.qrData,
    required this.etag,
    required this.initialKind,
    required this.localAuthenticated,
    this.claimId,
    this.responseSent = false,
    this.consumed = false,
  });

  final Uri sessionUri;
  final Uint8List secret;
  final String challenge;
  final DateTime expiresAt;
  final String qrData;
  final String initialKind;
  final bool localAuthenticated;
  String etag;
  String? claimId;
  bool responseSent;
  bool consumed;
  Map<String, Object?>? _pendingLoginResponse;
  bool _loginCompleted = false;

  bool get isExpired => !DateTime.now().toUtc().isBefore(expiresAt);
}

class OrexQrRendezvousApproval {
  OrexQrRendezvousApproval({
    required this.sessionUri,
    required this.secret,
    required this.challenge,
    required this.expiresAt,
    required this.etag,
    required this.deviceName,
  });

  final Uri sessionUri;
  final Uint8List secret;
  final String challenge;
  final DateTime expiresAt;
  final String etag;
  final String deviceName;
}

extension MatrixQrLoginApi on MatrixService {
  /// Создаёт зашифрованную rendezvous-сессию.
  ///
  /// Авторизованное устройство публикует [offer] и само подтверждает вход после
  /// сканирования. Неавторизованное устройство публикует [request], который
  /// подтверждает уже авторизованный сканер.
  Future<OrexQrRendezvousSession> createQrRendezvous({
    required bool authenticatedOwner,
  }) async {
    final secret = _orexSecureRandomBytes(32);
    final challenge = _orexBase64Url(_orexSecureRandomBytes(18));
    final expiresAt = DateTime.now().toUtc().add(_orexQrSessionLifetime);
    final initialKind = authenticatedOwner
        ? _orexQrOfferKind
        : _orexQrRequestKind;
    final request = <String, Object?>{
      'v': 1,
      'kind': initialKind,
      'challenge': challenge,
      'homeserver': homeserver.toString(),
      'device_name': _orexQrDeviceName(),
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
    final rendezvousDirectory = base.replace(
      path: '${base.path.replaceAll(RegExp(r'/+$'), '')}/',
      query: null,
      fragment: null,
    );
    final sessionUri = rendezvousDirectory.resolve(location);
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
      initialKind: initialKind,
      localAuthenticated: authenticatedOwner,
    );
  }

  /// Неавторизованное устройство заявляет rendezvous-offer, показанный
  /// авторизованным устройством, после чего ждёт подтверждение владельца.
  Future<OrexQrRendezvousSession> claimQrRendezvous(String qrData) async {
    final payload = OrexQrLoginPayload.parse(qrData);
    if (!payload.isRendezvous) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_LEGACY_TOKEN',
        message: 'Прямые token QR больше не поддерживаются. Создайте новый код.',
      );
    }
    _orexValidateQrHomeserver(payload.homeserver);
    final sessionUri = payload.rendezvousUri!;
    _orexValidateRendezvousOrigin(sessionUri);

    final current = await _orexReadRendezvous(
      sessionUri,
      secret: payload.secret!,
      challenge: payload.challenge!,
    );
    _orexValidateSessionEnvelope(
      current.envelope,
      challenge: payload.challenge!,
      expiresAt: payload.expiresAt!,
    );
    if (current.envelope['kind'] != _orexQrOfferKind) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_ALREADY_CLAIMED',
        message: 'QR-код уже используется, использован или отменён',
      );
    }

    final claimId = _orexBase64Url(_orexSecureRandomBytes(18));
    final claimEnvelope = <String, Object?>{
      'v': 1,
      'kind': _orexQrClaimKind,
      'challenge': payload.challenge,
      'claim_id': claimId,
      'homeserver': homeserver.toString(),
      'device_name': _orexQrDeviceName(),
      'expires': payload.expiresAt!.millisecondsSinceEpoch,
    };
    final response = await _orexPutRendezvous(
      sessionUri,
      etag: current.etag,
      body: _orexEncryptQrEnvelope(
        jsonEncode(claimEnvelope),
        secret: payload.secret!,
        challenge: payload.challenge!,
      ),
    );
    if (response.statusCode == 412) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_ALREADY_CLAIMED',
        message: 'QR-код уже отсканирован другим устройством',
      );
    }
    _orexRequireSuccessfulWrite(response);

    return OrexQrRendezvousSession(
      sessionUri: sessionUri,
      secret: payload.secret!,
      challenge: payload.challenge!,
      expiresAt: payload.expiresAt!,
      qrData: qrData,
      etag: _orexRequireEtag(response),
      initialKind: _orexQrOfferKind,
      localAuthenticated: false,
      claimId: claimId,
    );
  }

  /// Один poll rendezvous-сессии.
  ///
  /// После фактического Matrix login новое устройство возвращает [loggedIn] и
  /// отдельно отправляет [consumed]-подтверждение. Владелец QR продолжает ждать
  /// этот ACK, прежде чем показать terminal-state и удалить rendezvous-запись.
  Future<OrexQrRendezvousPollResult> pollQrRendezvous(
    OrexQrRendezvousSession session,
  ) async {
    if (session.consumed) {
      return const OrexQrRendezvousPollResult(
        OrexQrRendezvousPollState.used,
      );
    }
    if (session._loginCompleted) {
      return const OrexQrRendezvousPollResult(
        OrexQrRendezvousPollState.loggedIn,
      );
    }
    if (session.isExpired) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_EXPIRED',
        message: 'Срок действия QR-кода истёк',
      );
    }
    if (!session.localAuthenticated && session._pendingLoginResponse != null) {
      return _orexCompletePendingQrLogin(session);
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
    if (response.statusCode == 304) {
      return const OrexQrRendezvousPollResult(
        OrexQrRendezvousPollState.waiting,
      );
    }
    if (response.statusCode == 404) {
      // Совместимость с клиентами предыдущей версии, которые удаляли запись
      // сразу после успешного login. Новые клиенты используют consumed ACK.
      if (session.responseSent) {
        return const OrexQrRendezvousPollResult(
          OrexQrRendezvousPollState.used,
        );
      }
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_GONE',
        message: 'QR-код уже использован, отменён или истёк',
      );
    }
    if (response.statusCode != 200) {
      throw OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_POLL',
        statusCode: response.statusCode,
        message: 'Не удалось проверить QR-сессию',
      );
    }

    final newEtag = response.headers['etag'];
    if (newEtag == null || newEtag.isEmpty) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Rendezvous-сервер не вернул ETag',
      );
    }
    session.etag = newEtag;
    final decoded = _orexDecodeQrEnvelope(
      response.body,
      secret: session.secret,
      challenge: session.challenge,
    );
    final kind = decoded['kind'];

    if (kind == session.initialKind) {
      return const OrexQrRendezvousPollResult(
        OrexQrRendezvousPollState.waiting,
      );
    }

    if (kind == _orexQrClaimKind &&
        session.localAuthenticated &&
        session.initialKind == _orexQrOfferKind) {
      _orexValidateSessionEnvelope(
        decoded,
        challenge: session.challenge,
        expiresAt: session.expiresAt,
      );
      final claimId = decoded['claim_id'];
      if (claimId is! String || claimId.isEmpty) {
        throw const OrexAuthProtocolException(
          code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
          message: 'Запрос нового устройства повреждён',
        );
      }
      session.claimId = claimId;
      return OrexQrRendezvousPollResult(
        OrexQrRendezvousPollState.approvalRequested,
        deviceName: _orexEnvelopeDeviceName(decoded),
      );
    }

    if (kind == _orexQrResponseKind) {
      if (session.localAuthenticated) {
        if (session.responseSent) {
          return const OrexQrRendezvousPollResult(
            OrexQrRendezvousPollState.waiting,
          );
        }
        throw const OrexAuthProtocolException(
          code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
          message: 'Получен неожиданный ответ QR-сессии',
        );
      }
      // Сохраняем уже прочитанный response до успешного Matrix login. Иначе
      // transient M_LIMIT_EXCEEDED/timeout оставляет новый ETag в session, а
      // следующий conditional GET получает 304 и больше никогда не повторяет
      // вход по одноразовому токену.
      session._pendingLoginResponse = decoded;
      return _orexCompletePendingQrLogin(session);
    }

    if (kind == _orexQrConsumedKind) {
      _orexValidateSessionEnvelope(
        decoded,
        challenge: session.challenge,
        expiresAt: session.expiresAt,
      );
      _orexValidateClaimId(decoded, session.claimId);
      if (session.localAuthenticated && session.responseSent) {
        unawaited(_orexDeleteRendezvous(session.sessionUri));
      }
      return const OrexQrRendezvousPollResult(
        OrexQrRendezvousPollState.used,
      );
    }

    if (kind == _orexQrRejectedKind) {
      _orexValidateSessionEnvelope(
        decoded,
        challenge: session.challenge,
        expiresAt: session.expiresAt,
      );
      _orexValidateClaimId(decoded, session.claimId);
      return const OrexQrRendezvousPollResult(
        OrexQrRendezvousPollState.rejected,
      );
    }

    throw const OrexAuthProtocolException(
      code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
      message: 'Получено неизвестное состояние QR-сессии',
    );
  }

  /// Читает запрос, показанный новым устройством, до показа диалога
  /// подтверждения на уже авторизованном устройстве.
  Future<OrexQrRendezvousApproval> inspectQrRendezvous(String qrData) async {
    final payload = OrexQrLoginPayload.parse(qrData);
    if (!payload.isRendezvous) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_LEGACY_TOKEN',
        message: 'Прямые token QR больше не поддерживаются. Создайте новый код.',
      );
    }
    _orexValidateQrHomeserver(payload.homeserver);
    final sessionUri = payload.rendezvousUri!;
    _orexValidateRendezvousOrigin(sessionUri);
    final current = await _orexReadRendezvous(
      sessionUri,
      secret: payload.secret!,
      challenge: payload.challenge!,
    );
    _orexValidateSessionEnvelope(
      current.envelope,
      challenge: payload.challenge!,
      expiresAt: payload.expiresAt!,
    );
    if (current.envelope['kind'] != _orexQrRequestKind) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_WRONG_MODE',
        message: 'Этот QR нужно сканировать на новом неавторизованном устройстве',
      );
    }
    return OrexQrRendezvousApproval(
      sessionUri: sessionUri,
      secret: payload.secret!,
      challenge: payload.challenge!,
      expiresAt: payload.expiresAt!,
      etag: current.etag,
      deviceName: _orexEnvelopeDeviceName(current.envelope),
    );
  }

  /// Авторизованное устройство подтверждает QR, показанный новым клиентом.
  Future<void> approveQrRendezvous(
    OrexQrRendezvousApproval approval,
  ) async {
    await _orexWriteLoginResponse(
      sessionUri: approval.sessionUri,
      etag: approval.etag,
      secret: approval.secret,
      challenge: approval.challenge,
      sessionExpiresAt: approval.expiresAt,
    );
  }

  /// Авторизованное устройство, показывающее QR-offer, подтверждает
  /// появившийся claim и продолжает ждать фактического использования токена.
  Future<void> approveDisplayedQrRendezvous(
    OrexQrRendezvousSession session,
  ) async {
    final claimId = session.claimId;
    if (!session.localAuthenticated ||
        session.initialKind != _orexQrOfferKind ||
        claimId == null ||
        claimId.isEmpty) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Нет ожидающего запроса на вход',
      );
    }
    final result = await _orexWriteLoginResponse(
      sessionUri: session.sessionUri,
      etag: session.etag,
      secret: session.secret,
      challenge: session.challenge,
      sessionExpiresAt: session.expiresAt,
      claimId: claimId,
    );
    session
      ..etag = result.etag
      ..responseSent = true
      ..consumed = result.consumed;
  }

  /// Отклоняет QR-запрос видимым terminal-состоянием. Запись не удаляется
  /// сразу, чтобы второе устройство гарантированно увидело отказ.
  Future<void> rejectQrRendezvous(
    OrexQrRendezvousApproval approval,
  ) async {
    await _orexWriteTerminalState(
      sessionUri: approval.sessionUri,
      etag: approval.etag,
      secret: approval.secret,
      challenge: approval.challenge,
      expiresAt: approval.expiresAt,
      kind: _orexQrRejectedKind,
    );
  }

  /// Отклоняет claim к QR, который показан на авторизованном устройстве.
  Future<void> rejectDisplayedQrRendezvous(
    OrexQrRendezvousSession session,
  ) async {
    final claimId = session.claimId;
    if (claimId == null || claimId.isEmpty) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Нет ожидающего запроса на вход',
      );
    }
    session.etag = await _orexWriteTerminalState(
      sessionUri: session.sessionUri,
      etag: session.etag,
      secret: session.secret,
      challenge: session.challenge,
      expiresAt: session.expiresAt,
      kind: _orexQrRejectedKind,
      claimId: claimId,
    );
  }

  Future<bool> cancelQrRendezvous(OrexQrRendezvousSession session) =>
      _orexDeleteRendezvous(session.sessionUri);

  Future<({String etag, bool consumed})> _orexWriteLoginResponse({
    required Uri sessionUri,
    required String etag,
    required Uint8List secret,
    required String challenge,
    required DateTime sessionExpiresAt,
    String? claimId,
  }) async {
    // Токен создаётся ровно один раз. Если PUT или его ответ потеряются по
    // сети, повторно отправляется тот же зашифрованный envelope, а не
    // выпускается второй действующий login token.
    final token = await _orexGenerateLoginToken();
    final responseEnvelope = <String, Object?>{
      'v': 1,
      'kind': _orexQrResponseKind,
      'challenge': challenge,
      'claim_id': ?claimId,
      'login_token': token.loginToken,
      'expires': DateTime.now()
          .toUtc()
          .add(Duration(milliseconds: token.expiresInMs))
          .millisecondsSinceEpoch,
    };
    final encryptedResponse = _orexEncryptQrEnvelope(
      jsonEncode(responseEnvelope),
      secret: secret,
      challenge: challenge,
    );

    var currentEtag = etag;
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final response = await _orexPutRendezvous(
          sessionUri,
          etag: currentEtag,
          body: encryptedResponse,
        );
        if (response.statusCode != 412) {
          _orexRequireSuccessfulWrite(response);
          return (etag: _orexRequireEtag(response), consumed: false);
        }
        lastError = const OrexAuthProtocolException(
          code: 'OREX_QR_STATE_CHANGED',
          statusCode: 412,
          message: 'QR-сессия изменилась во время подтверждения',
        );
      } catch (error) {
        lastError = error;
      }

      // PUT мог сохраниться, а HTTP-ответ потеряться. Читаем текущее
      // состояние и считаем операцию успешной только если на сервере лежит
      // именно наш response (или уже последовавший consumed ACK).
      try {
        final current = await _orexReadRendezvous(
          sessionUri,
          secret: secret,
          challenge: challenge,
        );
        final currentKind = current.envelope['kind'];
        if (currentKind == _orexQrResponseKind) {
          if (current.envelope['challenge'] == challenge &&
              current.envelope['claim_id'] == claimId &&
              current.envelope['login_token'] == token.loginToken) {
            return (etag: current.etag, consumed: false);
          }
          throw const OrexAuthProtocolException(
            code: 'OREX_QR_STATE_CHANGED',
            message: 'QR-сессия уже подтверждена другим ответом',
          );
        }
        if (currentKind == _orexQrConsumedKind) {
          _orexValidateSessionEnvelope(
            current.envelope,
            challenge: challenge,
            expiresAt: sessionExpiresAt,
          );
          _orexValidateClaimId(current.envelope, claimId);
          return (etag: current.etag, consumed: true);
        }
        if (currentKind == _orexQrRejectedKind) {
          throw const OrexAuthProtocolException(
            code: 'OREX_QR_REJECTED',
            message: 'QR-вход уже отклонён',
          );
        }

        final isRetryableInitialState =
            currentKind == _orexQrRequestKind ||
                currentKind == _orexQrClaimKind;
        if (isRetryableInitialState) {
          _orexValidateSessionEnvelope(
            current.envelope,
            challenge: challenge,
            expiresAt: sessionExpiresAt,
          );
        }
        final canRetryRequest =
            claimId == null && currentKind == _orexQrRequestKind;
        final canRetryClaim = claimId != null &&
            currentKind == _orexQrClaimKind &&
            current.envelope['claim_id'] == claimId;
        if (!canRetryRequest && !canRetryClaim) {
          throw const OrexAuthProtocolException(
            code: 'OREX_QR_STATE_CHANGED',
            message: 'QR-сессия уже изменилась на другом устройстве',
          );
        }
        currentEtag = current.etag;
      } catch (error) {
        lastError = error;
        if (error is OrexAuthProtocolException &&
            !_orexIsRetryableQrError(error)) {
          rethrow;
        }
      }

      if (attempt < 2) {
        await Future<void>.delayed(
          Duration(milliseconds: 300 * (attempt + 1)),
        );
      }
    }

    if (lastError is OrexAuthProtocolException) throw lastError;
    throw const OrexAuthProtocolException(
      code: 'OREX_QR_RENDEZVOUS_WRITE',
      message: 'Не удалось передать разрешение на вход. Повторите попытку.',
    );
  }


  Future<String> _orexWriteTerminalState({
    required Uri sessionUri,
    required String etag,
    required Uint8List secret,
    required String challenge,
    required DateTime expiresAt,
    required String kind,
    String? claimId,
  }) async {
    final envelope = <String, Object?>{
      'v': 1,
      'kind': kind,
      'challenge': challenge,
      'claim_id': ?claimId,
      'homeserver': homeserver.toString(),
      'expires': expiresAt.millisecondsSinceEpoch,
    };
    final response = await _orexPutRendezvous(
      sessionUri,
      etag: etag,
      body: _orexEncryptQrEnvelope(
        jsonEncode(envelope),
        secret: secret,
        challenge: challenge,
      ),
    );
    if (response.statusCode == 412) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_STATE_CHANGED',
        message: 'QR-сессия уже изменилась на другом устройстве',
      );
    }
    _orexRequireSuccessfulWrite(response);
    return _orexRequireEtag(response);
  }

  Future<void> _orexAcknowledgeConsumed(
    OrexQrRendezvousSession session,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        session.etag = await _orexWriteTerminalState(
          sessionUri: session.sessionUri,
          etag: session.etag,
          secret: session.secret,
          challenge: session.challenge,
          expiresAt: session.expiresAt,
          kind: _orexQrConsumedKind,
          claimId: session.claimId,
        );
        return;
      } catch (error) {
        lastError = error;
        // PUT мог успешно сохраниться, а ответ потеряться по сети. Проверяем
        // текущее состояние, прежде чем повторять запись со старым ETag.
        try {
          final current = await _orexReadRendezvous(
            session.sessionUri,
            secret: session.secret,
            challenge: session.challenge,
          );
          if (current.envelope['kind'] == _orexQrConsumedKind) {
            _orexValidateSessionEnvelope(
              current.envelope,
              challenge: session.challenge,
              expiresAt: session.expiresAt,
            );
            _orexValidateClaimId(current.envelope, session.claimId);
            session.etag = current.etag;
            return;
          }
          session.etag = current.etag;
        } on OrexAuthProtocolException catch (readError) {
          // Владелец мог уже увидеть ACK и удалить запись — это тоже успех.
          if (readError.code == 'OREX_QR_GONE') return;
          lastError = readError;
        } catch (readError) {
          lastError = readError;
        }
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 250 * (attempt + 1)),
          );
        }
      }
    }
    // Вход уже выполнен, поэтому ошибка ACK не должна разлогинивать новое
    // устройство. Старая сторона просто дождётся TTL вместо зелёного статуса.
    OrexLog.d('QR', 'consumed acknowledgement failed', lastError);
  }

  Future<OrexQrRendezvousPollResult> _orexCompletePendingQrLogin(
    OrexQrRendezvousSession session,
  ) async {
    final response = session._pendingLoginResponse;
    if (response == null) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Ответ QR-входа потерян до завершения авторизации',
      );
    }

    if (!client.isLogged()) {
      await _orexLoginFromResponse(response, session: session);
    }
    session
      .._pendingLoginResponse = null
      .._loginCompleted = true;

    // Login уже завершён и должен немедленно убрать QR-route. ACK нужен другой
    // стороне для зелёного terminal-state, но сетевой retry ACK не должен
    // удерживать новый клиент на экране входа.
    unawaited(_orexAcknowledgeConsumed(session));
    return const OrexQrRendezvousPollResult(
      OrexQrRendezvousPollState.loggedIn,
    );
  }

  Future<void> _orexLoginFromResponse(
    Map<String, Object?> decoded, {
    required OrexQrRendezvousSession session,
  }) async {
    if (decoded['challenge'] != session.challenge) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Получен неверный ответ на QR-запрос',
      );
    }
    if (session.claimId != null && decoded['claim_id'] != session.claimId) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'QR-ответ предназначен для другого устройства',
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
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true);
    if (!DateTime.now().toUtc().isBefore(expiresAt)) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_EXPIRED',
        message: 'Одноразовый токен QR-входа уже истёк',
      );
    }
    await client.checkHomeserver(homeserver);
    await client.login(
      'm.login.token',
      token: token,
      initialDeviceDisplayName: _orexQrDeviceName(),
      refreshToken: true,
    );
    voip?.resumeStaleMembershipCleanupForLoggedInAccount();
  }

  Future<({Map<String, Object?> envelope, String etag})>
      _orexReadRendezvous(
    Uri sessionUri, {
    required Uint8List secret,
    required String challenge,
  }) async {
    final current = await http
        .get(sessionUri, headers: const {'Cache-Control': 'no-store'})
        .timeout(_orexQrRequestTimeout);
    if (current.statusCode == 404) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_GONE',
        message: 'QR-код уже использован, отменён или истёк',
      );
    }
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
    return (
      envelope: _orexDecodeQrEnvelope(
        current.body,
        secret: secret,
        challenge: challenge,
      ),
      etag: etag,
    );
  }

  Future<http.Response> _orexPutRendezvous(
    Uri sessionUri, {
    required String etag,
    required String body,
  }) =>
      http
          .put(
            sessionUri,
            headers: {
              'Content-Type': 'application/octet-stream',
              'Cache-Control': 'no-store',
              'If-Match': etag,
            },
            body: body,
          )
          .timeout(_orexQrRequestTimeout);

  void _orexRequireSuccessfulWrite(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_WRITE',
        statusCode: response.statusCode,
        message: 'Не удалось обновить QR-сессию',
      );
    }
  }

  String _orexRequireEtag(http.Response response) {
    final etag = response.headers['etag'];
    if (etag == null || etag.isEmpty) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Rendezvous-сервер не вернул новый ETag',
      );
    }
    return etag;
  }

  void _orexValidateClaimId(
    Map<String, Object?> envelope,
    String? expectedClaimId,
  ) {
    final actualClaimId = envelope['claim_id'];
    if (expectedClaimId == null || expectedClaimId.isEmpty) {
      if (actualClaimId == null || actualClaimId == '') return;
    } else if (actualClaimId == expectedClaimId) {
      return;
    }
    throw const OrexAuthProtocolException(
      code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
      message: 'QR-сессия относится к другому устройству',
    );
  }

  void _orexValidateSessionEnvelope(
    Map<String, Object?> envelope, {
    required String challenge,
    required DateTime expiresAt,
  }) {
    final requestExpires = envelope['expires'];
    if (envelope['challenge'] != challenge ||
        envelope['homeserver'] != homeserver.toString() ||
        requestExpires is! int ||
        requestExpires != expiresAt.millisecondsSinceEpoch) {
      throw const OrexAuthProtocolException(
        code: 'OREX_QR_RENDEZVOUS_PROTOCOL',
        message: 'Запрос QR-входа не прошёл проверку',
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
          path: value.path == '/'
              ? ''
              : value.path.replaceAll(RegExp(r'/+$'), ''),
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

  Future<bool> _orexDeleteRendezvous(Uri sessionUri) async {
    try {
      final response = await http
          .delete(sessionUri, headers: const {'Cache-Control': 'no-store'})
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 404 ||
          (response.statusCode >= 200 && response.statusCode < 300);
    } catch (_) {
      return false;
    }
  }
}

bool _orexIsRetryableQrError(Object error) {
  if (error is TimeoutException || error is http.ClientException) return true;
  if (error is OrexAuthProtocolException) {
    final status = error.statusCode;
    return status == 408 ||
        status == 425 ||
        status == 429 ||
        (status != null && status >= 500);
  }
  final details = error.toString();
  return details.contains('SocketException') ||
      details.contains('Connection reset') ||
      details.contains('Connection closed');
}

String _orexEnvelopeDeviceName(Map<String, Object?> envelope) {
  final value = envelope['device_name'];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return 'Новое устройство Orex';
}

String _orexQrDeviceName() {
  if (kIsWeb) return 'Orex Web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'Orex Android',
    TargetPlatform.iOS => 'Orex iPhone',
    TargetPlatform.macOS => 'Orex macOS',
    TargetPlatform.windows => 'Orex Windows',
    TargetPlatform.linux => 'Orex Linux',
    TargetPlatform.fuchsia => 'Orex',
  };
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
