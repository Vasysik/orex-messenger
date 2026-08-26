# Changelog

Здесь фиксируются пользовательские релизы Orex Messenger. Внутренние Debug,
candidate и промежуточные build-номера отдельно не перечисляются: их изменения
относятся к следующему пользовательскому релизу.

## 0.4.4+7 — 2026-08-26

### Медиа и файлы

- Унифицирован безопасный pipeline временных медиафайлов: sanitization имён,
  отдельный каталог, атомарная запись и контролируемая очистка.
- Пересылка больших медиа использует существующие Matrix-ссылки без повторного
  скачивания файла в память; для E2EE блокируется небезопасное повторное
  использование plaintext-медиа.
- Улучшены platform helpers для скачивания, открытия и временного хранения файлов
  на Web, Android и Windows.

### Интерфейс и производительность

- Убраны подтверждённые scrolling hot paths в списке чатов, timeline и настройках
  без упрощения визуального дизайна.
- Добавлены календарные разделители и стабильная sticky-date в timeline.
- Добавлена кнопка возврата к последним сообщениям и унифицирован desktop pointer
  behavior интерактивных элементов composer/timeline.
- Медиа-плитки звонка сохраняют размер содержимого при speaking; активность
  отображается рамкой без окрашивания видео.
- Добавлен полноэкранный режим выбранной медиа-плитки с auto-hide call controls и
  корректным выходом через double tap, `Esc` или системный Back.
- Верхние служебные баннеры получили предсказуемое появление без повторной
  анимации при переключении между состояниями.

### PiP и звонки

- Добавлен системный media PiP на Web, Android и Windows с синхронизацией
  camera/screen-share source, no-media lifecycle и фактического aspect ratio.
- PiP корректно переживает выключение/включение камеры, смену камеры и переход
  между камерой и демонстрацией экрана; при завершении звонка системная
  поверхность закрывается.
- Web teardown звонка упорядочен так, чтобы камера, микрофон и поздно завершившиеся
  media operations не оставались активными после выхода из звонка.
- Укреплён Android Core-Telecom lifecycle между последовательными звонками:
  освобождение предыдущего системного call owner больше не гоняется со стартом
  следующей попытки.
- Исправлены reject/join сценарии Android: отказ от входящего не оставляет
  захваченное incoming ownership, а Reject из push может выполняться headless,
  не поднимая основное окно Orex.
- На Android жесты локального video renderer изолированы от screen share:
  аппаратный pinch-to-zoom применяется только к реальной camera track и не
  вызывается для MediaProjection.
- Исправлен Android fullscreen media через native system-bars bridge с корректным
  восстановлением status/navigation bars после выхода.

### Web и desktop

- Добавлена фирменная Flutter-страница `/download/` со stable update feed и
  ссылками на актуальные Android/Windows сборки.
- Исправлен lifecycle Web QR-камеры: scanner освобождает только принадлежащий ему
  `MediaStreamTrack`, не затрагивая WebRTC/LiveKit media.
- Добавлен persistent Web-кэш MXC-аватаров и bundled branding assets без хранения
  Matrix access token в cache key.
- Windows сохраняет normal-размер, позицию, maximized/restored state и монитор с
  безопасным восстановлением при изменении конфигурации дисплеев.

### Мобильные сценарии и release hardening

- Снижена фоновая нагрузка на мобильных устройствах: при сворачивании Orex
  приостанавливает только необязательные фоновые задачи, не прерывая sync,
  push-уведомления и активные звонки.
- Консолидированы Android diagnostic/log collection и release/testing инструкции.
- Расширены regression-тесты для PiP, fullscreen, push actions, call lifecycle,
  camera gestures, timeline/composer и media policies.

## 0.4.3+6 — 2026-07-23

### Windows

- Добавлены системные уведомления Windows с аватарками пользователей, чтобы
  уведомления было проще различать вне открытого окна Orex.
- Добавлено сворачивание Orex в системный трей: приложение может оставаться
  запущенным без постоянного окна на панели задач и возвращаться из трея по
  действию пользователя.

### Аккаунт, почта и восстановление

