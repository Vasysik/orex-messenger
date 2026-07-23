param(
    [switch]$ReuseFlutterBuilds
)

$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "build_channel.ps1") `
    -Channel debug `
    -DebugLogs `
    -ReuseFlutterBuilds:$ReuseFlutterBuilds
