# Стабилизация телефонии Orex

Дата ревизии: 14 июля 2026.

## 1. Что было до исправления

Телефония уже разделена на разумные подсистемы, но несколько слоёв одновременно
считали себя владельцами одного и того же пользовательского состояния.

```text
FCM / Matrix sync / MatrixRTC
          |
          v
  OrexPushBridge + VoipService
          |
          v
       CallController  <----> LiveKit / WebRTC
          |
          +----> OrexCallForegroundService
          +----> OrexAndroidTelecomManager (Core-Telecom)
          +----> MainActivity / CallScreen / incoming-call Activity
```

Основные компоненты:

| Компонент | Фактическая роль |
| --- | --- |
| `VoipService` | MatrixRTC-сигналинг, поиск ring/disposition-событий, дедупликация попыток |
| `CallController` | единая Dart state machine звонка, MatrixRTC/LiveKit и media lifecycle |
| `OrexCallForegroundService` | Android foreground ownership, persisted descriptor, wake lock и watchdog |
| `OrexAndroidTelecomManager` | Core-Telecom, системные endpoint/mute/answer/hang-up события |
| `OrexPushBridge` | FCM, persisted commands, MethodChannel и запуск Android UI/runtime |
| `OrexNotificationCenter` | входящие/активные call notifications и native ringtone presentation |
| `OrexFlutterEngineOwner` | process-owned FlutterEngine для активного звонка |
| `OrexPushBackgroundResolver` | отдельный краткоживущий FlutterEngine для расшифровки обычных E2EE push |
| Flutter `OrexApp` | выбор комнаты, incoming dialog и переход на `CallScreen` |
| Windows runner | native notification и окно Flutter |

Разделение в целом правильное. Ошибки возникали не из-за отсутствия state
machine, а из-за нарушения ownership-инвариантов на границах Android/Dart/UI.

## 2. Найденные первопричины

### 2.1. Рингтон прекращался, а карточка оставалась

Первый FCM-получатель публиковал notification `4040` с `FLAG_INSISTENT`.
После этого Core-Telecom или background avatar resolver повторно публиковал тот
же ID как `SILENT_REFRESH`. Новый объект notification уже не содержал
`FLAG_INSISTENT`, поэтому OEM прекращал звук, но оставлял карточку «Входящий
звонок». Частота зависела от порядка FCM, Matrix sync, Telecom registration и
разрешения аватара — отсюда нестабильные 2/3 случаев.

**Новое правило:** первый успешно заявивший ring presentation — единственный
владелец notification и рингтона. Последующие источники могут принять состояние,
но не имеют права заменять активный notification.

### 2.2. Answer из notification был Android notification trampoline

Кнопка notification открывала `BroadcastReceiver`, а receiver затем запускал
Activity. На Android 12+ такой переход запрещён для notification actions и
нестабилен на OEM-прошивках.

**Новое правило:** Answer/Reject запускают `OrexCallActionActivity` напрямую
через activity `PendingIntent`. Activity сначала сохраняет точную команду
`(roomId, ringEventId)`, запускает foreground runtime, затем открывает
`MainActivity` для пользователя.

### 2.3. Cold Answer показывал splash/error вместо handoff

`bringCallHandoffToFront()` намеренно не передавал `EXTRA_CALL_HANDOFF`, хотя
`MainActivity` уже содержит native connecting cover. Поэтому при холодном
старте пользователь видел промежуточный launcher/Flutter bootstrap и мог попасть
в ошибку запуска до восстановления Matrix.

**Новое правило:** cold Answer всегда устанавливает native handoff cover; экран
Flutter является проекцией и подключается после восстановления runtime.

### 2.4. Два FlutterEngine могли одновременно открыть Matrix runtime

Обычный E2EE push мог поднять `OrexPushBackgroundResolver`, а Answer почти сразу
создавал process-owned engine. Оба isolate набирали плагины и пытались работать с
одной Matrix/SQLCipher базой. Это создаёт гонки запуска, plugin ownership и
непредсказуемые cold-start ошибки.

