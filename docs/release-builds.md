# Orex Release Builds

Эта инструкция нужна для сборки артефактов `0.3.3+3` тестировщикам.
README описывает продукт, а здесь лежит практическая часть: ключи Android,
Windows dogfood build и ограничения desktop SQL.

## 1. Перед сборкой

Проверьте версию в `pubspec.yaml`:

```yaml
version: 0.3.3+3
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

### 2.3. Собрать APK

```powershell
flutter build apk --release --no-pub `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Артефакт:

```text
build\app\outputs\flutter-apk\app-release.apk
```

Если Gradle пишет `Android release signing is not configured`, значит
`android/key.properties` не найден, путь к keystore неправильный или не заданы
env-переменные.

`OREX_ALLOW_UNSIGNED_ANDROID_RELEASE=true` используйте только для CI
compile-check. Такой APK нельзя отдавать как релизный артефакт.

## 3. Windows build для тестировщиков

На Windows/Linux desktop cache пока не SQLCipher. Поэтому production desktop
режим с `OREX_ENV=production` должен падать при попытке использовать
незашифрованную Matrix-БД.

Для тестировщиков сейчас используйте dogfood-сборку:

```powershell
flutter build windows --release --no-pub `
  --dart-define=OREX_ENV=dev `
  --dart-define=OREX_HOMESERVER=https://vasys.ru `
  --dart-define=OREX_JWT_SERVICE=https://jwt.vasys.ru `
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

а не один `.exe`, потому что рядом лежат DLL и runtime-файлы Flutter.

Эта сборка не требует `OREX_ALLOW_INSECURE_DESKTOP_CACHE`, потому что она
собрана как `dev`. Но это именно dogfood/testing build, а не публичный
production desktop release.

## 4. Windows production release

Команда будущей production-сборки:

```powershell
flutter build windows --release --no-pub `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_DEBUG_LOGS=false
```

Но на текущем коде такую сборку нельзя честно отдавать как публичный secure
desktop release: Windows/Linux используют обычный SQLite через
`sqflite_common_ffi`, а не SQLCipher.

Чтобы production Windows стал настоящим релизом, нужно:

- подключить SQLCipher-backed desktop database;
- открыть Matrix SDK database через зашифрованный backend;
- хранить ключ БД через Windows Credential Manager / DPAPI или другой
  защищённый механизм;
- оставить fail-closed policy для production, если encrypted storage недоступен.

`OREX_ALLOW_INSECURE_DESKTOP_CACHE=true` не используйте для публичного релиза.
Это аварийный dogfood escape hatch.

## 5. Web release

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

## 6. Что отправлять тестировщикам для `0.3.3+3`

Минимально:

- `app-release.apk` для Android;
- папку `build\windows\x64\runner\Release\` для Windows;
- короткий changelog и список smoke-сценариев.

Smoke:

```text
login / restore session
старый канал с одним постом открывается без ручной прокрутки вверх
поиск человека -> preview -> вход в DM
сообщение + reply + attachment
обычный исходящий и входящий звонок
отклонение / завершение звонка
голосовой канал: grant / revoke
```
