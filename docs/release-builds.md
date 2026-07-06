# Orex Release Builds

Эта инструкция нужна для сборки артефактов `0.4.0+10` тестировщикам.
README описывает продукт, а здесь лежит практическая часть: ключи Android,
Windows production build и SQLCipher-проверки.

## 1. Перед сборкой

Проверьте версию в `pubspec.yaml`:

```yaml
version: 0.4.0+10
```

Затем выполните базовый gate:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

## 2. Android release APK

Android release нельзя распространять без release signing. Debug key больше не
используется для release-сборки.

### 2.1. Создать keystore

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

Сохраните пароли. Потеря keystore означает, что обновлять уже розданные APK тем
же package id будет проблемно.

### 2.2. Создать `android/key.properties`

Файл не коммитится. Пример:

```properties
storeFile=secrets/orex-release.jks
storePassword=ВАШ_STORE_PASSWORD
keyAlias=orex
keyPassword=ВАШ_KEY_PASSWORD
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

### 2.3. Настроить Android push

Для реальной background-доставки нужен Firebase Android app с package id
`ru.orex.messenger`. Скачайте его `google-services.json` и положите сюда:

```text
android/app/google-services.json
```

Файл уже исключён через `.gitignore`; не коммитьте его и не пересылайте как
часть исходников. Android release теперь **не собирается** без этого файла:
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
доставляет FCM **data-message**. В production нельзя рассчитывать на
Orex-специфичное поле `orex_kind`: стандартный Sygnal формирует payload из
Matrix notification. При `event_id_only` гарантированно доступны прежде всего
routing-поля (`room_id`, `event_id` и служебные счётчики), а подробности события
могут отсутствовать.

Клиент сохраняет `event_id_only`, чтобы push-инфраструктура не зависела от текста
сообщения. Cold-start storage хранит только routing-поля, не `title/body`.
Начиная с `0.4.0+10`, живой Android-процесс в background показывает системное
уведомление для новых Matrix notification counts, а новый личный звонок
отправляет targeted MSC4075 RTC notification типа `ring` после публикации
MatrixRTC membership.

Полностью закрытый процесс пока показывает только то, что реально пришло через
FCM. Если минимальный `event_id_only` payload не содержит тип RTC event, native
код не должен угадывать звонок по одному `room_id`: следующий этап — headless
fetch/decrypt/classification перед bootstrap Core-Telecom.

Release-задача завершится ошибкой, если `android/app/google-services.json`
отсутствует. Только для явной compile-only CI-проверки, артефакт которой нельзя
распространять, существует escape hatch:

```powershell
$env:OREX_ALLOW_ANDROID_RELEASE_WITHOUT_PUSH = "true"
```

Для обычной Orex release-сборки эту переменную не задавайте.

### 2.4. Собрать APK

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

Для большинства современных Android-устройств нужен `app-arm64-v8a-release.apk`.
Не собирайте распространяемый fat APK без `--split-per-abi`: он включает native
библиотеки сразу для всех ABI и заметно увеличивает размер установщика.

Если Gradle пишет `Android release signing is not configured`, значит
`android/key.properties` не найден, путь к keystore неправильный или не заданы
env-переменные.

`OREX_ALLOW_UNSIGNED_ANDROID_RELEASE=true` используйте только для CI
compile-check. Такой APK нельзя отдавать как релизный артефакт.

## 3. Windows production build для тестировщиков

Windows использует SQLCipher через `sqlcipher_flutter_libs` и
`sqflite_common_ffi`. Перед сборкой на машине разработчика должны быть доступны
инструменты CMake/MSVC из обычного Flutter Windows toolchain. Для сборки
SQLCipher-плагина также нужен OpenSSL с headers/libs. Runtime/Light-пакет не
подходит.

```powershell
choco install openssl
```

Если Chocolatey не установлен:

```powershell
winget install --id ShiningLight.OpenSSL.Dev -e `
  --accept-package-agreements `
  --accept-source-agreements