- Добавлена привязка электронной почты к Matrix-аккаунту как 3PID с обязательным
  подтверждением адреса через письмо.
- Добавлено управление привязанной почтой из настроек безопасности; адрес не
  публикуется другим пользователям Orex.
- Добавлено восстановление пароля по ранее подтверждённой электронной почте через
  стандартный Matrix/Synapse flow.

### QR-вход и устройства

- Добавлен безопасный вход в аккаунт по QR-коду с явным подтверждением на уже
  авторизованном устройстве.
- Одноразовый Matrix login token не хранится непосредственно в QR-коде: вход
  использует краткоживущую зашифрованную rendezvous-сессию, а использованный,
  отклонённый или истёкший QR больше не считается действующим.
- Добавлен экран управления Matrix-устройствами: отображаются текущая и другие
  сессии, имя устройства и состояние проверки.
- Устройства можно переименовывать, проверять и завершать по одному или сразу
  несколько сессий; текущее устройство не попадает в массовое завершение.

### Обновления

- Добавлено встроенное обновление Orex без ручного поиска и скачивания новой
  версии через браузер.
- Клиент показывает доступную версию и запускает установку подходящего
  Windows-инсталлятора или Android APK через системный механизм установки.
- Добавлены отдельные stable/debug update channels и сервер update feed с
  versioned artifacts и `notes.md`.

### Android и медиа

- Добавлена демонстрация экрана на Android через системный MediaProjection с
  запросом разрешения перед началом трансляции.
- Добавлен foreground service для Android screen share и platform bridge для
  передачи MediaProjection в WebRTC/LiveKit capture.
- Управление демонстрацией встроено в экран звонка, поэтому её можно запускать и
  останавливать без отдельного внешнего приложения.
- Добавлена orientation-aware обработка screen capture для корректного перехода
  между portrait и landscape.

### Стабильность

- Усилен fail-closed bootstrap для обязательных crypto/runtime компонентов.
- Расширены protocol- и platform-тесты для QR login, Matrix auth, updater,
  Android screen share и notification policy.

## 0.4.2+5 — 2026-07-20

### Media E2EE звонков

- Добавлен отдельный LiveKit media-E2EE слой поверх MatrixRTC: ключи звонка
  передаются через Matrix-защищённый control path, а не доверяются SFU.
- Добавлены LiveKit E2EE key provider, Matrix call-control transport и Orex
  LiveKit backend с явным разделением signaling, credentials и media lifecycle.
- Звонок fail-closed не стартует в незашифрованной Matrix-комнате без явного
  diagnostic escape hatch.
- Исправлено восстановление media-E2EE ключей после ответа на звонок из cold start.

### Android call lifecycle

- Активный Android-звонок получил foreground call service и более устойчивый
  lifecycle при background/lock/cold-start сценариях.
- Стабилизирован handoff между нативной incoming-call поверхностью, Core-Telecom
  и Flutter `CallScreen`, включая ответ с заблокированного экрана.
- Добавлена точная идентичность call attempt, чтобы поздние accept/reject/end от
  старого вызова не применялись к следующему звонку в той же Matrix-комнате.
- Добавлены cleanup coordinator, disposition registry, lifecycle policies и
  watchdogs для rollback/teardown при ошибках signaling или media connect.
- Устранены гонки между системным звонком, notification ownership и Flutter
  состоянием; стабилизированы ringtone/alert handoff и системные действия.

### Signaling, push и безопасность

- Call-control события accepted/rejected/busy/ended/handled в E2EE-комнатах
  переведены на адресную защищённую доставку между Matrix-устройствами.
- Matrix call writes проходят через общий request gate с coalescing/backoff,
  чтобы retries и rate-limit не создавали конфликтующие состояния звонка.
- Усилен background push resolver и подавление устаревших call events.
- Добавлена входная media policy и дополнительные проверки доверенных LiveKit
  endpoints/credentials.

### Платформа и зависимости

- Обновлён основной Matrix stack до Matrix Dart SDK `8.1.0` и согласованный
  realtime/media набор зависимостей.
- Обновлён `file_picker` с исправлением Android path-traversal и закреплены
  проверенные версии ключевых runtime-зависимостей.
