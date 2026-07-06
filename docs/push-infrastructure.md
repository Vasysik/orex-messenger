# Orex Push Infrastructure

Этот документ фиксирует production-контракт клиентской ветки `0.4.0+12`.
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

Не публикуйте `/_matrix/push/v1/notify` в интернет без отдельной необходимости.

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

Не добавляйте в whitelist весь `172.16.0.0/12`, весь Docker subnet или другие
широкие private ranges: исключение должно быть минимальным и относиться только к
контейнеру Sygnal.

После изменения `homeserver.yaml` перезапустите Synapse и проверьте его логи при
первой регистрации pusher/первом push-событии.

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


## 5. Почему Sygnal может быть пустым

Sygnal получает запросы только после того, как Android-клиент получил FCM token
и зарегистрировал Matrix HTTP-pusher. Поэтому пустой access log почти всегда
означает, что цепочка оборвалась **до** gateway.

Проверяйте по порядку:

1. В Firebase существует Android app с package id `ru.orex.messenger`.
2. Его `google-services.json` лежит в `android/app/` **до** сборки APK.
3. Установлена новая сборка, пользователь вошёл в аккаунт хотя бы один раз, а
   Android не запретил Orex уведомления.
4. У пользователя появился pusher с `app_id = ru.vasys.orex_messenger` и URL
   `http://sygnal:5000/_matrix/push/v1/notify`.
5. Synapse разрешён exact `/32` адрес Sygnal через `ip_range_whitelist`.
6. Тестовое сообщение отправляет **другой пользователь** на аккаунт с
   зарегистрированным Android-устройством; собственные исходящие события не
   являются нормальным тестом push-доставки.

Для локального пользователя администратор Synapse может проверить pusher через
Admin API `GET /_synapse/admin/v1/users/<user_id>/pushers`. Не публикуйте в
тикетах или логах полный `pushkey`: это FCM registration token конкретной
установки приложения.

## 6. Диагностика end-to-end доставки

Наличие строки в таблице `pushers` означает только, что Android получил FCM token
и клиент успешно вызвал Matrix `pushers/set`. Это ещё не доказывает, что:

- событие создало push action для получателя;
- Synapse разрешил исходящий HTTP к private IP Sygnal;
- Sygnal принял запрос и успешно отправил его в FCM;
- Android получил data-message.

Проверяйте цепочку по порядку.

### 6.1. Тест должен идти от другого Matrix-аккаунта

Пользователь с зарегистрированным Android pusher должен **получить** новое
событие от другого пользователя. Отправка сообщения из Windows-клиента под тем
же Matrix ID не является тестом push на собственный Android: исходящее событие
не должно уведомлять его автора как новое входящее сообщение.

### 6.2. Проверить pusher без вывода pushkey

```bash
docker exec postgres-matrix \
  psql -U synapse -d synapse \
  -c "SELECT user_name, app_id, kind, data FROM pushers WHERE app_id='ru.vasys.orex_messenger';"
```

Ожидаются `kind = http`, правильный внутренний URL и `format = full Matrix/Sygnal data payload`.
Не выводите полный `pushkey` в общие логи: это FCM registration token установки.

### 6.3. Проверить, что Synapse реально создал push action

Для конкретного получателя:

```bash
docker exec postgres-matrix \
  psql -U synapse -d synapse \
  -c "SELECT room_id, event_id, user_id, notif, highlight, stream_ordering
      FROM event_push_actions
      WHERE user_id='@vasys:vasys.ru'
      ORDER BY stream_ordering DESC
      LIMIT 20;"
```

Если после сообщения от **другого** аккаунта новых строк/`notif` нет, проблема
на уровне Matrix push rules, а не Sygnal.

### 6.4. Проверить private-IP exception Synapse

Текущий внутренний DNS должен разрешаться из контейнера Synapse:

```bash
docker exec matrix-synapse getent hosts sygnal
```

Проверьте применённый `homeserver.yaml`:

```bash
docker exec matrix-synapse sh -lc \
  "grep -nA3 -B2 'ip_range_whitelist' /data/homeserver.yaml"

# Если start_pushers отсутствует, Synapse использует default=true.
# Если явно стоит false, должен реально работать pusher worker.
docker exec matrix-synapse sh -lc \
  "grep -nE '^(start_pushers|pusher_instances):' /data/homeserver.yaml || true"
```

Для текущего динамического адреса `172.20.0.6` временный точный exception:

```yaml
ip_range_whitelist:
  - '172.20.0.6/32'
```

После изменения нужен restart Synapse. `start_pushers` по умолчанию включён; если
в конфиге он явно `false`, должен реально работать экземпляр из
`pusher_instances`, иначе строки `pushers` будут существовать, но отправлять их
будет некому.

Production-вариант выше в этом документе использует отдельную сеть и статический
`/32`, чтобы restart Docker не сломал разрешение и whitelist не расширял
SSRF-поверхность.

### 6.5. Смотреть Synapse и Sygnal одновременно

```bash
docker compose logs -f synapse sygnal
```

Для уже прошедших событий:

```bash
docker compose logs --since=15m synapse | \
  grep -Ei 'push|pusher|sygnal|blacklist|172\.20\.0\.6'
```

Интерпретация:

- push action есть, но Sygnal не видит POST — проблема между Synapse и gateway
  (часто private-IP policy или конфигурация pusher worker);
- Sygnal видит POST, но пишет FCM error — проверяйте service account, `project_id`,
  `app_id` и соответствие Firebase-проектов;
- Sygnal успешно отправил, но Android молчит — переходите к logcat.

### 6.6. Проверить Android

После установки Android-сборки `0.4.0+12`:

```powershell
adb logcat -c
adb logcat -s OrexPush
```

Безопасные сообщения:

```text
FCM registration token is available
FCM data message received keys=[...]
System notification posted kind=message|call
```

При запрещённом Android permission будет явный безопасный лог:

```text
Notification dropped: POST_NOTIFICATIONS is not granted
```

Token и значения Matrix routing-полей не печатаются. Если строки
`FCM data message received` нет, FCM data-message до приложения не дошёл. Если
она есть, но нет `System notification posted`, проверяйте permission/channel и
следующую строку native-лога.

## 7. Что изменилось в `0.4.0+12`

- живой процесс в background/recents теперь создаёт системное Android-уведомление
  при росте Matrix notification count вместо одного только звука;
- инициатор нового личного звонка отправляет targeted MSC4075 RTC `ring` event;
- Android умеет распознавать стандартный RTC `ring` payload из полного Sygnal
  FCM API v1 data-message;
- Orex больше не описывает `orex_kind` как обязательный контракт стандартного
  Sygnal;
- Android pusher в dogfood-ветке регистрируется без `event_id_only`, чтобы
  уведомления показывали автора, комнату, текст и CallStyle-входящий звонок.
  `event_id_only` остаётся будущим privacy-hardening режимом после появления
  headless resolver/fetch/decrypt.
