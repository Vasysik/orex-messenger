# Выпуск Orex для Windows

Перед сборкой запустите локальную проверку:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

## Версия берётся только из `pubspec.yaml`

Единственный источник версии приложения — строка `version:` в `pubspec.yaml`:

```yaml
version: <version>+<build>
```

`flutter build windows` автоматически записывает эти значения в метаданные
приложения. Передавать `--build-name` и `--build-number` в release-командах не
нужно: это создало бы второй источник версии и риск рассинхронизации с именем
установщика и папкой на сервере.

Для Inno Setup и имён файлов версия читается из того же `pubspec.yaml`:

```powershell
$VersionMatch = [regex]::Match(
  (Get-Content pubspec.yaml -Raw),
  '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$'
)
if (-not $VersionMatch.Success) {
  throw 'В pubspec.yaml ожидается version: X.Y.Z+N'
}

$VersionName = '{0}.{1}.{2}' -f `
  $VersionMatch.Groups[1].Value, `
  $VersionMatch.Groups[2].Value, `
  $VersionMatch.Groups[3].Value
$BuildNumber = $VersionMatch.Groups[4].Value
$Release = "$VersionName+$BuildNumber"
$VersionInfo = "$VersionName.$BuildNumber"
```

После изменения версии в `pubspec.yaml` заново выполните `flutter pub get`, чтобы
Flutter обновил служебные файлы проекта.

## Stable и Debug устанавливаются параллельно

Оба канала собираются в Flutter `--release`. Отличаются идентичность
Windows-приложения, каталог Inno Setup и канал обновлений:

| Канал | EXE | Каталог установки | Канал обновлений |
| --- | --- | --- | --- |
| stable | `orex_messenger.exe` | `Orex Messenger` | `/updates/stable/` |
| debug | `orex_messenger_debug.exe` | `Orex Messenger Debug` | `/updates/debug/` |

Перед переключением канала выполняйте `flutter clean`: CMake кэширует имя
исполняемого файла. Скопируйте готовый установщик в папку релиза до следующего
`flutter clean`.

Windows временно использует совместимую связку `sqlite3 2.9.x`,
`sqflite_common_ffi 2.3.x` и `sqlcipher_flutter_libs 0.6.8`. Orex проверяет
`PRAGMA cipher_version` и останавливает запуск, если вместо SQLCipher загрузился
обычный SQLite.

### Stable-сборка

```powershell
flutter clean
$env:OREX_WINDOWS_CHANNEL = 'stable'
flutter pub get
flutter build windows --release --no-pub `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_UPDATE_CHANNEL=stable `
  --dart-define=OREX_DEBUG_LOGS=false
```

Артефакт приложения:

```text
build\windows\x64\runner\Release\orex_messenger.exe
```

### Параллельная Debug-сборка

```powershell
flutter clean
$env:OREX_WINDOWS_CHANNEL = 'debug'
flutter pub get
flutter build windows --release --no-pub `
  --dart-define=OREX_ENV=production `
  --dart-define=OREX_UPDATE_CHANNEL=debug `
  --dart-define=OREX_DEBUG_LOGS=true
```

Артефакт приложения:

```text
build\windows\x64\runner\Release\orex_messenger_debug.exe
```

`OREX_WINDOWS_CHANNEL` меняет native-имя бинарника. `OREX_UPDATE_CHANNEL` меняет
название внутри Flutter и адрес update feed. Значения должны совпадать.

## Сборка установщика Inno Setup

Установите Inno Setup один раз:

```powershell
winget install --id JRSoftware.InnoSetup -e `
  --accept-package-agreements `
  --accept-source-agreements
```

В том же PowerShell-сеансе сначала выполните блок чтения версии из
`pubspec.yaml`, приведённый выше, затем выберите канал и соберите установщик:

```powershell
$Channel = 'debug' # stable или debug
$OrexDebug = if ($Channel -eq 'debug') { 1 } else { 0 }

$Iscc = @(
  "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
  "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
  "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $Iscc) {
  throw 'Inno Setup 6 не найден'
}

& $Iscc `
  "/DOrexDebug=$OrexDebug" `
  "/DMyAppVersion=$Release" `
  "/DMyAppVersionInfo=$VersionInfo" `
  windows\installer\orex.iss
```

Результат:

```powershell
$Installer = "build\windows\x64\installer\$Channel\Orex-Setup-$Release.exe"
Test-Path $Installer
```

Inno Setup использует разные `AppId`, ярлыки и пользовательские каталоги,
поэтому stable и debug не заменяют друг друга. Во время обновления установщик
попросит закрыть запущенный экземпляр нужного канала и после установки предложит
запустить его снова.

Загрузите установщик в папку версии того же канала:

```powershell
$Destination = "updates\$Channel\$Release"
New-Item -ItemType Directory -Force $Destination
Copy-Item $Installer $Destination
```

Полная серверная схема описана в `docs/release-updates.md`.

Windows-БД создаётся как новое поколение:

```text
orex-cache-v3.sqlite
```

Старые `orex.sqlite` и `orex-sqlcipher.sqlite` из dogfood-сборок не
мигрируются и удаляются вместе с WAL/SHM/journal. После обновления локальный
Matrix-кэш создаётся заново.

При старте Orex проверяет `PRAGMA cipher_version`. Если вместо SQLCipher
подхватится обычный SQLite, приложение не откроет Matrix cache как plaintext.

`OREX_ALLOW_INSECURE_DESKTOP_CACHE=true` для Windows release больше не нужен.

## Windows smoke

Проверьте установку и обновление обоих каналов, запуск с SQLCipher-backed БД,
login/restore session, отправку сообщений, вложения и обычный/видеозвонок.

Для Windows-уведомлений дополнительно проверьте работающий desktop-процесс:

- откройте чат A, сверните либо закройте окно в трей, отправьте в A новое
  сообщение с аватаркой; появится уведомление с аватаркой, а нажатие вернёт
  окно и откроет A;
- отправьте сообщение в чат B, затем вернитесь в A: очистка A не должна
  убирать уведомление B;
- левый клик по иконке трея и пункт «Открыть Orex» восстанавливают окно;
  пункт «Выйти» завершает процесс и убирает иконку.
