# Тестирование и диагностика Orex

Этот файл — единая точка для quality gate, smoke-сценариев и диагностических
сборов. Release-документы описывают сборку/деплой и ссылаются сюда, чтобы тесты
не расходились между платформами.

## 1. Базовый quality gate

Из корня проекта перед релизом и после изменений в хрупких runtime-flow:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

CI дополнительно запускает Android Kotlin/JUnit, Web security contract и
release/debug builds. Локально Android проверки можно повторить так:

```powershell
gradle -p android :app:testDebugUnitTest --no-daemon --stacktrace
gradle -p android verifyDebugVodozemacNativeLibs --no-daemon --stacktrace
```

Обновления зависимостей (`flutter pub outdated`) делаются отдельной задачей и не
смешиваются с bugfix-релизом без необходимости.

## 2. Общий smoke

На каждой целевой платформе проверить:

- cold start и восстановление Matrix-сессии;
- личный чат, reply, attachment и большой входящий файл;
- E2EE сообщение после перезапуска;
- обычный/видеозвонок, reconnect и завершение;
- updater и переход на опубликованный build;
- logout без оставшегося runtime/push state.

## 3. Android

Минимум на AOSP/Pixel-подобном устройстве и Xiaomi/MIUI:

- foreground/outgoing и incoming звонок;
- Answer/Reject из notification и с lock screen;
- Home, Back, swipe task и повторное открытие во время connecting/active;
- ошибка защищённого старта звонка → немедленная повторная попытка не должна
  получать системное «уже устанавливается соединение»;
- remote cancel до/после Answer, отсутствие сети и истёкший ring;
- speaker/earpiece/wired/Bluetooth, system mute/hold;
- камера: включение/выключение и переключение без переподключения;
- screen share: permission, background, системный Stop/status chip и повторный
  старт с новым разрешением;
- PiP: portrait/landscape aspect, camera ↔ screen share, media off/on, закрытие
  звонка и возврат из PiP;
- Android 13+ notification permission и Stop в Active apps;
- killed-process notification/ring handoff и открытие нужной комнаты.

`adb shell am force-stop ru.orex.messenger` — отдельный stopped-state сценарий,
а не тест обычной фоновой живучести.

## 4. Web

После deploy проверить обычную вкладку, которая уже открывала предыдущий релиз:

- login/restore session, E2EE, attachments и большие входящие файлы;
- QR scanner: `Сканировать → Показать код` и закрытие экрана гасят camera
  indicator; повторное открытие снова получает изображение;
- звонок с camera/microphone → завершение звонка гасит browser capture
  indicators без refresh вкладки;
- screen share → завершение звонка прекращает capture;
- media PiP: zoom/unzoom, переключение камеры, camera ↔ screen share, появление
  screen share после открытия PiP, `video on → off → on` без второго PiP-click;
- PiP после обновления открывается без CSP violation и JS bridge errors.

Стандартный browser video PiP может показывать browser-owned paused/black frame,
пока remote media выключено; после возврата media движение обязано продолжиться.

## 5. Windows

Проверить:

- install/update обоих каналов и запуск с SQLCipher-backed БД;
- login/restore session, сообщения, вложения и звонки;
- PiP: portrait/landscape, camera ↔ screen share, media off/on и закрытие вместе
  со звонком;
- notification из свернутого/закрытого в tray окна открывает правильный чат;
- уведомление другого чата не удаляется очисткой текущего;
- tray `Открыть Orex` восстанавливает окно, `Выйти` завершает процесс.

## 6. Push / killed process

Тестовое входящее событие должен отправлять **другой Matrix-аккаунт**. Свое
исходящее сообщение тому же Matrix ID не проверяет push на Android.

Последовательность диагностики:

1. Android получил FCM token и зарегистрировал HTTP pusher с
   `app_id = ru.vasys.orex_messenger`.
2. Synapse создал push action для получателя.
3. Synapse разрешил внутренний адрес Sygnal.
4. Sygnal получил POST и отправил его в FCM.
5. Android получил data-message и опубликовал notification либо явно записал
   причину отказа.

Pusher без вывода полного pushkey:

