import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' hide Visibility;
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/encryption/utils/bootstrap.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/audio_cue_service.dart';
import '../config/orex_config.dart';
import '../push/orex_push_service.dart';
import '../voip/call_controller.dart';
import '../logging/orex_logger.dart';
import '../media/orex_avatar_cache.dart';
import '../../domain/rooms/room_metadata.dart';
import '../voip/voip_service.dart';
import '../voip/voice_participant_state.dart';

export '../../domain/rooms/room_metadata.dart';

part 'matrix_auth_api.dart';
part 'matrix_rooms_api.dart';
part 'matrix_room_reference_api.dart';
part 'matrix_room_discovery_api.dart';
part 'matrix_room_metadata_mappers.dart';
part 'matrix_supergroup_api.dart';
part 'matrix_room_identity_api.dart';
part 'matrix_room_creation_api.dart';
part 'matrix_room_admin_api.dart';
part 'matrix_voice_permissions_service.dart';
part 'matrix_security_api.dart';
part 'matrix_account_api.dart';
part 'matrix_media_api.dart';
part 'matrix_conversation_identity_api.dart';

const _orexRoomKindEvent = 'ru.orex.room.kind';
const _orexRoomIconEvent = 'ru.orex.room.icon';
const _orexSpaceChildPreviewEvent = 'ru.orex.space.child.preview';
const _orexVoicePermissionsEvent = 'ru.orex.voice.permissions';
const _orexVoiceParticipantEvent = orexVoiceParticipantEventType;

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
/// в Dart SDK на момент написания стабильно не выставлен публичным API. Его
/// включение требует отдельной проверки совместимости с используемой версией SDK.
class MatrixService extends ChangeNotifier {
  MatrixService({required this.homeserver, required this.database});

  /// Например: https://vasys.ru
  final Uri homeserver;
  final DatabaseApi database;

  late final Client client = Client(
    'OrexMessenger',
    database: database,
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

  /// Нативная push-доставка Android + регистрация Matrix HTTP-pusher.
  late final OrexPushService push = OrexPushService(
    client: client,
    gateway: OrexConfig.pushGatewayUri,
  );

  /// Короткие звуки приложения: уведомления, входящий вызов, вход в голос.
  late final AudioCueService audio = AudioCueService();

  /// Голосовые права каналов и Matrix state для raised-hand/reactions.
  late final MatrixVoicePermissionsService voicePermissions =
      MatrixVoicePermissionsService(this);

  /// Локально отслеживаемая подтверждённая версия бэкапа на сервере.
  /// null означает подтверждённое отсутствие/отключение; транспортная ошибка
  /// не стирает ранее известное состояние и оставляет проверку на retry.
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

  final Map<String, int> _notificationCounts = {};
  bool _notificationSnapshotReady = false;
  String? _foregroundRoomId;
  StreamSubscription? _syncSub;
  StreamSubscription? _loginStateSub;
  StreamSubscription? _userProfileSub;
  Future<void>? _avatarWarmupFuture;
  bool _avatarWarmupRequestedAfterCurrent = false;
  DateTime? _lastAvatarWarmup;

  /// Когда в последний раз ключи выгружались в бэкап (для показа в настройках).
  DateTime? lastBackup;

  /// Автоматический бэкап включён. По умолчанию false (пока пользователь сам не включит).
  bool autoBackup = false;

  /// Идёт ручной бэкап (для индикатора в UI).
  bool backupInProgress = false;

  Timer? _autoBackupTimer;
  final List<Timer> _deferredKeyBackupRestoreTimers = <Timer>[];

  final Map<String, Uint8List> _mediaCache = {};
  final Map<String, DateTime> _mediaCachedAt = {};
  final Map<String, Future<Uint8List?>> _mediaInflight = {};
  int _mediaCacheBytes = 0;

  static const Duration _mediaCacheTtl = Duration(hours: 12);
  static const int _mediaCacheMaxBytes = 32 * 1024 * 1024;

  /// Инициализация: восстановление сессии из БД (если была) и подписка на sync.
  Future<void> init() async {
    await audio.init();
    // Для E2EE инициализируйте vodozemac до init():
    //   await vod.init();  (пакет flutter_vodozemac)
    await client.init(
      waitForFirstSync: false, // покажем кэш сразу, не ждём сеть
    );
    _syncSub = client.onSync.stream.listen((_) {
      _playNotificationCueIfNeeded();
      push.handleMatrixSync();
      _scheduleAvatarCacheWarmup();
      // Проверяем версию бэкапа только один раз после логина,
      // и только если пользователь не выключал его вручную в этой сессии.
      if (!_checkedServerBackup &&
          client.isLogged() &&
          !_backupDisabledByUser) {
        updateServerBackupVersion();
      }
      notifyListeners();
    });
    _loginStateSub = client.onLoginStateChanged.stream.listen((_) async {
      // При логауте/смене аккаунта сбрасываем runtime-статус и перечитываем
      // сохранённое намерение пользователя для текущего аккаунта.
      _checkedServerBackup = false;
      _serverBackupVersion = null;
      _backupDisabledByUser = false;
      _notificationCounts.clear();
      _notificationSnapshotReady = false;
      _lastAvatarWarmup = null;
      await _loadBackupPrefs();
      push.handleLoginStateChanged();
      if (client.isLogged()) _scheduleAvatarCacheWarmup(force: true);
      notifyListeners();
    });
    // Обновление профиля меняет сам MXC URI. Не чистим весь media-cache на
    // каждый sync/profile-event: иначе аватарки моргают и постоянно refetch-ятся.
    // Если URI реально поменялся, MxcAvatar сам подхватит новые байты.
    _userProfileSub = client.onUserProfileUpdate.stream.listen((_) {
      _scheduleAvatarCacheWarmup(force: true);
      notifyListeners();
    });
    // VoIP-сигналинг (звонки). Изолируем сбой, чтобы он не ронял запуск.
    try {
      voip = VoipService(client);
    } catch (e) {
      _log('Voip', 'init failed, calls disabled', e);
    }
    _scheduleAvatarCacheWarmup(force: true);

    await _loadBackupPrefs();

    // Push не должен ломать запуск Matrix-клиента: отсутствие Firebase config
    // или gateway оставляет приложение в обычном foreground-sync режиме.
    try {
      await push.start();
    } catch (e) {
      _log('Push', 'init failed, background delivery disabled', e);
    }

    // Восстанавливаем ключи из бэкапа с задержкой — только если бэкап не выключен.
    for (final s in const [3, 8]) {
      _deferredKeyBackupRestoreTimers.add(
        Timer(Duration(seconds: s), () {
          if (!_backupDisabledByUser) restoreKeyBackup();
        }),
      );
    }
  }

  void _scheduleAvatarCacheWarmup({bool force = false}) {
    if (!client.isLogged()) return;
    final last = _lastAvatarWarmup;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < const Duration(minutes: 10)) {
      return;
    }
    if (_avatarWarmupFuture != null) {
      if (force) _avatarWarmupRequestedAfterCurrent = true;
      return;
    }
    _lastAvatarWarmup = DateTime.now();
    late final Future<void> operation;
    operation = _warmConversationAvatarCache().whenComplete(() {
      if (!identical(_avatarWarmupFuture, operation)) return;
      _avatarWarmupFuture = null;
      if (_avatarWarmupRequestedAfterCurrent) {
        _avatarWarmupRequestedAfterCurrent = false;
        _scheduleAvatarCacheWarmup(force: true);
      }
    });
    _avatarWarmupFuture = operation;
  }

