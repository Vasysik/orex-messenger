# Orex Messenger — архитектура (Lead Flutter Architect)

Тёплый ореховый мессенджер на **Flutter** поверх **Matrix (Synapse)** и **LiveKit**.
Единая кодовая база: **Web · Android · Windows** (плюс iOS/macOS/Linux «бесплатно»,
если понадобятся).

Этот пакет — рабочий **каркас**: тема, glassmorphism-компоненты, адаптивный
двухпанельный layout в стиле Telegram, список чатов с папками, окно переписки,
оверлей звонка и сервисы Matrix/LiveKit. Бизнес-логику и крайние случаи нужно
дорастить (см. «Дорожная карта»).

---

## 1. Технологический стек (проверено на актуальность)

| Слой              | Решение                                  | Заметки |
|-------------------|------------------------------------------|---------|
| UI                | Flutter 3.24+, Material 3                | Glassmorphism через `BackdropFilter` |
| Протокол          | Matrix CS API (Synapse 1.155+)           | Логин, sync, сообщения, комнаты |
| Matrix-клиент     | `matrix` (Famedly), ветка **7.x**        | Содержит встроенные LiveKit-звонки («famedly calls») |
| E2EE              | **vodozemac** (`flutter_vodozemac`)      | Заменил устаревший olm |
| Звонки            | `livekit_client` 2.x + lk-jwt-service    | Поток в стиле Element Call / MatrixRTC |
| TURN/STUN         | Coturn (на сервере)                      | Прозрачно для клиента через LiveKit |

### Важные уточнения (читать перед стартом)

1. **Sliding Sync.** Нативный Simplified Sliding Sync (MSC4186) реализован в
   Synapse и в Rust/JS SDK. Но **Dart SDK (Famedly) исторически работает на
   классическом `/sync`** + локальный кэш; «мгновенный запуск» там делается за
   счёт БД, а не sliding sync. Поэтому архитектура опирается на
   `Client.init(waitForFirstSync: false)` + локальную базу. Если ваша версия
   Dart SDK уже умеет MSC4186 — включайте отдельно и тестируйте; не считайте это
   гарантированным «из коробки».

2. **Звонки.** Встроенные «famedly calls» в SDK 7.x умеют LiveKit. При этом ваш
   развёрнутый `lk-jwt-service` ждёт **OpenID-токен** Matrix (не сырой
   `access_token`). В `CallService` реализован корректный поток:
   `openid/request_token` → `POST /sfu/get` → `connect()`. Если ваш сервис
   настроен иначе — точка правки одна (`CallService._requestSfu`).

3. **Версии API SDK.** Экосистема быстро меняется, между мажорами matrix SDK
   бывают breaking changes. Отдельные геттеры в коде (например,
   `directChatPresence`, `canSendDefaultMessages`) сверьте с установленной
   версией — это пометки `// уточните` в коде. Запустите
   `flutter pub upgrade --major-versions` и поправьте сигнатуры под реальный API.

---

## 2. Структура проекта

```
lib/
├─ main.dart                      # запуск, DI сервисов, выбор экрана
├─ theme/
│  ├─ orex_theme.dart            # палитра (walnut/copper) + ThemeData
│  └─ glass.dart                 # GlassPanel + амбиентный фон
├─ core/
│  ├─ matrix_service.dart        # клиент, логин, sync, папки, отправка
│  └─ call_service.dart          # OpenID → lk-jwt-service → LiveKit
├─ widgets/
│  └─ squirrel_mascot.dart       # маскот-Белочка (пустые состояния)
└─ features/
   ├─ auth/login_screen.dart
   ├─ home/home_shell.dart        # адаптивный двухпанельный каркас
   ├─ chat_list/chat_list_panel.dart  # поиск + папки + список чатов
   ├─ chat/chat_view.dart         # шапка + лента + ввод
   ├─ chat/message_bubble.dart
   └─ call/call_overlay.dart      # стеклянный оверлей звонка
```

**Управление состоянием.** Каркас намеренно использует `ChangeNotifier` +
`AnimatedBuilder`, чтобы не навязывать стек. Для продакшена рекомендую
**Riverpod** (или Bloc): обернуть `MatrixService`/`CallService` в провайдеры,
а таймлайны комнат — в семейство провайдеров по `roomId`.

---

## 3. Потоки данных

### Авторизация
```
LoginScreen → MatrixService.login()
  → client.checkHomeserver(https://vasys.ru)
  → client.login(m.login.password)         # POST /_matrix/client/v3/login
  → SDK сохраняет access_token + deviceId в локальную БД
```

