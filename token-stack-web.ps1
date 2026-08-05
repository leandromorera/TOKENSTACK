<#
.SYNOPSIS
    Starts the web control panel for the token-reduction stack.

.DESCRIPTION
    Launches web/server.py on the shared tool venv's Python and opens the
    browser. That venv already carries fastapi and uvicorn - headroom-ai[proxy]
    depends on them - so this costs no new dependency and never touches the
    project's own interpreter.

    Same installer underneath as install.ps1 and token-stack-gui.ps1. Pick
    whichever front end you like:

      install.ps1           command line, zero dependencies
      token-stack-gui.ps1   native WPF window, no browser, no server
      token-stack-web.ps1   this - React in the browser, works over SSH tunnels

    The server binds to 127.0.0.1 and mints a session token, printed as part of
    the URL. Every API call must carry it, because a page you have open in
    another tab could otherwise POST to this port and run an installer.

.PARAMETER ProjectPath
    Project to pre-select. Defaults to the current directory.

.PARAMETER Port
    Port for the panel itself (NOT the Headroom proxy). Default 8799.

.PARAMETER ToolsHome
    Where the shared venv lives. Default ~/.token-tools.

.PARAMETER NoBrowser
    Print the URL but do not open a browser.

.EXAMPLE
    .\token-stack-web.ps1
    .\token-stack-web.ps1 -ProjectPath C:\code\my-app -Port 8801
#>
[CmdletBinding()]
param(
    [string] $ProjectPath = (Get-Location).Path,
    [int]    $Port        = 8799,
    [string] $ToolsHome   = (Join-Path $HOME '.token-tools'),
    [switch] $NoBrowser
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

$Server = Join-Path $ScriptRoot 'web\server.py'
$Dist   = Join-Path $ScriptRoot 'web\app\dist\index.html'
if (-not (Test-Path $Server)) { throw "server.py not found: $Server" }

if (-not (Test-Path $ProjectPath)) { throw "Project path not found: $ProjectPath" }
$ProjectPath = (Resolve-Path $ProjectPath).Path

# The shared venv is the intended interpreter. Falling back to PATH keeps the
# panel usable before the first install, when the venv does not exist yet.
$VenvPython = Join-Path $ToolsHome 'venv\Scripts\python.exe'
if (Test-Path $VenvPython) {
    $python = $VenvPython
} else {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'No Python found. Install Python 3.10+, or run install.ps1 first to build the shared venv.' }
    $python = $cmd.Source
    Write-Host "  shared venv not built yet - using $python" -ForegroundColor DarkYellow
}

# Fail with an instruction rather than a traceback.
& $python -c "import fastapi, uvicorn" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '  fastapi/uvicorn are not available to this interpreter.' -ForegroundColor Yellow
    Write-Host "  Run install.ps1 first - it builds the shared venv, which includes them." -ForegroundColor Yellow
    Write-Host "    $(Join-Path $ScriptRoot 'install.ps1') -ProjectPath $ProjectPath" -ForegroundColor White
    Write-Host ''
    exit 1
}

if (-not (Test-Path $Dist)) {
    Write-Host ''
    Write-Host '  The UI bundle is missing. Build it once with Node:' -ForegroundColor Yellow
    Write-Host "    cd $(Join-Path $ScriptRoot 'web\app')" -ForegroundColor White
    Write-Host '    npm install; npm run build' -ForegroundColor White
    Write-Host ''
    exit 1
}

# Probe the port before uvicorn binds it. Otherwise a panel left running from an
# earlier session produces two misleading symptoms at once: this process prints a
# URL carrying a freshly minted session token and then dies on the bind conflict,
# so the browser reaches the OLD process and reports "Bad or missing session
# token" — which reads like an auth bug rather than a port conflict.
$held = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($held.Count -gt 0) {
    Write-Host ''
    Write-Host "  Port $Port is already in use." -ForegroundColor Yellow
    foreach ($conn in $held) {
        $owner = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
        if ($owner) {
            Write-Host "    held by PID $($owner.Id) ($($owner.ProcessName), started $($owner.StartTime))" -ForegroundColor DarkYellow
        } else {
            Write-Host "    held by PID $($conn.OwningProcess)" -ForegroundColor DarkYellow
        }
    }
    Write-Host ''
    Write-Host '  If that is an older panel, it has its own session token, so a URL printed' -ForegroundColor Yellow
    Write-Host '  by this run would be rejected by it. Either reuse that panel, stop it:' -ForegroundColor Yellow
    Write-Host "    Stop-Process -Id $($held[0].OwningProcess) -Force" -ForegroundColor White
    Write-Host '  or start this one elsewhere:' -ForegroundColor Yellow
    Write-Host "    -Port $($Port + 2)" -ForegroundColor White
    Write-Host ''
    exit 1
}

$serverArgs = @($Server, '--port', "$Port", '--project', $ProjectPath)
if ($NoBrowser) { $serverArgs += '--no-browser' }

Write-Host ''
Write-Host '  Token stack - web control panel' -ForegroundColor White
Write-Host "  python  : $python"
Write-Host "  project : $ProjectPath"
Write-Host ''

& $python @serverArgs
