# Orex Messenger

Тёплый ореховый мессенджер на **Flutter** поверх **Matrix (Synapse)**, со
сквозным шифрованием сообщений через **vodozemac** и нативными звонками Orex на
стеке **MatrixRTC / LiveKit**. Единая кодовая база: **Web · Android · Windows**.

Orex сейчас находится в стадии **cross-platform prerelease 0.4.2+5**: это
исходный release candidate для dogfood с системными Android-звонками,
killed-process push, MatrixRTC/LiveKit media E2EE и обязательным release quality
gate. После обновления зависимостей сборки должны быть заново подтверждены на
Android, Web и Windows. Версия ещё не является
публичным security-certified релизом: перед таким заявлением нужны независимый
аудит и полный Android ↔ Web ↔ Windows device smoke.

## 1. Продуктовый фокус

Orex строится как личный мессенджер с тёплым визуальным стилем, Matrix-основой и
собственным интерфейсом звонков. Приложение не пытается быть тонкой оболочкой
над Element: чат, звонки, голосовые каналы, предпросмотры и настройки собраны в
единый Orex UX.

Главные принципы:

- один клиент для Web, Android и Windows;
- Matrix как протокол комнат, пользователей, Spaces и E2EE-сообщений;
- собственный Orex UI для звонков поверх MatrixRTC + LiveKit;
- честное разделение того, что уже защищено, и того, что ещё требует отдельной
  production-инфраструктуры.

## 2. Аккаунт, сессия и безопасность сообщений

Приложение входит в Matrix homeserver, восстанавливает локальную сессию и
запускает sync через Matrix SDK.

Flutter-запуск и авторизация используют единый бренд-блок:

- Flutter splash показывает иконку → название → слоган → версия/сборка →
  индикатор запуска;
- вход и регистрация используют ту же иконку, слоган и строку версии вместо
  временной белочки-маскота;
- источник оформления один — `OrexBrandHeader`, поэтому splash и auth-экраны
  не смогут разъехаться при следующем изменении брендинга.

Сообщения защищаются на Matrix-слое:

- `vodozemac` инициализируется до старта Matrix-клиента;
- приватные Matrix-комнаты могут использовать E2EE;
- локальная база на Android/iOS/macOS открывается через SQLCipher-совместимый
  путь текущего DB-стека;
- Windows/Linux desktop cache открывается через SQLCipher-backed FFI database и
  проверяет `PRAGMA cipher_version` перед использованием.

Важно: E2EE сообщений и media E2EE звонков — разные криптографические слои.
Orex включает их отдельно и не считает transport encryption заменой media E2EE.
Desktop-кэш также защищается отдельным SQLCipher-backed слоем. Границы каждого
механизма описаны явно, чтобы продукт не обещал больше, чем реально проверено.

## 3. Чаты и навигация

Левая панель объединяет список комнат, папки, фильтры и глобальный поиск. В
Orex есть личные комнаты, группы, каналы и супергруппы на базе Matrix Spaces.

В чате поддерживаются:

- текстовые сообщения;
- базовые ответы и редактирование;
- вложения и drag-and-drop с едиными лимитами;
- группировка близких медиа в альбомы;
- MXC-медиа и аватары;
- системные карточки вступления, выхода, приглашений и Orex-инвайтов;
- read markers и аккуратная догрузка истории старых малых каналов.

`ChatView` всё ещё остаётся главным экраном переписки, но самые рискованные
части уже вынесены в отдельные контроллеры и адаптеры: composer state,
attachment queue и timeline grouping.

## 4. Поиск и предпросмотр

Глобальный поиск работает не только по локальному списку комнат. Он умеет
показывать людей, публичные комнаты и Matrix room references.

Ключевой UX-инвариант `0.3.3`: клик по найденному человеку **не создаёт личную
переписку сразу**. Сначала открывается единый предпросмотр, такой же концептуально,
как у комнат и каналов. Пользователь сам решает, входить ли в личный чат.

Предпросмотр используется для:

- найденных людей;
- публичных комнат;
- ссылок/alias-ов на комнаты;
- дочерних комнат супергрупп до вступления.

## 5. Супергруппы и каналы

Супергруппа в Orex — это Matrix Space. Дочерние комнаты живут внутри
супергруппы и не дублируются как обычные чаты в левой панели.

Поведение супергрупп:

- пустая супергруппа предлагает администратору добавить первый чат;
- дочерние комнаты не создаются автоматически пачкой при создании Space;
- metadata дочерних комнат сохраняется в `m.space.child`, чтобы preview был
  нормальным до вступления;
- если пользователь не состоит в супергруппе, вход в дочернюю комнату блокируется;
- Matrix alias в Orex показывается в локальном виде `#room`, потому что текущий
  UX рассчитан на один основной homeserver.

Каналы отличаются от групп прежде всего поведением публикации и голосового
режима: обычный участник может смотреть и читать, но право говорить в голосовом
канале выдаётся отдельно.

## 6. Медиа и файлы

Orex поддерживает отправку вложений, предпросмотр медиа, открытие файлов через
платформенный helper и галерею для просмотра изображений/видео.

Для вложений действует единая очередь:

- максимум файлов;
- максимум размера одного файла;
- максимум размера batch;
- предварительная проверка drag-and-drop до чтения больших файлов в память.

Это важно для desktop UX: пользователь может случайно бросить в окно огромный
файл, и приложение не должно бездумно читать всё в RAM. Предварительная
проверка уже защищает выбор и добавление вложений в очередь, но пересылка
очень больших файлов ещё требует отдельного streaming-hardening из roadmap.
На IO-платформах
открытие скачанных файлов и системное воспроизведение медиа проходят через один
helper с sanitization имени и защитой от path traversal.

## 7. Звонки и голосовые каналы

Звонки в Orex реализованы нативно в Flutter UI поверх MatrixRTC и LiveKit.
`call.element.io` не встраивается.

Что есть сейчас:

- мобильный исходящий и принятый звонок открывается развёрнутым; при ответе из
  background/cold start нативная оболочка сначала показывает «Подключаем к
  звонку…», затем передаёт экран уже поставленному в navigator `CallScreen` со
  статусом «Соединение…», не показывая Home или свёрнутую панель между этапами;
