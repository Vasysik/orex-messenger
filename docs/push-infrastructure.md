# Orex Push Infrastructure

Этот документ фиксирует production-контракт клиентской ветки `0.4.0+4`.
Секреты Firebase сюда не добавляются.

## 1. Production identity

Orex Android регистрирует Matrix HTTP-pusher со следующими значениями:

```text
url    = http://sygnal:5000/_matrix/push/v1/notify
app_id = ru.vasys.orex_messenger
format = full Matrix/Sygnal data payload
```

Эти значения встроены в production-конфигурацию клиента. Обычная release-сборка
не требует `OREX_PUSH_GATEWAY` или ручного app id.

Android-приложение **не подключается** к `sygnal` напрямую. Оно передаёт URL
homeserver-у при регистрации pusher; затем Synapse вызывает Push Gateway по
внутренней Docker-сети.

## 2. Network boundary

Sygnal должен оставаться закрытым:

- без `ports:`;
- без Traefik router;
- в отдельной internal Docker-сети вместе с Synapse;
- Firebase service-account JSON монтируется только в Sygnal read-only.

Публикация `/_matrix/push/v1/notify` в интернет без отдельной необходимости не
допускается.

## 3. Synapse private-address policy

Synapse по умолчанию блокирует исходящие запросы к private IP ranges, и это
правило применяется в том числе к push servers. Поэтому внутренний Sygnal надо
разрешить через `ip_range_whitelist`.

Production-вариант должен использовать **статический IP Sygnal** в отдельной
узкой Docker-сети и разрешать только этот адрес `/32`.

Пример:

```yaml
# homeserver.yaml
ip_range_whitelist:
  - 172.31.250.10/32
```

И соответствующий compose-фрагмент:

```yaml
services:
  synapse:
    networks:
      - traefik-proxy
      - matrix-backend
      - matrix-push

  sygnal:
    networks:
      matrix-push:
        ipv4_address: 172.31.250.10

networks:
  matrix-push:
    internal: true
    ipam:
      config:
        - subnet: 172.31.250.0/29
```

В whitelist не добавляются весь `172.16.0.0/12`, весь Docker subnet или другие
широкие private ranges: исключение должно быть минимальным и относиться только к
контейнеру Sygnal.

После изменения `homeserver.yaml` требуется restart Synapse и проверка логов при
первой регистрации pusher или первом push-событии.

## 4. Sygnal app contract

В `sygnal.yaml` должен существовать ровно тот app id, который использует клиент:

```yaml
apps:
  ru.vasys.orex_messenger:
    type: gcm
    api_version: v1
    project_id: "YOUR_FIREBASE_PROJECT_ID"
    service_account_file: "/sygnal/firebase-service-account.json"
```

`firebase-service-account.json` остаётся только на сервере. Android использует
отдельный `android/app/google-services.json`, который также не коммитится.

## 5. Что изменилось в `0.4.0`

- FCM callback больше не ждёт Matrix, сеть, SQLCipher или FlutterEngine;
- для E2EE-сообщений добавлен expedited `OrexPushResolveWorker`;
- worker сначала использует живой Flutter/Matrix client, а при отсутствии UI
  запускает сериализованный `OrexPushBackgroundResolver`;
- `room_id/event_id` разрешаются через `Client.getEventByPushNotification()`,
  после чего Matrix SDK возвращает реальный decrypted event; при отсутствующем
  Megolm-ключе выполняется один bounded retry после `oneShotSync`;
- transient resolution failure возвращает `null` и повторяется WorkManager, а
  не превращается в permanent drop;
- заглушка «Новое зашифрованное сообщение» удалена: без plaintext системное
  message notification не публикуется;
- `MessagingStyle` хранит до шести последних сообщений на комнату;
- входящий звонок открывает отдельную `OrexIncomingCallActivity`, а не
  `MainActivity`; Activity работает поверх lock screen и имеет две call-action
  кнопки;
- `CallStyle` использует dedicated full-screen PendingIntent только когда Orex
  не foreground; внутри приложения показывается Flutter incoming-call screen;
- Android 14+ capability `canUseFullScreenIntent()` проверяется, а отсутствующее
  право можно выдать через системную страницу, открываемую при первичном запросе
  notification permission;
- Matrix pusher остаётся без `event_id_only`: ring классифицируется мгновенно,
  а encrypted messages всё равно разрешаются локально по routing ids.

## 6. E2EE и wake-envelope звонка

Обычный `Room.sendRtcNotification()` в зашифрованной комнате проходит через
`Room.sendEvent()` и становится `m.room.encrypted`. Для полностью закрытого
Android-процесса это неразрешимо без запуска Flutter/Matrix crypto и открытия
локальной БД. Теперь этот crypto-путь вынесен из FCM callback в WorkManager и используется только для сообщений; звонок остаётся мгновенным.

Поэтому Orex отправляет персональный ring как короткоживущий открытый MatrixRTC
event через `Client.sendMessage()`. Payload содержит только:

- `notification_type = ring`;
- `sender_ts` и `lifetime` (45 секунд);
- `m.mentions.user_ids` адресатов;
- опциональный call intent, когда он доступен.

Текст сообщений, вложения, ключи шифрования и медиапоток туда не попадают и
остаются в своих E2EE/transport-контурах. Цена этого решения: сам факт и адресаты
попытки звонка видимы homeserver/push-инфраструктуре. Это намеренный production
trade-off ради входящего звонка при убитом процессе; скрывать этот metadata и
одновременно требовать нативный killed-process call UI без доверенного server-side
call hint невозможно.
