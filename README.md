# Orex Messenger — архитектура (Lead Flutter Architect)

Тёплый ореховый мессенджер на **Flutter** поверх **Matrix (Synapse)**, со
сквозным шифрованием сообщений через **vodozemac** и нативными звонками на
стеке **MatrixRTC / Element Call** поверх вашего **LiveKit**. Единая кодовая
база: **Web · Android · Windows**.

Проект уже находится близко к рабочему продукту: тема, glassmorphism,
адаптивный двухпанельный layout, список чатов с папками, переписка,
настройки профиля и комнат, E2EE для Matrix-сообщений, глобальный поиск
людей и публичных комнат, супергруппы на Matrix Spaces и нативные звонки
на LiveKit без iframe.

---

## 1. Стек

| Слой     | Решение                               | Заметки |
|----------|---------------------------------------|---------|
| UI       | Flutter 3.24+, Material 3             | Glassmorphism, тёплая медная гамма, адаптивный двухпанельный интерфейс |
| Протокол | Matrix CS API / Synapse               | Логин, sync, сообщения, профиль, устройства, rooms/spaces |
| Клиент   | `matrix` (Famedly) 7.3.x              | Классический `/sync`, локальный кэш, E2EE-обвязка |
| E2EE     | `flutter_vodozemac` 0.5.x             | Rust/vodozemac вместо устаревшего olm |
| Звонки   | `livekit_client` + MatrixRTC signaling | Наш Flutter UI, токены через lk-jwt-service |
| Кэш      | sqflite_sqlcipher / ffi / IndexedDB   | SQLCipher на мобильных/macOS, desktop-шифрование требует отдельного закрепления |

---

## 2. Что реализовано

- **Авторизация и сессии:** логин по паролю, восстановление сессии из локальной БД,
  корректная инициализация Matrix-клиента и загрузка ключей.
- **E2EE для сообщений:** `vodozemac` инициализируется до `client.init()`. По
  умолчанию приложение не должно тихо запускаться без криптослоя.
- **Список чатов:** папки, поиск, аватары, превью, время, счётчики непрочитанных,
  адаптивный layout. Локальные комнаты ищутся не только по названию и описанию,
  но и по Matrix-alias/tag вида `#room:server` или `#room`. Дочерние чаты
  супергрупп не показываются как отдельные комнаты в левой колонке: они живут
  внутри своей супергруппы.
- **Глобальный поиск:** единая зона discovery в левой панели. Сейчас там ищутся
  **люди** и **публичные комнаты**, поэтому отдельный поиск внутри окна
  «Новый чат» больше не нужен. Серверный Matrix-поиск используется как есть:
  если homeserver возвращает широкую выдачу по части домена, клиент не скрывает
  эти результаты искусственными фильтрами.
- **Создание комнат:** кнопка-карандаш не открывает отдельный экран, а показывает
  компактный выбор создаваемого типа: группа, канал, супергруппа.
- **Переписка:** баблы сообщений, отправка текста и вложений, автоматическая
  пометка прочитанного, жесты под мобильные устройства. Вход, выход, приглашение,
  удаление и блокировка участников отображаются аккуратными системными плашками
  в ленте, а не сырым `m.room.member`. Системные сообщения Orex-приглашений
  оформляются отдельной карточкой. Клик по карточке сначала
  открывает локальную комнату или invite, затем пробует public preview, а при
  необходимости выполняет join по alias/roomId с понятной ошибкой в UI и логах.
- **Публичный preview:** предпросмотр публичной комнаты встроен в правый блок чата.
  Это не отдельный экран: пользователь видит чат как обычную переписку, а снизу
  вместо поля ввода находится кнопка входа.
- **Супергруппы:** супергруппа реализуется как Matrix Space. При создании
  супергруппы дочерние чаты больше не создаются автоматически: это снижает риск
  rate-limit / `Too Many Requests`, а пустая супергруппа сама предлагает
  администратору добавить первый чат. Дочерние чаты не рассылают инвайты всем
  участникам автоматически: пользователь видит их внутри супергруппы и вступает
  сам. Если пользователя нет в супергруппе, вход в дочерний чат блокируется.
  Внутренние чаты не дублируются в общем списке слева.
- **Метаданные чатов супергруппы:** название и иконка дочернего чата сохраняются
  не только в самой комнате, но и в `m.space.child`, чтобы список чатов и preview
  показывали нормальный вид ещё до вступления в дочернюю комнату. В UI Matrix
  alias отображается в локальном виде `#room`, без серверного суффикса, потому
  что Orex сейчас рассчитан на один homeserver без федеративного UX.