```bash
docker exec postgres-matrix \
  psql -U synapse -d synapse \
  -c "SELECT user_name, app_id, kind, data FROM pushers WHERE app_id='ru.vasys.orex_messenger';"
```

Последние push actions:

```bash
docker exec postgres-matrix \
  psql -U synapse -d synapse \
  -c "SELECT room_id, event_id, user_id, notif, highlight, stream_ordering
      FROM event_push_actions
      WHERE user_id='@vasys:vasys.ru'
      ORDER BY stream_ordering DESC
      LIMIT 20;"
```

Проверка внутреннего Sygnal и worker-конфигурации:

```bash
docker exec matrix-synapse getent hosts sygnal
docker exec matrix-synapse sh -lc \
  "grep -nA3 -B2 'ip_range_whitelist' /data/homeserver.yaml"
docker exec matrix-synapse sh -lc \
  "grep -nE '^(start_pushers|pusher_instances):' /data/homeserver.yaml || true"
docker compose logs -f synapse sygnal
```

На Android безопасные ожидаемые логи включают `FCM registration token is
available`, `FCM data message received`, `Message notification posted` и
`Incoming call notification posted`. Полный FCM pushkey в тикеты/общие логи не
публикуется.

## 7. Updater

Для Debug-канала:

1. Установить build с меньшим номером.
2. Увеличить только `build` в `pubspec.yaml`.
3. Собрать и опубликовать полный Debug release в
   `updates/debug/<version>+<build>/`.
4. Запустить установленный клиент: native updater проверяет feed один раз на
   запуск после первого Flutter frame.
5. Проверить также ручной путь
   `Настройки → О приложении → Проверить обновления` и установку найденного
   installer/APK.

Stable и Debug должны читать только собственные feeds.

## 8. QR rendezvous

После настройки Synapse-модуля:

```bash
curl -i -X POST \
  -H 'Content-Type: application/octet-stream' \
  --data-binary 'test' \
  https://vasys.ru/_synapse/client/org.matrix.msc3886/rendezvous
```

Ожидаются `201 Created`, `Location` и `ETag`.

## 9. Производительность

Измерять scrolling/jank нужно не в debug.

- Android/Windows: profile build + Flutter DevTools → Performance.
- Web: Chrome DevTools → Performance на production/staging. Если локальный
  `flutter run -d chrome --profile` не может работать с backend из-за CORS,
  production trace всё равно подходит для поиска UI/JS/layout/raster класса
  узкого места, хотя хуже связывает минифицированный JS с Dart symbols.

Для регрессии повторять один workload: длинный fling chat list, timeline и
settings, в том числе с приходом нового сообщения. Оптимизировать следует
конкретные frame-time spikes, а не упрощать дизайн заранее.

## 10. Android diagnostic collector

Общий сборщик:

```powershell
.\tool\collect_orex_android_logs.ps1
.\tool\collect_orex_android_logs.ps1 -Area calls
.\tool\collect_orex_android_logs.ps1 -Area push
.\tool\collect_orex_android_logs.ps1 -Area media
```

Сборщик сначала пытается выбрать активный Orex (`ru.orex.messenger.debug` или
`ru.orex.messenger`). Если обе установки одновременно запущены или ни одна не
активна, пакет лучше указать явно:

```powershell
.\tool\collect_orex_android_logs.ps1 -Area calls -Package ru.orex.messenger.debug
```

Это важно для `dumpsys package/meminfo/gfxinfo`: диагностика другого application
ID формально собирается, но не описывает тестируемый процесс. При нескольких
устройствах передать `-Serial <adb-serial>`. `-NoClear` сохраняет предыдущий
logcat, `-Bugreport` добавляет полный `adb bugreport`.

`general` собирает общий logcat и Activity/notification/package/power/window/
meminfo/gfxinfo. Режимы добавляют только профильные состояния:

- `calls` — Telecom и audio;
- `push` — JobScheduler/WorkManager-контекст;
- `media` — camera, MediaProjection и audio.

Архивы создаются в `orex-test-logs/` и не коммитятся. Перед передачей проверить
их на Matrix access token, FCM token, пароли и приватные URL.