**Новое правило:** process-owned call engine имеет абсолютный приоритет.
Headless resolver уступает владение и возвращает retry, если call runtime уже
создаётся или работает. Для входящего call-envelope headless resolver вообще не
запускается: нативных metadata достаточно для показа звонка.

### 2.5. Native watchdog завершал Answer раньше Dart bootstrap

Foreground service очищал `ANSWERING` через 35 секунд, хотя документированный
контракт и холодное восстановление Matrix допускают более длинный путь.

**Новое правило:** единый timeout 70 секунд. Это конечный бюджет, а не вечный
recovery; по его истечении выполняется полный cleanup.

### 2.6. Cold sync искал комнату только один раз

После Answer Flutter выполнял один `oneShotSync(timeout: Duration.zero)` и сразу
считал комнату отсутствующей. На реально холодном процессе локальный cache и
первый `/sync` часто ещё не готовы.

**Новое правило:** bounded room recovery до 12 секунд с короткими sync nudges и
polling локального cache. Общий 70-секундный native watchdog остаётся верхней
границей всего Answer flow.

### 2.7. Desktop signaling мог подписаться слишком поздно

`CallController` — `late final`. Sync/login callback мог впервые создать его до
создания `VoipService`; в конструкторе controller подписки через `matrix.voip?`
становились `null` навсегда. Исходящий звонок затем «прогревал» другие пути, что
маскировало ошибку.

Кроме того, incoming dialog был запрещён при lifecycle `inactive`, хотя для
Windows это нормальное состояние свёрнутого/неактивного окна.

**Новые правила:**

1. `VoipService` создаётся до регистрации sync/login callback и до materialize
   `CallController`.
2. После login выполняется явный rescan входящих звонков.
3. Desktop может поставить incoming UI в очередь независимо от focus state.
4. Windows runner явно восстанавливает и фокусирует окно перед показом диалога.

## 3. Целевая лаконичная архитектура

### 3.1. Один владелец на каждую ответственность

```text
Delivery:       FCM / Matrix sync
                    |
Signaling:          VoipService
                    |
Domain owner:       CallController
                 /       |        \
Android lifetime: FGS   Telecom    UI projection
                    |
Runtime owner:  one process FlutterEngine
```

| Инвариант | Владелец |
| --- | --- |
| Точная попытка `(roomId, ringEventId)` | `CallController` + persisted native descriptor |
| MatrixRTC/LiveKit/media state | только `CallController` |
| Android foreground lifetime | только `OrexCallForegroundService` |
| Системный call session и route | только `OrexAndroidTelecomManager` |
| Входящий notification/ringtone | первый owner в `OrexCallPresentationState` |
| Flutter runtime во время звонка | только `OrexFlutterEngineOwner` |
| Экран/диалог | пассивная проекция, никогда не runtime lock |

### 3.2. Входящий звонок

```text
FCM ring
  -> native validate TTL + exact ring token
  -> FIRST_ALERT claim
  -> one persistent incoming notification + ringtone
  -> Core-Telecom adopts attempt without reposting notification
  -> Matrix sync confirms signaling state
```

Duplicate FCM, avatar refresh и Telecom adoption не заменяют notification.
Remote accepted/rejected/cancelled событие закрывает точную попытку.

### 3.3. Answer из notification

```text
Activity PendingIntent
  -> OrexCallActionActivity
  -> mark ANSWERING + persist exact command
  -> startForegroundService + immediate foreground notification
  -> stop incoming ringtone/presentation
  -> stop/yield headless resolver
  -> start/reuse process FlutterEngine
  -> direct MainActivity launch with native handoff cover
  -> drain persisted command through process MethodChannel
  -> bounded room recovery
  -> CallController accepts exact attempt
  -> MatrixRTC + LiveKit
  -> mark ACTIVE; show CallScreen
```

