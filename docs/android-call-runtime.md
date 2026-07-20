# Android call runtime

## Цель

Звонок Orex не принадлежит экрану и не принадлежит `MainActivity`. Экран — только проекция состояния. Владельцем Android-жизненного цикла является `OrexCallForegroundService`, а владельцем Matrix/LiveKit-состояния — один process-owned `FlutterEngine`.

Отдельный `android:process` намеренно не используется: Flutter plugins, Matrix client, E2EE и LiveKit уже живут в одном Dart isolate. Вынос только Service в другой процесс создал бы второй runtime и потребовал бы полноценного IPC. Если когда-нибудь потребуется настоящий отдельный media process, в него нужно переносить весь media/signaling stack, а не только notification service.

## Единственные владельцы

| Слой | Ответственность |
| --- | --- |
| `OrexCallForegroundService` | foreground ownership, ongoing notification, wake lock, persisted descriptor, answer watchdog, запуск process runtime |
| `OrexFlutterEngineOwner` | ровно один FlutterEngine/Dart isolate на процесс |
| `CallController` | MatrixRTC/LiveKit state machine и media lifecycle |
| `OrexAndroidTelecomManager` | Core-Telecom session, системные endpoints, mute/route callbacks |
| `OrexPushBridge` | process-owned MethodChannel и exactly-once pending command |
| `MainActivity` / incoming Activity / overlay | только UI; их уничтожение не завершает звонок |

## Состояния

```text
IDLE
  -> RINGING
  -> ANSWERING (не более 70 секунд)
  -> ACTIVE
  -> ENDING
  -> IDLE
```

`ANSWERING` — не активный звонок и не вечное recovery-состояние. Если Dart не повысил descriptor до `answered=true`, native watchdog очищает command, notification, Telecom presentation и service.

## Cold-start Answer

```text
Notification/Core-Telecom Answer
  -> markAnswering(exact roomId + ringEventId)
  -> persist foreground descriptor
  -> startForegroundService()
  -> startForeground(notification) immediately
  -> native readiness acknowledgement for exact call attempt
  -> start/reuse process-owned FlutterEngine
  -> deliver persisted Answer over process MethodChannel
  -> CallController claims foreground ownership
  -> MatrixRTC signaling + LiveKit connect
  -> descriptor answered=true
  -> expanded UI may attach when ready
```

Ни один шаг исполнения звонка не ждёт Activity, overlay или Flutter route. UI launch — best effort.

## Инварианты

1. Первый источник, получивший `FIRST_ALERT`, единолично владеет входящим notification и рингтоном; `SILENT_REFRESH` никогда не перепубликует тот же notification ID.
2. Notification Answer/Reject запускают `OrexCallActionActivity` прямым activity `PendingIntent`, без BroadcastReceiver/Service trampoline.
3. До Matrix signaling/media Android обязан подтвердить успешный `startForeground()` для точной попытки звонка.
4. `MethodChannel` принадлежит FlutterEngine и не снимается в `Activity.onDestroy()`.
5. Любая команда идентифицируется парой `(roomId, ringEventId)`; допускается только однонаправленное повышение legacy `null -> exact ringEventId`.
6. UI никогда не является lock/ack для Answer.
7. Каждый bootstrap имеет конечный timeout и полный cleanup.
8. Swipe из recent apps или закрытие Activity не уничтожает engine и не останавливает Service.
9. Force stop и системная кнопка остановки активного приложения считаются безусловным завершением процесса; приложение не пытается обходить Android.

## Обязательная проверка перед релизом

Проверять минимум на Pixel/AOSP и Xiaomi/MIUI:

- исходящий и входящий аудиозвонок из foreground;
- Answer из notification при выгруженной task;
- Answer с заблокированного экрана;
- Home, Back и swipe task во время connecting и active;
- повторное открытие приложения во время активного звонка;
- remote cancel до/после Answer;
- отсутствие сети, истёкший ring и ошибка MatrixRTC;
- Bluetooth/earpiece/speaker и аппаратный mute;
- разрешение уведомлений разрешено, запрещено и channel вручную выключен;
- Android 13+ Stop в Active apps — ожидаемое завершение;
- process recreation с `answered=true` descriptor.

Полезные проверки:

```bash
adb shell dumpsys activity services ru.orex.messenger
adb shell dumpsys notification --noredact | grep -i orex
adb logcat -s OrexCallService OrexFlutterEngine OrexPush OrexCallHandoff OrexTelecom
```

`adb shell am force-stop ru.orex.messenger` не является тестом фоновой живучести: force stop обязан остановить приложение и его service.


## v3 handoff invariants

- Presentation ring tokens never own or reject the foreground runtime.
- Every foreground descriptor update receives a fresh `startForeground()` acknowledgement.
- Duplicate notification intents cannot extend the native handoff timeout.
- An answered call reveals Flutter after an 8-second UI grace period even if the optional `callUiReady` acknowledgement is lost.
- The accepted-call route request remains pending until a Navigator host exists; it no longer expires after a fixed retry count.
- Native connecting surfaces use an OEM-independent rotating arc rather than the device `ProgressBar` skin.