- входящий личный звонок поверх текущего экрана;
- полный экран звонка;
- свёрнутая панель активного звонка;
- единые call controls для полного и свёрнутого вида;
- плитки участников, фокус на участника, zoom и предпочтение screen share;
- microphone/camera/speaker controls;
- последовательное переключение активной камеры с одной управляемой LiveKit
  publication: без второй вручную опубликованной camera publication и без
  permission-probe, открывающего дополнительный capture во время звонка;
- screen-share controls и desktop source picker на поддерживаемых платформах;
- Android screen share пока не показывается в controls: MediaProjection flow ещё
  не реализован;
- настройки аудиоустройств;
- известное ограничение Web на Windows: на некоторых Bluetooth-гарнитурах сам
  запуск microphone capture может перевести системный вывод в hands-free/mono,
  даже когда в Orex выбран отдельный внешний микрофон и стереовыход. Пока это не
  воспроизведено как клиентская ошибка, приложение должно логировать фактически
  выбранные input/output device ID и не пытаться лечить профиль повторным
  открытием устройств или скрытым переключением маршрута;
- на Android маршрутом earpiece/speaker/wired/Bluetooth управляет Core-Telecom;
  для connected audio-call на earpiece proximity wake lock гасит экран у уха и
  освобождается при видео, смене маршрута и завершении звонка;
- семантический вибро-отклик Android для selection/action/confirm/destructive
  действий в звонке и composer; desktop/web остаются безопасным no-op;
- реакции и поднятая рука как состояние участника звонка; звук реакции
  воспроизводится только у удалённых участников при появлении нового remote
  reaction timestamp, а не локально у отправителя;
- голосовые каналы для групп, каналов и чатов супергрупп;
- listen-only UX для каналов;
- rollback при ошибках signaling/media connect, чтобы не оставлять фантомную
  активную сессию;
- точная идентичность попытки `room + ring event`: stale accept/reject/ended не
  применяется к следующему звонку в той же комнате;
- `accepted` публикуется после успешного MatrixRTC membership, `handled` закрывает
  только лишние ringing surfaces, а reject/busy не уничтожает созданный
  вызывающим зашифрованный MatrixRTC-канал;
- delayed ring без живого membership подавляется и не может воскресить старый
  Android incoming call;
- accepted/rejected/busy/ended/handled в E2EE-комнатах отправляются как
  Olm-encrypted to-device события конкретным Matrix DeviceKeys;
- все call-control Matrix writes проходят через общую очередь с coalescing и
  backoff по серверному `retry_after_ms`;
- звонок fail-closed не запускается в незашифрованной Matrix-комнате. Временный
  `OREX_ALLOW_UNENCRYPTED_CALLS=true` предназначен только для локальной
  диагностики и снимает защиту доставки медиаключей от homeserver.

Начиная с `0.4.0+4`, личные звонки на Android 8+ интегрированы с Android
Telecom через Jetpack Core-Telecom:

- входящие и исходящие личные звонки регистрируются как системные call-сессии;
- ответ, отклонение, завершение, mute и hold из системного UI/гарнитуры
  синхронизируются с `CallController` и LiveKit;
- во время зарегистрированного системного звонка выбор earpiece/speaker/wired/
  Bluetooth endpoint передаётся только Core-Telecom; встроенные speaker/earpiece
  подтверждаются по типу endpoint, а громкость остаётся на системном
  `STREAM_VOICE_CALL`; сохранённый выбор earpiece больше не сбрасывается при
  следующем запуске приложения; после успешной Telecom-регистрации LiveKit
  получает полноценную `communication` audio-session configuration и остаётся в
  manual lifecycle на время системного вызова, поэтому Core-Telecom сохраняет
  единоличное владение endpoint routing; после завершения возвращается automatic
  lifecycle, а fallback без Telecom его не покидает;
- системные mute/hold не перезаписывают пользовательское предпочтение микрофона:
  после восстановления возвращается выбранное в Orex состояние;
- входящие и активные вызовы разделены на разные notification channels: входящий
  вызов использует high-importance канал, активный — обычный ongoing-канал;
  active-call notification принадлежит только `OrexCallForegroundService`, поэтому
  поздний ring/handled/end cleanup не может удалить её из push-слоя; call cards
  строятся через `NotificationCompat.CallStyle`: ongoing-карточка получает
  обязательное системное действие завершения и два пользовательских действия —
  микрофон и локальный звук;
- на Android ниже API 26 и для несистемных голосовых каналов сохраняется прежний
  безопасный in-app fallback.

Граница Core-Telecom этапа намеренная: системный UI работает для вызовов,
которые уже обнаружил Matrix sync. В `0.4.0+6` начата отдельная production-
цепочка push-доставки для полностью закрытого Android-процесса; она не подменяет
Matrix push локальными таймерами или фоновым polling.

### 7.1. Push, E2EE-уведомления и входящий звонок вне приложения (`0.4.0+15`)

В `0.4.0+15` Android push-слой разделён на два независимых по задержке пути:

- `FirebaseMessagingService` остаётся коротким: он только нормализует FCM и
  либо сразу публикует звонок/готовый plaintext, либо ставит E2EE-resolution в
  expedited `WorkManager`;
- `m.room.encrypted` никогда не превращается в заглушку. Worker получает
  `room_id/event_id`, использует Matrix SDK и локальную зашифрованную сессию,
  при необходимости делает bounded one-shot sync для недостающих Megolm-ключей
  и публикует `MessagingStyle` только после получения реального plaintext;
- если основной Flutter/Matrix engine жив, resolution выполняется через него.
  Если процесса UI нет, WorkManager поднимает сериализованный headless Matrix
  resolver. Этот FlutterEngine запускается уже после возврата FCM callback и не
  блокирует доставку;
- уведомления по комнате хранят короткую локальную историю последних сообщений,
  поэтому `MessagingStyle` показывает контекст беседы, а не одну безымянную
  строку;
- персональный MatrixRTC `ring` остаётся короткоживущим открытым wake-envelope:
  он нужен, чтобы полностью убитый Android-процесс мгновенно отличил звонок от
  обычного E2EE-события. Текст, ключи и медиаданные в этот envelope не попадают;
