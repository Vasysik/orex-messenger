import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' hide Visibility;
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/encryption/utils/bootstrap.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../audio/audio_cue_service.dart';
import '../config/orex_config.dart';
import '../push/orex_push_service.dart';
import '../push/push_platform_bridge.dart';
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

/// Decides whether a newly unread room should reach the native notification
/// bridge. A selected conversation is quiet only while the application is
/// actually visible; once the window is minimized or hidden, it needs the
/// same system notification as every other room.
@visibleForTesting
bool orexShouldPublishSyncedMatrixNotification({
  required bool notificationSnapshotReady,
  required int previousCount,
  required int currentCount,
  required String roomId,
  required String? foregroundRoomId,
  required bool appIsBackgrounded,
}) =>
    notificationSnapshotReady &&
    currentCount > previousCount &&
    (roomId != foregroundRoomId || appIsBackgrounded);

@visibleForTesting
bool orexIsBackgroundedForNotification({
  required AppLifecycleState? lifecycle,
  required bool isWindows,
  required bool desktopWindowVisible,
}) =>
    (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
    (isWindows && !desktopWindowVisible);

@visibleForTesting
int orexTotalUnreadCount(Iterable<int> counts) => counts.fold<int>(
  0,
  (total, count) => total + (count < 0 ? 0 : count),
);

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
    // MatrixRTC logs raw media keys at INFO. Never enable SDK INFO/FINE in the
    // application process; opt-in debug builds retain warnings, production and
    // explicitly quiet debug runs emit only SDK errors.
    logLevel: kDebugMode && OrexConfig.debugLogs ? Level.warning : Level.error,
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
  StreamSubscription<bool>? _desktopWindowVisibilitySub;
  bool _desktopWindowVisible = true;
  final Map<String, Future<void>> _incomingCallAnswerBootstraps = {};
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

    // Build signaling before any sync/login callback can lazily construct the
    // CallController. Previously an early desktop sync could create CallController
    // while matrix.voip was still null, permanently missing all incoming/remote
    // call stream subscriptions until another call path warmed the runtime.
    try {
      voip = VoipService(client);
    } catch (e) {
      _log('Voip', 'init failed, calls disabled', e);
    }
    final callController = call;
    // Android can dispatch an accepted native call while the Activity is still
    // constructing its Flutter view. Claim that action at the process layer,
    // not from a widget listener, so CallController can create its local
    // session immediately and queue the later UI handoff safely.
    push.setIncomingCallAnswerHandler(_handleIncomingCallAnswer);

    _desktopWindowVisibilitySub = push.desktopWindowVisibilityChanges.listen(
      (visible) => _desktopWindowVisible = visible,
    );

    _syncSub = client.onSync.stream.listen((_) {
      _playNotificationCueIfNeeded();
      push.handleMatrixSync();
      _scheduleAvatarCacheWarmup();
      if (client.isLogged()) unawaited(callController.recoverPendingCall());
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
      final loggedIn = client.isLogged();
      if (loggedIn) {
        // A successful login may reuse this MatrixService after a previous
        // logout. Its first /sync will schedule cleanup for the new account.
        voip?.resumeStaleMembershipCleanupForLoggedInAccount();
      } else {
        // Session expiry and remote logout bypass MatrixAuthApi.logout().
        // Latch local call cancellation before the asynchronous cleanup starts.
        voip?.pauseStaleMembershipCleanupForAccountTransition();
        unawaited(callController.terminateForAccountTransition());
      }
      // При логауте/смене аккаунта сбрасываем runtime-статус и перечитываем
      // сохранённое намерение пользователя для текущего аккаунта.
      _checkedServerBackup = false;
      _serverBackupVersion = null;
      _backupDisabledByUser = false;
      _notificationCounts.clear();
      _notificationSnapshotReady = false;
      unawaited(push.updateDesktopUnreadCount(0));
      _lastAvatarWarmup = null;
      await _loadBackupPrefs();
      push.handleLoginStateChanged();
      if (client.isLogged()) {
        _scheduleAvatarCacheWarmup(force: true);
        voip?.refreshIncomingCalls();
        unawaited(callController.recoverPendingCall());
      }
      notifyListeners();
    });
    // Обновление профиля меняет сам MXC URI. Не чистим весь media-cache на
    // каждый sync/profile-event: иначе аватарки моргают и постоянно refetch-ятся.
    // Если URI реально поменялся, MxcAvatar сам подхватит новые байты.
    _userProfileSub = client.onUserProfileUpdate.stream.listen((_) {
      _scheduleAvatarCacheWarmup(force: true);
      notifyListeners();
    });
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

  Future<void> _handleIncomingCallAnswer(OrexPushOpen open) {
    final roomId = open.roomId?.trim();
    if (roomId == null || roomId.isEmpty) {
      return _finishUnresolvableIncomingCallAnswer(open, roomId: null);
    }
    final instance = OrexCallInstance(
      roomId: roomId,
      ringEventId: open.ringEventId,
    );
    final existing = _incomingCallAnswerBootstraps[instance.routeKey];
    if (existing != null) return existing;

    late final Future<void> operation;
    operation = _acceptIncomingCallFromPush(open, instance).whenComplete(() {
      if (identical(
        _incomingCallAnswerBootstraps[instance.routeKey],
        operation,
      )) {
        _incomingCallAnswerBootstraps.remove(instance.routeKey);
      }
    });
    _incomingCallAnswerBootstraps[instance.routeKey] = operation;
    return operation;
  }

  Future<void> _acceptIncomingCallFromPush(
    OrexPushOpen open,
    OrexCallInstance instance,
  ) async {
    final callVoip = voip;
    var nativeAnswerClaimed = false;
    bool isThisAttemptActive() {
      final current = call.currentCallInstance;
      return call.isActive &&
          current != null &&
          current.roomId == instance.roomId &&
          orexCallInstanceIdsMatch(current.ringEventId, instance.ringEventId);
    }

    _log(
      'Push',
      'bootstrap answer received room=${instance.roomId} '
          'ring=${instance.ringEventId}',
    );
    try {
      var room = client.getRoomById(instance.roomId);
      room ??= await _resolveIncomingCallRoom(instance.roomId);
      if (room == null) {
        await _finishUnresolvableIncomingCallAnswer(
          open,
          roomId: instance.roomId,
        );
        return;
      }

      _log(
        'Push',
        'bootstrap answer resolved room=${room.id}; starting CallController',
      );
      if (callVoip == null ||
          !callVoip.claimIncomingCallFromNativeAction(instance)) {
        _log(
          'Push',
          'bootstrap answer rejected stale or unavailable attempt '
              'room=${instance.roomId} ring=${instance.ringEventId}',
        );
        await push.notifyCallEnded(
          instance.roomId,
          ringEventId: instance.ringEventId,
        );
        return;
      }
      nativeAnswerClaimed = true;
      // This mirrors the former widget-level path. It only removes an
      // incoming presentation for this exact attempt. The claim above keeps
      // ownership alive even when the first Matrix sync has not yet
      // materialized the incoming call.
      callVoip.dismissIncomingFromSystem(instance);
      await call.acceptIncoming(
        room,
        video: open.video,
        instance: instance,
        fromSystem: open.fromSystem,
        requestExpandedUi: true,
      );
      if (!isThisAttemptActive()) {
        _log(
          'Push',
          'bootstrap answer completed without an active call '
              'room=${instance.roomId}',
        );
        await push.notifyCallEnded(
          instance.roomId,
          ringEventId: instance.ringEventId,
        );
      }
    } catch (error) {
      _log('Push', 'bootstrap answer failed room=${instance.roomId}', error);
      if (!isThisAttemptActive()) {
        await push.notifyCallEnded(
          instance.roomId,
          ringEventId: instance.ringEventId,
        );
      }
    } finally {
      if (nativeAnswerClaimed && !isThisAttemptActive()) {
        callVoip?.releaseIncomingCallFromNativeAction(instance);
      }
      push.consumePendingIncomingAnswer(open);
    }
  }

  Future<void> _finishUnresolvableIncomingCallAnswer(
    OrexPushOpen open, {
    required String? roomId,
  }) async {
    final targetRoomId = roomId ?? open.roomId?.trim();
    _log(
      'Push',
      'bootstrap answer has no available room room=$targetRoomId '
          'ring=${open.ringEventId}',
    );
    if (targetRoomId != null && targetRoomId.isNotEmpty) {
      await push.notifyCallEnded(targetRoomId, ringEventId: open.ringEventId);
    }
    push.consumePendingIncomingAnswer(open);
  }

  Future<Room?> _resolveIncomingCallRoom(String roomId) async {
    const totalBudget = Duration(seconds: 12);
    const syncTimeout = Duration(seconds: 2);
    final deadline = DateTime.now().add(totalBudget);
    Object? lastError;

    while (DateTime.now().isBefore(deadline)) {
      final cached = client.getRoomById(roomId);
      if (cached != null) return cached;
      try {
        await client
            .oneShotSync(timeout: syncTimeout)
            .timeout(const Duration(seconds: 4));
      } catch (error) {
        lastError = error;
      }
      final synced = client.getRoomById(roomId);
      if (synced != null) return synced;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    if (lastError != null) {
      _log(
        'Push',
        'bootstrap answer room sync exhausted room=$roomId',
        lastError,
      );
    }
    return client.getRoomById(roomId);
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
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final appIsBackgrounded = orexIsBackgroundedForNotification(
      lifecycle: lifecycle,
      isWindows: !kIsWeb && defaultTargetPlatform == TargetPlatform.windows,
      desktopWindowVisible: _desktopWindowVisible,
    );
    for (final room in client.rooms) {
      final count = room.notificationCount;
      final previous = _notificationCounts[room.id] ?? 0;
      if (_notificationSnapshotReady && previous > 0 && count == 0) {
        unawaited(push.dismissRoomNotifications(room.id));
      }
      if (orexShouldPublishSyncedMatrixNotification(
        notificationSnapshotReady: _notificationSnapshotReady,
        previousCount: previous,
        currentCount: count,
        roomId: room.id,
        foregroundRoomId: _foregroundRoomId,
        appIsBackgrounded: appIsBackgrounded,
      )) {
        final rtcNotification = room.lastEvent
            ?.tryParseRtcNotificationContent();
        if (rtcNotification?.notificationType != RtcNotificationType.ring) {
          increasedRooms.add(room);
        }
      }
      _notificationCounts[room.id] = count;
    }
    final activeRoomIds = client.rooms.map((room) => room.id).toSet();
    _notificationCounts.removeWhere(
      (roomId, _) => !activeRoomIds.contains(roomId),
    );
    unawaited(
      push.updateDesktopUnreadCount(
        orexTotalUnreadCount(_notificationCounts.values),
      ),
    );
    _notificationSnapshotReady = true;
    if (increasedRooms.isEmpty) return;

    final nativeLocalNotifications =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.windows);
    if (nativeLocalNotifications) {
      // В background Android remote pusher уже владеет доставкой и локальный
      // sync не должен создавать дубль. В foreground FCM намеренно подавляется
      // native bridge, поэтому сообщение из НЕ открытой комнаты публикуем из
      // текущего Matrix sync. Windows всегда использует свой native runner.
      if (appIsBackgrounded && push.ownsBackgroundNotifications) return;
      for (final room in increasedRooms) {
        unawaited(_showSyncedMatrixNotification(room));
      }
      return;
    }

    // У платформ без собственного notification bridge остаётся только
    // внутриприложенный звуковой cue.
    audio.playNotification();
  }

  Future<void> _showSyncedMatrixNotification(Room room) async {
    final event = room.lastEvent;
    if (event == null) return;
    String? avatarCacheKey;
    final senderAvatar = event.senderFromMemoryOrFallback.avatarUrl;
    if (senderAvatar?.scheme == 'mxc') {
      try {
        avatarCacheKey = await ensureAvatarCached(
          senderAvatar,
        ).timeout(const Duration(seconds: 2));
      } catch (_) {
        // The notification itself is more important than an avatar download.
      }
    }
    await push.showSyncedMatrixNotification(
      roomId: room.id,
      eventId: event.eventId,
      avatarCacheKey: avatarCacheKey,
    );
  }

  void setForegroundRoomId(String? roomId) {
    final value = roomId?.trim();
    final next = value == null || value.isEmpty ? null : value;
    if (next == _foregroundRoomId) return;
    _foregroundRoomId = next;
    if (next != null) unawaited(push.dismissRoomNotifications(next));
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

  Future<void> _disposeNetworkResources(VoipService? voipService) async {
    try {
      // Keep Matrix and native E2EE resources alive until CallController's
      // synchronous dispose hook has finished its asynchronous Room teardown.
      await call.shutdownComplete;
      voipService?.dispose();
      final voipShutdown = voipService?.shutdownComplete;
      if (voipShutdown != null) await voipShutdown;
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
    _desktopWindowVisibilitySub?.cancel();
    push.setIncomingCallAnswerHandler(null);
    _incomingCallAnswerBootstraps.clear();
    final voipService = voip;
    call.dispose();
    audio.dispose();
    unawaited(_disposeNetworkResources(voipService));
    super.dispose();
  }
}
