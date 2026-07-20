[CmdletBinding()]
param(
    [string]$Package = "ru.orex.messenger",
    [string]$OutputRoot = ".\orex-test-logs",
    [switch]$NoClear,
    [switch]$Bugreport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-AdbToFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $output = & adb @Arguments 2>&1
    $output | Out-File -FilePath $Path -Encoding utf8
}

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw "adb не найден в PATH. Открой PowerShell из Android Studio/Flutter SDK окружения или добавь platform-tools в PATH."
}

& adb start-server | Out-Null
& adb wait-for-device

$devices = & adb devices
$connected = @(
    $devices |
        Select-String -Pattern "^\S+\s+device$" |
        ForEach-Object { $_.Line }
)

if ($connected.Count -eq 0) {
    throw "Нет подключённого Android-устройства в состоянии device. Проверь USB debugging и команду: adb devices"
}
if ($connected.Count -gt 1) {
    throw "Подключено несколько устройств. Оставь одно устройство либо адаптируй скрипт, добавив adb -s <serial>."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$sessionDir = Join-Path $OutputRoot "orex-call-$stamp"
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$rawLog = Join-Path $sessionDir "01-logcat-full.txt"
$focusedLog = Join-Path $sessionDir "02-logcat-orex-focused.txt"
$logcatErr = Join-Path $sessionDir "03-logcat-stderr.txt"
$deviceInfo = Join-Path $sessionDir "00-device-info.txt"

@(
    "CapturedAt=$(Get-Date -Format o)"
    "Package=$Package"
    "ADB=$((Get-Command adb).Source)"
    ""
    "=== adb devices -l ==="
    (& adb devices -l 2>&1)
    ""
    "=== getprop ==="
    (& adb shell getprop 2>&1)
    ""
    "=== package version ==="
    (& adb shell dumpsys package $Package 2>&1 | Select-String -Pattern "versionName=|versionCode=|firstInstallTime=|lastUpdateTime=")
) | Out-File -FilePath $deviceInfo -Encoding utf8

if (-not $NoClear) {
    & adb logcat -c
}

# Важно: не используем --pid. После холодного старта PID изменится,
# но поток logcat продолжит собирать события нового процесса.
$logcatProcess = Start-Process `
    -FilePath "adb" `
    -ArgumentList @("logcat", "-b", "all", "-v", "threadtime") `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $rawLog `
    -RedirectStandardError $logcatErr

Write-Host ""
Write-Host "Сбор логов запущен." -ForegroundColor Green
Write-Host "Каталог: $sessionDir"
Write-Host "PID adb logcat: $($logcatProcess.Id)"
Write-Host ""
Write-Host "Перед каждым сценарием ставь метку, например:" -ForegroundColor Cyan
Write-Host '  adb shell log -p i -t OREX_TEST "CASE=03 PROCESS_KILLED START"'
Write-Host '  adb shell log -p i -t OREX_TEST "CASE=03 ANSWER_TAPPED"'
Write-Host '  adb shell log -p i -t OREX_TEST "CASE=03 END result=FAIL connecting_timeout"'
Write-Host ""
Write-Host "Полезные способы закрытия:" -ForegroundColor Cyan
Write-Host "  Фон:             нажать Home"
Write-Host "  Убрать из recent: смахнуть карточку вручную"
Write-Host "  Убить процесс:   adb shell am kill $Package"
Write-Host "  Force-stop:      adb shell am force-stop $Package"
Write-Host ""
Write-Host "Force-stop — отдельный сценарий: Android переводит пакет в stopped-state,"
Write-Host "поэтому push обычно не разбудит приложение до ручного запуска."
Write-Host ""
Read-Host "Проведи тесты, затем нажми Enter здесь для остановки и упаковки логов"

if (-not $logcatProcess.HasExited) {
    Stop-Process -Id $logcatProcess.Id -Force
}
Start-Sleep -Milliseconds 500

Invoke-AdbToFile -Arguments @("shell", "dumpsys", "activity", "processes") `
    -Path (Join-Path $sessionDir "10-dumpsys-activity-processes.txt")
Invoke-AdbToFile -Arguments @("shell", "dumpsys", "activity", "activities") `
    -Path (Join-Path $sessionDir "11-dumpsys-activity-activities.txt")
Invoke-AdbToFile -Arguments @("shell", "dumpsys", "notification") `
    -Path (Join-Path $sessionDir "12-dumpsys-notification.txt")
Invoke-AdbToFile -Arguments @("shell", "dumpsys", "telecom") `
    -Path (Join-Path $sessionDir "13-dumpsys-telecom.txt")
Invoke-AdbToFile -Arguments @("shell", "dumpsys", "package", $Package) `
    -Path (Join-Path $sessionDir "14-dumpsys-package.txt")
Invoke-AdbToFile -Arguments @("shell", "dumpsys", "deviceidle") `
    -Path (Join-Path $sessionDir "15-dumpsys-deviceidle.txt")
Invoke-AdbToFile -Arguments @("shell", "dumpsys", "power") `
    -Path (Join-Path $sessionDir "16-dumpsys-power.txt")
Invoke-AdbToFile -Arguments @("shell", "dumpsys", "audio") `
    -Path (Join-Path $sessionDir "17-dumpsys-audio.txt")

$focusPattern = @(
    "OREX_TEST",
    "ru\.orex\.messenger",
    "\bOrex",
    "\bflutter\b",
    "AndroidRuntime",
    "FATAL EXCEPTION",
    "ANR in ",
    "ActivityManager",
    "ActivityTaskManager",
    "Firebase",
    "\bFCM\b",
    "Telecom",
    "CallsManager",
    "CallSession",
    "CallControl",
    "LiveKit",
    "FlutterWebRTC",
    "MediaConnectException",
    "MediaPlayer",
    "AudioManager",
    "AudioTrack",
    "AudioRecord",
    "NotificationManager",
    "WindowManager"
) -join "|"

if (Test-Path $rawLog) {
    Get-Content -Path $rawLog |
        Select-String -Pattern $focusPattern |
        ForEach-Object { $_.Line } |
        Out-File -FilePath $focusedLog -Encoding utf8
}

if ($Bugreport) {
    Write-Host "Снимаю adb bugreport — файл может быть большим..." -ForegroundColor Yellow
    $bugreportPath = Join-Path $sessionDir "20-bugreport.zip"
    & adb bugreport $bugreportPath
}

$zipPath = "$sessionDir.zip"
Compress-Archive -Path (Join-Path $sessionDir "*") -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Готово." -ForegroundColor Green
Write-Host "Полный архив: $zipPath"
Write-Host "Для быстрой диагностики можно сначала отправлять:"
Write-Host "  $focusedLog"
Write-Host ""
Write-Host "Перед отправкой проверь файлы на access token, FCM token, пароли и приватные URL."
