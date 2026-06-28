import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/encryption/utils/bootstrap.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../call_controller.dart';
import '../orex_logger.dart';
import '../room_metadata.dart';
import '../voip_service.dart';

export '../room_metadata.dart';

part 'matrix_auth_api.dart';
part 'matrix_rooms_api.dart';
part 'matrix_security_api.dart';
part 'matrix_account_api.dart';
part 'matrix_media_api.dart';

const _orexRoomKindEvent = 'ru.orex.room.kind';
const _orexRoomIconEvent = 'ru.orex.room.icon';
const _orexSpaceChildPreviewEvent = 'ru.orex.space.child.preview';

const _kLastBackup = 'orex_last_backup_ms';
const _kAutoBackup = 'orex_auto_backup';
const _kBackupDisabledByUser = 'orex_backup_disabled_by_user';

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

  /// Флаг явного отключения бэкапа пользователем.
  /// Пока он true — sync не будет автоматически «переоткрывать» бэкап.
  /// Сохраняется локально, потому что после сброса/удаления серверный статус
  /// может на короткое время выглядеть включённым из кэша SDK.
  bool _backupDisabledByUser = false;

  final Map<String, bool> _roomPublicOverrides = {};

  /// Optimistic metadata для child-комнат супергруппы. Matrix state/event sync
  /// может прийти через несколько секунд, а UI должен показать название и
  /// иконку сразу после создания, без закрытия настроек и переоткрытия чата.
  final Map<String, Map<String, Map<String, Object?>>>
      _spaceChildPreviewOverrides = {};
  final Map<String, List<String>> _spaceChildOrderOverrides = {};

  /// Когда в последний раз ключи выгружались в бэкап (для показа в настройках).
  DateTime? lastBackup;

  /// Автоматический бэкап включён. По умолчанию false (пока пользователь сам не включит).
  bool autoBackup = false;

  /// Идёт ручной бэкап (для индикатора в UI).
  bool backupInProgress = false;

  Timer? _autoBackupTimer;

  final Map<String, Uint8List> _mediaCache = {};
  final Map<String, DateTime> _mediaCachedAt = {};
  final Map<String, Future<Uint8List?>> _mediaInflight = {};
  int _mediaCacheBytes = 0;

  static const Duration _mediaCacheTtl = Duration(hours: 12);
  static const int _mediaCacheMaxBytes = 32 * 1024 * 1024;

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
      if (!_checkedServerBackup &&
          client.isLogged() &&
          !_backupDisabledByUser) {
        updateServerBackupVersion();
      }
      notifyListeners();
    });
    client.onLoginStateChanged.stream.listen((_) async {
      // При логауте/смене аккаунта сбрасываем runtime-статус и перечитываем
      // сохранённое намерение пользователя для текущего аккаунта.
      _checkedServerBackup = false;
      _serverBackupVersion = null;
      _backupDisabledByUser = false;
      await _loadBackupPrefs();
      notifyListeners();
    });
    // Обновление профиля меняет сам MXC URI. Не чистим весь media-cache на
    // каждый sync/profile-event: иначе аватарки моргают и постоянно refetch-ятся.
    // Если URI реально поменялся, MxcAvatar сам подхватит новые байты.
    client.onUserProfileUpdate.stream.listen((_) {
      notifyListeners();
    });
    // VoIP-сигналинг (звонки). Изолируем сбой, чтобы он не ронял запуск.
    try {
      voip = VoipService(client);
    } catch (e) {
      debugPrint('VoipService init failed, calls disabled: $e');
    }

    await _loadBackupPrefs();

    // Восстанавливаем ключи из бэкапа с задержкой — только если бэкап не выключен.
    for (final s in const [3, 8]) {
      Future.delayed(Duration(seconds: s), () {
        if (!_backupDisabledByUser) restoreKeyBackup();
      });
    }
  }

  /// Принудительно перерисовать слушателей (например, после завершения
  /// проверки сессии, чтобы плашка «не подтверждена» убралась без перезагрузки).
  void refresh() => notifyListeners();

  /// Безопасная точка уведомления для API-extensions этого library/part.
  ///
  /// Нельзя вызывать protected [notifyListeners] из extension напрямую:
  /// analyzer корректно считает это внешним доступом к protected member.
  /// Все разнесённые Matrix API дергают этот private wrapper, а сам
  /// [notifyListeners] остаётся внутри [MatrixService].
  void _emitChange() => notifyListeners();

  void _log(String area, String message, [Object? error]) =>
      OrexLog.d(area, message, error);

  @override
  void dispose() {
    _autoBackupTimer?.cancel();
    client.dispose();
    super.dispose();
  }
}
