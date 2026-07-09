# Orex Android Release

Перед сборкой версия сверяется с `pubspec.yaml`, затем запускается локальный quality gate:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

## Android release APK

Android release нельзя распространять без release signing. Debug key больше не
используется для release-сборки.

### 1. Создать keystore

Один раз на релизной машине:

```powershell
New-Item -ItemType Directory -Force android\secrets

keytool -genkeypair -v `
  -keystore android\secrets\orex-release.jks `
  -storetype JKS `
  -keyalg RSA `
  -keysize 2048 `
  -validity 10000 `
  -alias orex
```

Пароли и keystore должны храниться в резервируемом секретном хранилище. Потеря
keystore не позволит нормально обновлять уже розданные APK с тем же package id.

### 2. Создать `android/key.properties`

Файл не коммитится. Пример:

```properties
storeFile=secrets/orex-release.jks
storePassword=<STORE_PASSWORD>
keyAlias=orex
keyPassword=<KEY_PASSWORD>
```

`storeFile` читается относительно папки `android/`, потому что Gradle использует
`rootProject.file(...)`.

Можно не создавать файл и передать те же значения через переменные окружения:

```text
OREX_ANDROID_STORE_FILE
OREX_ANDROID_STORE_PASSWORD
OREX_ANDROID_KEY_ALIAS
OREX_ANDROID_KEY_PASSWORD
```

### 3. Настроить Android push

Для реальной background-доставки нужен Firebase Android app с package id
`ru.orex.messenger`. Его `google-services.json` размещается по пути:

```text
android/app/google-services.json
```

Файл уже исключён через `.gitignore` и не должен попадать в коммиты или
передаваться как часть исходников. Android release теперь **не собирается** без этого файла:
предыдущая мягкая проверка позволяла получить внешне рабочий APK без FCM token,
поэтому Matrix pusher вообще не регистрировался и Sygnal оставался без запросов.

`google-services.json` должен быть скачан из того же Firebase-проекта, чей
`project_id` и service account использует Sygnal. Firebase Android app должен
иметь package id ровно `ru.orex.messenger`.

Production Orex Push Gateway уже задан в клиенте и не требует `--dart-define`:

```text
http://sygnal:5000/_matrix/push/v1/notify
app_id = ru.vasys.orex_messenger
```

Это намеренно внутренний Docker URL: Android-клиент передаёт его Synapse как
адрес HTTP-pusher, но сам к нему не подключается. `sygnal` должен находиться с
Synapse в закрытой сети `matrix-backend`, без `ports:` и без Traefik router. Для
внешних/custom gateway override по-прежнему разрешён только абсолютный HTTPS
URL со стандартным Matrix-путём. Серверная network-policy и точный
`ip_range_whitelist` описаны в `docs/push-infrastructure.md`.

Homeserver отправляет туда стандартный Matrix push notification, а Sygnal
доставляет FCM **data-message**. В `0.4.0+15` Android pusher не использует
`event_id_only`: нативному Android-коду нужен полный стандартный payload, чтобы
немедленно классифицировать MatrixRTC `ring` и готовый plaintext. Если приходит
`m.room.encrypted`, FCM callback ставит expedited WorkManager job и сразу
возвращается. Worker разрешает точный `room_id/event_id` через Matrix SDK и
публикует `MessagingStyle` только после реальной E2EE-расшифровки; никаких
privacy-placeholder строк больше нет.

Свежий MatrixRTC `ring` сразу становится `CallStyle` входящим вызовом и получает
отдельную full-screen call Activity поверх lock screen. После запуска
Matrix/Flutter существующий Core-Telecom flow продолжает сигналинг и медиа.

Для личного E2EE-звонка wake-envelope намеренно не шифруется Matrix room
шифрованием: иначе убитый Android-процесс увидит только `m.room.encrypted` и не
сможет показать входящий звонок без headless crypto engine. Envelope живёт 45
секунд и не содержит текста, ключей или медиа; видимым push-инфраструктуре
остаётся только metadata факта звонка и адресатов.

Release-задача завершится ошибкой, если `android/app/google-services.json`
отсутствует. Только для явной compile-only CI-проверки, артефакт которой нельзя
распространять, существует escape hatch:

```powershell
$env:OREX_ALLOW_ANDROID_RELEASE_WITHOUT_PUSH = "true"
```

В обычной Orex release-сборке эта переменная не задаётся.

### 4. Собрать APK

```powershell
flutter build apk --release --split-per-abi --no-pub `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Артефакты:

```text
build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
build\app\outputs\flutter-apk\app-x86_64-release.apk
```

Для большинства современных Android-устройств используется `app-arm64-v8a-release.apk`.
Распространяемый fat APK без `--split-per-abi` не используется: он включает native
библиотеки сразу для всех ABI и заметно увеличивает размер установщика.

Если Gradle пишет `Android release signing is not configured`, значит
`android/key.properties` не найден, путь к keystore неправильный или не заданы
env-переменные.

`OREX_ALLOW_UNSIGNED_ANDROID_RELEASE=true` используется только для CI
compile-check. Такой APK нельзя отдавать как релизный артефакт.


## Android smoke

```text
cold start: native splash -> Flutter splash без белой вспышки
login / registration: иконка, слоган и версия совпадают со splash
login / restore session
установка правильного split APK на arm64-v8a тестовом устройстве
старый канал с одним постом открывается без ручной прокрутки вверх
поиск человека -> preview -> вход в DM
сообщение + reply + attachment
обычный исходящий и входящий звонок
видеозвонок: переключение камеры без переподключения к звонку
отклонение / завершение звонка
Android 8+: входящий -> системная карточка -> принять / отклонить
Android 8+: активный звонок -> завершить из системного UI / гарнитуры
Android 8+: system mute / hold -> микрофон и входящий звук восстанавливаются
Android 8+: speaker / earpiece / wired / Bluetooth route без конфликта AudioManager
Android: не показывается неработающая кнопка screen share до MediaProjection flow
Android 13+: permission на уведомления появляется после основного UI, не на splash
FCM token -> Matrix pusher зарегистрирован на homeserver
ротация FCM token -> старый pushkey удалён, новый зарегистрирован
logout -> pusher текущего устройства удалён до завершения Matrix logout
закрыть процесс -> encrypted FCM -> WorkManager decrypt -> plaintext уведомление
заблокировать экран -> входящий ring -> отдельное full-screen окно звонка
ответить / отклонить из native окна -> cold-start Matrix action
тап по cold-start уведомлению -> после sync открывается нужная room_id
голосовой канал: grant / revoke
системная тема сохраняется после перезапуска приложения
```
