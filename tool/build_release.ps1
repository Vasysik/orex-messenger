$ErrorActionPreference = "Stop"

& (Join-Path $PSScriptRoot "build_channel.ps1") `
    -Channel stable
