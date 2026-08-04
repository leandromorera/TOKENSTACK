<#
.SYNOPSIS
    Smart launcher for token-stack — works from both the standalone zip bundle
    and a plain git clone.

.DESCRIPTION
    STANDALONE BUNDLE (extracted from tokenstack-standalone.zip)
        A pre-built venv lives next to this script at .\venv\. bootstrap.ps1
        detects it, sets ToolsHome to this directory, and launches the web
        control panel immediately — no internet access, no Python install, no
        pip required.

    PLAIN GIT CLONE (cloned from GitHub)
        No bundled venv present. bootstrap.ps1 falls back to the normal flow:
        launches the web panel, which shows the Install button to build the
        shared venv and download packages from PyPI.

    Both paths use token-stack-web.ps1 under the hood; this script only decides
    which ToolsHome to hand it.

.PARAMETER ProjectPath
    Project to pre-select in the control panel. Defaults to current directory.

.PARAMETER Port
    Port for the web panel itself (NOT the Headroom proxy). Default 8799.

.PARAMETER NoBrowser
    Print the URL but do not open a browser tab.

.EXAMPLE
    # From the extracted standalone zip:
    .\bootstrap.ps1 -ProjectPath C:\code\my-app

    # From a git clone (will prompt to install via the web UI):
    .\bootstrap.ps1
#>
[CmdletBinding()]
param(
    [string] $ProjectPath = (Get-Location).Path,
    [int]    $Port        = 8799,
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

$WebScript   = Join-Path $Root 'token-stack-web.ps1'
$BundledPy   = Join-Path $Root 'venv\Scripts\python.exe'
$DefaultHome = Join-Path $HOME '.token-tools'

if (-not (Test-Path $WebScript)) {
    throw "token-stack-web.ps1 not found next to bootstrap.ps1. Ensure the bundle was extracted completely."
}

$extraArgs = @('-ProjectPath', $ProjectPath, '-Port', "$Port")
if ($NoBrowser) { $extraArgs += '-NoBrowser' }

if (Test-Path $BundledPy) {
    # Standalone bundle: the venv is right here. Tell token-stack-web.ps1 to
    # use this directory as ToolsHome so it finds venv\Scripts\python.exe.
    Write-Host ''
    Write-Host '  Token stack - standalone bundle' -ForegroundColor White
    Write-Host "  bundled venv : $Root\venv"
    Write-Host ''
    & $WebScript @extraArgs -ToolsHome $Root
} else {
    # Plain git clone: no bundled venv. Use the default shared-venv location.
    # The web panel's Install button will create it on first use.
    Write-Host ''
    Write-Host '  Token stack - git clone mode (no bundled venv)' -ForegroundColor DarkYellow
    Write-Host "  tools home   : $DefaultHome"
    Write-Host '  Click Install in the web panel to build the shared venv.' -ForegroundColor DarkYellow
    Write-Host ''
    & $WebScript @extraArgs -ToolsHome $DefaultHome
}
