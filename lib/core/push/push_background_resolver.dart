import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/encryption/utils/key_verification.dart';
import 'package:matrix/matrix.dart';

import '../logging/orex_logger.dart';
import '../storage/database.dart';

const _backgroundPushChannelName = 'orex/push_background';
const _backgroundPushClientName = 'OrexMessenger';

/// Результат background-resolution Matrix push.
///
/// Native Android получает только строки, чтобы результат без потерь прошёл
/// через MethodChannel и мог быть безопасно сохранён в Intent/SharedPreferences.
class OrexResolvedPush {
  const OrexResolvedPush(this.data);

  final Map<String, String> data;
}

class _OrexPushDecryptionPending implements Exception {
  const _OrexPushDecryptionPending(this.roomId, this.eventId);

  final String roomId;
  final String eventId;

  @override
  String toString() => 'Matrix event is not decrypted yet: $roomId / $eventId';
}

/// Разрешает Matrix push в реальное событие через локальную сессию Orex.
///
/// Sygnal получает только `event_id_only`. Автор, тип звонка и plaintext E2EE
/// появляются исключительно после загрузки конкретного Matrix event на устройстве
/// и его расшифровки ключами текущей сессии Orex.
class OrexMatrixPushResolver {
  OrexMatrixPushResolver(this.client);

  final Client client;

  static const _serverTimeout = Duration(seconds: 10);
  static const _maxRingAge = Duration(seconds: 55);

  Future<OrexResolvedPush> resolve(Map<String, String> rawPayload) async {
    final roomId = _nonEmpty(rawPayload['room_id']);
    final eventId = _nonEmpty(rawPayload['event_id']);
    if (roomId == null || eventId == null) {
      return OrexResolvedPush(_richPayloadOrDrop(rawPayload));
    }

    final notificationJson = <String, Object?>{
      ...rawPayload,
      'room_id': roomId,
      'event_id': eventId,
    };

    final event = await client.getEventByPushNotification(
      PushNotification.fromJson(notificationJson),
      // Notification resolution must not mutate the timeline cache. In
      // particular, never persist a temporary BadEncrypted event before the
      // one-shot sync has had a chance to fetch missing megolm keys.
      storeInDatabase: false,
      timeoutForServerRequests: _serverTimeout,
      returnNullIfSeen: true,
    );
    if (event == null) {
      return OrexResolvedPush(
        _dropPayload(
          rawPayload,
          roomId: roomId,
          eventId: eventId,
          reason: 'already_read_or_unavailable',
        ),
      );
    }

    final rtc = event.tryParseRtcNotificationContent();
    if (rtc != null) {
      final isFreshRing = rtc.notificationType == RtcNotificationType.ring &&
          _isFresh(event.originServerTs, _maxRingAge);
      if (!isFreshRing) {
        return OrexResolvedPush(
          _dropPayload(
            rawPayload,
            roomId: roomId,
            eventId: eventId,
            reason: 'rtc_not_fresh_ring',
          ),
        );
      }

      await event.fetchSenderUser();
      final caller = _senderName(event, rawPayload);
      return OrexResolvedPush(<String, String>{
        ..._routingFields(rawPayload, roomId: roomId, eventId: eventId),
        'orex_kind': 'incoming_call',
        'call_id': roomId,
        'type': event.type,
        'sender': event.senderId,
        'sender_display_name': caller,
        'title': caller,
        'body': 'Входящий звонок',
        'orex_video': 'false',
        'orex_ring_ts_ms':
            event.originServerTs.millisecondsSinceEpoch.toString(),
      });
    }

    // Ни membership MatrixRTC, ни реакции, state events, receipts или старый
    // signaling не должны маскироваться под сообщения. После targeted RTC ring
    // системное уведомление разрешено только для реального message/sticker.
    if (event.type != EventTypes.Message && event.type != EventTypes.Sticker) {
      return OrexResolvedPush(
        _dropPayload(
          rawPayload,
          roomId: roomId,
          eventId: eventId,
          reason: 'non_message_event',
        ),
      );
    }

    if (event.messageType == MessageTypes.BadEncrypted) {
      throw _OrexPushDecryptionPending(roomId, eventId);
    }

    final body = _messageBody(event);
    if (body == null) {
      return OrexResolvedPush(
        _dropPayload(
          rawPayload,
          roomId: roomId,
          eventId: eventId,
          reason: 'empty_message_body',
        ),
      );
    }

    await event.fetchSenderUser();
    final sender = _senderName(event, rawPayload);
    final roomName = _roomName(event, rawPayload);
    final title = event.room.isDirectChat == true || roomName == null
        ? sender
        : '$sender · $roomName';

    return OrexResolvedPush(<String, String>{
      ..._routingFields(rawPayload, roomId: roomId, eventId: eventId),
      'orex_kind': 'matrix_event',
      'type': event.type,
      'sender': event.senderId,
      'sender_display_name': sender,
      if (roomName != null) 'room_name': roomName,
      'title': title,
      'body': body,
      'content_body': body,
      'content_msgtype': event.messageType,
    });
  }

