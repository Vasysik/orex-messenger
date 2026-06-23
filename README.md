# Orex Messenger — архитектура (Lead Flutter Architect)

Тёплый ореховый мессенджер на **Flutter** поверх **Matrix (Synapse)**, со
сквозным шифрованием (**vodozemac**) и звонками через **Element Call**
(MatrixRTC + ваш LiveKit). Единая кодовая база: **Web · Android · Windows**.

Это уже близкий к рабочему билд: тема, glassmorphism, адаптивный двухпанельный
layout, список чатов с папками, переписка, **настройки (профиль, тема,
устройства, выход)**, **E2EE** и **звонки через Element Call**.

---

## 1. Стек (сверено с реальными исходниками 7.3.0)

| Слой     | Решение                               | Заметки |
|----------|---------------------------------------|---------|
| UI       | Flutter 3.24+, Material 3             | Glassmorphism, орехово-медная гамма |
| Протокол | Matrix CS API (Synapse 1.155+)        | Логин, sync, сообщения, профиль, устройства |
| Клиент   | `matrix` (Famedly) 7.3.x              | Классический `/sync` + локальный кэш |
| E2EE     | `flutter_vodozemac` 0.5.x (vodozemac) | Заменил olm |
| Звонки   | **Element Call** (web/native)         | Поверх вашего LiveKit + lk-jwt-service |
| Кэш      | sqflite / ffi / IndexedDB             | Кроссплатформенно через conditional import |

---

## 2. Что реализовано

- Авторизация по паролю, восстановление сессии из локальной БД.
- Список чатов: поиск, папки, аватары, превью, время, непрочитанные; адаптивный layout.
- Переписка: статус сети/число участников, баблы, отправка, авто-пометка прочитанного.
- E2EE: vodozemac до `client.init()`, дальше SDK сам шифрует зашифрованные комнаты.
- Звонки через Element Call: web — `<iframe>`, native — системный браузер
  (без тяжёлого WebRTC в клиенте — это и убирало лаги).
- Настройки: профиль (аватар + имя), тема (сохраняется), устройства аккаунта
  (переименование, удаление с паролём через UIA), Matrix ID, выход.
- Иконка приложения: `assets/icon/app_icon.png` + `flutter_launcher_icons`.

---

## 3. Структура

```
lib/
├─ main.dart                 # vodozemac → тема → БД → Matrix → запуск
├─ core/
│  ├─ config.dart            # адреса бэкенда (homeserver, Element Call)
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
   └─ call/element_call*.dart   # фасад + web(iframe) + native(browser) + url
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

> Дальше по E2EE: кросс-подпись, верификация устройств, key backup (SDK умеет —
> нужен UI).

---

## 5. Звонки (Element Call)

EC — веб-приложение MatrixRTC поверх **вашего** LiveKit + lk-jwt-service. Мы его
открываем, а не реализуем WebRTC в Flutter:
- Web → `<iframe>` на полноэкранном экране (камера/микрофон через `allow`).
- Native → системный браузер (`url_launcher`), надёжно вкл. Windows.

Настройка в `core/config.dart`:
```dart
static const String elementCallBase = 'https://call.element.io';
```
Рекомендуется поднять свой EC (`https://call.vasys.ru`) на ваш homeserver+LiveKit.

> Точный набор query-параметров URL EC зависит от версии — сверьте
> `element_call_url.dart` со своим деплоем. Встроенный звонок в native без выхода
> в браузер — следующий шаг (webview + Matrix Widget API).

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
- Android: `INTERNET` в манифесте.
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
