import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/encryption/key_manager.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/encryption/utils/bootstrap.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'call_controller.dart';
import 'voip_service.dart';

/// Модель аутентификации для регистрации через токен приглашения (MSC3231)
class AuthenticationRegistrationToken extends AuthenticationData {
  AuthenticationRegistrationToken({
    required this.token,
    super.session,
  }) : super(type: 'm.login.registration_token');

  final String token;

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        'token': token,
      };
}

/// Тонкая обёртка над Famedly Matrix Dart SDK.
///
/// Отвечает за: инициализацию клиента с локальной БД (ради «мгновенного»
/// запуска), логин/логаут, поток синхронизации и отправку сообщений.
///
/// ВАЖНО про синхронизацию: Dart SDK работает на классическом `/sync` +
/// локальный кэш. «Instant launch» достигается тем, что [Client.init] поднимает
/// комнаты из БД ДО первого сетевого ответа. Нативный Sliding Sync (MSC4186)
/// в Dart SDK на момент написания стабильно не выставлен публичным API —
/// если ваша версия SDK его уже умеет, включайте отдельно и проверяйте.
class MatrixService extends ChangeNotifier {
  MatrixService({required this.homeserver, required DatabaseApi database})
      : _database = database;

  /// Например: https://vasys.ru
  final Uri homeserver;
  final DatabaseApi _database;

  late final Client client = Client(
    'OrexMessenger',
    database: _database,
    // crossVerifiedIfEnabled гарантирует, что ключи шифрования будут уходить
    // только на проверенные (верифицированные) сессии.
    shareKeysWith: ShareKeysWith.crossVerifiedIfEnabled,
    verificationMethods: const {
      KeyVerificationMethod.emoji,
      KeyVerificationMethod.numbers,
    },
  );

  bool get isLoggedIn => client.isLogged();

  /// MatrixRTC-сигналинг звонков. Создаётся при init(); null, если модуль
  /// почему-то не поднялся (тогда звонки просто не работают, но клиент жив).
  VoipService? voip;

  /// Активный звонок (живёт поверх экранов — можно свернуть).
  late final CallController call = CallController(this);

  /// Локально отслеживаемая версия бэкапа на сервере.
  /// null означает, что бэкап на сервере отсутствует или недоступен.
  String? _serverBackupVersion;
  String? get serverBackupVersion => _serverBackupVersion;

  bool _checkedServerBackup = false;

  /// Флаг явного отключения бэкапа пользователем в этой сессии.
  /// Пока он true — sync не будет автоматически «переоткрывать» бэкап.
  /// Сбрасывается при логауте/рестарте (тогда updateServerBackupVersion
  /// снова честно проверит сервер).
  bool _backupDisabledByUser = false;

  /// Инициализация: восстановление сессии из БД (если была) и подписка на sync.
  Future<void> init() async {
    // Для E2EE инициализируйте vodozemac до init():
    //   await vod.init();  (пакет flutter_vodozemac)
    await client.init(
      waitForFirstSync: false, // покажем кэш сразу, не ждём сеть
    );
    client.onSync.stream.listen((_) {
      // Проверяем версию бэкапа только один раз после логина,
      // и только если пользователь не выключал его вручную в этой сессии.
      if (!_checkedServerBackup && client.isLogged() && !_backupDisabledByUser) {
        updateServerBackupVersion();
      }
      notifyListeners();
    });
    client.onLoginStateChanged.stream.listen((_) {
      // При логауте/смене аккаунта сбрасываем все флаги бэкапа.
      _checkedServerBackup = false;
      _serverBackupVersion = null;
      _backupDisabledByUser = false;
      notifyListeners();
    });
    // Обновление профиля (имя/аватар) — сбрасываем кэш медиа и перерисовываем,
    // чтобы новый аватар появился без перезагрузки вкладки.
    client.onUserProfileUpdate.stream.listen((_) {
      _mediaCache.clear();
      notifyListeners();
    });
    // VoIP-сигналинг (звонки). Изолируем сбой, чтобы он не ронял запуск.
    try {
      voip = VoipService(client);
    } catch (e) {
      debugPrint('VoipService init failed, calls disabled: $e');
    }

    // Восстанавливаем ключи из бэкапа с задержкой — только если бэкап не выключен.
    for (final s in const [3, 8]) {
      Future.delayed(Duration(seconds: s), () {
        if (!_backupDisabledByUser) restoreKeyBackup();
      });
    }
    await _loadBackupPrefs();
  }

  /// Логин по паролю: POST /_matrix/client/v3/login под капотом SDK.
  Future<void> login({
    required String username,
    required String password,
  }) async {
    await client.checkHomeserver(homeserver);
    await client.login(
      LoginType.mLoginPassword,
      identifier: AuthenticationUserIdentifier(user: username),
      password: password,
      initialDeviceDisplayName: 'Orex',
    );
    // access_token и deviceId SDK сохранит в свою БД автоматически.
  }

