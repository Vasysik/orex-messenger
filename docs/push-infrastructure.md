# Orex Push Infrastructure

Этот документ фиксирует production-контракт клиентской ветки `0.4.0+9`.
Секреты Firebase сюда не добавляются.

## 1. Production identity

Orex Android регистрирует Matrix HTTP-pusher со следующими значениями:

```text
url    = http://sygnal:5000/_matrix/push/v1/notify
app_id = ru.vasys.orex_messenger
format = event_id_only
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

После установки Android-сборки `0.4.0+9` полезны безопасные logcat-сообщения:

```powershell
adb logcat -s OrexPush
```

Они сообщают только состояние Firebase/token и имена ключей входящего payload,
но не печатают сам FCM token и значения Matrix routing-полей.