- **Настройки:** общие настройки и настройки чата приведены к единому визуальному
  стержню: полноэкранное окно, профильная карточка, длинные кнопки на всю ширину,
  единые секции и glass-панели.
- **Пакетная отправка и альбомы:** плиточное прикрепление очереди файлов в строке
  ввода. При отправке медиа группируются в компактную сетку-альбом, описание
  выносится под медиаблок.
- **Ленивая загрузка медиа:** предпросмотры и вложения не должны повторно
  дешифроваться и скачиваться при каждом скролле. Для MXC-аватаров добавлен
  RAM-кэш с TTL, чтобы аватарки не моргали, но обновлялись при смене URI.
- **Кастомный медиаплеер:** Orex-style аудио/видео-плеер для Web, системное
  открытие медиа на desktop/mobile через условные экспорты.
- **Галерея:** PageView, десктопные стрелки, pinch zoom, панорамирование при
  приближении, удаление своих отправленных медиа.
- **Звонки:** нативный интерфейс на LiveKit, без встраивания call.element.io.
  Signaling берётся из MatrixRTC, а подключение к SFU идёт через ваш
  `lk-jwt-service`. Для групп, каналов и чатов супергруппы звонок ведёт себя как
  голосовой канал: он отображается в UI, но не должен насильно вызывать всех
  участников. Панель активного/доступного звонка выводится над правым блоком
  разговора только для текущего открытого чата; в выпадающем списке супергруппы
  остальные активные звонки помечаются отдельной иконкой.
- **Иконка приложения:** генерируется из `assets/icon/app_icon.png`.

---

## 3. Структура

```
lib/
├─ main.dart                         # bootstrap: vodozemac -> БД -> Matrix -> UI
├─ core/                             # инфраструктура приложения, без Flutter-экранов
│  ├─ config/
│  │  └─ orex_config.dart            # homeserver, lk-jwt-service, security flags
│  ├─ logging/
│  │  └─ orex_logger.dart            # единая точка dev-логов Orex ([Orex][Area])
│  ├─ storage/
│  │  ├─ database.dart               # условный экспорт БД
│  │  ├─ database_io.dart            # SQLite / SQLCipher для IO-платформ
│  │  └─ database_web.dart           # IndexedDB/Web storage слой
│  ├─ files/
│  │  ├─ file_helper.dart            # условный экспорт скачивания/открытия файлов
│  │  ├─ file_helper_io.dart         # системный запуск файлов
│  │  └─ file_helper_web.dart        # blob-скачивание через package:web
│  ├─ matrix/
│  │  ├─ matrix_service.dart         # ядро MatrixService, lifecycle, sync, состояние
│  │  ├─ matrix_auth_api.dart        # логин, регистрация, logout
│  │  ├─ matrix_rooms_api.dart       # базовая классификация комнат и отправка
│  │  ├─ matrix_room_reference_api.dart  # open/join по roomId, alias и preview
│  │  ├─ matrix_room_discovery_api.dart  # поиск людей и публичных комнат
│  │  ├─ matrix_supergroup_api.dart      # spaces, child-чаты, preview metadata
│  │  ├─ matrix_room_identity_api.dart   # alias/MXID helpers single-homeserver UX
│  │  ├─ matrix_room_creation_api.dart   # создание групп, каналов и супергрупп
│  │  ├─ matrix_room_admin_api.dart      # права, visibility, invite/kick/delete
│  │  ├─ matrix_security_api.dart    # E2EE, key backup, verification, security reset
│  │  ├─ matrix_account_api.dart     # профиль, устройства, пароль
│  │  └─ matrix_media_api.dart       # MXC download/cache
│  └─ voip/
│     ├─ call_controller.dart        # состояние активного звонка на уровне приложения
│     ├─ call_session.dart           # LiveKit session + lk-jwt-service handshake
│     └─ voip_service.dart           # MatrixRTC-события и входящие вызовы
├─ domain/                           # доменная модель Orex, независимая от UI
│  └─ rooms/
│     ├─ room_metadata.dart          # OrexRoomKind, OrexRoomAlias
│     └─ member_event_text.dart      # человекочитаемые тексты m.room.member
├─ shared/                           # переиспользуемый UI/тема, не привязан к feature
│  ├─ theme/
│  │  ├─ orex_theme.dart
│  │  ├─ glass.dart
│  │  └─ theme_controller.dart
│  └─ widgets/
│     ├─ mxc_avatar.dart             # аватары Matrix с кэшем MXC
│     ├─ room_icon.dart              # иконки комнат по доменному типу
│     ├─ orex_settings_components.dart
│     ├─ orex_loading_overlay.dart
│     ├─ media_gallery.dart
│     ├─ media_player.dart
│     ├─ media_player_io.dart
│     ├─ media_player_web.dart
│     └─ squirrel_mascot.dart
└─ features/                         # продуктовые вертикали
   ├─ auth/
   │  └─ login_screen.dart
   ├─ home/
   │  └─ home_shell.dart             # двухпанельный shell: список слева, чат/preview справа
   ├─ chats/
   │  ├─ sidebar/
   │  │  ├─ chat_list_panel.dart     # state левой панели и глобальный поиск
   │  │  ├─ chat_list_layout_widgets.dart
   │  │  ├─ chat_folder_manager_widgets.dart
   │  │  ├─ chat_room_tile_widgets.dart
   │  │  └─ chat_folder_controller.dart
   │  └─ conversation/
   │     ├─ chat_view.dart           # основной экран переписки
   │     ├─ chat_header.dart
   │     ├─ chat_input_bar.dart
   │     ├─ chat_timeline_items.dart
   │     ├─ message_bubble.dart
   │     ├─ message_attachments.dart
   │     ├─ message_system_cards.dart
   │     ├─ public_room_preview_view.dart
   │     ├─ room_settings_screen.dart
   │     └─ room_settings_components.dart
   ├─ calls/
   │  ├─ call_screen.dart
   │  ├─ incoming_call_screen.dart
   │  └─ minimized_call_panel.dart
   └─ settings/
      ├─ settings_screen.dart
      ├─ devices_screen.dart
      ├─ key_storage_screen.dart
      ├─ verification_screen.dart
      └─ verify_session_screen.dart
```