- входящий звонок использует high-importance `CallStyle`, ringtone, вибрацию и
  отдельную `OrexIncomingCallActivity`. Full-screen intent больше не ведёт в
  `MainActivity`: нативное окно может появиться поверх lock screen до запуска
  Flutter и содержит имя, статус, крупный аватар/fallback и две основные кнопки
  «Отклонить»/«Ответить»;
- на Android 14+ Orex проверяет `canUseFullScreenIntent()` и при первом запросе
  notification permission открывает системную страницу доступа, если право на
  полноэкранный звонок не выдано;
- ringing и ongoing call notifications используют разные ID и разных владельцев:
  answer/reject/push cleanup снимает только входящую карточку, а ongoing-карточку
  создаёт и удаляет исключительно foreground call service;
- внутри открытого приложения используется полноэкранный Flutter call UI той же
  двухкнопочной композиции; native full-screen intent подавляется, пока Activity
  реально находится в foreground;
- `google-services.json` не хранится в репозитории, а Android release
  fail-closed и не собирается без Firebase-конфигурации.

Production gateway развёрнут рядом с Synapse как внутренний Sygnal:
`http://sygnal:5000/_matrix/push/v1/notify`. Android сам к нему не подключается.
Production build использует `app_id = ru.vasys.orex_messenger`.

Когда desktop-процесс уже запущен, Windows показывает системные Matrix
уведомления для новых сообщений из неоткрытых комнат и открывает нужный чат по
нажатию. Доставка и активация для полностью закрытого Windows-клиента —
отдельная задача ветки `0.4.x`.

Практическая сборка описана в `docs/release-android.md`,
`docs/release-windows.md` и `docs/release-web.md`; диагностика цепочки
Synapse → Sygnal → FCM — в `docs/push-infrastructure.md`.

LiveKit JWT берётся через `lk-jwt-service` по legacy-compatible контракту
`POST /sfu/get`. В этот endpoint нельзя отправлять `requested_livekit_grants`:
совместимые backend-ы отклоняют неизвестные поля с HTTP 400.

## 7.2. `M_LIMIT_EXCEEDED` и приватный Synapse

`M_LIMIT_EXCEEDED` возвращает homeserver или reverse proxy, а не LiveKit.
Orex сериализует call-related Matrix writes, объединяет одинаковые in-flight
операции и соблюдает `retry_after_ms`, чтобы ring, membership cleanup и
media-key retry не создавали повторный request storm.

Для маленького доверенного Synapse лимит сообщений настраивается в
`homeserver.yaml`:

```yaml
rc_message:
  per_second: 50
  burst_count: 200
```

После изменения требуется полный restart Synapse и его workers. Если 429
остаётся, отдельно проверяется rate limiting в nginx/Traefik.

Для конкретного локального пользователя message ratelimit можно отключить через
Synapse Admin API `/_synapse/admin/v1/users/<user_id>/override_ratelimit`, передав
`messages_per_second: 0` и `burst_count: 0`. Admin access token никогда не должен
попадать в клиент Orex или репозиторий. Глобально отключать защиту не требуется:
клиентский backoff всё равно остаётся обязательным на случай перегрузки сервера.

## 8. Media E2EE звонков

Звонки Orex теперь подключают LiveKit frame encryption через
`RoomOptions(encryption: E2EEOptions(...))`. Ключи не берутся из LiveKit URL,
JWT или room id: один `BaseKeyProvider` используется одновременно MatrixRTC-
signaling слоем и LiveKit media layer.

По умолчанию звонки разрешены только в Matrix-комнатах с включённым E2EE.
Управляющие accepted/rejected/busy/ended/handled также идут через encrypted
to-device; открытым остаётся только короткоживущий wake/cancel envelope, нужный
Android-процессу до разблокировки Matrix crypto.

MatrixRTC передаёт и запрашивает SFU-ключи через E2EE to-device события Matrix,
а LiveKit шифрует audio/video/data frames теми же participant keys. Перед входом
в медиа-комнату включён `preShareKey`. Для late join Orex после LiveKit transport
явно пересинхронизирует MatrixRTC membership, запрашивает отсутствующие remote
media keys и ждёт callbacks key-provider до публикации состояния `connected`.
Тот же resync запускается при появлении нового remote participant и после media
reconnect. Если комната не зашифрована, key provider или обязательные remote keys недоступны, звонок
завершается ошибкой, а не продолжает работу с чёрным/немым ciphertext и не
откатывается в plaintext. Escape hatch `OREX_ALLOW_UNENCRYPTED_CALLS=true`
осознанно ослабляет эту гарантию и запрещён для production-пререлиза.

На Web обязателен version-matched `e2ee.worker.dart.js`. CI собирает worker из
того же тега `livekit_client`, который зафиксирован в `pubspec.yaml`, и Web
release не проходит security contract без этого файла.

Это не снимает оставшиеся release-требования: нужно прогнать реальные
Android ↔ Windows ↔ Web звонки, late join, reconnect и key rotation. Server-side
проверка ролей/voice grants в `/sfu/get` пока отдельно не реализована и не
смешивается с media E2EE.

## 9. Локальное хранение

Локальная Matrix-БД шифруется на всех нативных платформах:

- Android/iOS/macOS: `sqflite_sqlcipher 3.4.x`;
- Windows/Linux: `sqlite3 2.9.x` + `sqflite_common_ffi 2.3.x` +
  `sqlcipher_flutter_libs 0.6.8`; эта совместимая ветка временно сохраняется,
  потому что `matrix 8.1.0` ограничивает `sqlite3` диапазоном 2.x;
- 256-битный пароль БД хранится через `flutter_secure_storage`.

Имена базы и ключа не менялись: мобильные платформы продолжают использовать
`orex.sqlite`, Windows/Linux — `orex-sqlcipher.sqlite`, а пароль хранится под
ключом `orex_db_pass`. Обновление `0.4.2` не удаляет существующий локальный кэш
и не требует повторного входа только из-за изменений зависимостей.

На Windows/Linux Orex проверяет `PRAGMA cipher_version` и отказывается запускать
Matrix cache, если native asset оказался обычным SQLite. Plaintext fallback в
production отсутствует.

## 10. Архитектура

