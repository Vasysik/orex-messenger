# Orex Messenger — архитектура (Lead Flutter Architect)

Тёплый ореховый мессенджер на **Flutter** поверх **Matrix (Synapse)**, со
сквозным шифрованием (**vodozemac**) и **нативными звонками** на стеке Element
Call (MatrixRTC) поверх вашего LiveKit. Единая кодовая база: **Web · Android · Windows**.

Это уже близкий к рабочему билд: тема, glassmorphism, адаптивный двухпанельный
layout, список чатов с папками, переписка, **настройки (профиль, тема,
устройства, проверка по эмодзи, выход)**, **E2EE**, **поиск людей / группы /
каналы** и **нативные звонки на LiveKit**.

---

## 1. Стек (сверено с реальными исходниками 7.3.0)

| Слой     | Решение                               | Заметки |
|----------|---------------------------------------|---------|
| UI       | Flutter 3.24+, Material 3             | Glassmorphism, орехово-медная гамма |
| Протокол | Matrix CS API (Synapse 1.155+)        | Логин, sync, сообщения, профиль, устройства |
| Клиент   | `matrix` (Famedly) 7.3.x              | Классический `/sync` + локальный кэш |
| E2EE     | `flutter_vodozemac` 0.5.x (vodozemac) | Заменил olm |
| Звонки   | **livekit_client** (наш UI)           | Стек Element Call: ваш LiveKit + lk-jwt-service |
| Кэш      | sqflite / ffi / IndexedDB             | Кроссплатформенно через conditional import |

---

## 2. Что реализовано

- Авторизация по паролю, восстановление сессии из локальной БД.
- Список чатов: поиск, папки, аватары (через аутентифицированные медиа),
  превью, время, непрочитанные; адаптивный layout.
- Переписка: статус сети/число участников, баблы, отправка, авто-пометка прочитанного.
- **Новый чат**: поиск людей в директории сервера → личный чат; создание
  **групп** и **каналов** (кнопка-карандаш в шапке списка).
- E2EE: vodozemac до `client.init()`, дальше SDK сам шифрует зашифрованные комнаты.
- **Проверка сессий по эмодзи (SAS)** — своя, как в Element: убирает
  «зашифровано устройством, не проверенным владельцем». Принимает входящие
  запросы (из Element X) и умеет запускать проверку своих сессий.
- **Нативные звонки** на LiveKit в нашем интерфейсе (стек Element Call), без
  встраивания call.element.io.
- Настройки: профиль (аватар + имя), тема (сохраняется), устройства аккаунта
  (переименование, удаление с паролём через UIA, проверка), Matrix ID, выход.
- Иконка приложения: `assets/icon/app_icon.png` + `flutter_launcher_icons`.

---

## 3. Структура

```
lib/
├─ main.dart                 # vodozemac → тема → БД → Matrix → запуск
├─ core/
│  ├─ config.dart            # адреса бэкенда (homeserver, lk-jwt-service)
│  ├─ matrix_service.dart    # логин, sync, профиль, устройства, E2EE-флаг
│  ├─ database.dart / database_web.dart / database_io.dart
├─ theme/ orex_theme.dart, glass.dart, theme_controller.dart
├─ widgets/squirrel_mascot.dart
└─ features/
   ├─ auth/login_screen.dart
   ├─ home/home_shell.dart
   ├─ chat_list/chat_list_panel.dart
   ├─ chat/chat_view.dart, message_bubble.dart
   ├─ settings/settings_screen.dart, devices_screen.dart
   ├─ call/call_session.dart    # LiveKit-сессия (OpenID → lk-jwt → connect)
   ├─ call/call_screen.dart     # наш экран звонка (сетка участников)
   ├─ new_chat/new_chat_screen.dart  # поиск людей, группы, каналы
   └─ settings/verification_screen.dart  # сверка эмодзи (SAS)
```

---

## 4. Шифрование (E2EE)

vodozemac **обязан** инициализироваться до `client.init()` — иначе SDK не включит
шифрование (это была причина, почему «шифрование не происходило»). В `main.dart`:

```dart
try { await vod.init(); } catch (e) { /* работаем без E2EE */ }
```

- Android / Windows / desktop — `flutter_vodozemac` собирает Rust через cargokit.
  Для desktop-сборки нужен **Rust toolchain** (`rustup`).
- Web — vodozemac это **wasm**, и его надо собрать в `web/pkg/`:

```bash
./tool/setup_web_vodozemac.sh          # bash / git-bash / WSL
```
PowerShell-эквивалент (если нет bash) — см. шаги в скрипте; ключевая команда:
`flutter_rust_bridge_codegen build-web --dart-root dart --rust-root <abs>/rust --release`,
затем перенести получившийся `pkg/` в `web/pkg/`.

После этого запускайте web с заголовками cross-origin isolation (нужно
flutter_rust_bridge для разделяемой памяти):

```bash
flutter run -d chrome \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```

> Если wasm не собран, `vod.init()` на web завис бы и блокировал запуск
> (белый экран). В `main.dart` он теперь под таймаутом 6 c: при отсутствии wasm
> приложение стартует **без** E2EE, а не зависает. Это и была причина, почему
> «приложение не запускалось».

Статус: Настройки → Безопасность → «Сквозное шифрование».

> Проверка сессий (эмодзи/SAS) уже реализована — см. экран «Проверка сессии».
> Дальше по E2EE: кросс-подпись/key backup setup (bootstrap) — намеренно не
> трогаем вслепую, чтобы не потерять ключи; обычно это уже настроено в Element.

---

## 5. Звонки (нативно, стек Element Call)

Мы **не встраиваем** call.element.io. Звонок реализован в нашем интерфейсе на
`livekit_client`, а токен берётся у **вашего** `lk-jwt-service` по OpenID —
это и есть стек Element Call (MatrixRTC):

1. `client.requestOpenIdToken(...)` → OpenID-токен Matrix.
2. `POST {lk-jwt-service}/sfu/get` с этим токеном и `room` → `{url, jwt}` LiveKit.
3. `livekit_client` подключается к вашему SFU; рисуем сетку участников сами.

Два клиента Orex, начавшие звонок в одной Matrix-комнате, получают одну и ту же
LiveKit-комнату (она выводится из roomId) и встречаются в звонке.

Настройка в `core/config.dart`:
```dart
static const String jwtService = 'https://jwt.vasys.ru';
```

> Что осталось для полноценного MatrixRTC-интероп с Element X: публикация
> membership-события `com.famedly.call.member` в состоянии комнаты (сигналинг
> «кто в звонке») и обмен ключами шифрования звонка. Сейчас реализовано
> подключение к общей LiveKit-комнате + наш UI. В matrix SDK есть модуль
> `VoIP`/`GroupCallSession` с LiveKit-бэкендом — следующий шаг перевести
> сигналинг на него.

---

## 6. Иконка приложения

```bash
flutter pub get
dart run flutter_launcher_icons   # генерит иконки для всех платформ из PNG
```

---

## 7. Сборка и запуск

Репозиторий хранит только исходники (`lib/`, `pubspec.yaml`, `assets/`,
`tool/`). Платформенные папки регенерируются (см. `.gitignore`):

```bash
flutter create --platforms=web,android,windows .   # воссоздать android/web/windows
flutter pub get
dart run flutter_launcher_icons                     # иконки (ios отключён)
./tool/setup_web_vodozemac.sh                        # wasm для E2EE на web

# web (быстрее всего), с cross-origin isolation для шифрования:
flutter run -d chrome \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp

# flutter run -d android  /  flutter run -d windows
```

Мелочи:
- Android: в `AndroidManifest.xml` нужны `INTERNET`, а для звонков —
  `RECORD_AUDIO`, `CAMERA`, `MODIFY_AUDIO_SETTINGS`, `BLUETOOTH` и
  `android.permission.FOREGROUND_SERVICE`. minSdkVersion ≥ 23 (требование
  livekit_client/flutter_webrtc).
- Web: CORS на Synapse (иначе логин из браузера упадёт); wasm vodozemac в `web/pkg/`.
- Windows: Rust toolchain для E2EE-сборки.

### Что не коммитится в Git
`.gitignore` исключает `android/ios/windows/web/linux/macos`, `test/`, `build/`,
`.dart_tool/` и т.п. — это и есть «лишнее», что попадало в репозиторий. После
`git clone` восстановите платформы командами выше. Минус подхода: `web/pkg/`
(wasm) тоже не хранится — пересоберите его скриптом `tool/setup_web_vodozemac.sh`.

---

## 8. Дорожная карта

E2EE UI (верификация, key backup) · вложения/reactions/ответы · пуши ·
Matrix Spaces вместо эвристики каналов · встроенный EC через webview ·
маскот-Белочка как помощник · пагинация ленты · Riverpod/Bloc.

## 9. Заметки

Лицензия matrix SDK — AGPL-3.0. После первой удачной сборки закрепите версии
пакетов (у matrix SDK бывают breaking changes между мажорами).