  static bool _isFresh(DateTime eventTs, Duration maxAge) {
    final age = DateTime.now().difference(eventTs);
    return age.isNegative || age <= maxAge;
  }

  static Map<String, String> _routingFields(
    Map<String, String> raw, {
    required String roomId,
    required String eventId,
  }) {
    return <String, String>{
      'room_id': roomId,
      'event_id': eventId,
      if (_nonEmpty(raw['message_id']) case final messageId?)
        'message_id': messageId,
      if (_nonEmpty(raw['unread']) case final unread?) 'unread': unread,
      if (_nonEmpty(raw['missed_calls']) case final missedCalls?)
        'missed_calls': missedCalls,
    };
  }

  static Map<String, String> _dropPayload(
    Map<String, String> raw, {
    String? roomId,
    String? eventId,
    required String reason,
  }) {
    return <String, String>{
      if (roomId != null && eventId != null)
        ..._routingFields(raw, roomId: roomId, eventId: eventId)
      else ...<String, String>{
        if (_nonEmpty(raw['room_id']) case final value?) 'room_id': value,
        if (_nonEmpty(raw['event_id']) case final value?) 'event_id': value,
        if (_nonEmpty(raw['message_id']) case final value?) 'message_id': value,
      },
      'orex_drop': 'true',
      'orex_drop_reason': reason,
    };
  }

  /// Используется только если push не содержит room_id/event_id. Никаких
  /// искусственных «Новое сообщение»: показываем только уже действительно
  /// информативный payload либо отбрасываем его.
  static Map<String, String> _richPayloadOrDrop(Map<String, String> raw) {
    final kind = _nonEmpty(raw['orex_kind']);
    final callId = _nonEmpty(raw['call_id']) ?? _nonEmpty(raw['room_id']);
    if (kind == 'incoming_call' && callId != null) {
      return <String, String>{
        ...raw,
        'orex_kind': 'incoming_call',
        'call_id': callId,
      };
    }

    final body = _nonEmpty(raw['body']) ?? _nonEmpty(raw['content_body']);
    final author = _nonEmpty(raw['sender_display_name']) ??
        _nonEmpty(raw['sender']) ??
        _nonEmpty(raw['title']) ??
        _nonEmpty(raw['room_name']);
    if (body != null && author != null && !_isGenericBody(body)) {
      return <String, String>{
        ...raw,
        'orex_kind': kind ?? 'matrix_event',
        'title': _nonEmpty(raw['title']) ?? author,
        'body': body,
      };
    }

    return _dropPayload(raw, reason: 'missing_routing_or_rich_content');
  }

  static bool _isGenericBody(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized == 'новое сообщение' ||
        normalized == 'новое событие' ||
        normalized == 'новое событие в orex';
  }

  static String _senderName(Event event, Map<String, String> raw) {
    final resolved = event.senderFromMemoryOrFallback.calcDisplayname().trim();
    if (resolved.isNotEmpty && resolved != event.senderId) return resolved;
    return _nonEmpty(raw['sender_display_name']) ??
        _nonEmpty(raw['sender']) ??
        event.senderId;
  }

  static String? _roomName(Event event, Map<String, String> raw) {
    final pushName = _nonEmpty(raw['room_name']) ?? _nonEmpty(raw['room_alias']);
    if (pushName != null) return pushName;
    final resolved = event.room.getLocalizedDisplayname().trim();
    if (resolved.isEmpty || resolved == event.room.id) return null;
    return resolved;
  }

