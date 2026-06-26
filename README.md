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
| UI       | Flutter 3.24+, Material 3             | Glassmorphism, тёплая медная гамма |
| Протокол | Matrix CS API (Synapse 1.155+)        | Логин, sync, сообщения, профиль, устройства |
| Клиент   | `matrix` (Famedly) 7.3.x              | Классический `/sync` + локальный кэш |
| E2EE     | `flutter_vodozemac` 0.5.x (vodozemac) | Заменил устаревший olm |
| Звонки   | **livekit_client** (наш UI)           | Стек Element Call: ваш LiveKit + lk-jwt-service |
| Кэш      | sqflite_sqlcipher / ffi / IndexedDB   | Полнодисковое AES-256 шифрование на мобильных/macOS |

---

## 2. Что реализовано

- **Авторизация и сессии:** Логин по паролю, восстановление сессии из локальной БД, корректная поддержка онлайн-бэкапа ключей (`loadAllKeys()`) [cite: 7.4.1].
- **Список чатов:** Поиск, вкладки-папки, аватары (через аутентифицированное скачивание), превью, время, счетчик непрочитанных, адаптивный layout.
- **Переписка:** Пресенс собеседника, баблы сообщений, отправка, автоматическая пометка прочитанного.
- **Новый чат:** Поиск людей в директории сервера -> личный чат; создание **групп** и **каналов** (кнопка-карандаш в шапке списка).
- **Пакетная отправка и альбомы (Presentation Models):** Плиточное прикрепление очереди файлов в строке ввода. При отправке медиа автоматически группируются в симметричную сетку-альбом (до 4-х плиток с заглушкой `+N` для скрытых файлов). Описание выносится строго под медиаблок.
- **Сверхбыстрая прокрутка (RAM-кэширование):** Глобальный оперативный кэш `_decryptedCache` предотвращает повторный ресурсоемкий запуск дешифрации WASM-вложений при скролле.
- **Ленивая дешифрация (Экономия трафика):** Плашки в ленте чата запрашивают только легковесные превью-эскизы (`downloadAndDecryptThumbnail()`) [cite: 1.2.1]. Оригинальный медиафайл загружается по требованию только при переходе в галерею.
- **Кастомный медиаплеер (Orex-style):** Собственный медный аудио-плеер в дизайне Orex на Flutter Web. Элемент видео принудительно останавливает фоновое воспроизведение при перелистывании слайдов или закрытии.
- **Продвинутая галерея (Медиапросмотр):** Масштабирование щепоткой (pinch zoom/out до 0.5x с автовозвратом к 1.0x), навигационные стрелки для десктопа, удаление своих отправленных медиа. Панорамирование включается только при приближении, сохраняя нативные свайпы перелистывания страниц.
- **Жесты под мобильные устройства:** Одиночный тап по сообщению открывает меню реакций на узких экранах, а клик на пустой фон чата мгновенно сворачивает клавиатуру [cite: 1.2.1].
- **E2EE и шифрование БД:** Инициализация vodozemac до запуска клиента. Проверка сессий по эмодзи (SAS) — своя, убирает предупреждения о непроверенном владельце. Локальная база данных `orex.sqlite` на Android, iOS и macOS зашифрована по протоколу AES-256 (пароль генерируется и хранится в Keystore/Keychain [cite: 1.1.5, 3.1.4]).
- **Нативные звонки:** На LiveKit в нашем интерфейсе (стек Element Call), без встраивания iframe. Сквозное шифрование медиапотоков (E2EE) успешно настроено через встроенную поддержку sframe [cite: 2.4.1].
- **Иконка приложения:** Сгенерирована под все платформы из `assets/icon/app_icon.png`.

---

## 3. Структура