```text
lib/
  core/
    config/       runtime config, app version
    storage/      platform database selection and cache security policy
    matrix/       MatrixService facade and Matrix APIs
    push/         Matrix pusher lifecycle and native notification bridge
    voip/         lifecycle orchestration, attempt/disposition/ring policies, Matrix signaling gate, media controllers
    audio/        audio cues and device preferences
  domain/
    rooms/        Orex room/domain preview models and Matrix mappers
  features/
    home/         shell and conversation coordinator
    chats/        sidebar, chat view, timeline adapter, composer, attachments
    calls/        call presentation, participant tiles, controls and UI actions
    settings/     settings screens and reusable settings content
  shared/
    theme/        Orex theme/glass styling
    widgets/      dialogs, avatars, profile cards, reusable UI
test/
  core/
  domain/
  features/
```

`MatrixService` пока остаётся compatibility facade. Это осознанно: на текущем
этапе важнее стабильность, чем ещё один большой перенос API по папкам.
Дальнейшая миграция должна идти по мере реальных продуктовых задач.

Телефония после 0.4.2 разделена на presentation/coordinator, lifecycle policy,
идентичность попытки и tombstone registry, encrypted Matrix control transport,
rate-limit gate и media/platform integration. `VoipService` остаётся orchestration
root для Matrix sync, MatrixRTC, push и UI streams; дальнейшее деление выполняется
только вместе с конкретной runtime-проблемой, а не ради количества файлов.

## 11. Сборки и релизные артефакты

Release-инструкции разделены по платформам:

- [Android](docs/release-android.md)
- [Windows](docs/release-windows.md)
- [Web](docs/release-web.md)

Короткий локальный quality gate перед release candidate:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
Push-Location android
.\gradlew.bat :app:testDebugUnitTest :app:assembleDebug --no-daemon
Pop-Location
flutter build web --release --no-web-resources-cdn
flutter build apk --release --split-per-abi
flutter build windows --release
```

`pubspec.lock` коммитится после успешного `flutter pub get` той же Flutter
версией, которой собирается пререлиз. Android release требует signing и Firebase
configuration; Windows/Linux дополнительно проверяют наличие SQLCipher через
runtime fail-closed check.

### 11.1. Служебные инструменты

#### Диагностика Android-звонка

`tool\collect_orex_call_logs.ps1` интерактивно собирает один тестовый сеанс
Android-звонка. Скрипт проверяет подключённое ADB-устройство, по умолчанию
очищает logcat, сохраняет все его буферы без привязки к PID, снимает состояние
Activity/Telecom/уведомлений/audio/power через `dumpsys`, создаёт
отфильтрованный `02-logcat-orex-focused.txt` и упаковывает результат в
`orex-test-logs\orex-call-<дата>.zip`.

```powershell
.\tool\collect_orex_call_logs.ps1
.\tool\collect_orex_call_logs.ps1 -NoClear    # сохранить старый logcat
.\tool\collect_orex_call_logs.ps1 -Bugreport  # дополнительно снять adb bugreport
```

Скрипт рассчитан на одно устройство в состоянии `adb devices = device`.
Перед передачей архива проверьте его на access token, FCM token, пароли и
приватные URL. Каталог `orex-test-logs` не коммитится.

#### Web-биндинги vodozemac

`tool/setup_web_vodozemac.sh` пересобирает WASM-биндинги vodozemac и полностью
заменяет сгенерированный каталог `web/pkg`. Он нужен после обновления
`flutter_vodozemac`, при восстановлении отсутствующего `web/pkg` или при
осознанной регенерации Web-криптографии; обычный `flutter build web` его не
запускает.

Скрипт запускается из корня репозитория в Bash и требует Rust (`rustup`,
`cargo`). Версия `VERSION` в скрипте должна меняться вместе с версией
`flutter_vodozemac` в `pubspec.yaml`.

```bash
./tool/setup_web_vodozemac.sh
```

Не храните вручную созданные файлы в `web/pkg`: скрипт удаляет каталог перед
генерацией.

#### Проверка Android native vodozemac

`android/cargokit_proxy/run_build_tool.cmd` — внутренний Windows-proxy, а не
команда для ручного запуска. Gradle автоматически подключает его только для
задач `flutter_vodozemac` на Windows.

Proxy берёт Flutter SDK из `android/local.properties`, вызывает исходный
Cargokit с теми же входными параметрами, удаляет старые `.so` перед сборкой и
завершает Gradle с ошибкой, если хотя бы для одного запрошенного ABI не создан
`libvodozemac_bindings_dart.so`. Это предотвращает ложный успешный APK без
native E2EE-библиотеки. `android/cargokit_proxy/gradle/plugin.gradle` —
служебный marker-файл proxy и также не запускается вручную.

Задачи `verifyDebugVodozemacNativeLibs`, `verifyProfileVodozemacNativeLibs` и
`verifyReleaseVodozemacNativeLibs` проверяют уже объединённые native-библиотеки
приложения. Они автоматически входят в `assemble*`, `package*` и `bundle*`;
при диагностике можно вызвать проверку отдельно:

```powershell
Push-Location android
.\gradlew.bat verifyDebugVodozemacNativeLibs --no-daemon
Pop-Location
```

#### Деплой и CI

`docker-compose.web.yml` публикует `build/web` через nginx в существующей
внешней сети `traefik-proxy` и задаёт production security headers. Инструкции
по запуску — в [Web release](docs/release-web.md).

`.github/workflows/ci.yml` выполняет проверки для pull request и веток
`main`/`master`: Dart analyze/test, Kotlin/JUnit, проверку Web security
contract, Android debug/release и Windows release build. Workflow не публикует
артефакты и не выполняет деплой.

## 12. Древо разработки

### Текущий статус ветки 0.4.2

**Сделано:** полноэкранный запуск мобильного звонка, исправленный accept/reject,
точная идентичность попытки, anti-replay по ID/времени, encrypted call-control,
Matrix request gate с `retry_after_ms`, fail-closed media E2EE и SQLCipher 4.10
через совместимую ветку `sqlite3 2.x` на desktop без смены существующей базы
или ключа. В `0.4.2+9` добавлены конечные deadlines для MatrixRTC/LiveKit,
рабочее отключение входящего LiveKit-аудио, ongoing-уведомление Android и
исправление lifetime Web-диалогов. В `0.4.2+10` каждый личный звонок получает
отдельное MatrixRTC-поколение по точному ring event ID: поздний cleanup первого
звонка больше не может удалить membership второго. Compound lifecycle
`GroupCallSession.enter/leave` не удерживает глобальную очередь Matrix-записей;
запоздалый `enter` получает compensating teardown, cleanup одной SDK-сессии
сериализован, а любой Matrix write имеет обязательный hard timeout. Завершение
звонка освобождает UI и локальный owner до сетевого cleanup и само ограничено
по времени, поэтому повторный вызов не ждёт зависшую предыдущую операцию. Так
как `call_id` личного звонка стал поколенческим, для smoke и dogfood все
участники звонка должны одновременно использовать сборку `0.4.2+10` или новее.
В `0.4.2+11` Android-представление входящего вызова различает живого владельца
звонка и оставшееся после остановленного процесса состояние `answering/active`.
Свежий точный ring больше не подавляется старым SharedPreferences-состоянием и
не записывается ошибочно в cancellation tombstone; это восстанавливает
уведомление и full-screen incoming UI в фоне и при cold start. GitHub CI также
запускает точную Gradle-задачу `:app:testDebugUnitTest`, поэтому native
Kotlin/JUnit-тесты Orex проверяются отдельно от тестов Flutter-плагинов. В
`0.4.2+12` принятие из background/cold start получило явный UI handoff:
нативное окно остаётся в состоянии «Подключаем к звонку…», MainActivity строит
Flutter navigator под нативным cover, затем мобильный `CallScreen` открывается
развёрнутым со статусом «Соединение…». Нативный cover снимается только после
post-frame подтверждения расширенного route; foreground service и Core-Telecom
больше не могут преждевременно закрыть connecting shell. В `0.4.2+14` неудачные UI-изменения `+13` точечно откатены: у нативного
экрана «Подключаем к звонку…» снова нет отдельной кнопки отмены или failure-
режима, а ongoing-карточка снова использует прежние явные кнопки микрофона,
звука и завершения вместо `CallStyle`, скрывавшего пользовательские действия.
Cold-start handoff больше не отправляет Answer в ещё не готовый Dart
`MethodChannel`: native bridge ждёт первого реального вызова из Dart, после чего
доставляет сохранённый Answer; persisted open остаётся резервным путём. Это
устраняет зависший connecting-cover и повторный Flutter-рингтон без добавления
кнопок в экран подключения. Полезная часть `+13` сохранена: process-owned
FlutterEngine, foreground phone-call service, wake lock, `START_STICKY`,
удержание runtime при удалении задачи и восстановление пропавшей ongoing-
карточки. Обычное сворачивание или смахивание Orex из recent apps не должно
завершать активный разговор.


**До выдачи пререлиза:** повторно выполнить `pub get`, `analyze`, `test` после
изменений `+14`; smoke двух последовательных звонков Android ↔ Web ↔ Windows для accept/reject/redial, потери
сети, stage timeout, повторного входа после фантома, audio mute, background/lock
screen и reconnect; проверить logout/soft logout после Matrix 8.x, release-сборки
и push на убитом Android-процессе. Web smoke должен выполняться через
production reverse proxy: Chrome может блокировать Matrix `/sync` с
`http://localhost` на публичный homeserver по Private Network Access/CORS, и в
таком режиме звонок закономерно не получает membership и медиаключи. Переход на
`sqlite3 3.x` отложен до снятия ограничения в Matrix SDK; он не должен
форсироваться через `dependency_overrides`. Для Android отдельно проверить
Answer при выключенном экране, смахивание задачи во время активного разговора,
возврат по ongoing-уведомлению и отказ в `POST_NOTIFICATIONS`: без системного
разрешения Android оставляет foreground service в Task Manager, но приложение
не может принудительно показать карточку в notification drawer. Force stop из
настроек Android остаётся жёсткой системной границей и прекращает любой call
runtime; обычное закрытие UI/смахивание задачи теперь не должно завершать
звонок.

