# Orex Windows Release

Перед сборкой версия сверяется с `pubspec.yaml`, затем запускается локальный quality gate:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

## Windows production build для тестировщиков

Windows временно использует совместимую связку `sqlite3 2.9.x`,
`sqflite_common_ffi 2.3.x` и `sqlcipher_flutter_libs 0.6.8`. Matrix 8.1.0
ограничивает `sqlite3` веткой 2.x, поэтому переход на native build hooks
`sqlite3 3.x` отложен до обновления ограничения в Matrix SDK.

`sqlcipher_flutter_libs 0.6.8` поставляет SQLCipher 4.10.0. Orex дополнительно
проверяет `PRAGMA cipher_version`, поэтому случайная загрузка обычного SQLite
завершает запуск fail-closed.

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

Тестировщику передаётся вся папка:

```text
build\windows\x64\runner\Release\
```

а не один `.exe`, потому что рядом лежат Flutter runtime-файлы и
`sqlite3.dll`, поставляемая SQLCipher-плагином.

### Windows installer вместо zip

Для нормального `.exe` установщика используется Inno Setup:

```powershell
winget install --id JRSoftware.InnoSetup -e `
  --accept-package-agreements `
  --accept-source-agreements
```

После успешной Windows release-сборки версия читается из `pubspec.yaml` и
передаётся в Inno Setup:

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
build\windows\x64\installer\Orex-Setup-<version-from-pubspec>.exe
```

Именно этот `.exe` используется как основной артефакт для тестировщиков вместо zip. Он ставит Orex в
user-level папку `%LOCALAPPDATA%\Programs\Orex Messenger`, не требует админских
прав и забирает все DLL из `build\windows\x64\runner\Release\`.

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

Проверьте установку/обновление, запуск с SQLCipher-backed БД, login/restore session, отправку сообщений, вложения и обычный/видео звонок.