### Синхронизация и список чатов
```
App start → MatrixService.init()
  → client.init(waitForFirstSync:false)    # поднимает кэш из БД -> мгновенный UI
  → client.onSync.stream → notifyListeners()
ChatListPanel слушает MatrixService, фильтрует rooms по папке (Все/Личные/Группы/Каналы)
```

### Сообщения
```
ChatView.open → room.getTimeline(onUpdate: setState)
Отправка → room.sendTextEvent(text)        # PUT /rooms/{id}/send/m.room.message
```

### Звонок (LiveKit / MatrixRTC)
```
Кнопка звонка → CallService.joinCall(roomId, video)
  1. POST /_matrix/client/v3/user/{userId}/openid/request_token  → openid access_token
  2. POST https://jwt.vasys.ru/sfu/get
        { room, openid_token:{access_token, matrix_server_name}, device_id }
     → { url: "wss://lk.vasys.ru", jwt }
  3. lk.Room.connect(url, jwt) → publish mic/cam
CallOverlay рисует сетку участников поверх чата
```

---

## 4. Дизайн-система

**Палитра** (`OrexColors`): медь `#C8763C`, светлая медь `#D98C4A`, орех
`#8B5A2B`, глубокий орех `#5E3A1A`, охра `#D9A05B`, кремовый `#FBF5EC`.
**Тёмная тема** — «чёрный шоколад»: фон `#1C140E`, поверхности с тёплым медным
отливом, никакого холодного синего/серого.

**Glassmorphism** (`GlassPanel`): `BackdropFilter(blur)` + полупрозрачный тёплый
слой + тонкая медная светящаяся граница + диагональный световой градиент.
Под стеклом — `AmbientBackground` с тёплыми «пятнами» света, чтобы блюру было
что размывать.

**Маскот-Белочка** появляется на splash/логине, в пустом списке, в пустом окне
переписки и в звонке «ожидаем собеседника». Положите ассет в
`assets/mascot/squirrel.png` (есть graceful-fallback на эмодзи 🐿).

---

## 5. Сборка под платформы

**Общее:** `flutter pub get`, затем правьте `kHomeserver`/`kJwtService` в `main.dart`.

- **Web.** Для vodozemac нужен wasm/worker — следуйте README `flutter_vodozemac`.
  Для E2EE LiveKit на web соберите `e2ee.worker.dart.js` (см. доку livekit_client).
  Synapse должен слать корректные CORS-заголовки (у вас бэкенд готов — проверьте).
- **Android.** В `AndroidManifest.xml` — разрешения `INTERNET`, `RECORD_AUDIO`,
  `CAMERA`, `BLUETOOTH`/`MODIFY_AUDIO_SETTINGS`; для демонстрации экрана —
  foreground service (требование flutter_webrtc).
- **Windows.** Десктоп-таргет Flutter + Visual Studio (C++ desktop workload).
  `livekit_client` поддерживает desktop через flutter_webrtc.

---

## 6. Дорожная карта (что дорастить)

Приоритет 1 — функциональный паритет:
- Локальная БД для кэша (Hive/SQLite) и устойчивый старт оффлайн.
- E2EE: инициализация vodozemac, верификация устройств, key backup.
- Вложения: загрузка/скачивание media (`room.sendFileEvent`), превью.
- Прочитанные/печатает/доставлено, reactions, ответы, редактирование.
- Пуш-уведомления (UnifiedPush/FCM) + бейджи непрочитанного.

Приоритет 2 — «лучше Telegram»:
- Настоящие папки Matrix (spaces / m.space) вместо эвристики каналов.
- Групповые звонки с раскладками, шумоподавление, демонстрация экрана.
- Поиск по сообщениям, закреплённые, мьюты, архив.
- Тонкая настройка sliding sync, если Dart SDK его поддержит.

Технический долг каркаса:
- Заменить `ChangeNotifier` на Riverpod/Bloc.
- Пагинация таймлайна (`timeline.requestHistory()`), индикаторы загрузки.
- Обработка ошибок сети/токена (soft logout, refresh).
- Сверить помеченные `// уточните` геттеры SDK с установленной версией.

---

## 7. Риски и рекомендации

- **Версии SDK.** Закрепите версии после первой успешной сборки и обновляйтесь
  осознанно — у matrix SDK бывают breaking changes между мажорами.
- **Sliding sync.** Не закладывайте маркетинг «instant sync через MSC4186» в
  Dart-клиенте, пока не подтвердите поддержку в вашей версии SDK.
- **Звонки.** Протестируйте формат запроса к `lk-jwt-service` против реального
  ответа вашего сервиса (поле `room`: id или alias; нужен ли `device_id`).
- **Юридическое.** Лицензия matrix SDK — AGPL-3.0; учтите требования при
  распространении клиента.