**Отложено:** миграция Android-проекта и зависимых Flutter-плагинов на
Built-in Kotlin до того, как будущая версия Flutter удалит поддержку применения
Kotlin Gradle Plugin из app/plugins; режим «только подтверждённые cross-signed
устройства», серверный enforcement LiveKit grants/voice permissions, переход на
`sqlite3 3.x` после
совместимого Matrix SDK, миграция `flutter_secure_storage` на следующий major и
дальнейшее дробление `VoipService` без подтверждённой runtime-проблемы.


Древо разработки ниже фиксирует продуктовый порядок работ и зависимости между
функциями. Она не превращает каждый пункт в обещание конкретной даты: версии —
это логические этапы, а не календарный контракт.

Главный принцип дальнейшего планирования: сначала закрепить системную
надёжность мобильного и desktop-клиентов, затем построить единый слой контактов,
сессий, приватности, уведомлений и локальных данных, и только после этого
расширять timeline, профили и мультимедиа. Так новые функции не придётся
повторно пришивать к разным экранам и платформенным обходным путям.

### 12.1. Ветка 0.4.x — release hardening

Эта ветка не должна разрастаться в новый продуктовый релиз. Её задача —
сделать уже существующие функции предсказуемыми перед расширением UX.

* 🟡 единый безопасный pipeline временных медиафайлов: sanitization имён и
  запрет path traversal уже используются и для скачанных файлов, и для системного
  media player; контролируемая очистка временных файлов ещё нужна;
* 🟡 **Допилить уведомления на Windows.** Аватарки в уведомлениях, отработка 
  уведомления при открытом чате, но свёрнутом приложении; сворчивание в трей
* 🟡 **Обновление из приложения.** Простая проверка папки релизов на собственном
  web-сервере, предложение обновиться в разделе «О приложении» и запуск штатного
  installer-потока платформы; без ручного manifest и скрытой установки;
* 🟡 **Устойчивая пересылка очень больших файлов.** Streaming-передача,
  ограничение памяти, отмена и понятная ошибка вместо вылета при forwarding;
* 🟡 **Почта, восстановление и QR-вход.** Привязка и подтверждение e-mail,
  безопасный сброс пароля и QR-передача/подтверждение сессии должны использовать
  один account-security flow и не раскрывать адрес почты другим пользователям;
* 🟡 **Демонстрация экрана на Android.** Полный MediaProjection lifecycle:
  системное разрешение, foreground ownership, publication, stop/revoke и
  корректное восстановление после background/lock screen;