При заблокированном устройстве Activity не использует `showWhenLocked`; Android
сохраняет обычную границу разблокировки для открытия основного приложения.
Исполнение звонка не зависит от успешной отрисовки Flutter route.

### 3.4. Desktop incoming

```text
Matrix client init
  -> create VoipService
  -> create CallController and all subscriptions
  -> sync/login rescan
  -> incoming event
  -> restore/focus native window
  -> enqueue Answer/Decline dialog
```

Ни один шаг не зависит от ранее совершённого исходящего звонка.

## 4. Почему не скопированы исходники Element X целиком

Element X Android построен на Kotlin/Compose и Matrix Rust SDK, тогда как Orex
использует Flutter, Matrix Dart SDK и собственный LiveKit media layer. Прямое
копирование lifecycle/media кода добавило бы второй несовместимый стек.

Вместо этого заимствованы архитектурные принципы:

- звонок — доменная state machine, а не экран;
- нативный call lifecycle отделён от UI;
- действия адресуют конкретную call attempt;
- Matrix signaling и media transport имеют явных владельцев;
- delivery, presentation и active runtime не смешиваются.

## 5. Изменённые файлы

- `android/.../OrexNotificationCenter.kt`
- `android/.../OrexPushBridge.kt`
- `android/.../OrexCallForegroundService.kt`
- `android/.../OrexFlutterEngineOwner.kt`
- `android/.../OrexPushBackgroundResolver.kt`
- `lib/core/matrix/matrix_service.dart`
- `lib/core/voip/voip_service.dart`
- `lib/core/push/push_platform_bridge.dart`
- `lib/core/push/orex_push_service.dart`
- `lib/main.dart`
- `windows/runner/flutter_window.{h,cpp}`
- `test/core/push/orex_push_service_test.dart`

## 6. Обязательная prerelease-матрица

Каждый сценарий выполнить не менее 10 раз, отдельно на Pixel/AOSP и Xiaomi/MIUI.

| Сценарий | Ожидание |
| --- | --- |
| Android foreground incoming | непрерывный ring до answer/reject/cancel/TTL |
| Android background incoming | одна карточка и непрерывный ring |
| Android process cold + Answer | unlock при необходимости, native handoff, затем CallScreen |
| Duplicate FCM + Telecom adoption | нет повторного звука и нет преждевременного stop |
| Remote laptop connects, но не принимает | телефон продолжает звонить |
| Remote accepts на другом устройстве | точный ring token закрывается везде |
| Answer при медленном `/sync` | остаётся `Подключение`, затем входит либо clean timeout |
| Swipe task во время active call | service/engine/media продолжают работать |
| Force stop | ожидаемое полное завершение Android process |
| Windows fresh install incoming | dialog появляется без предварительного outgoing |
| Windows minimized incoming | окно восстанавливается и получает focus |
| Reconnect/network loss | один runtime owner, без второго call/session |
| Bluetooth/earpiece/speaker | route контролирует Telecom, без взаимного перетягивания |

Логи для одного теста должны позволять проследить одну пару
`roomId + ringEventId` через FCM, presentation claim, service descriptor,
MethodChannel, MatrixRTC и LiveKit.

## 7. Quality gate

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
flutter build apk --debug --no-pub
flutter build windows --debug --no-pub
```

Android runtime smoke:

```bash
adb logcat -c
adb logcat -s OrexPush OrexNotifications OrexCallAction OrexCallService \
  OrexFlutterEngine OrexSystemCall flutter
adb shell dumpsys notification --noredact | grep -i orex
adb shell dumpsys activity services ru.orex.messenger
```

Критерий выпуска: ни один duplicate source не заменяет активный ringing
notification; каждая cold Answer attempt либо становится `ACTIVE`, либо
завершается одним конечным cleanup без зависшего «Подключение».
