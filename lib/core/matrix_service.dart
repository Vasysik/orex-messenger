import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';

import 'voip_service.dart';

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
  );

  bool get isLoggedIn => client.isLogged();

  /// MatrixRTC-сигналинг звонков. Создаётся при init(); null, если модуль
  /// почему-то не поднялся (тогда звонки просто не работают, но клиент жив).
  VoipService? voip;

  /// Инициализация: восстановление сессии из БД (если была) и подписка на sync.
  Future<void> init() async {
    // Для E2EE инициализируйте vodozemac до init():
    //   await vod.init();  (пакет flutter_vodozemac)
    await client.init(
      waitForFirstSync: false, // покажем кэш сразу, не ждём сеть
    );
    client.onSync.stream.listen((_) => notifyListeners());
    client.onLoginStateChanged.stream.listen((_) => notifyListeners());
    // VoIP-сигналинг (звонки). Изолируем сбой, чтобы он не ронял запуск.
    try {
      voip = VoipService(client);
    } catch (e) {
      debugPrint('VoipService init failed, calls disabled: $e');
    }
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
  // Шифрование и проверка ТЕКУЩЕЙ сессии (кросс-подпись)
  // ---------------------------------------------------------------------------

  /// E2EE доступно, только если vodozemac был инициализирован ДО client.init().
  bool get encryptionEnabled => client.encryptionEnabled;

  /// Дождаться, пока ключи устройств подгрузятся из БД/сети (иначе статусы ниже
  /// могут быть «ложно непроверенными» сразу после логина).
  Future<void> ensureKeysLoaded() => client.userDeviceKeysLoading ?? Future.value();

  /// На аккаунте настроена кросс-подпись (обычно её включают в Element).
  /// Если false — проверять нечем: сперва нужно настроить безопасность в Element
  /// (или сделать bootstrap, что мы намеренно не делаем вслепую).
  bool get crossSigningAvailable =>
      client.encryption?.crossSigning.enabled ?? false;

  /// Текущее устройство уже доверенное (подписано напрямую или кросс-подписью).
  bool get isThisSessionVerified {
    final dk =
        client.userDeviceKeys[client.userID]?.deviceKeys[client.deviceID];
    return dk?.verified ?? false;
  }

  /// Нужно ли просить подтвердить эту сессию: шифрование включено, на аккаунте
  /// есть кросс-подпись, но эта сессия ещё не доверенная. Именно из-за этого
  /// другие клиенты (Element X) пишут «владелец не подтверждён».
  bool get needsSessionVerification =>
      encryptionEnabled && crossSigningAvailable && !isThisSessionVerified;

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
  }

  // ---------------------------------------------------------------------------
  // Профиль
  // ---------------------------------------------------------------------------

  String get userId => client.userID ?? '';
  String? get deviceId => client.deviceID;

  Future<Profile> ownProfile() => client.getProfileFromUserId(client.userID!);

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
    notifyListeners();
  }

  Future<void> removeAvatar() async {
    await client.setAvatar(null);
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

  // ---------------------------------------------------------------------------
  // Поиск людей и создание чатов
  // ---------------------------------------------------------------------------

  /// Поиск пользователей в директории сервера.
  Future<List<Profile>> searchUsers(String query) async {
    if (query.trim().isEmpty) return [];
    final res = await client.searchUserDirectory(query.trim(), limit: 30);
    return res.results;
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