```

Проверка, что установлен именно dev-вариант:

```powershell
Test-Path "C:\Program Files\OpenSSL-Win64\include\openssl\opensslv.h"
Test-Path "C:\Program Files\OpenSSL-Win64\lib\VC\x64\MD\libcrypto_static.lib"
```

Обе команды должны вернуть `True`. Если CMake всё ещё пишет:

```text
Could NOT find OpenSSL
```

удалите `OpenSSL Light` и поставьте `ShiningLight.OpenSSL.Dev`. Проект сам
подсказывает CMake стандартный путь `C:\Program Files\OpenSSL-Win64`; для
нестандартной установки задайте `OPENSSL_ROOT_DIR`.

Сборка:

```powershell
flutter build windows --release --no-pub `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Артефакт:

```text
build\windows\x64\runner\Release\orex_messenger.exe
```

Для передачи тестировщику отдавайте всю папку:

```text
build\windows\x64\runner\Release\
```

а не один `.exe`, потому что рядом лежат DLL, включая SQLCipher-backed
`sqlite3.dll`, и runtime-файлы Flutter.

### 3.1. Windows installer вместо zip

Для нормального `.exe` установщика используйте Inno Setup:

```powershell
winget install --id JRSoftware.InnoSetup -e `
  --accept-package-agreements `
  --accept-source-agreements
```

После успешной Windows release-сборки задай версию из `pubspec.yaml` и передай её в Inno Setup:

```powershell
$VersionLine = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$').Matches[0]
$Version = '{0}.{1}.{2}+{3}' -f `
  $VersionLine.Groups[1].Value, `
  $VersionLine.Groups[2].Value, `
  $VersionLine.Groups[3].Value, `
  $VersionLine.Groups[4].Value
$VersionInfo = '{0}.{1}.{2}.{3}' -f `
  $VersionLine.Groups[1].Value, `
  $VersionLine.Groups[2].Value, `
  $VersionLine.Groups[3].Value, `
  $VersionLine.Groups[4].Value

$Iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

& $Iscc `
  "/DMyAppVersion=$Version" `
  "/DMyAppVersionInfo=$VersionInfo" `
  windows\installer\orex.iss
```

Артефакт:

```text
build\windows\x64\installer\Orex-Setup-0.4.0+10.exe
```

Именно этот `.exe` удобно отдавать тестировщикам вместо zip. Он ставит Orex в
user-level папку `%LOCALAPPDATA%\Programs\Orex Messenger`, не требует админских
прав и забирает все DLL из `build\windows\x64\runner\Release\`.

Windows-БД создаётся как новый файл:

```text
orex-sqlcipher.sqlite
```

Старый `orex.sqlite` из прежних dogfood-сборок не мигрируется. Для `0.4.0+10`
это ожидаемо.

При старте Orex проверяет `PRAGMA cipher_version`. Если вместо SQLCipher
подхватится обычный SQLite, приложение не откроет Matrix cache как plaintext.

`OREX_ALLOW_INSECURE_DESKTOP_CACHE=true` для Windows release больше не нужен.

## 4. Web release

```powershell
flutter build web --release --no-pub `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Артефакт:

```text
build\web
```

Web не использует `OREX_ALLOW_INSECURE_DESKTOP_CACHE`: это правило относится к
IO desktop-кэшу, а не к browser storage.

## 5. Что отправлять тестировщикам для `0.4.0+10`

Минимально:

- нужный ABI-specific APK для Android (`arm64-v8a` для большинства современных
  устройств; остальные ABI — только соответствующим тестировщикам);
- папку `build\windows\x64\runner\Release\` для Windows;
- короткий changelog и список smoke-сценариев.

Не переименовывайте три split-артефакта в один `app-release.apk`: имя ABI должно
оставаться видимым, иначе легко отправить тестировщику несовместимый пакет.

Smoke:

```text
cold start: native splash -> Flutter splash без белой вспышки
login / registration: иконка, слоган и версия совпадают со splash
login / restore session
установка правильного split APK на arm64-v8a тестовом устройстве
старый канал с одним постом открывается без ручной прокрутки вверх
поиск человека -> preview -> вход в DM
сообщение + reply + attachment
обычный исходящий и входящий звонок
отклонение / завершение звонка
Android 8+: входящий -> системная карточка -> принять / отклонить
Android 8+: активный звонок -> завершить из системного UI / гарнитуры
Android 8+: system mute / hold -> микрофон и входящий звук восстанавливаются
Android 8+: speaker / earpiece / wired / Bluetooth route без конфликта AudioManager
Android 13+: permission на уведомления появляется после основного UI, не на splash
FCM token -> Matrix pusher зарегистрирован на homeserver
ротация FCM token -> старый pushkey удалён, новый зарегистрирован
logout -> pusher текущего устройства удалён до завершения Matrix logout
закрыть процесс -> FCM data-message -> системное уведомление без Flutter UI
тап по cold-start уведомлению -> после sync открывается нужная room_id
голосовой канал: grant / revoke
```
