part of 'matrix_service.dart';

/// Одноразовая сессия подтверждения нового почтового адреса.
///
/// [clientSecret] связывает письмо и завершающий запрос и живёт только в памяти
/// открытого диалога. Сохранять его в БД или настройки нельзя.
class OrexEmailBindingSession {
  const OrexEmailBindingSession({
    required this.email,
    required this.clientSecret,
    required this.sid,
    required this.sendAttempt,
  });

  final String email;
  final String clientSecret;
  final String sid;
  final int sendAttempt;
}

@visibleForTesting
List<String> orexAccountEmailAddresses(
  Iterable<ThirdPartyIdentifier> identifiers,
) {
  final normalized = <String, String>{};
  for (final identifier in identifiers) {
    if (identifier.medium != ThirdPartyIdentifierMedium.email) continue;
    final address = identifier.address.trim();
    if (address.isEmpty) continue;
    normalized.putIfAbsent(address.toLowerCase(), () => address);
  }
  final result = normalized.values.toList(growable: false)
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return List<String>.unmodifiable(result);
}

extension MatrixAccountApi on MatrixService {
  // ---------------------------------------------------------------------------
  // Профиль
  // ---------------------------------------------------------------------------

  String get userId => client.userID ?? '';
  String? get deviceId => client.deviceID;

  /// Профиль. [fresh] — обойти кэш (нужно сразу после смены имени/аватара,
  /// иначе вернётся старое значение и придётся перезагружать вкладку).
  Future<Profile> ownProfile({bool fresh = false}) =>
      client.getProfileFromUserId(
        client.userID!,
        maxCacheAge: fresh ? Duration.zero : const Duration(days: 1),
      );

  Future<void> setDisplayName(String name) async {
    await client.setProfileField(client.userID!, 'displayname', {
      'displayname': name,
    });
    _emitChange();
  }

  /// Загружает и устанавливает аватар из сырых байтов (см. file_picker).
  Future<void> setAvatarBytes(List<int> bytes, String filename) async {
    await client.setAvatar(
      MatrixFile(bytes: Uint8List.fromList(bytes), name: filename),
    );
    _clearMxcCache(); // сбросить кэш, чтобы новый аватар подтянулся сразу
    _emitChange();
  }

  Future<void> removeAvatar() async {
    await client.setAvatar(null);
    _clearMxcCache();
    _emitChange();
  }

  // ---------------------------------------------------------------------------
  // Почта аккаунта
  // ---------------------------------------------------------------------------

  List<String> get accountEmails => _accountEmails;
  bool get accountEmailsLoaded => _accountEmailsLoaded;
  bool get accountEmailsLoadFailed => _accountEmailsLoadFailed;
  bool get hasAccountEmail => _accountEmails.isNotEmpty;

  /// Обновляет подтверждённые 3PID-адреса аккаунта. Ошибка сети не стирает
  /// последнее успешно загруженное состояние и не создаёт ложную плашку.
  Future<List<String>> refreshAccountEmails({bool force = false}) {
    if (!client.isLogged()) {
      _accountEmails = const <String>[];
      _accountEmailsLoaded = false;
      _accountEmailsLoadFailed = false;
      _accountEmailsRefresh = null;
      return Future<List<String>>.value(_accountEmails);
    }
    final existing = _accountEmailsRefresh;
    if (existing != null) return existing;
    if (!force && _accountEmailsLoaded) {
      return Future<List<String>>.value(_accountEmails);
    }

    final userAtStart = client.userID;
    late final Future<List<String>> operation;
    operation = (() async {
      try {
        final identifiers =
            await client.getAccount3PIDs() ?? const <ThirdPartyIdentifier>[];
        final emails = orexAccountEmailAddresses(identifiers);
        if (client.isLogged() && client.userID == userAtStart) {
          _accountEmails = emails;
          _accountEmailsLoaded = true;
          _accountEmailsLoadFailed = false;
          _emitChange();
        }
        return emails;
      } catch (error) {
        _log('Account', 'load account emails failed', error);
        if (client.isLogged() && client.userID == userAtStart) {
          _accountEmailsLoadFailed = true;
          _emitChange();
        }
        return _accountEmails;
      } finally {
        if (identical(_accountEmailsRefresh, operation)) {
          _accountEmailsRefresh = null;
        }
      }
    })();
    _accountEmailsRefresh = operation;
    return operation;
  }

  Future<OrexEmailBindingSession> requestAccountEmailBinding({
    required String email,
  }) async {
    final normalized = email.trim();
    if (!_orexLooksLikeEmail(normalized)) {
      throw const OrexAuthProtocolException(
        message: 'Введите корректный адрес электронной почты',
      );
    }
    if (_accountEmails.any(
      (address) => address.toLowerCase() == normalized.toLowerCase(),
    )) {
      throw const OrexAuthProtocolException(
        code: 'OREX_EMAIL_ALREADY_LINKED',
        message: 'Этот адрес уже привязан к аккаунту',
      );
    }
    return _requestAccountEmailBinding(
      email: normalized,
      clientSecret: _orexRandomClientSecret(),
      sendAttempt: 1,
    );
  }

