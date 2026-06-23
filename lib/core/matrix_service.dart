import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

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

  /// Инициализация: восстановление сессии из БД (если была) и подписка на sync.
  Future<void> init() async {
    // Для E2EE инициализируйте vodozemac до init():
    //   await vod.init();  (пакет flutter_vodozemac)
    await client.init(
      waitForFirstSync: false, // покажем кэш сразу, не ждём сеть
    );
    client.onSync.stream.listen((_) => notifyListeners());
    client.onLoginStateChanged.stream.listen((_) => notifyListeners());
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
  // Шифрование
  // ---------------------------------------------------------------------------

  /// E2EE доступно, только если vodozemac был инициализирован ДО client.init().
  bool get encryptionEnabled => client.encryptionEnabled;

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
