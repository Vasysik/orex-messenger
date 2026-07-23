# QR-вход Orex без MAS

QR-вход использует встроенный Synapse endpoint `/_matrix/client/v1/login/get_token`.
Токен одноразовый, имеет короткий TTL и превращается на новом устройстве в
отдельную Matrix-сессию через `m.login.token`.

## Режимы

1. **Авторизованное устройство показывает QR.** Новое устройство сканирует
   одноразовый login token напрямую. Дополнительный сервис не участвует.
2. **Новое устройство показывает QR.** Авторизованный телефон сканирует запрос,
   получает login token от Synapse и возвращает его через временный rendezvous.
   Конверт шифруется AES-256-GCM; ключ передаётся только внутри QR, поэтому relay
   не видит Matrix token.

Сканер доступен на Android, iOS, macOS и в web. На нативных Windows
и Linux переключатель сканирования скрыт: экран сразу показывает QR-код.

## Synapse: обязательная часть

Добавьте в `data/homeserver.yaml`:

```yaml
login_via_existing_session:
  enabled: true
  require_ui_auth: false
  token_timeout: "2m"
```

`require_ui_auth: false` позволяет подтверждать создание новой сессии внутри
Orex без повторного ввода пароля. Клиент всё равно показывает явный диалог
подтверждения. Компромисс: украденный действующий access token также сможет
запросить одноразовый login token, поэтому особенно важны короткий TTL, защита
локального хранилища токена и возможность быстро завершать сессии.

Проверьте поддержку после перезапуска:

```bash
curl -fsS https://vasys.ru/_matrix/client/v3/login | jq
```

В ответе должен присутствовать `m.login.token`, а сервер должен разрешать
получение login token существующей сессией.

Этого блока достаточно для направления «авторизованное устройство показывает
QR». Rendezvous ниже нужен только для удобного desktop-сценария, когда QR
показывает ещё не авторизованный компьютер.

## Rendezvous для desktop → phone

Готовая конфигурация находится в `deploy/synapse-rendezvous/`. Она использует
готовый модуль `matrix-http-rendezvous-synapse`; собственного account/backend API
у Orex нет.

Важно: модуль реализует старый MSC3886, имеет статус alpha, а его последняя
версия `0.1.12` выпущена в 2023 году. Репозиторий реализации впоследствии был
архивирован после замены MSC3886 на MSC4108. Современный встроенный rendezvous
Synapse рассчитан на OAuth/MAS, поэтому после отказа от MAS этот модуль остаётся
компромиссным способом поддержать направление desktop → phone. Перед каждым
обновлением Synapse проверяйте совместимость на тестовом экземпляре и фиксируйте
версию Docker image.

Скопируйте каталог `deploy/synapse-rendezvous` рядом с вашим
`docker-compose.yml`. В сервисе Synapse замените:

```yaml
image: matrixdotorg/synapse:latest
```

на:

```yaml
build:
  context: ./deploy/synapse-rendezvous
  args:
    SYNAPSE_IMAGE: matrixdotorg/synapse:ВАШ_ПРОВЕРЕННЫЙ_ТЕГ
environment:
  SYNAPSE_CONFIG_PATH: /data/homeserver.yaml
  SYNAPSE_ASYNC_IO_REACTOR: "1"
```

Затем объедините блоки из
`deploy/synapse-rendezvous/homeserver.yaml.example` с существующим
`homeserver.yaml`. Не создавайте второй `experimental_features` или `modules`,
если такой блок уже есть.

Рабочий блок конфигурации для текущей версии модуля:

```yaml
modules:
  - module: matrix_http_rendezvous_synapse.SynapseRendezvousModule
    config:
      prefix: /_synapse/client/org.matrix.msc3886/rendezvous
      ttl: 2m
      # В актуальной сборке поле ожидает целое число байт, не строку `16KiB`.
      max_bytes: 4096
      max_entries: 1000

experimental_features:
  msc3886_endpoint: /_synapse/client/org.matrix.msc3886/rendezvous
```

`4096` байт достаточно для Orex-конверта и уменьшает верхнюю границу памяти и
нагрузки от публичного неаутентифицированного rendezvous endpoint.

Пересоберите только Synapse:

```bash
docker compose build --no-cache synapse
docker compose up -d synapse
docker logs matrix-synapse --since 5m
```

Проверка relay:

```bash
curl -i -X POST \
  -H 'Content-Type: application/octet-stream' \
  --data-binary 'test' \
  https://vasys.ru/_synapse/client/org.matrix.msc3886/rendezvous
```

Ожидается `201 Created`, а в заголовках — `Location` и `ETag`. Тест создаёт
короткоживущую запись, которая сама исчезнет по TTL.

Traefik уже должен направлять `/_synapse/client` в Synapse. Если правило было
изменено при удалении MAS, верните этот path-prefix в публичный Synapse router.

## Клиентская конфигурация

Production URL уже задан в `OrexConfig`. Для другого адреса передайте при
сборке:

```text
--dart-define=OREX_QR_RENDEZVOUS_URL=https://example.org/_synapse/client/org.matrix.msc3886/rendezvous
```

URL обязан быть HTTPS. Клиент принимает session URL только с того же origin и
только внутри настроенного rendezvous path.

## Безопасность и ограничения

- QR действует около двух минут.
- Login token используется один раз.
- Прямой QR содержит одноразовый login token: не публикуйте его и не оставляйте
  экран без присмотра.
- Обратный QR фактически является запросом на выдачу полной сессии. Подтверждайте
  его только для собственного устройства, которое находится перед вами; QR со
  страницы, письма или чужого экрана может быть фишинговым.
- Публичный MSC3886 endpoint не требует аутентификации. Ограничьте его rate limit
  на reverse proxy и не выставляйте `max_entries`/`max_bytes` без необходимости.
- MSC3886 и используемый модуль архивированы и не являются современной
  проверенной схемой привязки устройств; критичные развёртывания должны считать
  desktop → phone режим экспериментальным.
- Rendezvous хранит только AES-GCM ciphertext; ключ находится в QR.
- Камера-сканер доступна на Android, iOS, macOS и в web через HTTPS.
- Нативные Windows и Linux только показывают QR; его подтверждает телефон.
- После входа E2EE-ключи восстанавливаются обычным механизмом Orex: проверка
  устройства и key backup остаются отдельным этапом.
- При недоступном rendezvous прямое направление phone/старое устройство → новое
  устройство продолжает работать.