  /// Регистрация нового аккаунта с использованием ключа приглашения (registration token).
  ///
  /// Synapse всегда отвечает на первый POST /register кодом 401 + { session, flows } —
  /// это штатный UIA-хендшейк (User-Interactive Auth), а не ошибка.
  /// Алгоритм:
  ///   Шаг 1: отправляем запрос БЕЗ auth → сервер возвращает session.
  ///   Шаг 2: повторяем запрос С auth { type: registration_token, token, session }.
  Future<void> registerWithToken({
    required String username,
    required String password,
    required String token,
  }) async {
    await client.checkHomeserver(homeserver);

    // Шаг 1: «пустой» запрос — получаем session от сервера.
    // Synapse отвечает 401 + { session, flows } — это нормально.
    String? uiaSession;
    try {
      await client.register(
        username: username.trim(),
        password: password,
        initialDeviceDisplayName: 'Orex',
      );
      // Если регистрация прошла без UIA — готово (редко, но возможно).
      return;
    } on MatrixException catch (e) {
      if (e.requireAdditionalAuthentication) {
        // Штатный случай: забираем session для шага 2.
        uiaSession = e.session;
      } else {
        // Настоящая ошибка (M_USER_IN_USE, M_INVALID_USERNAME и т.д.)
        rethrow;
      }
    }

    // Шаг 2: повторяем с auth { type, token, session }.
    await client.register(
      username: username.trim(),
      password: password,
      initialDeviceDisplayName: 'Orex',
      auth: AuthenticationRegistrationToken(
        token: token.trim(),
        session: uiaSession,
      ),
    );
  }

  Future<void> logout() async {
    await client.logout();
    notifyListeners();
  }

