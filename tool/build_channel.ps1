param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("debug", "stable")]
    [string]$Channel,

    [switch]$DebugLogs,

    [switch]$ReuseFlutterBuilds
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$PreviousAndroidDistribution = $env:OREX_ANDROID_DISTRIBUTION
$PreviousWindowsChannel = $env:OREX_WINDOWS_CHANNEL

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw ("Native command failed with exit code {0}: {1}" -f $LASTEXITCODE, $FilePath)
    }
}

function Restore-EnvironmentVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        Remove-Item ("Env:{0}" -f $Name) -ErrorAction SilentlyContinue
    }
    else {
        Set-Item ("Env:{0}" -f $Name) $Value
    }
}

Push-Location $RepoRoot
try {
    Write-Host "=== Reading version from pubspec.yaml ==="

    $Pubspec = Get-Content (Join-Path $RepoRoot "pubspec.yaml") -Raw
    $VersionMatch = [regex]::Match(
        $Pubspec,
        '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$'
    )

    if (-not $VersionMatch.Success) {
        throw "Expected version: X.Y.Z+N in pubspec.yaml"
    }

    $VersionName = "{0}.{1}.{2}" -f $VersionMatch.Groups[1].Value, $VersionMatch.Groups[2].Value, $VersionMatch.Groups[3].Value
    $BuildNumber = $VersionMatch.Groups[4].Value
    $Release = "{0}+{1}" -f $VersionName, $BuildNumber
    $OutputDir = Join-Path $RepoRoot ("updates\{0}\{1}" -f $Channel, $Release)
    $DebugLogsValue = if ($DebugLogs.IsPresent) { "true" } else { "false" }

    Write-Host ("Version: {0}" -f $Release)
    Write-Host ("Channel: {0}" -f $Channel)
    Write-Host ("Output: {0}" -f $OutputDir)

    $AndroidArm64 = Join-Path $RepoRoot "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"
    $AndroidArmV7 = Join-Path $RepoRoot "build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk"
    $WindowsExeName = if ($Channel -eq "debug") {
        "orex_messenger_debug.exe"
    }
    else {
        "orex_messenger.exe"
    }
    $WindowsExe = Join-Path $RepoRoot ("build\windows\x64\runner\Release\{0}" -f $WindowsExeName)

    if ($ReuseFlutterBuilds.IsPresent) {
        Write-Host ""
        Write-Host "=== Reusing existing Flutter artifacts ==="

        foreach ($ArtifactPath in @($AndroidArm64, $AndroidArmV7, $WindowsExe)) {
            if (-not (Test-Path $ArtifactPath)) {
                throw ("Reusable artifact was not found: {0}" -f $ArtifactPath)
            }

            Write-Host ("  {0}" -f $ArtifactPath)
        }
    }
    else {
        Write-Host ""
        Write-Host "=== Building Android APKs ==="
        $env:OREX_ANDROID_DISTRIBUTION = $Channel
        Invoke-NativeCommand -FilePath "flutter" -ArgumentList @(
            "build",
            "apk",
            "--release",
            "--split-per-abi",
            "--no-pub",
            "--dart-define=OREX_ENV=production",
            "--dart-define=OREX_UPDATE_CHANNEL=$Channel",
            "--dart-define=OREX_DEBUG_LOGS=$DebugLogsValue"
        )

        Write-Host ""
        Write-Host "=== Building Windows application ==="
        $env:OREX_WINDOWS_CHANNEL = $Channel
        Invoke-NativeCommand -FilePath "flutter" -ArgumentList @(
            "build",
            "windows",
            "--release",
            "--no-pub",
            "--dart-define=OREX_ENV=production",
            "--dart-define=OREX_UPDATE_CHANNEL=$Channel",
            "--dart-define=OREX_DEBUG_LOGS=$DebugLogsValue"
        )
    }

    Write-Host ""
    Write-Host "=== Building Windows installer ==="
    $IsccCandidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
    )
    $Iscc = $IsccCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if (-not $Iscc) {
        throw "Inno Setup 6 was not found"
    }

    $InstallerOutputDir = Join-Path $RepoRoot ("build\windows\x64\installer\{0}" -f $Channel)
    $InstallerPath = Join-Path $InstallerOutputDir ("Orex-Setup-{0}.exe" -f $Release)
    New-Item -ItemType Directory -Path $InstallerOutputDir -Force | Out-Null
    Remove-Item -Path $InstallerPath -Force -ErrorAction SilentlyContinue

    $IsccArguments = @(
        "/DMyAppVersion=$Release",
        "/DMyAppVersionInfo=$VersionName",
        "windows\installer\orex.iss"
    )

    if ($Channel -eq "debug") {
        $IsccArguments = @("/DOrexDebug") + $IsccArguments
    }

    Invoke-NativeCommand -FilePath $Iscc -ArgumentList $IsccArguments

    if (-not (Test-Path $InstallerPath)) {
        throw ("Installer was not created for channel '{0}': {1}" -f $Channel, $InstallerPath)
    }

    Write-Host ""
    Write-Host "=== Publishing artifacts ==="
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

    $Artifacts = @(
        @{
            Source = $AndroidArm64
            Target = "app-arm64-v8a-$Release.apk"
        },
        @{
            Source = $AndroidArmV7
            Target = "app-armeabi-v7a-$Release.apk"
        },
        @{
            Source = $InstallerPath
            Target = "Orex-Setup-$Release.exe"
        }
    )

    foreach ($Artifact in $Artifacts) {
        if (-not (Test-Path $Artifact.Source)) {
            throw ("Artifact was not found: {0}" -f $Artifact.Source)
        }

        $Destination = Join-Path $OutputDir $Artifact.Target
        Copy-Item -Path $Artifact.Source -Destination $Destination -Force
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host "Build completed successfully"
    Write-Host ("Artifacts: {0}" -f $OutputDir)
    foreach ($Artifact in $Artifacts) {
        Write-Host ("  {0}" -f $Artifact.Target)
    }
    Write-Host "========================================"
}
finally {
    Restore-EnvironmentVariable -Name "OREX_ANDROID_DISTRIBUTION" -Value $PreviousAndroidDistribution
    Restore-EnvironmentVariable -Name "OREX_WINDOWS_CHANNEL" -Value $PreviousWindowsChannel
    Pop-Location
}