- Расширены Web security headers, CI quality gate и автоматические regression-тесты
  звонков, E2EE, push и platform policies.

## 0.4.0+4 — 2026-07-09

### Android как полноценная call-платформа

- Личные звонки Android интегрированы с Jetpack Core-Telecom: системный call UI,
  ответ/отклонение/завершение, mute/hold и системная маршрутизация аудио.
- Добавлены нативная incoming-call Activity, системные CallStyle-уведомления и
  отдельное состояние presentation/handoff между Android и Flutter.
- Добавлено быстрое переключение активной камеры без пересоздания всего звонка с
  безопасным fallback при ошибке fast switch.
- Earpiece/speaker/wired/Bluetooth routing передаётся системному Telecom там, где
  Android уже владеет звонком.

### Push и закрытое приложение

- Добавлен Android FCM receiver и Matrix HTTP-pusher flow с безопасной
  регистрацией/ротацией push token.
- E2EE push-события могут разрешаться в expedited WorkManager, не удерживая
  `FirebaseMessagingService` долгой Matrix/crypto работой.
- Входящий звонок может появиться поверх lock screen при закрытом процессе;
  Answer/Reject сохраняются и передаются в основной call flow после cold start.
- Добавлены защита от дублирующих incoming surfaces и более строгая привязка
  действий к конкретной попытке звонка.

### Хранение и platform security

- Windows/Linux local Matrix cache переведён на SQLCipher-backed FFI с проверкой
  наличия cipher runtime вместо молчаливого plaintext production fallback.
- Для Android явно отключён platform backup чувствительных данных приложения.
- Production runtime config стал fail-closed для обязательных homeserver/JWT/
  crypto-настроек.

### Release infrastructure

- Добавлены production build/release инструкции и Windows installer на Inno Setup.
- Укреплены Android signing/push checks для release-сборок и CI compile-only
  escape hatches.
- Расширены automated tests для push, call integration, runtime config и storage
  security policies.

## 0.3.3+3 — 2026-07-06

### Архитектура и качество

- Проведён большой refactor без смены продуктовой модели: Matrix, call, media и
  settings-логика разделены на более узкие services/controllers/policies.
- Добавлен постоянный CI quality gate для analyze/test и platform release builds,
  а также документация release-процесса и пример Android signing config.
- Добавлены unit/widget tests для storage security, Matrix room metadata,
  call/media policies, composer/timeline и других вынесенных компонентов.

### Звонки и голосовые каналы

- Call UI разбит на отдельные controls, participant tile, presentation и action
  слои вместо монолитного экрана.
- Добавлены CameraDeviceController, ScreenShareController, LiveKit credentials /
  token policies и безопасный доступ к media tracks.
- Добавлены voice gate/state repository и отдельная permission-модель голосовых
  каналов, включая listen-only сценарии.
- Улучшены rollback и cleanup при ошибках подключения, чтобы не оставлять
  фантомную активную call session.

### Чаты и комнаты

- Вынесены attachment queue, message composer state и timeline grouping.
- Унифицированы room metadata/mappers для групп, каналов, Spaces и preview.
- Добавлен единый conversation coordinator и переиспользуемые Orex dialogs /
  profile cards.
- Глобальный поиск и preview-поток приведены к модели, где найденный пользователь
  или публичная комната сначала открываются как preview, а не создают чат
  автоматически.

### Локальное хранение и runtime policy

- Добавлена отдельная database security policy и более строгая runtime config
  validation.
- Границы защищённого и незашифрованного desktop cache стали явными: release не
  должен молча считать обычный SQLite эквивалентом SQLCipher.

## 0.3.2+4 — 2026-07-03

### Звонки и устройства

- Существенно расширены настройки аудиоустройств: выбор input/output, быстрый
  device sheet и платформенные helpers для маршрутизации.
- Добавлены короткие Orex audio cues для уведомлений, входящих вызовов и
  голосовых действий.
- Добавлены voice-activity визуализация и проверка уровня микрофона.
- Добавлен desktop source picker для демонстрации экрана и улучшены full/minimized
  call layouts.