* privacy-safe crash reporting и диагностика критических flow: login, sync,
  calls и media;
* release smoke tests и фиксация воспроизводимых версий backend/client
  зависимостей перед публичным распространением.

#### Простая схема обновления из приложения

Для первой production-реализации публикация релиза должна сводиться к созданию
папки с версией и загрузке готовых файлов. Никакой manifest, SHA-256 или ручное
редактирование JSON для каждого релиза не требуется:

```text
/updates/stable/
  0.4.2+5/
    Orex-Setup-0.4.2+5.exe
    app-arm64-v8a-0.4.2+5.apk
    app-armeabi-v7a-0.4.2+5.apk
    notes.md                         # необязательно

  0.4.3+6/
    Orex-Setup-0.4.3+6.exe
    app-arm64-v8a-0.4.3+6.apk
    app-armeabi-v7a-0.4.3+6.apk
    notes.md                         # необязательно
```

Имя папки имеет строгий формат `<version>+<build>`, например `0.4.3+6`.
`build` должен монотонно увеличиваться для каждого релиза. Имена файлов внутри
папки также содержат ту же версию и сборку:

- Windows x64: `Orex-Setup-<version>+<build>.exe`;
- Android arm64: `app-arm64-v8a-<version>+<build>.apk`;
- Android armv7: `app-armeabi-v7a-<version>+<build>.apk`;
- описание изменений: необязательный `notes.md`.

Один раз на сервере настраивается endpoint `/updates/stable/latest.json`. Он
сканирует только папки, имя которых соответствует ожидаемому формату, выбирает
релиз с наибольшим `build`, проверяет наличие известных файлов и автоматически
возвращает их размер. Для нового релиза достаточно загрузить новую папку:

```json
{
  "version": "0.4.3",
  "build": 6,
  "notes_url": "/updates/stable/0.4.3+6/notes.md",
  "artifacts": {
    "windows-x64": {
      "url": "/updates/stable/0.4.3+6/Orex-Setup-0.4.3+6.exe",
      "size_bytes": 84213760
    },
    "android-arm64-v8a": {
      "url": "/updates/stable/0.4.3+6/app-arm64-v8a-0.4.3+6.apk",
      "size_bytes": 60497920
    },
    "android-armeabi-v7a": {
      "url": "/updates/stable/0.4.3+6/app-armeabi-v7a-0.4.3+6.apk",
      "size_bytes": 57319424
    }
  }
}
```

Если `notes.md` или одна из сборок отсутствует, endpoint просто не возвращает
соответствующее поле. В первой версии `notes.md` можно показывать как обычный
текст с сохранением переносов строк, не добавляя отдельный Markdown renderer.

Правила клиента:

- текущая версия берётся из package metadata и сравнивается с `version + build`;
- сервер и клиент считают `build` главным монотонным номером релиза, а
  `version` — пользовательским номером;
- автоматическая проверка выполняется неблокирующе после восстановления сессии,
  затем не чаще одного раза в шесть часов; ручная проверка выполняется сразу;
- предложение не показывается во время активного звонка и появляется после его
  завершения;
- ошибка сервера не мешает запуску приложения и не означает, что обновлений нет;
- обычное обновление никогда не скачивается и не устанавливается незаметно;
- закрытие предложения запоминается только для точного `version + build`;
- downgrade запрещён: сборка с `build`, не превышающим установленный, не
  предлагается;
- web-клиент не скачивает APK или EXE: после публикации новой web-сборки он
  использует обычный service-worker/reload flow.

##### Выбор файла для платформы

Windows-клиент использует `windows-x64`. Android-клиент через небольшой native
bridge получает первый поддерживаемый ABI из `Build.SUPPORTED_ABIS` и выбирает
`android-arm64-v8a` либо `android-armeabi-v7a`. Если подходящего файла нет,
кнопка установки не показывается и пользователь видит понятное сообщение.
Опционально позднее можно добавить `app-universal-<version>+<build>.apk` как
fallback для редких архитектур и эмуляторов.

##### Окно обновления

Верхняя плашка содержит заголовок `Доступна новая версия` и пояснение
`Нажмите, чтобы посмотреть изменения`. Нажатие сразу открывает окно обновления,
а не переводит пользователя в настройки.

В проекте уже используется единый стиль `AlertDialog` в
`lib/shared/widgets/orex_dialogs.dart`. Для обновлений нужен отдельный
`OrexUpdateDialog`, а не расширение простого `showOrexConfirmDialog`: содержимое
окна должно изменяться во время асинхронной загрузки, показывать прогресс и
поддерживать отмену. Тот же диалог открывается из верхней плашки и из раздела
`О приложении`.

Начальное состояние окна:

```text
Доступна новая версия

Orex Messenger 0.4.3 (сборка 6)
Установлено: 0.4.2 (сборка 5)

Что нового
• Исправлено переключение камеры на Windows
• Улучшена работа звонков

Windows x64 · 80,3 МБ

[ Отмена ]  [ Установить ]
```

После нажатия `Установить` окно остаётся открытым и переходит в состояние
скачивания:

```text
Скачивание обновления

████████░░░░░░░░  48%
Скачано 38,5 из 80,3 МБ

[ Отменить загрузку ]
```

Требования к этому состоянию:

- закрытие нажатием вне окна и системной кнопкой Back блокируется;
- кнопка отмены закрывает отдельный HTTP client, удаляет недокачанный временный
  файл и возвращает окно к информации об обновлении;
- прогресс берётся из количества реально записанных байтов и `Content-Length`
  либо `size_bytes`; при неизвестном размере используется неопределённый
  progress indicator;
- повторное нажатие не запускает вторую параллельную загрузку;
- сетевые ошибки оставляют окно открытым и показывают действия `Повторить` и
  `Закрыть`.

После успешного скачивания:

- Windows запускает скачанный installer отдельным процессом. Само приложение не
  пытается заменить собственный `.exe`; установщик отвечает за закрытие Orex,
  замену файлов и последующий запуск новой версии;
- Android передаёт выбранный APK системному package installer. Пользователь
  подтверждает установку в системном интерфейсе;
