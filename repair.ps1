<#
.SYNOPSIS
    Makes an extracted standalone bundle runnable at its current location.

.DESCRIPTION
    A Python venv is not relocatable. The bundle's venv is built in CI at a path
    that exists on no other machine, which leaves two things broken after
    extraction:

      1. venv\pyvenv.cfg points at the CI base interpreter. venv\Scripts\python.exe
         is a stub that reads `home` from that file to find the real interpreter
         and the standard library, so it aborts before running any code.

      2. Every Python console script in venv\Scripts\*.exe embeds the CI venv
         path as a #! line inside the launcher binary. Those shims exit 1 with no
         output — a silent failure. This matters beyond convenience: install.ps1
         writes these paths into the project's .mcp.json, and the web panel's
         proxy button invokes headroom.exe directly, so both fail quietly.

    This script rewrites both to absolute paths under the current bundle
    location. It prefers the interpreter shipped in the bundle at .\python\, so
    no Python needs to be installed on the machine; if that directory is absent
    (older bundle, or a plain git clone) it falls back to a locally installed
    interpreter whose major.minor version matches the venv's.

    bootstrap.ps1 runs this automatically. Run it by hand after moving or copying
    an already-extracted bundle to a new path.

    Idempotent: it detects work already done and skips it.

.PARAMETER PythonHome
    Base interpreter directory to point the venv at, overriding auto-detection.
    Must contain python.exe of the same major.minor version as the venv.

.PARAMETER Quiet
    Print only warnings and errors. Used when invoked from bootstrap.ps1.

.PARAMETER Force
    Re-apply every step even if it looks already done.

.EXAMPLE
    .\repair.ps1

.EXAMPLE
    .\repair.ps1 -PythonHome C:\Python311
#>
[CmdletBinding()]
param(
    [string] $PythonHome,
    [switch] $Quiet,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }

$VenvDir     = Join-Path $Root 'venv'
$VenvScripts = Join-Path $VenvDir 'Scripts'
$VenvPython  = Join-Path $VenvScripts 'python.exe'
$PyvenvCfg   = Join-Path $VenvDir 'pyvenv.cfg'
$BundledPy   = Join-Path $Root 'python'

function Write-Info { param([string] $Text) if (-not $Quiet) { Write-Host "    $Text" -ForegroundColor DarkGray } }
function Write-Did  { param([string] $Text) if (-not $Quiet) { Write-Host "    $Text" -ForegroundColor DarkGreen } }
function Write-Warn { param([string] $Text) Write-Host "    $Text" -ForegroundColor DarkYellow }

# A git clone has no bundled venv; there is nothing to relocate.
if (-not (Test-Path $PyvenvCfg)) {
    Write-Info 'no bundled venv - nothing to repair'
    exit 0
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host '  Bundle repair' -ForegroundColor White
}

# ---------------------------------------------------------------------------
# Resolve a base interpreter of the right version
# ---------------------------------------------------------------------------
$cfg     = Get-Content -Path $PyvenvCfg
$verLine = $cfg | Where-Object { $_ -match '^\s*version\s*=' } | Select-Object -First 1
if (-not $verLine) { throw "venv\pyvenv.cfg has no version line; cannot match a base interpreter." }

$venvVersion = ($verLine -split '=', 2)[1].Trim()
$needMinor   = ($venvVersion -split '\.')[0..1] -join '.'

function Test-Interpreter {
    param([string] $ExePath, [string] $WantMinor)
    if (-not $ExePath) { return $false }
    if (-not (Test-Path $ExePath)) { return $false }
    # WindowsApps entries are Store launcher stubs, not usable as a venv base.
    if ($ExePath -like '*\WindowsApps\*') { return $false }
    $v = & $ExePath -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return ($v -and $v.Trim() -eq $WantMinor)
}

$homeLine    = $cfg | Where-Object { $_ -match '^\s*home\s*=' } | Select-Object -First 1
$currentHome = if ($homeLine) { ($homeLine -split '=', 2)[1].Trim() } else { '' }