  Future<void> _warmConversationAvatarCache() async {
    final rooms = client.rooms.toList(growable: false)
      ..sort((a, b) {
        final aTs = a.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0;
        final bTs = b.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0;
        return bTs.compareTo(aTs);
      });
    final candidates = rooms.take(24).toList(growable: false);
    const batchSize = 4;
    for (var offset = 0; offset < candidates.length; offset += batchSize) {
      final end = offset + batchSize < candidates.length
          ? offset + batchSize
          : candidates.length;
      await Future.wait<void>(
        candidates.sublist(offset, end).map((room) async {
          await ensureConversationAvatarCached(room);
        }),
      );
    }
  }

  void _playNotificationCueIfNeeded() {
    if (!client.isLogged()) return;
    final increasedRooms = <Room>[];
    for (final room in client.rooms) {
      final count = room.notificationCount;
      final previous = _notificationCounts[room.id] ?? 0;
      if (_notificationSnapshotReady &&
          count > previous &&
          room.id != _foregroundRoomId) {
        final rtcNotification =
            room.lastEvent?.tryParseRtcNotificationContent();
        if (rtcNotification?.notificationType != RtcNotificationType.ring) {
          increasedRooms.add(room);
        }
      }
      _notificationCounts[room.id] = count;
    }
    _notificationSnapshotReady = true;
    if (increasedRooms.isEmpty) return;

    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final appIsBackgrounded =
        lifecycle != null && lifecycle != AppLifecycleState.resumed;
    if (appIsBackgrounded) {
      // При настроенном Matrix pusher системным уведомлением владеет FCM.
      // Локальный sync-fallback иначе создаст второй notification поверх него.
      if (push.isConfigured) return;
      for (final room in increasedRooms) {
        unawaited(
          push.showSyncedMatrixNotification(
            roomId: room.id,
            eventId: room.lastEvent?.eventId,
          ),
        );
      }
      return;
    }

    audio.playNotification();
  }

  void setForegroundRoomId(String? roomId) {
    final value = roomId?.trim();
    _foregroundRoomId = value == null || value.isEmpty ? null : value;
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

  Future<void> _disposeNetworkResources() async {
    try {
      // Push lifecycle may still have an in-flight pusher mutation that uses
      // the Matrix client. Keep the client alive until that queue is drained.
      await push.dispose();
    } finally {
      await client.dispose();
    }
  }

  @override
  void dispose() {
    _autoBackupTimer?.cancel();
    for (final timer in _deferredKeyBackupRestoreTimers) {
      timer.cancel();
    }
    _deferredKeyBackupRestoreTimers.clear();
    _syncSub?.cancel();
    _loginStateSub?.cancel();
    _userProfileSub?.cancel();
    call.dispose();
    voip?.dispose();
    audio.dispose();
    unawaited(_disposeNetworkResources());
    super.dispose();
  }
}
