# Orex Windows Release

Перед сборкой версия сверяется с `pubspec.yaml`, затем запускается локальный quality gate:

```powershell
flutter pub get
flutter analyze --no-pub
flutter test --no-pub
```

## Windows production build для тестировщиков

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

`OpenSSL Light` заменяется на `ShiningLight.OpenSSL.Dev`. Проект передаёт CMake
стандартный путь `C:\Program Files\OpenSSL-Win64`; для нестандартной установки
задаётся `OPENSSL_ROOT_DIR`.

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

а не один `.exe`, потому что рядом лежат DLL, включая SQLCipher-backed
`sqlite3.dll`, и runtime-файлы Flutter.

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

Windows-БД создаётся как новый файл:

```text
orex-sqlcipher.sqlite
```

Старый `orex.sqlite` из прежних dogfood-сборок не мигрируется. Для `0.4.0+25`
это всё ещё ожидаемое ограничение.

При старте Orex проверяет `PRAGMA cipher_version`. Если вместо SQLCipher
подхватится обычный SQLite, приложение не откроет Matrix cache как plaintext.

`OREX_ALLOW_INSECURE_DESKTOP_CACHE=true` для Windows release больше не нужен.


## Windows smoke

Проверьте установку/обновление, запуск с SQLCipher-backed БД, login/restore session, отправку сообщений, вложения и обычный/видео звонок.