  static String? _messageBody(Event event) {
    if (event.type == EventTypes.Sticker) {
      final stickerBody = event.calcUnlocalizedBody(
        hideReply: true,
        hideEdit: true,
        plaintextBody: true,
        removeMarkdown: true,
      ).trim();
      return stickerBody.isEmpty ? 'Стикер' : stickerBody.take(240);
    }

    final text = event.calcUnlocalizedBody(
      hideReply: true,
      hideEdit: true,
      plaintextBody: true,
      removeMarkdown: true,
    ).trim();

    return switch (event.messageType) {
      MessageTypes.Text || MessageTypes.Notice || MessageTypes.None =>
        text.nonEmptyOrNull?.take(240),
      MessageTypes.Emote => text.nonEmptyOrNull?.take(240),
      MessageTypes.Image => _withCaption('📷 Фото', text),
      MessageTypes.Video => _withCaption('🎬 Видео', text),
      MessageTypes.Audio => _withCaption('🎵 Аудио', text),
      MessageTypes.File => _withCaption('📎 Файл', text),
      MessageTypes.Location => _withCaption('📍 Геопозиция', text),
      MessageTypes.BadEncrypted => null,
      _ => text.nonEmptyOrNull?.take(240),
    };
  }

  static String _withCaption(String fallback, String body) {
    final normalized = body.trim();
    if (normalized.isEmpty) return fallback;
    return normalized.take(180);
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

extension on String {
  String? get nonEmptyOrNull => trim().isEmpty ? null : this;
  String take(int maxLength) =>
      length <= maxLength ? this : substring(0, maxLength);
}

Future<Map<String, String>?> resolveOrexMatrixPush(
  Client client,
  Map<String, String> rawPayload,
) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      return (await OrexMatrixPushResolver(client).resolve(rawPayload)).data;
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
      if (attempt > 0) rethrow;

      // Missing megolm keys and just-arrived room state are both fixed by the
      // same bounded one-shot sync. The second exact-event fetch then decrypts
      // again without ever storing the temporary BadEncrypted result.
      try {
        await client.oneShotSync(timeout: Duration.zero);
      } catch (syncError) {
        OrexLog.d('PushBackground', 'resolution retry sync failed', syncError);
      }
      await Future<void>.delayed(
        error is _OrexPushDecryptionPending
            ? const Duration(milliseconds: 700)
            : const Duration(milliseconds: 350),
      );
    }
  }
  Error.throwWithStackTrace(firstError!, firstStackTrace!);
}

class _OrexBackgroundPushRuntime {
  Client? _client;
  Future<Client>? _clientFuture;

  Future<Map<String, String>?> resolve(Map<String, String> raw) async {
    final client = await _ensureClient();
    return resolveOrexMatrixPush(client, raw);
  }

  Future<Client> _ensureClient() {
    final existing = _client;
    if (existing != null) return Future<Client>.value(existing);
    final inFlight = _clientFuture;
    if (inFlight != null) return inFlight;

    late final Future<Client> initialization;
    initialization = _createClient().then((client) {
      _client = client;
      return client;
    }).whenComplete(() {
      if (identical(_clientFuture, initialization)) _clientFuture = null;
    });
    _clientFuture = initialization;
    return initialization;
  }

  Future<Client> _createClient() async {
    await vod.init().timeout(const Duration(seconds: 6));
    final database = await buildOrexDatabase();
    final client = Client(
      _backgroundPushClientName,
      database: database,
      shareKeysWith: ShareKeysWith.crossVerifiedIfEnabled,
      verificationMethods: const {
        KeyVerificationMethod.emoji,
        KeyVerificationMethod.numbers,
      },
    );
    await client.init(
      waitForFirstSync: false,
      waitUntilLoadCompletedLoaded: false,
    );
    client.backgroundSync = false;
    if (!client.isLogged()) {
      await client.dispose();
      throw StateError('Orex Matrix session is not logged in');
    }
    return client;
  }
}

/// Named Android headless entrypoint. It is called by a native FlutterEngine
/// created directly from FirebaseMessagingService when no UI is required.
@pragma('vm:entry-point')
Future<void> runOrexPushBackgroundEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(_backgroundPushChannelName);
  final runtime = _OrexBackgroundPushRuntime();

  channel.setMethodCallHandler((call) async {
    if (call.method != 'resolvePush') return null;
    final raw = _stringMap(call.arguments);
    if (raw.isEmpty) return null;
    try {
      return await runtime.resolve(raw);
    } catch (error, stackTrace) {
      OrexLog.d('PushBackground', 'event resolution failed', error);
      OrexLog.d('PushBackground', 'event resolution stack', stackTrace);
      return OrexMatrixPushResolver._dropPayload(
        raw,
        reason: 'resolution_failed',
      );
    }
  });

  await channel.invokeMethod<void>('backgroundReady');
}

Map<String, String> _stringMap(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  final result = <String, String>{};
  for (final entry in raw.entries) {
    final key = entry.key?.toString().trim() ?? '';
    if (key.isEmpty) continue;
    result[key] = entry.value?.toString() ?? '';
  }
  return result;
}