if (-not $PythonHome) {
    # 1. The interpreter shipped inside the bundle. Preferred: it makes the
    #    bundle self-contained and its version always matches the venv.
    if (Test-Interpreter (Join-Path $BundledPy 'python.exe') $needMinor) {
        $PythonHome = $BundledPy
    }
    # 2. Already-valid home from a previous repair or a local build.
    elseif (-not $Force -and (Test-Interpreter (Join-Path $currentHome 'python.exe') $needMinor)) {
        $PythonHome = $currentHome
    }
    # 3. A locally installed interpreter of the same major.minor version.
    else {
        $candidates = @()
        foreach ($cmd in @('python', 'python3', 'py')) {
            $c = Get-Command $cmd -ErrorAction SilentlyContinue
            if ($c -and $c.Source) { $candidates += $c.Source }
        }
        $flat = $needMinor -replace '\.', ''
        $candidates += @(
            "$env:LOCALAPPDATA\Programs\Python\Python$flat\python.exe",
            "$env:ProgramFiles\Python$flat\python.exe",
            "C:\Python$flat\python.exe"
        )
        foreach ($cand in ($candidates | Select-Object -Unique)) {
            if (Test-Interpreter $cand $needMinor) { $PythonHome = Split-Path -Parent $cand; break }
        }
    }
}

