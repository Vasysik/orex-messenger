[CmdletBinding()]
param(
    [ValidateSet("general", "calls", "push", "media")]
    [string]$Area = "general",
    [string]$Package = "ru.orex.messenger",
    [string]$OutputRoot = ".\orex-test-logs",
    [string]$Serial,
    [switch]$NoClear,
    [switch]$Bugreport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Command adb -ErrorAction SilentlyContinue)) {
    throw "adb не найден в PATH. Добавь Android platform-tools в PATH."
}

& adb start-server | Out-Null
$deviceLines = & adb devices
$connectedSerials = @(
    $deviceLines |
        Select-String -Pattern "^(\S+)\s+device$" |
        ForEach-Object { $_.Matches[0].Groups[1].Value }
)

if ($Serial) {
    if ($connectedSerials -notcontains $Serial) {
        throw "Устройство '$Serial' не найдено в состоянии device. Проверь: adb devices"
    }
    $selectedSerial = $Serial
} else {
    if ($connectedSerials.Count -eq 0) {
        throw "Нет подключённого Android-устройства в состоянии device. Проверь: adb devices"
    }
    if ($connectedSerials.Count -gt 1) {
        throw "Подключено несколько устройств. Передай -Serial <serial>."
    }
    $selectedSerial = $connectedSerials[0]
}

$adbTarget = @("-s", $selectedSerial)
& adb @adbTarget wait-for-device