  Future<OrexEmailBindingSession> resendAccountEmailBinding(
    OrexEmailBindingSession session,
  ) =>
      _requestAccountEmailBinding(
        email: session.email,
        clientSecret: session.clientSecret,
        sendAttempt: session.sendAttempt + 1,
      );

  Future<OrexEmailBindingSession> _requestAccountEmailBinding({
    required String email,
    required String clientSecret,
    required int sendAttempt,
  }) async {
    final response = await client.requestTokenTo3PIDEmail(
      clientSecret,
      email,
      sendAttempt,
    );
    return OrexEmailBindingSession(
      email: email,
      clientSecret: clientSecret,
      sid: response.sid,
      sendAttempt: sendAttempt,
    );
  }

  /// Завершает привязку после перехода пользователя по ссылке из письма.
  /// При необходимости проходит Matrix UIA текущим паролем внутри Orex.
  Future<void> finishAccountEmailBinding({
    required OrexEmailBindingSession session,
    required String currentPassword,
  }) async {
    final userID = client.userID;
    if (userID == null || userID.isEmpty) {
      throw StateError('Нет активной Matrix-сессии');
    }
    try {
      await client.add3PID(session.clientSecret, session.sid);
    } on MatrixException catch (error) {
      if (!error.requireAdditionalAuthentication) rethrow;
      if (currentPassword.isEmpty) {
        throw const OrexAuthProtocolException(
          code: 'OREX_PASSWORD_REQUIRED',
          message: 'Введите текущий пароль аккаунта',
        );
      }
      await client.add3PID(
        session.clientSecret,
        session.sid,
        auth: AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: userID),
          password: currentPassword,
          session: error.session,
        ),
      );
    }
    await refreshAccountEmails(force: true);
  }

  Future<void> unlinkAccountEmail(String address) async {
    final normalized = address.trim();
    if (normalized.isEmpty) return;
    await client.delete3pidFromAccount(
      normalized,
      ThirdPartyIdentifierMedium.email,
    );
    await refreshAccountEmails(force: true);
  }

  // ---------------------------------------------------------------------------
  // Устройства аккаунта
  // ---------------------------------------------------------------------------

  Future<List<Device>> devices() async {
    final list = await client.getDevices();
    return list ?? <Device>[];
  }

  Future<void> renameDevice(String deviceId, String name) async {
    await client.updateDevice(deviceId, displayName: name);
    _emitChange();
  }

  /// Начать проверку (SAS) другой своей сессии.
  Future<KeyVerification?> verifyDevice(String deviceId) async {
    final dk = client.userDeviceKeys[client.userID]?.deviceKeys[deviceId];
    if (dk == null) return null;
    return dk.startVerification();
  }

  /// Доверена ли (проверена напрямую или кросс-подписью) другая сессия —
  /// для значка статуса в списке устройств.
  bool isDeviceVerified(String deviceId) {
    final dk = client.userDeviceKeys[client.userID]?.deviceKeys[deviceId];
    return dk?.verified ?? false;
  }

  /// Входящие запросы на проверку (от Element X и др.).
  Stream<KeyVerification> get incomingVerifications =>
      client.onKeyVerificationRequest.stream;

  /// Удаляет одну или несколько сессий одним UIA-подтверждением.
  /// Текущее устройство всегда отфильтровывается на уровне API, даже если
  /// вызывающий экран по ошибке передал его ID.
  Future<void> deleteDevices(Iterable<String> deviceIds, String password) async {
    final userID = client.userID!;
    final currentDeviceId = client.deviceID;
    final ids = deviceIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && id != currentDeviceId)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return;

    try {
      await client.deleteDevices(ids);
    } on MatrixException catch (error) {
      if (!error.requireAdditionalAuthentication) rethrow;
      await client.deleteDevices(
        ids,
        auth: AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: userID),
          password: password,
          session: error.session,
        ),
      );
    }
    _emitChange();
  }

  Future<void> deleteDevice(String deviceId, String password) =>
      deleteDevices(<String>[deviceId], password);

  /// Изменение пароля аккаунта с поддержкой User-Interactive Auth.
  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final userID = client.userID!;
    try {
      await client.changePassword(newPassword);
    } on MatrixException catch (e) {
      if (!e.requireAdditionalAuthentication) rethrow;
      await client.changePassword(
        newPassword,
        auth: AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: userID),
          password: currentPassword,
          session: e.session,
        ),
      );
    }
    _emitChange();
  }
}

bool _orexLooksLikeEmail(String value) {
  final at = value.indexOf('@');
  return at > 0 &&
      at < value.length - 3 &&
      value.indexOf('.', at) > at + 1;
}
