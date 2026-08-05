<#
.SYNOPSIS
    Smart launcher for token-stack — works from both the standalone zip bundle
    and a plain git clone.

.DESCRIPTION
    STANDALONE BUNDLE (extracted from tokenstack-standalone.zip)
        A pre-built venv lives next to this script at .\venv\, and the matching
        Python interpreter at .\python\. bootstrap.ps1 detects them, runs
        repair.ps1 to bind the venv to this extract location, sets ToolsHome to
        this directory, and launches the web control panel — no internet access,
        no Python install, no pip required.

        The repair step is not optional. A venv is not relocatable: it records
        the absolute path of its base interpreter, and its console-script .exe
        shims embed the absolute path of the venv they were built in. Both point
        at the CI machine until repair.ps1 rewrites them. It is idempotent, so it
        costs nothing on later runs.

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

.PARAMETER SkipRepair
    Do not run repair.ps1 first. Only useful when debugging the repair step
    itself — the bundle does not run without it.

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
    [switch] $NoBrowser,
    [switch] $SkipRepair
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

$WebScript   = Join-Path $Root 'token-stack-web.ps1'
$RepairScript = Join-Path $Root 'repair.ps1'
$BundledPy   = Join-Path $Root 'venv\Scripts\python.exe'
$DefaultHome = Join-Path $HOME '.token-tools'

if (-not (Test-Path $WebScript)) {
    throw "token-stack-web.ps1 not found next to bootstrap.ps1. Ensure the bundle was extracted completely."
}

# Scripts extracted from a downloaded zip carry a Zone.Identifier stream, which
# RemoteSigned rejects. Clearing it here keeps nested script calls from being
# blocked halfway through. Best-effort: not being able to unblock is not fatal.
try {
    Get-ChildItem -Path $Root -Filter *.ps1 -File -ErrorAction Stop | Unblock-File -ErrorAction Stop
} catch {
    Write-Host "  could not clear the zip zone marking: $($_.Exception.Message)" -ForegroundColor DarkYellow
}

if (Test-Path $BundledPy) {
    Write-Host ''
    Write-Host '  Token stack - standalone bundle' -ForegroundColor White
    Write-Host "  bundled venv : $Root\venv"
    Write-Host ''

    # Bind the copied venv to this extract path before anything tries to use it.
    if (-not $SkipRepair) {
        if (-not (Test-Path $RepairScript)) {
            throw "repair.ps1 not found next to bootstrap.ps1. Ensure the bundle was extracted completely."
        }
        & $RepairScript -Quiet
        if ($LASTEXITCODE -ne 0) {
            Write-Host '  Bundle repair failed - see the message above. Aborting.' -ForegroundColor Red
            exit $LASTEXITCODE
        }
    }

    $splat = @{ ProjectPath = $ProjectPath; Port = $Port; ToolsHome = $Root }
    if ($NoBrowser) { $splat['NoBrowser'] = $true }
    & $WebScript @splat
    # Propagate the panel's status. Without this a caller in a script or CI sees
    # success even when the panel refused to start.
    exit $LASTEXITCODE
} else {
    Write-Host ''
    Write-Host '  Token stack - git clone mode (no bundled venv)' -ForegroundColor DarkYellow
    Write-Host "  tools home   : $DefaultHome"
    Write-Host '  Click Install in the web panel to build the shared venv.' -ForegroundColor DarkYellow
    Write-Host ''
    $splat = @{ ProjectPath = $ProjectPath; Port = $Port; ToolsHome = $DefaultHome }
    if ($NoBrowser) { $splat['NoBrowser'] = $true }
    & $WebScript @splat
    exit $LASTEXITCODE
}