function Invoke-AdbToFile {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $output = & adb @adbTarget @Arguments 2>&1
    $output | Out-File -FilePath $Path -Encoding utf8
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$sessionDir = Join-Path $OutputRoot "orex-$Area-$stamp"
New-Item -ItemType Directory -Path $sessionDir -Force | Out-Null

$rawLog = Join-Path $sessionDir "01-logcat-full.txt"
$focusedLog = Join-Path $sessionDir "02-logcat-orex-focused.txt"
$logcatErr = Join-Path $sessionDir "03-logcat-stderr.txt"
$deviceInfo = Join-Path $sessionDir "00-device-info.txt"

@(
    "CapturedAt=$(Get-Date -Format o)"
    "Area=$Area"
    "Package=$Package"
    "Serial=$selectedSerial"
    "ADB=$((Get-Command adb).Source)"
    ""
    "=== adb devices -l ==="
    (& adb devices -l 2>&1)
    ""
    "=== getprop ==="
    (& adb @adbTarget shell getprop 2>&1)
    ""
    "=== package version ==="
    (& adb @adbTarget shell dumpsys package $Package 2>&1 |
        Select-String -Pattern "versionName=|versionCode=|firstInstallTime=|lastUpdateTime=")
) | Out-File -FilePath $deviceInfo -Encoding utf8

if (-not $NoClear) {
    & adb @adbTarget logcat -c
}

# Не ограничиваем logcat PID: cold start/recreation меняет PID процесса Orex.
$logcatArgs = @($adbTarget + @("logcat", "-b", "all", "-v", "threadtime"))
$logcatProcess = Start-Process `
    -FilePath "adb" `
    -ArgumentList $logcatArgs `
    -PassThru `
    -NoNewWindow `
    -RedirectStandardOutput $rawLog `
    -RedirectStandardError $logcatErr

Write-Host ""
Write-Host "Сбор Android-диагностики запущен ($Area)." -ForegroundColor Green
Write-Host "Устройство: $selectedSerial"
Write-Host "Каталог: $sessionDir"
Write-Host ""
Write-Host "Перед сценарием можно поставить метку:" -ForegroundColor Cyan
Write-Host ('  adb -s {0} shell log -p i -t OREX_TEST "CASE=01 START"' -f $selectedSerial)
Write-Host ('  adb -s {0} shell log -p i -t OREX_TEST "CASE=01 END result=PASS"' -f $selectedSerial)
Write-Host ""
Read-Host "Воспроизведи сценарий и нажми Enter для остановки и упаковки"

if (-not $logcatProcess.HasExited) {
    Stop-Process -Id $logcatProcess.Id -Force
}
Start-Sleep -Milliseconds 500

$commonDumps = @(
    @{ Name = "10-dumpsys-activity-processes.txt"; Args = @("shell", "dumpsys", "activity", "processes") },
    @{ Name = "11-dumpsys-activity-activities.txt"; Args = @("shell", "dumpsys", "activity", "activities") },
    @{ Name = "12-dumpsys-notification.txt"; Args = @("shell", "dumpsys", "notification") },
    @{ Name = "13-dumpsys-package.txt"; Args = @("shell", "dumpsys", "package", $Package) },
    @{ Name = "14-dumpsys-deviceidle.txt"; Args = @("shell", "dumpsys", "deviceidle") },
    @{ Name = "15-dumpsys-power.txt"; Args = @("shell", "dumpsys", "power") },
    @{ Name = "16-dumpsys-window.txt"; Args = @("shell", "dumpsys", "window") },
    @{ Name = "17-dumpsys-meminfo.txt"; Args = @("shell", "dumpsys", "meminfo", $Package) },
    @{ Name = "18-dumpsys-gfxinfo.txt"; Args = @("shell", "dumpsys", "gfxinfo", $Package) }
)

foreach ($dump in $commonDumps) {
    Invoke-AdbToFile -Arguments $dump.Args -Path (Join-Path $sessionDir $dump.Name)
}

if ($Area -eq "calls") {
    Invoke-AdbToFile -Arguments @("shell", "dumpsys", "telecom") `
        -Path (Join-Path $sessionDir "30-dumpsys-telecom.txt")
    Invoke-AdbToFile -Arguments @("shell", "dumpsys", "audio") `
        -Path (Join-Path $sessionDir "31-dumpsys-audio.txt")
}

if ($Area -eq "push") {
    Invoke-AdbToFile -Arguments @("shell", "dumpsys", "jobscheduler") `
        -Path (Join-Path $sessionDir "30-dumpsys-jobscheduler.txt")
}

if ($Area -eq "media") {
    Invoke-AdbToFile -Arguments @("shell", "dumpsys", "audio") `
        -Path (Join-Path $sessionDir "30-dumpsys-audio.txt")
    Invoke-AdbToFile -Arguments @("shell", "dumpsys", "media.camera") `
        -Path (Join-Path $sessionDir "31-dumpsys-media-camera.txt")
    Invoke-AdbToFile -Arguments @("shell", "dumpsys", "media_projection") `
        -Path (Join-Path $sessionDir "32-dumpsys-media-projection.txt")
}

$focus = @(
    "OREX_TEST",
    "ru\.orex\.messenger",
    "\bOrex",
    "\bflutter\b",
    "AndroidRuntime",
    "FATAL EXCEPTION",
    "ANR in ",
    "ActivityManager",
    "ActivityTaskManager",
    "WindowManager",
    "NotificationManager"
)

switch ($Area) {
    "calls" {
        $focus += @("Telecom", "CallsManager", "CallSession", "CallControl", "LiveKit", "FlutterWebRTC", "AudioManager", "AudioTrack", "AudioRecord")
    }
    "push" {
        $focus += @("OrexPush", "OrexNotifications", "Firebase", "\bFCM\b", "WorkManager", "JobScheduler")
    }
    "media" {
        $focus += @("LiveKit", "FlutterWebRTC", "Camera", "MediaProjection", "ScreenShare", "AudioManager", "AudioTrack", "AudioRecord")
    }
}

if (Test-Path $rawLog) {
    Get-Content -Path $rawLog |
        Select-String -Pattern ($focus -join "|") |
        ForEach-Object { $_.Line } |
        Out-File -FilePath $focusedLog -Encoding utf8
}

if ($Bugreport) {
    Write-Host "Снимаю adb bugreport — файл может быть большим..." -ForegroundColor Yellow
    & adb @adbTarget bugreport (Join-Path $sessionDir "40-bugreport.zip")
}

$zipPath = "$sessionDir.zip"
Compress-Archive -Path (Join-Path $sessionDir "*") -DestinationPath $zipPath -Force

Write-Host ""
Write-Host "Готово: $zipPath" -ForegroundColor Green
Write-Host "Для первого просмотра: $focusedLog"
Write-Host "Перед отправкой проверь архив на access/FCM tokens, пароли и приватные URL."