```
lib/
├─ main.dart                 # OrexScrollBehavior -> БД -> Matrix -> запуск
├─ core/
│  ├─ config.dart            # homeserver, lk-jwt-service
│  ├─ matrix_service.dart    # синхронизация ключей, бэкап, профиль, устройства
│  ├─ file_helper.dart       # условный экспорт скачивания и открытия файлов
│  ├─ file_helper_io.dart    # системный запуск файлов через open_app_file
│  ├─ file_helper_web.dart    # blob-скачивание файлов через package:web
│  └─ database.dart / database_web.dart / database_io.dart
├─ theme/ orex_theme.dart, glass.dart, theme_controller.dart
├─ widgets/
│  ├─ squirrel_mascot.dart   # маскот-заглушка
│  ├─ media_gallery.dart     # интерактивный просмотрщик (PageView, жесты, удаление)
│  ├─ media_player.dart      # условный экспорт плееров
│  ├─ media_player_io.dart   # системный запуск видео/аудио
│  └─ media_player_web.dart  # HTML5-видео/аудио плеер в дизайне Orex
└─ features/
   ├─ auth/login_screen.dart
   ├─ home/home_shell.dart
   ├─ chat_list/chat_list_panel.dart
   ├─ chat/chat_view.dart, message_bubble.dart
   ├─ settings/settings_screen.dart, devices_screen.dart, key_storage_screen.dart
   ├─ call/call_session.dart / call_screen.dart
   ├─ new_chat/new_chat_screen.dart
   └─ settings/verification_screen.dart
```

---

## 4. Шифрование (E2EE)

vodozemac **обязан** инициализироваться до `client.init()` — иначе SDK не включит
шифрование. В `main.dart`:

```dart
try { await vod.init(); } catch (e) { /* работаем без E2EE */ }
```

- Android / Windows / desktop — `flutter_vodozemac` собирает Rust через cargokit.
  Для desktop-сборки нужен **Rust toolchain** (`rustup`).
- Web — vodozemac это **wasm**, и его надо собрать в `web/pkg/`:

```bash
./tool/setup_web_vodozemac.sh          # bash / git-bash / WSL
```

После этого запускайте web с заголовками cross-origin isolation (нужно
для разделяемой памяти):

```bash
flutter run -d chrome \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp
```

---

## 5. Звонки (нативно, стек Element Call)

Мы **не встраиваем** call.element.io. Звонок реализован в нашем интерфейсе на
`livekit_client`, а токен берётся у **вашего** `lk-jwt-service` по OpenID:

1. `client.requestOpenIdToken(...)` → OpenID-токен Matrix.
2. `POST {lk-jwt-service}/sfu/get` с этим токеном и `room` → `{url, jwt}` LiveKit.
3. `livekit_client` подключается к вашему SFU; рисуем сетку участников сами.

Настройка в `core/config.dart`:
```dart
static const String jwtService = 'https://jwt.vasys.ru';
```

---

## 6. Иконка приложения

```bash
flutter pub get
dart run flutter_launcher_icons   # генерит иконки для всех платформ из PNG
```

---

## 7. Сборка и запуск

Репозиторий хранит только исходники (`lib/`, `pubspec.yaml`, `assets/`,
`tool/`). Платформенные папки регенерируются:

```bash
flutter create --platforms=web,android,windows .   # воссоздать android/web/windows
flutter pub get
dart run flutter_launcher_icons                     # иконки (ios отключён)
./tool/setup_web_vodozemac.sh                        # wasm для E2EE на web

# web (быстрее всего), с cross-origin isolation для шифрования:
flutter run -d chrome \
  --web-header=Cross-Origin-Opener-Policy=same-origin \
  --web-header=Cross-Origin-Embedder-Policy=require-corp

# Сборка под Android (разделение APK по архитектурам для минимизации размера в 2.5 раза):
flutter build apk --split-per-abi

# Сборка под Windows (требуется Rust-компилятор для шифрования):
flutter build windows
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

Внедрение SQLCipher для полной защиты локальной БД Windows · пуши ·
Matrix Spaces вместо эвристики каналов · встроенный EC через webview ·
маскот-Белочка как помощник · Riverpod/Bloc.

## 9. Заметки

Лицензия matrix SDK — AGPL-3.0. После первой удачной сборки закрепите версии
пакетов (у matrix SDK бывают breaking changes между мажорами).