- временный файл удаляется после отмены, ошибки или когда он больше не нужен;
- перед скачиванием и перед запуском ещё раз проверяются ожидаемые домен,
  расширение файла и отсутствие перехода на более старую сборку.

##### Размещение в разделе «О приложении»

Текущий экран уже использует `OrexSettingsSection` и `OrexSettingsTile`, поэтому
не нужен отдельный экран. Под информацией о версии добавляется второй action-tile:

```text
О ПРИЛОЖЕНИИ

ⓘ  Orex Messenger
   Версия 0.4.2 · Сборка 5

⇩  Проверить обновления
   Поиск новой версии Orex Messenger
```

Состояния второго tile:

- `Проверить обновления` — обычное состояние;
- `Проверяем…` — действие временно недоступно, рядом небольшой индикатор;
- `Установлена последняя версия` — результат ручной проверки;
- `Обновить приложение` / `Доступна версия 0.4.3 · Сборка 6` — открывает тот же
  `OrexUpdateDialog`;
- `Не удалось проверить обновления` — повторное нажатие запускает новый запрос.

##### Безопасность первой версии

Ручной SHA-256 не является обязательной частью релизного процесса. Сервер может
автоматически считать размер файла, а целостность транспорта обеспечивается
HTTPS. При этом хеш, полученный с того же скомпрометированного сервера, сам по
себе не защищает от подмены релиза, поэтому главный production-шаг для Windows —
подписывать installer Authenticode-сертификатом. Проверку подписи можно добавить
в updater без изменения структуры папок.

Android APK должен иметь тот же application ID и быть подписан тем же release
key, что и установленное приложение; номер `versionCode` новой ABI-сборки должен
быть выше установленного. Ключ подписи Android нельзя менять или терять.

Для текущей стадии разумен собственный updater с EXE/APK. Если позже потребуется
полностью управляемое Windows автообновление, отдельным этапом можно перейти с
EXE installer на MSIX + App Installer. Это не требуется для первой реализации и
не должно блокировать текущий release flow.

#### Единая верхняя системная плашка

Текущий `_VerifyBanner` должен стать одним переиспользуемым компонентом и
контроллером системных notices, а не копироваться для каждой новой функции.
Контроллер принимает модель с `id`, приоритетом, иконкой, заголовком, пояснением,
основным действием, `dedupeKey` и политикой закрытия. Одновременно показывается
одна плашка — самая приоритетная; после её устранения или закрытия контроллер
показывает следующую без наложения нескольких полос сверху.

Порядок приоритетов:

1. критическая проблема безопасности или обязательное обновление;
2. неподтверждённая текущая Matrix-сессия;
3. доступное необязательное обновление;
4. разовая рекомендация включить автобэкап ключей.

Политика закрытия зависит от причины:

- предупреждение о неподтверждённой сессии скрывается до следующего запуска или
  до изменения verification state; нажатие открывает существующий экран
  подтверждения;
- необязательное обновление скрывается для точного `version + build`; новая
  версия снова имеет право показать notice;
- обязательное обновление не имеет крестика, но оставляет понятное действие и не
  запускает installer само;
- рекомендация автобэкапа показывается один раз на сочетание Matrix user + device
  после загрузки security preferences, только если серверное хранилище ключей не
  включено. Крестик сохраняет dismiss локально; явное отключение хранилища не
  должно немедленно создавать ту же плашку заново;
- нажатие на рекомендацию не включает backup автоматически, а открывает
  `Настройки → Хранилище ключей`, где пользователь видит recovery flow и сам
  подтверждает действие.

Текст рекомендации должен описывать реальную функцию key backup, например:

> **Защитите историю сообщений**
>
> Включите автобэкап ключей, чтобы читать зашифрованную историю на новых
> устройствах.

Состояние закрытия хранится отдельно от security-настроек: dismiss не должен
выглядеть как отключение автобэкапа. Для каждой notice нужны тесты приоритета,
дедупликации, persistence, перехода по нажатию, узкой/широкой раскладки и
доступности с клавиатуры и screen reader.

### 12.2. Версия 0.5.0 — доверие, контакты и управление сессиями

Главная цель `0.5.0` — построить единый слой отношений между пользователем,
собеседниками и устройствами. На него затем должны опираться приватность,
уведомления, профили и предупреждения безопасности.

1. **Контакты как отдельная доменная модель.** На первом этапе контакт — любой
   пользователь, с которым существует личный чат. Реализация не должна
   размазывать это правило по UI: нужен отдельный contacts/relation service, чтобы
   позже без миграции экранов заменить derived-логику на явную адресную книгу,
   запросы в контакты или другую модель отношений.
2. **Управление сессиями.** Список текущих Matrix-сессий, понятное обозначение
   текущего устройства и действие «Завершить все другие сессии» с безопасным
   подтверждением результата.
3. **Неподтверждённые сессии.** Сообщения и чувствительные действия должны явно
   показывать, что связанная сессия/устройство не подтверждены. Это расширяет уже
   запланированную безопасность собеседников и клиентов, а не создаёт второй
   параллельный механизм предупреждений.
4. **Получение сообщений от неподтверждённых сессий.** Пользователь может
   разрешить или запретить такие сообщения; блокировка должна применяться в
   едином policy-слое, а не только скрывать событие в UI.
5. **Базовый privacy policy engine.** Все privacy-настройки используют одну
   модель аудитории: `Все / Контакты / Никто`, где «Контакты» сначала опираются
   на derived contact relation из личных чатов.

Настройки приватности `0.5.0`:

- показывать время последней активности — `Все / Контакты / Никто`;
- показывать, когда пользователь в сети — `Все / Контакты / Никто`;
- показывать статус печати — `Все / Контакты / Никто`;
- кто может видеть аватарки — `Все / Контакты / Никто`;
- кто может инициировать личные чаты — `Все / Контакты / Никто`;
- кто может приглашать в группы — `Все / Контакты / Никто`;
- получение сообщений от неподтверждённых сессий — `Разрешить / Запретить`.

### 12.3. Ветка 0.5.x — уведомления и локальный контроль данных

Главная цель `0.5.x` — дать пользователю предсказуемый контроль над тем, что
приложение сообщает системе, загружает автоматически и хранит локально.

#### Глобальные настройки уведомлений