  /// Список комнат, отсортированный как в Telegram — по последней активности.
  List<Room> get rooms {
    final list = List<Room>.from(client.rooms);
    list.sort((a, b) =>
        b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime));
    return list;
  }

  /// Фильтрация под «папки»: Все / Личные / Группы / Каналы.
  List<Room> roomsForFolder(OrexFolder folder) {
    switch (folder) {
      case OrexFolder.all:
        return rooms;
      case OrexFolder.direct:
        return rooms.where((r) => r.isDirectChat).toList();
      case OrexFolder.groups:
        return rooms
            .where((r) => !r.isDirectChat && !_isBroadcast(r))
            .toList();
      case OrexFolder.channels:
        return rooms.where(_isBroadcast).toList();
    }
  }

  // Каналы в Matrix — это комнаты, где обычный участник не может писать
  // (events_default поднят выше его power level). Эвристика, уточните под
  // свою модель (например, помечайте каналы кастомным state-event или тегом).
  bool _isBroadcast(Room r) => !r.isDirectChat && !r.canSendDefaultMessages;

  Future<void> sendText(Room room, String text) =>
      room.sendTextEvent(text.trim());

  // ---------------------------------------------------------------------------
  // Приглашения в чаты
  // ---------------------------------------------------------------------------

  bool isInvite(Room room) => room.membership == Membership.invite;

  /// В комнате идёт звонок (учитываем и личные чаты).
  bool roomHasActiveCall(Room room) {
    final v = voip?.voip;
    if (v == null) return false;
    return room.hasActiveGroupCall(v, ignoreDirectChats: false);
  }

  /// userId участников активного звонка в комнате — для панели «войти».
  List<String> callMemberIds(Room room) {
    final v = voip?.voip;
    if (v == null) return const [];
    final mems = room.getCallMembershipsFromRoom(v).values.expand((e) => e);
    return mems
        .where((m) => !m.isExpired)
        .map((m) => m.userId)
        .toSet()
        .toList();
  }

  /// Принять приглашение (войти в комнату).
  Future<void> acceptInvite(Room room) async {
    await room.join();
    notifyListeners();
  }

  /// Отклонить приглашение (покинуть комнату).
  Future<void> rejectInvite(Room room) async {
    await room.leave();
    notifyListeners();
  }

  /// Удалить чат у себя: выйти из комнаты и «забыть» её.
  Future<void> deleteRoom(Room room) async {
    try {
      if (room.membership != Membership.leave) await room.leave();
    } catch (_) {}
    try {
      await room.forget();
    } catch (_) {}
    notifyListeners();
  }

  /// Принудительно перерисовать слушателей (например, после завершения
  /// проверки сессии, чтобы плашка «не подтверждена» убралась без перезагрузки).
  void refresh() => notifyListeners();

  // ---------------------------------------------------------------------------
  // Шифрование и проверка ТЕКУЩЕЙ сессии (кросс-подпись)
  // ---------------------------------------------------------------------------

  /// E2EE доступно, только если vodozemac был инициализирован ДО client.init().
  bool get encryptionEnabled => client.encryptionEnabled;

  /// Дождаться, пока ключи устройств подгрузятся из БД/сети (иначе статусы ниже
  /// могут быть «ложно непроверенными» сразу после логина).
  Future<void> ensureKeysLoaded() => client.userDeviceKeysLoading ?? Future.value();

  /// Включено ли «хранилище ключей» (онлайн-бэкап ключей сообщений). Когда
  /// включено, история восстанавливается на новых устройствах после проверки —
  /// сообщения не «теряются». Настраивается тем же bootstrap, что и кросс-подпись.
  bool get keyBackupEnabled =>
      (client.encryption?.keyManager.enabled ?? false) &&
      _serverBackupVersion != null &&
      !_backupDisabledByUser;

  /// Загрузка актуальной версии бэкапа с сервера.
  /// Вызывается при старте и после операций включения/выключения бэкапа.
  Future<void> updateServerBackupVersion() async {
    _checkedServerBackup = true;
    // Если пользователь явно отключил бэкап в этой сессии — не «переоткрываем».
    if (_backupDisabledByUser) return;
    try {
      final currentBackup = await client.getRoomKeysVersionCurrent();
      _serverBackupVersion = currentBackup.version;
    } catch (_) {
      _serverBackupVersion = null;
    }
    notifyListeners();
  }

  /// Скачать ВЕСЬ онлайн-бэкап ключей и расшифровать старую историю. Проверка
  /// сессии восстанавливает лишь часть ключей; этот вызов подтягивает все, что
  /// есть в бэкапе (включая сообщения прошлых сессий) — иначе на новой сессии
  /// видны только сообщения за её собственное время.
  Future<void> restoreKeyBackup() async {
    final km = client.encryption?.keyManager;
    if (km == null || _serverBackupVersion == null) return;
    try {
      if (await km.isCached()) {
        await km.loadAllKeys();
      }
    } catch (e) {
      debugPrint('Не удалось загрузить ключи из бэкапа: $e');
    }
    notifyListeners();
  }

  // --- Управление хранилищем ключей (бэкап сообщений) ---

  static const _kLastBackup = 'orex_last_backup_ms';
  static const _kAutoBackup = 'orex_auto_backup';

  /// Когда в последний раз ключи выгружались в бэкап (для показа в настройках).
  DateTime? lastBackup;

  /// Автоматический бэкап включён. По умолчанию false (пока пользователь сам не включит).
  bool autoBackup = false;

  /// Идёт ручной бэкап (для индикатора в UI).
  bool backupInProgress = false;

  Timer? _autoBackupTimer;

  Future<void> _loadBackupPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      autoBackup = prefs.getBool(_kAutoBackup) ?? false;
      final ms = prefs.getInt(_kLastBackup);
      if (ms != null) lastBackup = DateTime.fromMillisecondsSinceEpoch(ms);
      if (autoBackup) _startAutoBackup();
    } catch (_) {}
  }

  void _startAutoBackup() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer.periodic(
      const Duration(minutes: 2),
      (_) => _uploadKeys(record: true),
    );
  }

  /// Включить/выключить автоматический бэкап.
  Future<void> setAutoBackup(bool on) async {
    autoBackup = on;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoBackup, on);
    } catch (_) {}
    if (on) {
      _startAutoBackup();
      await _uploadKeys(record: true);
    } else {
      _autoBackupTimer?.cancel();
    }
  }

  /// Полный бэкап сейчас: помечаем ВСЕ ключи к выгрузке и загружаем в хранилище.
  Future<void> backupNow() async {
    backupInProgress = true;
    notifyListeners();
    try {
      await client.database
          .markInboundGroupSessionsAsNeedingUpload()
          .timeout(const Duration(seconds: 10));
      await _uploadKeys(record: true).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('backupNow failed: $e');
    } finally {
      backupInProgress = false;
      notifyListeners();
    }
  }

  Future<void> _uploadKeys({bool record = false}) async {
    final km = client.encryption?.keyManager;
    if (km == null || !km.enabled || _serverBackupVersion == null) return;
    try {
      await km.uploadInboundGroupSessions();
      await _recordLastBackupTime(record);
    } on MatrixException catch (e) {
      // Версия бэкапа на сервере исчезла (M_NOT_FOUND) — пробуем пересоздать
      // тихо, без интерактивных запросов (UIA). Если нужен пароль — прерываем.
      if (e.errcode == 'M_NOT_FOUND') {
        await _tryRecreateBackupSilently(km, record);
      } else {
        debugPrint('uploadInboundGroupSessions failed: $e');
      }
    } catch (e) {
      debugPrint('uploadInboundGroupSessions failed: $e');
    }
  }

  /// Фоновая попытка пересоздать бэкап без участия пользователя.
  /// Если bootstrap требует пароль или ключ — тихо прерываем.
  Future<void> _tryRecreateBackupSilently(
    KeyManager km,
    bool record,
  ) async {
    try {
      final completer = Completer<void>();
      client.encryption?.bootstrap(
        onUpdate: (b) async {
          try {
            switch (b.state) {
              case BootstrapState.askSetupOnlineKeyBackup:
                await b.askSetupOnlineKeyBackup(true);
                break;
              case BootstrapState.done:
                if (!completer.isCompleted) completer.complete();
                break;
              case BootstrapState.error:
                if (!completer.isCompleted) {
                  completer.completeError(StateError('bootstrap_error'));
                }
                break;
              case BootstrapState.loading:
              case BootstrapState.askSetupCrossSigning:
                break;
              default:
                // Любое другое состояние требует участия пользователя — прерываем тихо
                if (!completer.isCompleted) {
                  completer.completeError(StateError('interactive_required'));
                }
                break;
            }
          } catch (e) {
            if (!completer.isCompleted) completer.completeError(e);
          }
        },
      );
      await completer.future;
      await updateServerBackupVersion();
      await km.uploadInboundGroupSessions();
      await _recordLastBackupTime(record);
    } catch (_) {
      // Тихо: фоновая задача, пользователь не ждёт результата
    }
  }

  /// Сохраняет время последнего бэкапа в память и SharedPreferences.
  Future<void> _recordLastBackupTime(bool record) async {
    if (!record) return;
    lastBackup = DateTime.now();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastBackup, lastBackup!.millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Включить хранилище ключей на сервере.
  ///
  /// ВАЖНО: если бэкап уже существует на сервере — НЕ пересоздаём SSSS и не
  /// генерируем новый ключ восстановления. Просто загружаем ключи в
  /// существующий бэкап. Новый ключ возвращается ТОЛЬКО при первичной настройке.
  ///
  /// [askPassword] вызывается, когда серверу нужен пароль (UIA) при публикации
  /// ключей подписи. [recoveryKey] — уже введённый ключ для разблокировки SSSS.
  Future<String?> enableKeyBackup({
    required Future<String?> Function() askPassword,
    String? recoveryKey,
  }) async {
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('Шифрование не инициализировано');
    }

    // Снимаем флаг явного отключения — пользователь хочет включить бэкап.
    _backupDisabledByUser = false;

    // Проверяем, есть ли уже бэкап на сервере.
    // Если есть — просто подключаемся к нему, не трогая SSSS и ключ восстановления.
    try {
      final existing = await client.getRoomKeysVersionCurrent();
      if (existing.version.isNotEmpty) {
        _serverBackupVersion = existing.version;
        notifyListeners();
        await _uploadKeys(record: true);
        // null — новый ключ НЕ генерировался, диалог «сохраните ключ» не показываем.
        return null;
      }
    } catch (_) {
      // M_NOT_FOUND или сетевая ошибка — бэкапа нет, создаём ниже через bootstrap.
    }

    // Бэкапа нет — запускаем полный bootstrap для создания SSSS + бэкапа.
    final completer = Completer<String?>();

    // UIA: сервер может потребовать пароль при публикации сигнатуры бэкапа
    final uiaSub = client.onUiaRequest.stream.listen((uia) async {
      if (uia.state != UiaRequestState.waitForUser) return;
      if (!uia.nextStages.contains(AuthenticationTypes.password)) {
        uia.cancel(Exception('Неподдерживаемый способ входа: ${uia.nextStages}'));
        return;
      }
      final pw = await askPassword();
      if (pw == null || pw.isEmpty) {
        uia.cancel(Exception('Отменено пользователем'));
        return;
      }
      await uia.completeStage(
        AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: client.userID!),
          password: pw,
          session: uia.session,
        ),
      );
    });

    encryption.bootstrap(
      onUpdate: (b) async {
        try {
          switch (b.state) {
            case BootstrapState.askNewSsss:
              await b.newSsss();
              break;
            case BootstrapState.askUseExistingSsss:
              // SSSS уже есть — используем, НЕ пересоздаём и не генерируем новый ключ.
              b.useExistingSsss(true);
              break;
            case BootstrapState.openExistingSsss:
              await b.openExistingSsss();
              break;
            case BootstrapState.askUnlockSsss:
              final key = recoveryKey?.trim();
              if (key != null && key.isNotEmpty && b.oldSsssKeys != null) {
                bool unlockedAny = false;
                for (final k in b.oldSsssKeys!.values) {
                  try {
                    await k.unlock(recoveryKey: key);
                    unlockedAny = true;
                  } catch (_) {
                    try {
                      await k.unlock(passphrase: key);
                      unlockedAny = true;
                    } catch (_) {}
                  }
                }
                if (unlockedAny) {
                  b.unlockedSsss();
                  break;
                }
              }
              if (!completer.isCompleted) {
                completer.completeError(StateError('recovery_key_required'));
              }
              break;
            case BootstrapState.askBadSsss:
              // Плохой/несовместимый SSSS — требуем ключ, а не молча сносим.
              if (!completer.isCompleted) {
                completer.completeError(StateError('recovery_key_required'));
              }
              break;
            // enableKeyBackup НЕ должен ничего сносить — прерываем.
            case BootstrapState.askWipeSsss:
            case BootstrapState.askWipeCrossSigning:
            case BootstrapState.askWipeOnlineKeyBackup:
              if (!completer.isCompleted) {
                completer.completeError(StateError(
                  'Обнаружены существующие данные безопасности. '
                  'Используйте ключ восстановления для разблокировки.',
                ));
              }
              break;
            case BootstrapState.askSetupCrossSigning:
              await b.askSetupCrossSigning(
                setupMasterKey: true,
                setupSelfSigningKey: true,
                setupUserSigningKey: true,
              );
              break;
            case BootstrapState.askSetupOnlineKeyBackup:
              await b.askSetupOnlineKeyBackup(true);
              break;
            case BootstrapState.done:
              if (!completer.isCompleted) {
                // Возвращаем новый ключ только если он был сгенерирован в этом bootstrap.
                completer.complete(b.newSsssKey?.recoveryKey);
              }
              break;
            case BootstrapState.error:
              if (!completer.isCompleted) {
                completer
                    .completeError(StateError('Ошибка настройки резервной копии'));
              }
              break;
            case BootstrapState.loading:
              break;
          }
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        }
      },
    );

    try {
      final key = await completer.future;
      await updateServerBackupVersion();
      return key;
    } finally {
      await uiaSub.cancel();
    }
  }

  /// Отключить хранилище ключей (удалить текущую версию бэкапа с сервера).
  ///
  /// После вызова _backupDisabledByUser = true, чтобы sync и отложенные
  /// restoreKeyBackup() не «переоткрыли» бэкап автоматически в этой сессии.
  /// SSSS и кросс-подпись не затрагиваются.
  Future<void> disableKeyBackup() async {
    try {
      final currentBackup = await client.getRoomKeysVersionCurrent();
      await client.deleteRoomKeysVersion(currentBackup.version);
    } on MatrixException catch (e) {
      if (e.errcode != 'M_NOT_FOUND') {
        rethrow;
      }
    } catch (e) {
      debugPrint('disableKeyBackup failed: $e');
      rethrow;
    }

    // Помечаем: пользователь сам отключил бэкап — sync не должен его «вернуть».
    _backupDisabledByUser = true;
    _serverBackupVersion = null;

    // Выключаем автобэкап, чтобы таймер не пытался грузить в несуществующий бэкап.
    autoBackup = false;
    _autoBackupTimer?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAutoBackup, false);
    } catch (_) {}

    // Сбрасываем локальный кэш инфо о бэкапе в SDK
    try {
      await client.encryption?.keyManager.getRoomKeysBackupInfo(false);
    } catch (_) {}
    notifyListeners();
  }

  /// На аккаунте настроена кросс-подпись (обычно её включают в Element).
  /// Если false — проверять нечем: сперва нужно настроить безопасность в Element
  /// (или сделать bootstrap, что мы намеренно не делаем вслепую).
  bool get crossSigningAvailable =>
      client.encryption?.crossSigning.enabled ?? false;

  /// Эта сессия КРОСС-ПОДПИСАНА master-ключом владельца. Ровно этот признак
  /// смотрят и раздача ключей комнаты, и Element X: пока false — Element пишет
  /// «зашифровано устройством, не проверенным его владельцем».
  ///
  /// ВАЖНО про прошлые попытки: `dk.verified` для своей текущей сессии всегда
  /// true (доверяет себе локально); `signed`/`isUnknownSession` требует, чтобы
  /// master был directVerified — оба давали неверный статус. Корректно —
  /// `hasValidSignatureChain(verifiedByTheirMasterKey: true)`: есть ли валидная
  /// цепочка подписей устройство → SSK → master.
  bool get isThisSessionVerified {
    final dk =
        client.userDeviceKeys[client.userID]?.deviceKeys[client.deviceID];
    return dk?.hasValidSignatureChain(verifiedByTheirMasterKey: true) ?? false;
  }

  /// Нужно ли показать плашку «сессия не подтверждена». Показываем, как только
  /// шифрование включено, а сессия ещё не кросс-подписана — даже если на
  /// аккаунте кросс-подписи ещё нет (тогда экран предложит её НАСТРОИТЬ через
  /// bootstrap; для свежих аккаунтов это и нужно).
  bool get needsSessionVerification =>
      encryptionEnabled && !isThisSessionVerified;

  /// Запустить самопроверку этой сессии с других своих устройств (Element X и
  /// пр.). Они покажут сравнение эмодзи; после успеха кросс-подпишут это
  /// устройство, и в других клиентах оно станет «проверенным».
  Future<KeyVerification> startSelfVerification() async {
    await ensureKeysLoaded();
    final own = client.userDeviceKeys[client.userID];
    if (own == null) {
      throw StateError('Ключи устройства ещё не загружены');
    }
    return own.startVerification();
  }

  /// Подтвердить эту сессию ключом восстановления (или passphrase) — без второго
  /// устройства: разблокируем SSSS и сами кросс-подписываем это устройство.
  Future<void> verifyWithRecoveryKey(String keyOrPassphrase) async {
    final crossSigning = client.encryption?.crossSigning;
    if (crossSigning == null) {
      throw StateError('Шифрование не инициализировано');
    }
    await crossSigning.selfSign(keyOrPassphrase: keyOrPassphrase.trim());
    notifyListeners();
    // Ключ восстановления разблокировал SSSS → тянем всю историю из бэкапа.
    await restoreKeyBackup();
  }

  /// ПЕРВИЧНАЯ настройка проверки подлинности (как «собачки» в Element при
  /// регистрации): создаёт кросс-подпись (master/self/user-signing), ключ
  /// восстановления (SSSS) и онлайн-бэкап ключей, после чего эта сессия
  /// становится доверенной. Возвращает КЛЮЧ ВОССТАНОВЛЕНИЯ — его нужно
  /// сохранить (это и есть тот самый ключ, которым потом подтверждают сессии).
  ///
  /// [askPassword] вызывается, когда серверу нужен пароль (UIA) для загрузки
  /// ключей подписи.
  ///
  /// БЕЗОПАСНОСТЬ: если на аккаунте УЖЕ есть данные безопасности
  /// (SSSS/кросс-подпись/бэкап) — метод НЕ перезатирает их (иначе слетело бы
  /// доверие на других сессиях), а бросает ошибку. В этом случае нужно не
  /// настраивать заново, а подтвердить сессию ключом восстановления.
  Future<String> setupCrossSigning({
    required Future<String?> Function() askPassword,
  }) async {
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('Шифрование не инициализировано');
    }
    if (crossSigningAvailable) {
      throw StateError(
        'Кросс-подпись уже настроена — подтвердите сессию ключом восстановления',
      );
    }

    final completer = Completer<String>();
    void fail(Object e) {
      if (!completer.isCompleted) completer.completeError(e);
    }

    // UIA: сервер требует пароль при загрузке cross-signing ключей.
    final uiaSub = client.onUiaRequest.stream.listen((uia) async {
      if (uia.state != UiaRequestState.waitForUser) return;
      if (!uia.nextStages.contains(AuthenticationTypes.password)) {
        uia.cancel(Exception('Неподдерживаемый способ входа: ${uia.nextStages}'));
        return;
      }
      final pw = await askPassword();
      if (pw == null || pw.isEmpty) {
        uia.cancel(Exception('Отменено'));
        return;
      }
      await uia.completeStage(
        AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: client.userID!),
          password: pw,
          session: uia.session,
        ),
      );
    });

    encryption.bootstrap(onUpdate: (b) async {
      try {
        switch (b.state) {
          case BootstrapState.askNewSsss:
            // Без passphrase → SDK сгенерирует ключ восстановления.
            await b.newSsss();
            break;
          case BootstrapState.askSetupCrossSigning:
            await b.askSetupCrossSigning(
              setupMasterKey: true,
              setupSelfSigningKey: true,
              setupUserSigningKey: true,
            );
            break;
          case BootstrapState.askSetupOnlineKeyBackup:
            await b.askSetupOnlineKeyBackup(true);
            break;
          case BootstrapState.done:
            if (!completer.isCompleted) {
              completer.complete(b.newSsssKey?.recoveryKey ?? '');
            }
            break;
          case BootstrapState.error:
            fail(StateError('Не удалось настроить кросс-подпись'));
            break;
          case BootstrapState.loading:
            break;
          default:
            // askWipe* / askUseExisting / askUnlock / askBadSsss / openExisting —
            // значит данные уже есть. НЕ трогаем (риск потери ключей).
            fail(
              StateError(
                'На аккаунте уже есть данные безопасности — не трогаю их, чтобы '
                'не потерять ключи. Подтвердите эту сессию ключом восстановления '
                'или сбросьте безопасность в Element.',
              ),
            );
        }
      } catch (e) {
        fail(e);
      }
    });

    try {
      final key = await completer.future;
      notifyListeners();
      return key;
    } finally {
      await uiaSub.cancel();
    }
  }

  /// Полный принудительный сброс настроек безопасности (SSSS, кросс-подпись, бэкапы)
  /// и генерация новой конфигурации с новым ключом восстановления.
  ///
  /// После сброса:
  ///   - бэкап ключей НЕ создаётся автоматически (пользователь включит сам).
  ///   - _serverBackupVersion и _backupDisabledByUser сбрасываются,
  ///     чтобы пользователь мог заново включить бэкап через UI.
  Future<String> resetSecurity({
    required Future<String?> Function() askPassword,
  }) async {
    final encryption = client.encryption;
    if (encryption == null) {
      throw StateError('Шифрование не инициализировано');
    }

    final completer = Completer<String>();

    final uiaSub = client.onUiaRequest.stream.listen((uia) async {
      if (uia.state != UiaRequestState.waitForUser) return;
      if (!uia.nextStages.contains(AuthenticationTypes.password)) {
        uia.cancel(Exception('Неподдерживаемый способ входа: ${uia.nextStages}'));
        return;
      }
      final pw = await askPassword();
      if (pw == null || pw.isEmpty) {
        uia.cancel(Exception('Отменено'));
        return;
      }
      await uia.completeStage(
        AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: client.userID!),
          password: pw,
          session: uia.session,
        ),
      );
    });

    encryption.bootstrap(onUpdate: (b) async {
      try {
        switch (b.state) {
          case BootstrapState.askUseExistingSsss:
            // Отказываемся от старого SSSS на сервере, чтобы запустить Wipe-цепочку
            b.useExistingSsss(false);
            break;
          case BootstrapState.openExistingSsss:
          case BootstrapState.askUnlockSsss:
          case BootstrapState.askWipeSsss:
            b.wipeSsss(true);
            break;
          case BootstrapState.askWipeCrossSigning:
            b.wipeCrossSigning(true);
            break;
          case BootstrapState.askWipeOnlineKeyBackup:
            b.wipeOnlineKeyBackup(true);
            break;
          case BootstrapState.askNewSsss:
            await b.newSsss();
            break;
          case BootstrapState.askBadSsss:
            b.ignoreBadSecrets(true);
            break;
          case BootstrapState.askSetupCrossSigning:
            await b.askSetupCrossSigning(
              setupMasterKey: true,
              setupSelfSigningKey: true,
              setupUserSigningKey: true,
            );
            break;
          case BootstrapState.askSetupOnlineKeyBackup:
            // После сброса бэкап НЕ создаём — пользователь включит вручную.
            await b.askSetupOnlineKeyBackup(false);
            break;
          case BootstrapState.done:
            if (!completer.isCompleted) {
              completer.complete(b.newSsssKey?.recoveryKey ?? '');
            }
            break;
          case BootstrapState.error:
            if (!completer.isCompleted) {
              completer.completeError(
                  StateError('Не удалось выполнить сброс безопасности'));
            }
            break;
          case BootstrapState.loading:
            break;
        }
      } catch (e) {
        if (!completer.isCompleted) completer.completeError(e);
      }
    });

    try {
      final key = await completer.future;

      // После сброса бэкапа нет — сбрасываем локальный статус.
      // _backupDisabledByUser = false: даём пользователю возможность
      // включить бэкап заново через UI без перезагрузки приложения.
      _serverBackupVersion = null;
      _backupDisabledByUser = false;

      // Выключаем автобэкап — после сброса он теряет смысл до нового включения.
      autoBackup = false;
      _autoBackupTimer?.cancel();
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_kAutoBackup, false);
      } catch (_) {}

      notifyListeners();
      return key;
    } finally {
      await uiaSub.cancel();
    }
  }

  // ---------------------------------------------------------------------------
  // Профиль
  // ---------------------------------------------------------------------------

  String get userId => client.userID ?? '';
  String? get deviceId => client.deviceID;

  /// Профиль. [fresh] — обойти кэш (нужно сразу после смены имени/аватара,
  /// иначе вернётся старое значение и придётся перезагружать вкладку).
  Future<Profile> ownProfile({bool fresh = false}) => client.getProfileFromUserId(
        client.userID!,
        maxCacheAge: fresh ? Duration.zero : const Duration(days: 1),
      );

  Future<void> setDisplayName(String name) async {
    await client.setProfileField(client.userID!, 'displayname', {
      'displayname': name,
    });
    notifyListeners();
  }

  /// Загружает и устанавливает аватар из сырых байтов (см. file_picker).
  Future<void> setAvatarBytes(List<int> bytes, String filename) async {
    await client.setAvatar(
      MatrixFile(bytes: Uint8List.fromList(bytes), name: filename),
    );
    _mediaCache.clear(); // сбросить кэш, чтобы новый аватар подтянулся сразу
    notifyListeners();
  }

  Future<void> removeAvatar() async {
    await client.setAvatar(null);
    _mediaCache.clear();
    notifyListeners();
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
    notifyListeners();
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

  /// Удаляет устройство. Эта операция защищена User-Interactive Auth, поэтому
  /// требует пароль пользователя (паттерн повторяет сам SDK для changePassword).
  Future<void> deleteDevice(String deviceId, String password) async {
    final userID = client.userID!;
    try {
      await client.deleteDevice(deviceId);
    } on MatrixException catch (e) {
      if (!e.requireAdditionalAuthentication) rethrow;
      await client.deleteDevice(
        deviceId,
        auth: AuthenticationPassword(
          identifier: AuthenticationUserIdentifier(user: userID),
          password: password,
          session: e.session,
        ),
      );
    }
    notifyListeners();
  }

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
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Поиск людей и создание чатов
  // ---------------------------------------------------------------------------

  /// Поиск пользователей: директория сервера + прямое разрешение по MXID.
  ///
  /// Директория (`searchUserDirectory`) на свежем Synapse возвращает только тех,
  /// с кем уже есть общая комната/публичные комнаты — поэтому новых знакомых не
  /// найти. Дополнительно пробуем точный MXID (`@localpart:server`) через
  /// профиль, чтобы можно было найти любого по имени.
  Future<List<Profile>> searchUsers(String query) async {
    final q = query.trim();
    if (q.isEmpty) return [];

    final byId = <String, Profile>{};
    try {
      final res = await client.searchUserDirectory(q, limit: 30);
      for (final p in res.results) {
        byId[p.userId] = p;
      }
    } catch (_) {
      // директория может быть выключена/недоступна — не критично
    }

    final candidate = _asMxid(q);
    if (candidate != null && !byId.containsKey(candidate)) {
      try {
        final prof = await client.getProfileFromUserId(candidate);
        byId[candidate] = Profile(
          userId: candidate,
          displayName: prof.displayName,
          avatarUrl: prof.avatarUrl,
        );
      } catch (_) {
        // нет такого пользователя — просто не добавляем
      }
    }
    return byId.values.toList();
  }

  /// Привести введённое к виду `@localpart:server` (или null, если не похоже).
  String? _asMxid(String q) {
    if (q.contains(' ')) return null;
    if (q.startsWith('@') && q.contains(':')) return q; // уже полный MXID
    final localpart = q.startsWith('@') ? q.substring(1) : q;
    if (localpart.isEmpty || localpart.contains(':')) return null;
    final server = client.userID?.split(':').last;
    if (server == null) return null;
    return '@$localpart:$server';
  }

  /// Личный чат (создаёт или возвращает существующий).
  Future<String> startDirectChat(String userId) =>
      client.startDirectChat(userId);

  /// Создать группу.
  Future<String> createGroup(String name, {List<String> invite = const []}) =>
      client.createGroupChat(groupName: name, invite: invite);

  /// Создать канал: группа, где обычные участники не могут писать
  /// (events_default поднят) — совпадает с эвристикой папки «Каналы».
  Future<String> createChannel(String name) => client.createGroupChat(
        groupName: name,
        preset: CreateRoomPreset.publicChat,
        powerLevelContentOverride: const {'events_default': 50},
      );

  // ---------------------------------------------------------------------------
  // Медиа (аутентифицированные): качаем байты с токеном и кэшируем
  // ---------------------------------------------------------------------------

  final Map<String, Uint8List> _mediaCache = {};

  /// Скачивает содержимое mxc:// через аутентифицированный эндпоинт.
  /// Обычный <img>/NetworkImage на новых Synapse даёт 404, т.к. требуется
  /// заголовок авторизации — поэтому грузим сами.
  Future<Uint8List?> downloadMxc(Uri mxc) async {
    if (mxc.scheme != 'mxc') return null;
    final key = mxc.toString();
    final cached = _mediaCache[key];
    if (cached != null) return cached;
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

  @override
  void dispose() {
    _autoBackupTimer?.cancel();
    client.dispose();
    super.dispose();
  }
}

enum OrexFolder { all, direct, groups, channels }

extension OrexFolderLabel on OrexFolder {
  String get label => switch (this) {
        OrexFolder.all => 'Все',
        OrexFolder.direct => 'Личные',
        OrexFolder.groups => 'Группы',
        OrexFolder.channels => 'Каналы',
      };
}