Ключевая идея структуры: `core/` содержит инфраструктуру и интеграции,
`domain/` — чистые доменные сущности Orex, `shared/` — переиспользуемую тему и
виджеты, а `features/` — пользовательские сценарии. UI-фичи не лежат рядом с
Matrix-интеграцией, а `core/matrix/` не знает про экраны.

Matrix-room логика разделена на reference/discovery/supergroup/creation/admin
слои, левая панель чатов разложена по sidebar-компонентам, а системные карточки
сообщений вынесены из основного bubble. `voice` не является отдельным типом
комнаты: голосовой канал — это возможность каждой комнаты, а не отдельная
Matrix-сущность.

---

## 4. Диагностика

Внутренние dev-логи проекта идут через `OrexLog` в формате:

```text
[Orex][Area] message
```

Это сделано по тому же принципу, что и SDK-логи вида `[Matrix] ...`: во время
разработки видно, какой слой сработал — Home, Chat, Rooms, Voip, Security.
Выключение шума:

```bash
flutter run --dart-define=OREX_DEBUG_LOGS=false
```

---

## 5. Шифрование (E2EE)

`vodozemac` должен инициализироваться **до** `client.init()`, иначе Matrix SDK не
поднимет криптослой корректно.

```dart
await vod.init();
await matrix.init();
```

Важный принцип: защищённый клиент не должен незаметно деградировать в режим
«без E2EE». Поэтому в конфигурации есть явное требование криптослоя:

```dart
static const bool requireVodozemac = true;
```

- Android / Windows / desktop — `flutter_vodozemac` собирает Rust через cargokit.
  Для desktop-сборки нужен **Rust toolchain** (`rustup`).
- Web — vodozemac это **wasm**, и его надо собрать в `web/pkg/`:

```bash
./tool/setup_web_vodozemac.sh          # bash / git-bash / WSL
```

Для запуска Web с E2EE нужны cross-origin isolation заголовки:

```bash
flutter run -d chrome \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```

Замечания:

- Приватные Matrix-комнаты должны создаваться с шифрованием.
- Публичные комнаты и каналы не стоит автоматически считать E2EE-комнатами.
- Локальная БД на Android/iOS/macOS может использовать SQLCipher. Windows/Linux
  desktop-шифрование нужно дополнительно закрепить перед публичным релизом.

---

## 6. Звонки (нативно, стек Element Call)

Мы **не встраиваем** call.element.io. Звонок реализован в нашем интерфейсе на
`livekit_client`, а токен берётся у **вашего** `lk-jwt-service` по OpenID:

1. `client.requestOpenIdToken(...)` → OpenID-токен Matrix.
2. `POST {lk-jwt-service}/sfu/get` с этим токеном и `room` → `{url, jwt}` LiveKit.
3. `livekit_client` подключается к вашему SFU; сетка участников рисуется внутри Orex.

Настройка в `core/config/orex_config.dart`:

```dart
static const String jwtService = 'https://jwt.vasys.ru';
```

Важно: MatrixRTC signaling и LiveKit transport уже вынесены в нашу архитектуру,
но media E2EE для звонков нужно проверять отдельно на уровне SFrame/key-provider,
а не заявлять только по факту наличия MatrixRTC.

---

## 7. Иконка приложения

```bash
flutter pub get
dart run flutter_launcher_icons   # генерит иконки для всех платформ из PNG
```

---

## 8. Сборка и запуск

Репозиторий хранит только исходники (`lib/`, `pubspec.yaml`, `assets/`, `tool/`).
Платформенные папки можно регенерировать:

```bash
flutter create --platforms=web,android,windows .
flutter pub get
dart run flutter_launcher_icons
./tool/setup_web_vodozemac.sh
```

Web-запуск с cross-origin isolation:

```bash
flutter run -d chrome \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```

Android:

```bash
flutter build apk --split-per-abi
```

Windows:

```bash
flutter build windows
```

Мелочи:

- Android: в `AndroidManifest.xml` нужны `INTERNET`, а для звонков —
  `RECORD_AUDIO`, `CAMERA`, `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH` и
  `android.permission.FOREGROUND_SERVICE`. minSdkVersion ≥ 23.
- Web: нужен CORS на Synapse и собранный `web/pkg/` для vodozemac.
- Windows: нужен Rust toolchain для E2EE-сборки.

### Что не коммитится в Git

`.gitignore` исключает платформенные папки, `build/`, `.dart_tool/` и временные
артефакты. После `git clone` платформы восстанавливаются командами выше. Если
`web/pkg/` не хранится в Git, wasm для vodozemac пересобирается через
`tool/setup_web_vodozemac.sh`.

---

## 9. Дорожная карта

### 9.1. Звуки и голосовые каналы

- Звуки уведомлений, входящих вызовов и подключения к голосовым каналам.
- Переработка аудио-режима звонка: звук не должен забирать весь канал наушников
  и переключать Bluetooth-наушники в низкокачественный headset-режим без нужды.
  Нужна нормальная микшируемая модель звука.
- Режим трансляции экрана.
- Удобное переключение по плиткам: открытие стрима или вебки на весь экран,
  приближение отдельных участков видео/стрима.
- Реакции и поднятие руки в голосовых каналах.
- Настройка и проверка аудио-устройств.

### 9.2. Чаты и сообщения

- Отправка голосовых сообщений.
- Отправка видео-кружков и других коротких видео-форматов: квадратики,
  треугольники, ромбы и кастомные модели.
- Голосования.
- Стикеры и создание собственных стикер-паков.
- Выделение сообщений группами через зажатие и управление выбранными сообщениями.
- Собственный кроссплатформенный мультимедийный плеер как единый Orex-компонент.

### 9.3. Мобильное приложение

- Звонки должны проходить как настоящие Android-вызовы.
- Уведомления и вызовы должны приходить, когда приложение не открыто.
- Переключение камеры в видеозвонках.
- Работа звонков в фоне, включая заблокированный экран.
- Слуховой режим: при прикладывании телефона к уху экран гасится, звук ведёт себя
  как голосовая связь.
- Вибро-отклик.

### 9.4. Инфраструктура и качество

- Push-уведомления через нормальный Matrix push gateway / mobile push pipeline.
- Desktop SQLCipher для Windows/Linux или отдельная защищённая storage-модель.
- Закрепление media E2EE для звонков на уровне LiveKit SFrame/key-provider.
- Постепенное вынесение сложных UI-состояний из виджетов в контроллеры.
- Тесты на Matrix room/space сценарии: создание супергрупп, дочерние комнаты,
  join restrictions, kick cascade.

---

## 10. Заметки

- Лицензия Matrix SDK — AGPL-3.0. Перед релизом нужно отдельно проверить
  совместимость лицензий всех зависимостей с моделью распространения Orex.
- После первой стабильной сборки стоит закрепить версии пакетов: у Matrix SDK
  бывают breaking changes между мажорными версиями.
- README описывает текущую архитектуру приложения и ближайшее направление. Если
  код меняется структурно, этот файл нужно обновлять вместе с изменениями, а не
  после нескольких крупных коммитов.