- звук — `вкл / выкл`;
- вибрация — `вкл / выкл`;
- уведомления о сообщениях — `вкл / выкл`;
- входящие звонки — `вкл / выкл`;
- показывать текст сообщения отправителя — `вкл / выкл`;
- входящие вызовы на заблокированном экране — `вкл / выкл`;
- показывать уведомления на заблокированном экране — `вкл / выкл`.

#### Индивидуальные настройки чата

У каждого чата нужна быстрая настройка уведомлений без перехода в общий экран:

- `Включить`;
- `Только упоминания`;
- `Выключить`.

Эта модель должна одинаково влиять на foreground UI, обычные push-уведомления и
killed-process resolution. Нельзя делать отдельную локальную настройку, которую
не знает Android notification pipeline.

#### Данные и хранилище

- автозагрузка медиа — `Всегда / Только при Wi-Fi / Никогда`;
- максимальный размер автозагрузки, по умолчанию `20 МБ`;
- типы медиа для автозагрузки с множественным выбором: `Картинки`, `Музыка`,
  `Видео`, `Прочие файлы`; по умолчанию включено всё, кроме прочих файлов;
- очистка кэша;
- очистка локально сохранённых медиа;
- очистка всех локальных данных с отдельным подтверждением и ясным объяснением,
  что произойдёт с сессией и зашифрованным локальным состоянием.

### 12.4. Версия 0.6.0 — полноценная семантика переписки

Главная цель `0.6.0` — сделать timeline удобным для длинных и активных диалогов.

1. **Юзабельные ответы.** Базовые reply events уже поддерживаются, но нужны
   полноценная цитата исходного сообщения, понятная связь reply chain, переход к
   оригиналу, корректное поведение для удалённых/недоступных событий и удобный
   composer flow.
2. **Упоминания.** Создание `@mention`, визуальное выделение, уведомления по
   правилам чата и переход к соответствующему сообщению/контексту.
3. **Уведомления о реакциях.** Реакции должны участвовать в общей notification
   policy, учитывать mute/mentions-only режим и не превращать групповой чат в
   спам.
4. **Закреплённые сообщения.** Закрепление и открепление по Matrix permissions,
   список закреплённых сообщений, переход к событию и понятное отображение
   недоступных/удалённых pin-ов.
5. **Групповое выделение сообщений.** Выделение зажатием/множественным выбором и
   массовые действия над выбранными сообщениями.
6. **Удаление чужих сообщений владельцами комнат.** Модераторские действия с
   проверкой Matrix permissions/power levels и понятным отображением результата.
7. **Голосования.** Создание опросов, выбор вариантов, результаты и обновление
   состояния в реальном времени.

### 12.5. Ветка 0.6.x — профили, аватары и идентичность

Главная цель `0.6.x` — превратить текущие карточки пользователя и комнаты в
полноценные управляемые профили.

1. **Полноценные профили пользователей.** Аватар, описание, Matrix ID, общие
   комнаты, действия, настройки приватности и безопасности.
2. **Полноценные профили комнат.** Аватар, описание, alias/ID, участники,
   permissions и быстрые действия.
3. **Многоаватарочность.** Несколько пользовательских аватаров с управлением,
   выбором активного изображения и совместимостью с privacy policy «кто может
   видеть мои аватарки». Реализация должна заранее отделять список аватаров от
   единственного Matrix `m.avatar_url`, чтобы не запереть UX в текущем протоколе.
4. **Отображение смены аватарок.** Timeline-события и системные карточки при
   изменении аватара пользователя или комнаты.
5. **Настройки профиля.** Управление публичными данными, аватарами и связанными
   privacy-настройками из одного места.

### 12.6. Версия 0.7.0 — развитие мультимедиа

Главная цель `0.7.0` — довести медиавозможности Orex до уровня повседневного
мессенджера без зависимости от стороннего клиента.

1. **Голосовые сообщения.** Запись, предпросмотр, отправка, waveform и
   воспроизведение внутри чата.
2. **Видео-заметки любых форм.** Кружки, квадратики, треугольники, ромбы и
   пользовательские формы/кастомные модели с единым форматом отправки и
   воспроизведения.
3. **Стикеры и стикер-паки.** Отправка стикеров, создание собственных наборов,
   управление ими и переиспользование на разных устройствах.
4. **Собственный кроссплатформенный мультимедийный плеер.** Единый Orex player
   для аудио, видео, голосовых сообщений и видео-заметок на Web, Android и
   Windows.

### 12.7. Production security после первой публичной ветки

* Cross-platform hardening media E2EE: late join, reconnect, key rotation и
  совместимость Android ↔ Windows ↔ Web в release-сборках.
* Server-side Orex authorization gateway для LiveKit token grants и настоящего
  enforcement voice permissions.
* Дальнейшее сокращение plaintext-следов локального media cache и временных
  расшифрованных файлов.
* Подпись Windows-дистрибутива и проверяемая публикация release artifacts.

### 12.8. Архитектура после релиза

* Постепенно уводить API `MatrixService` за более узкие сервисы:
  `matrix.rooms`, `matrix.discovery`, `matrix.security`, `matrix.media`.
* Вынести contacts/relation policy отдельно от факта существования DM, чтобы
  будущая адресная книга не потребовала переписывать privacy и notification UX.
* Хранить privacy, notification и media-download policy как отдельные доменные
  настройки с единым применением в foreground, background и native слоях.
* Выносить новые контроллеры только там, где появляется реальная продуктовая
  боль, а не ради уменьшения количества строк.
* Не начинать новый большой архитектурный рефактор без конкретной runtime-
  проблемы, профилирования или повторяющегося продуктового сценария.

## 13. Заметки

- Лицензии Matrix SDK и зависимостей перед публичным релизом надо проверить
  отдельно относительно модели распространения Orex.
- Пререлиз фиксирует Matrix 8.1.0, LiveKit 2.9.0-dev.0 и flutter_webrtc 1.5.2.
  `file_picker 11.0.2` использует новый static API `FilePicker.pickFiles`;
  `package_info_plus 9.0.1` выбран как совместимая с `win32 5.x` ветка. Major
  dependency upgrades делаются только вместе с `pub get`, analyze/test и device
  smoke.
- README описывает продукт и архитектурные границы. Детальные команды и ключи
  должны жить в release-документах, а не растворяться в продуктовой презентации.