- Укреплён lifecycle входящих/исходящих звонков и очистка предыдущей MatrixRTC
  сессии, чтобы завершённый вызов не блокировал следующий.

### Desktop и UX

- Windows снова оформлен как полноценный Flutter desktop target с нативным runner
  и общим Orex branding.
- В настройки добавлено отображение фактической версии/сборки приложения.
- Улучшены общие choice sheets и переключение call devices без лишнего выхода из
  звонка.

## 0.2.4+1 — 2026-07-02

### Matrix, E2EE и аккаунт

- Orex перешёл от первоначального каркаса к полноценному Matrix service layer с
  отдельными API для auth, rooms, discovery, admin, Spaces/supergroups, media,
  account и security.
- `vodozemac` инициализируется до Matrix-клиента; приватные комнаты получили
  рабочий E2EE flow вместо декларативного scaffold.
- Добавлены self/session verification, SAS с emoji/numbers, cross-signing
  bootstrap и recovery key flow.
- Добавлено управление Matrix-устройствами и key backup: состояние резервной
  копии, ручная загрузка ключей и автоматическая догрузка.

### Сообщения

- Добавлены реакции, ответы, копирование, редактирование и удаление сообщений.
- Добавлен emoji picker и контекстное меню по long-press/right-click рядом с
  сообщением.
- Добавлены отправка/получение изображений и файлов, inline preview и системное
  открытие вложений.
- Добавлены read receipts и состояния собственных сообщений: отправка, ошибка,
  отправлено и просмотрено.
- Добавлены call summary сообщения в timeline для answered/missed/rejected с
  защитой от дублей со стороны инициатора.
- Добавлены системные карточки Matrix membership/invite событий вместо показа
  сырых `m.room.member` payloads.

### Навигация, комнаты и супергруппы

- Добавлены папки чатов, глобальный поиск людей и публичных комнат, точный поиск
  по MXID и preview перед вступлением.
- Добавлены группы, каналы и супергруппы на Matrix Spaces с дочерними комнатами,
  metadata в `m.space.child` и отдельным UX для preview/join.
- Дочерние комнаты супергруппы перестали дублироваться как обычные чаты в левой
  панели.
- Добавлены настройки комнат, права, visibility, приглашение/удаление участников
  и управление основными room properties.
- Приглашения можно принимать/отклонять из списка и непосредственно в открытом
  чате.

### Медиа

- Добавлены очередь вложений, batch send и группировка близких медиа в альбомы.
- Добавлены MXC avatar/media cache, Orex gallery с PageView/zoom и кастомный
  Web media player с platform fallback на desktop/mobile.
- Аватары и профиль стали обновляться без обязательной перезагрузки интерфейса.

### MatrixRTC / LiveKit звонки

- Добавлен MatrixRTC signaling поверх Matrix SDK при сохранении собственного Orex
  Flutter UI и LiveKit SFU transport.
- Добавлен отдельный incoming call screen и app-level CallController, благодаря
  которому звонок может жить при навигации между экранами.
- Добавлена свёрнутая call panel над текущей перепиской, плитки участников,
  имена/аватары и no-camera состояние.
- Если камера занята, видеозвонок может продолжиться как аудиозвонок вместо
  аварийного завершения.
- Добавлены карточки активного звонка/Join и голосовой режим для групповых комнат.

## 0.1.0+1 — 2026-06-23

### Первый каркас Orex

- Создан исходный Flutter-проект Orex Messenger для общей кодовой базы Web,
  Android и Windows.
- Заложены Matrix + vodozemac + LiveKit зависимости и базовый OpenID →
  `lk-jwt-service` → LiveKit handshake.
- Добавлены базовые login/sync/text-message flows через Matrix SDK и локальный
  cache для быстрого старта.
- Созданы тёплая walnut/copper Material 3 тема, glassmorphism-компоненты и
  адаптивный двухпанельный layout.
- Добавлены первоначальные список чатов с папками, окно переписки и простой
  call overlay.

Эта версия была именно рабочим архитектурным scaffold: значительная часть
E2EE UX, media, room management, verification, push и production call lifecycle
появилась в следующих версиях.
