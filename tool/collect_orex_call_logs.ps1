[CmdletBinding()]
param(
    [string]$Package = "ru.orex.messenger",
    [string]$OutputRoot = ".\orex-test-logs",
    [string]$Serial,
    [switch]$NoClear,
    [switch]$Bugreport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$collector = Join-Path $PSScriptRoot "collect_orex_android_logs.ps1"
$params = @{
    Area = "calls"
    Package = $Package
    OutputRoot = $OutputRoot
}
if ($Serial) { $params["Serial"] = $Serial }
if ($NoClear) { $params["NoClear"] = $true }
if ($Bugreport) { $params["Bugreport"] = $true }

& $collector @params
