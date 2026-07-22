$ErrorActionPreference = "Stop"

Write-Host "=== Reading version from pubspec.yaml ==="

$VersionMatch = [regex]::Match(
    (Get-Content pubspec.yaml -Raw),
    '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$'
)

if (-not $VersionMatch.Success) {
    throw "В pubspec.yaml ожидается version: X.Y.Z+N"
}

$VersionName = "{0}.{1}.{2}" -f `
    $VersionMatch.Groups[1].Value, `
    $VersionMatch.Groups[2].Value, `
    $VersionMatch.Groups[3].Value

$BuildNumber = $VersionMatch.Groups[4].Value
$Release = "$VersionName+$BuildNumber"

Write-Host "Version: $Release"

# ==========================================================
# Android
# ==========================================================

Write-Host ""
Write-Host "=== Building Android APK ==="

$env:OREX_ANDROID_DISTRIBUTION = "debug"

flutter build apk --release --split-per-abi --no-pub `
    --dart-define=OREX_ENV=production `
    --dart-define=OREX_UPDATE_CHANNEL=debug `
    --dart-define=OREX_DEBUG_LOGS=true

Copy-Item `
    "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk" `
    "app-arm64-v8a-$Release.apk" `
    -Force

Copy-Item `
    "build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk" `
    "app-armeabi-v7a-$Release.apk" `
    -Force

# ==========================================================
# Windows
# ==========================================================

Write-Host ""
Write-Host "=== Building Windows ==="

$env:OREX_WINDOWS_CHANNEL = "debug"

flutter pub get

flutter build windows --release --no-pub `
    --dart-define=OREX_ENV=production `
    --dart-define=OREX_UPDATE_CHANNEL=debug `
    --dart-define=OREX_DEBUG_LOGS=true

# ==========================================================
# Installer
# ==========================================================

Write-Host ""
Write-Host "=== Building installer ==="

$Channel = "debug"
$OrexDebug = if ($Channel -eq "debug") { 1 } else { 0 }

$Iscc = @(
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
) |
Where-Object { Test-Path $_ } |
Select-Object -First 1

if (-not $Iscc) {
    throw "Inno Setup 6 не найден"
}

& $Iscc `
    "/DOrexDebug=$OrexDebug" `
    "/DMyAppVersion=$Release" `
    "/DMyAppVersionInfo=$VersionName" `
    windows\installer\orex.iss

# ==========================================================
# Copy installer
# ==========================================================

Write-Host ""
Write-Host "=== Copy installer ==="

$Installer = "build\windows\x64\installer\$Channel\Orex-Setup-$Release.exe"

if (-not (Test-Path $Installer)) {
    throw "Не найден установщик: $Installer"
}

Copy-Item `
    $Installer `
    "Orex-Setup-$Release.exe" `
    -Force

Write-Host ""
Write-Host "========================================"
Write-Host "Build completed successfully!"
Write-Host ""
Write-Host "Artifacts:"
Write-Host "  app-arm64-v8a-$Release.apk"
Write-Host "  app-armeabi-v7a-$Release.apk"
Write-Host "  Orex-Setup-$Release.exe"
Write-Host "========================================"