if (-not $PythonHome) {
    Write-Host ''
    Write-Host "  This bundle's venv needs a Python $needMinor base interpreter and none was found." -ForegroundColor Red
    Write-Host "  Expected it inside the bundle at:" -ForegroundColor Yellow
    Write-Host "    $BundledPy" -ForegroundColor White
    Write-Host "  That directory is missing, so this bundle was built before the interpreter" -ForegroundColor Yellow
    Write-Host "  was included. Either download a newer release, install Python $venvVersion," -ForegroundColor Yellow
    Write-Host "  or pass an existing one explicitly:" -ForegroundColor Yellow
    Write-Host "    .\repair.ps1 -PythonHome C:\Path\To\Python$($needMinor -replace '\.','')" -ForegroundColor White
    Write-Host ''
    Write-Host "  The version must match exactly - the bundled packages contain" -ForegroundColor Yellow
    Write-Host "  $needMinor-tagged binaries that will not load on another minor version." -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

# ---------------------------------------------------------------------------
# 1. pyvenv.cfg
# ---------------------------------------------------------------------------
$basePython = Join-Path $PythonHome 'python.exe'
if (-not $Force -and $currentHome -eq $PythonHome) {
    Write-Info "base interpreter already correct: $PythonHome"
} else {
    if (-not (Test-Path "$PyvenvCfg.bak")) { Copy-Item $PyvenvCfg "$PyvenvCfg.bak" -Force }
    @(
        "home = $PythonHome"
        'include-system-site-packages = false'
        "version = $venvVersion"
        "executable = $basePython"
        "command = $basePython -m venv $VenvDir"
    ) | Set-Content -Path $PyvenvCfg -Encoding utf8
    Write-Did "base interpreter -> $PythonHome"
}

# ---------------------------------------------------------------------------
# 2. Console-script shims
# ---------------------------------------------------------------------------
# Done in Python: the target path is a byte string inside a binary launcher.
# The launcher scans for the #! marker rather than using a fixed offset, so a
# replacement of a different length is safe.
$patcher = @'
import re, sys
from pathlib import Path

scripts = Path(sys.argv[1])
force = len(sys.argv) > 2 and sys.argv[2] == 'force'
want = ('#!' + str(scripts / 'python.exe')).encode('utf-8')
# Non-greedy up to a trailing python.exe/pythonw.exe, no newlines or NULs, so
# this cannot run past the shebang into the zip payload that follows it.
pattern = re.compile(rb'#![^\r\n\x00]{0,300}?[\\/]python(?:w)?\.exe')

patched, already, failed = 0, 0, []
for exe in sorted(scripts.glob('*.exe')):
    try:
        data = exe.read_bytes()
    except OSError as e:
        failed.append('%s: %s' % (exe.name, e))
        continue
    m = pattern.search(data)
    if not m:
        continue                      # native binary or the interpreter stub
    if m.group(0) == want and not force:
        already += 1
        continue
    try:
        exe.write_bytes(data[:m.start()] + want + data[m.end():])
        patched += 1
    except OSError as e:
        failed.append('%s: %s' % (exe.name, e))

print('shims patched=%d already_ok=%d' % (patched, already))

# Verify by re-reading rather than trusting the write. This is the only
# CLI-independent proof that the rewrite took: asserting through a tool's
# --version couples the check to that tool's flags, which change between
# releases, and a launcher that cannot start is indistinguishable from a CLI
# that rejected the flag by exit code alone.
stale = []
for exe in sorted(scripts.glob('*.exe')):
    data = exe.read_bytes()
    m = pattern.search(data)
    if m and m.group(0) != want:
        stale.append('%s -> %s' % (exe.name, m.group(0)[2:].decode('utf-8', 'replace')))
for s in stale:
    print('STALE ' + s)
for f in failed:
    print('FAILED ' + f)
sys.exit(1 if (failed or stale) else 0)
'@

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "tokenstack-shims-$PID.py"
Set-Content -Path $tmp -Value $patcher -Encoding utf8
try {
    $shimArgs = @($tmp, $VenvScripts)
    if ($Force) { $shimArgs += 'force' }
    $out = & $VenvPython @shimArgs
    $shimExit = $LASTEXITCODE
    foreach ($line in $out) {
        if ($line -like 'FAILED*' -or $line -like 'STALE*') { Write-Warn $line } else { Write-Did $line }
    }
    if ($shimExit -ne 0) {
        Write-Warn 'some shims still point elsewhere - close any running proxy or MCP server and re-run'
        exit 1
    }
} finally {
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 3. Verify
# ---------------------------------------------------------------------------
# Single quotes inside the Python source: PowerShell strips double quotes when
# handing arguments to a native executable.
& $VenvPython -c 'import fastapi, uvicorn' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '  The venv still cannot import fastapi/uvicorn after repair.' -ForegroundColor Red
    Write-Host "  Base interpreter used: $basePython" -ForegroundColor Yellow
    Write-Host '  If that is a different build of Python than the bundle was made with,' -ForegroundColor Yellow
    Write-Host '  pass the matching one with -PythonHome.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

# Prove a launcher actually starts. headroom.exe is the one the web panel's proxy
# button invokes by absolute path, so it is the one worth probing.
#
# Exit code alone cannot decide this: a CLI that rejects --version and a launcher
# that cannot find its interpreter both exit non-zero. The distinguishing signal
# is output. A broken launcher writes NOTHING at all - no message, no traceback -
# whereas any Python that started produces version text, a usage block, or a
# traceback. So: any output means the shim works, whatever the exit code.
$probeExe = Join-Path $VenvScripts 'headroom.exe'
if (Test-Path $probeExe) {
    $probeOut = Join-Path ([System.IO.Path]::GetTempPath()) "tokenstack-probe-$PID.txt"
    $probeErr = Join-Path ([System.IO.Path]::GetTempPath()) "tokenstack-probe-$PID.err"
    try {
        $proc = Start-Process -FilePath $probeExe -ArgumentList '--version' -Wait -PassThru -NoNewWindow `
                    -RedirectStandardOutput $probeOut -RedirectStandardError $probeErr
        $said = ''
        foreach ($f in @($probeOut, $probeErr)) {
            if (Test-Path $f) { $said += (Get-Content $f -Raw) }
        }
        if ($proc.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($said)) {
            Write-Warn "headroom.exe exits $($proc.ExitCode) without output - its launcher cannot start."
            Write-Warn 'the proxy button and .mcp.json entries would fail silently. Try -Force.'
            exit 1
        }
    } finally {
        Remove-Item $probeOut, $probeErr -Force -ErrorAction SilentlyContinue
    }
}

Write-Did 'bundle ready'
if (-not $Quiet) { Write-Host '' }
exit 0
