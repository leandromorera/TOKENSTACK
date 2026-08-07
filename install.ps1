<#
.SYNOPSIS
    Installs the token-reduction stack (graphify, Headroom, token-savior, caveman)
    into any project with one command.

.DESCRIPTION
    Two scopes, deliberately separated:

      MACHINE  A single shared venv (default ~/.token-tools/venv) holding the tool
               binaries. Created once, reused by every project.
      PROJECT  Config files and the metrics harness written into the target repo.

    The tools are NEVER installed into the target project's interpreter. Headroom
    pulls its own fastapi/pydantic/openai, which silently upgrades a project's
    pinned versions — the isolated venv exists specifically to prevent that.

.PARAMETER ProjectPath
    Repo to configure. Defaults to the current directory.

.PARAMETER ToolsHome
    Where the shared venv lives. Defaults to ~/.token-tools.

.PARAMETER Port
    Headroom proxy port. Default 8787.

.PARAMETER SkipProxy
    Install the tools but do NOT point Claude Code at the proxy. Use this if you
    would rather start the proxy by hand than have Claude Code depend on it.

.PARAMETER Upgrade
    Upgrade the tool packages in the shared venv.

.PARAMETER DryRun
    Print every action without touching disk.

.PARAMETER Uninstall
    Remove this stack's project-level config. The shared venv is left alone
    unless -RemoveTools is also given.

.PARAMETER RemoveTools
    With -Uninstall, also delete the shared venv.

.EXAMPLE
    .\install.ps1
    .\install.ps1 -ProjectPath C:\code\my-app
    .\install.ps1 -DryRun
    .\install.ps1 -Uninstall -ProjectPath C:\code\my-app
#>

[CmdletBinding()]
param(
    [string] $ProjectPath = (Get-Location).Path,
    [string] $ToolsHome   = (Join-Path $HOME '.token-tools'),
    [int]    $Port        = 8787,
    [switch] $SkipProxy,
    [switch] $Upgrade,
    [switch] $DryRun,
    [switch] $Uninstall,
    [switch] $RemoveTools
)

$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Read packages from requirements-tools.txt when it lives next to this script;
# fall back to the hard-coded list so the script stays self-contained.
$ReqFile = Join-Path $ScriptRoot 'requirements-tools.txt'
if (Test-Path $ReqFile) {
    $Packages = (Get-Content $ReqFile) -notmatch '^\s*#' -notmatch '^\s*$'
} else {
    $Packages = @(
        'headroom-ai[proxy,mcp,code]',
        'token-savior-recall',
        'graphifyy'
    )
}
$CavemanRepo = 'https://github.com/JuliusBrussee/caveman.git'

# --- output helpers ---------------------------------------------------------
function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Info { param($m) Write-Host "    $m" -ForegroundColor DarkGray }
function Write-Warn { param($m) Write-Host "    $m" -ForegroundColor Yellow }

function Invoke-Action {
    param([string] $Description, [scriptblock] $Action)
    if ($DryRun) { Write-Host "    [dry-run] $Description" -ForegroundColor DarkYellow; return }
    Write-Info $Description
    & $Action
}

# $ErrorActionPreference='Stop' promotes ANY native-command stderr to a
# terminating error, and pip routinely writes warnings there. Run native tools
# with that suppressed and judge them on their exit code instead.
function Invoke-Native {
    param([string] $Exe, [string[]] $Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String) }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# One `pip list` beats one `pip show` per package: fewer subprocesses, less noise.
function Get-InstalledPackages {
    param([string] $Python)
    $r = Invoke-Native $Python @('-m', 'pip', 'list', '--format=json', '--disable-pip-version-check')
    $map = @{}
    if ($r.ExitCode -ne 0) { return $map }
    $jsonLine = ($r.Output -split "`n" | Where-Object { $_.TrimStart().StartsWith('[') } | Select-Object -First 1)
    if (-not $jsonLine) { return $map }
    try {
        foreach ($p in (ConvertFrom-Json $jsonLine)) { $map[$p.name.ToLower()] = $p.version }
    } catch { }
    return $map
}

# ConvertFrom-Json -AsHashtable is PowerShell 6+. This script must run on the
# Windows PowerShell 5.1 that ships with Windows, so convert by hand.
function ConvertTo-Hashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return @($InputObject | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    if ($InputObject -is [psobject] -and $InputObject.PSObject.Properties.Name) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $h[$p.Name] = ConvertTo-Hashtable $p.Value
        }
        return $h
    }
    return $InputObject
}

# Read JSON as a hashtable so we merge into what's there rather than clobber it.
function Read-JsonMap {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return @{} }
    $raw = (Get-Content $Path -Raw)
    if (-not $raw -or -not $raw.Trim()) { return @{} }
    try   { $obj = ConvertFrom-Json $raw }
    catch { throw "$Path is not valid JSON. Fix or remove it, then re-run." }
    $map = ConvertTo-Hashtable $obj
    if ($map -isnot [hashtable]) { throw "$Path must contain a JSON object." }
    return $map
}

# PowerShell 5.1's `Set-Content -Encoding utf8` emits a BOM, and a BOM makes a
# .json file unreadable to strict parsers (Python's json.load throws on it).
# Write UTF-8 without BOM explicitly.
function Write-TextFile {
    param([string] $Path, [string] $Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-JsonMap {
    param([string] $Path, [hashtable] $Map, [string] $Label)
    $json = ($Map | ConvertTo-Json -Depth 10)
    Invoke-Action "write $Label" { Write-TextFile $Path $json }
}

# --- resolve paths ----------------------------------------------------------
if (-not (Test-Path $ProjectPath)) { throw "Project path not found: $ProjectPath" }
$ProjectPath = (Resolve-Path $ProjectPath).Path
$ProjectName = Split-Path -Leaf $ProjectPath

$VenvDir     = Join-Path $ToolsHome 'venv'
$VenvScripts = Join-Path $VenvDir 'Scripts'
$VenvPython  = Join-Path $VenvScripts 'python.exe'

$McpFile      = Join-Path $ProjectPath '.mcp.json'
$SettingsFile = Join-Path $ProjectPath '.claude\settings.local.json'
$GitignoreF   = Join-Path $ProjectPath '.gitignore'
$MetricsDir   = Join-Path $ProjectPath 'tools\token-metrics'

# Kept deliberately ASCII-only: .gitignore is read by many tools and there is no
# upside to non-ASCII punctuation in it.
$GitignoreBlock = @(
    '',
    '# Token tooling - machine-local (absolute paths + a localhost proxy)',
    '.claude/settings.local.json',
    '.mcp.json',
    'tools/token-metrics/dashboard.html',
    '',
    '# graphify - machine-local state and regenerable cache',
    'graphify-out/cache/',
    'graphify-out/.graphify_python',
    'graphify-out/.graphify_root',
    'graphify-out/.graphify_labels.json'
)

Write-Host ''
Write-Host '  Token-reduction stack installer' -ForegroundColor White
Write-Host "  project : $ProjectPath"
Write-Host "  tools   : $VenvDir"
if ($DryRun) { Write-Host '  MODE    : dry run — nothing will be written' -ForegroundColor DarkYellow }

# ===========================================================================
# UNINSTALL
# ===========================================================================
if ($Uninstall) {
    Write-Step 'Removing project configuration'

    $mcp = Read-JsonMap $McpFile
    if ($mcp.mcpServers) {
        foreach ($k in @('token-savior', 'headroom', 'graphify')) { $mcp.mcpServers.Remove($k) | Out-Null }
        if ($mcp.mcpServers.Count -eq 0 -and $mcp.Keys.Count -eq 1) {
            Invoke-Action "delete .mcp.json (now empty)" { Remove-Item $McpFile -Force }
        } else {
            Write-JsonMap $McpFile $mcp '.mcp.json (entries removed)'
        }
    } else { Write-Info 'no .mcp.json entries to remove' }

    $settings = Read-JsonMap $SettingsFile
    if ($settings.env -and $settings.env.ContainsKey('ANTHROPIC_BASE_URL')) {
        $settings.env.Remove('ANTHROPIC_BASE_URL') | Out-Null
        if ($settings.env.Count -eq 0) { $settings.Remove('env') | Out-Null }
        if ($settings.Keys.Count -eq 0) {
            Invoke-Action 'delete .claude/settings.local.json (now empty)' { Remove-Item $SettingsFile -Force }
        } else {
            Write-JsonMap $SettingsFile $settings 'settings.local.json (proxy unset)'
        }
    } else { Write-Info 'proxy was not configured' }

    if (Test-Path $MetricsDir) {
        Write-Warn "leaving $MetricsDir in place — it holds metrics.jsonl (your measurement history)."
        Write-Warn 'delete it by hand if you really want the history gone.'
    }

    if ($RemoveTools -and (Test-Path $VenvDir)) {
        Invoke-Action "delete shared venv $VenvDir" { Remove-Item $VenvDir -Recurse -Force }
    } elseif (Test-Path $VenvDir) {
        Write-Info "shared venv kept (other projects may use it). -RemoveTools deletes it."
    }

    Write-Host "`n  Uninstalled. Remove the .gitignore block by hand if you want it gone.`n" -ForegroundColor Green
    return
}

# ===========================================================================
# 1. MACHINE SCOPE — shared tool venv
# ===========================================================================
Write-Step 'Shared tool venv'

if (-not (Test-Path $VenvPython)) {
    # Bootstrap interpreter. Only used to CREATE the venv — nothing is ever
    # installed into it, so using a project interpreter here is harmless.
    $bootstrap = $null
    foreach ($c in @('py', 'python3', 'python')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        # Verify the interpreter actually launches and meets the version floor.
        # The py launcher exists on Windows even when no Python is registered,
        # so checking Get-Command alone is not sufficient.
        $chk = Invoke-Native $cmd.Source @('-c', 'import sys; exit(0 if sys.version_info >= (3,10) else 1)')
        if ($chk.ExitCode -eq 0) { $bootstrap = $cmd.Source; break }
    }
    if (-not $bootstrap) { throw 'No Python 3.10+ found on PATH. Install Python 3.10+ and re-run.' }

    Write-Info "bootstrapping with $bootstrap"
    Invoke-Action "create venv at $VenvDir" {
        & $bootstrap -m venv $VenvDir
        if ($LASTEXITCODE -ne 0) { throw "venv creation failed (exit $LASTEXITCODE)" }
    }
} else {
    Write-Ok 'venv already present'
}

if (-not $DryRun -and (Test-Path $VenvPython)) {
    $installed = Get-InstalledPackages $VenvPython
    foreach ($pkg in $Packages) {
        # A requirement is name + optional extras + optional pin. Splitting on '['
        # alone left the '==x.y.z' glued to the name, so a pinned package with no
        # extras never matched the installed map and was reinstalled every run.
        # The pin also has to be COMPARED, not just parsed: presence-only matching
        # reports a venv sitting on the wrong version as "already installed" and
        # silently leaves it there, which would make pinning decorative.
        if ($pkg -match '^\s*([A-Za-z0-9._-]+)\s*(?:\[[^\]]*\])?\s*(?:==\s*([^\s;]+))?') {
            $name = $Matches[1]
            $want = $Matches[2]
        } else {
            $name = ($pkg -split '\[')[0]
            $want = $null
        }
        $have = $installed[$name.ToLower()]
        if (-not $Upgrade -and $have -and (-not $want -or $have -eq $want)) {
            Write-Ok "$name $have already installed"
            continue
        }
        if ($have -and $want -and $have -ne $want) {
            Write-Info "$name $have installed, pinned at $want - correcting"
        }
        Write-Info "installing $pkg ... (this can take a few minutes)"
        $pipArgs = @('-m', 'pip', 'install', '--quiet', '--disable-pip-version-check')
        if ($Upgrade) { $pipArgs += '--upgrade' }
        $r = Invoke-Native $VenvPython ($pipArgs + $pkg)
        if ($r.ExitCode -ne 0) {
            Write-Warn "$name failed to install — continuing without it"
            Write-Info ($r.Output.Trim() -split "`n" | Select-Object -Last 3 | Out-String).Trim()
        } else {
            Write-Ok "$name installed"
        }
    }
} elseif ($DryRun) {
    foreach ($pkg in $Packages) { Write-Host "    [dry-run] pip install $pkg" -ForegroundColor DarkYellow }
}

# ===========================================================================
# 2. PROJECT SCOPE — metrics harness
# ===========================================================================
Write-Step 'Metrics harness'

$payloadDir = Join-Path $ScriptRoot 'payload'
if (-not (Test-Path $payloadDir)) { throw "Payload directory missing: $payloadDir" }

Invoke-Action "copy collect.py + dashboard.py -> tools\token-metrics\" {
    New-Item -ItemType Directory -Force -Path $MetricsDir | Out-Null
    Copy-Item (Join-Path $payloadDir 'collect.py')   $MetricsDir -Force
    Copy-Item (Join-Path $payloadDir 'dashboard.py') $MetricsDir -Force
}

# metrics.jsonl is measurement history — never overwrite an existing one.
$metricsFile = Join-Path $MetricsDir 'metrics.jsonl'
if (Test-Path $metricsFile) {
    $n = (Get-Content $metricsFile | Measure-Object -Line).Lines
    Write-Ok "metrics.jsonl kept ($n existing record(s))"
}

# ===========================================================================
# 3. PROJECT SCOPE — MCP servers
# ===========================================================================
Write-Step 'MCP servers (.mcp.json)'

# Every entry below is an absolute path to a console-script .exe in the venv.
# Those launchers embed the absolute path of the venv they were BUILT in, so in a
# relocated bundle they exit 1 with no output. Claude Code would then report
# three dead MCP servers every session with nothing to explain it, and the
# installer would look like it had succeeded. Verify one now, and repair the
# whole set rather than writing paths that cannot run.
$probeExe = Join-Path $VenvScripts 'headroom.exe'
if (-not $DryRun -and (Test-Path $probeExe)) {
    $probe = Invoke-Native $probeExe @('--version')
    if ($probe.ExitCode -ne 0) {
        $repair = Join-Path $ScriptRoot 'repair.ps1'
        if (Test-Path $repair) {
            Write-Warn 'console-script shims point at another path - repairing the bundle'
            & $repair -Quiet
            $probe = Invoke-Native $probeExe @('--version')
        }
        if ($probe.ExitCode -ne 0) {
            Write-Warn "headroom.exe still exits $($probe.ExitCode)."
            Write-Warn 'the MCP entries below will be written but will not start. Run repair.ps1 -Force.'
        } else {
            Write-Ok 'console-script shims repaired'
        }
    }
}

$mcp = Read-JsonMap $McpFile
if (-not $mcp.mcpServers) { $mcp.mcpServers = @{} }

$mcp.mcpServers['token-savior'] = @{
    command = (Join-Path $VenvScripts 'token-savior.exe')
    env     = @{
        WORKSPACE_ROOTS       = $ProjectPath
        TOKEN_SAVIOR_CLIENT   = 'claude-code'
        TOKEN_SAVIOR_PROFILE  = 'optimized'
    }
}
$mcp.mcpServers['headroom'] = @{
    command = (Join-Path $VenvScripts 'headroom.exe')
    args    = @('mcp', 'serve')
}

# graphify serves an EXISTING graph. Wiring it before one is built would make
# Claude Code report a failed MCP server every session, so only link it once
# graph.json is on disk — re-run this installer after building the graph.
$GraphJson = Join-Path $ProjectPath 'graphify-out\graph.json'
if (Test-Path $GraphJson) {
    $mcp.mcpServers['graphify'] = @{
        command = (Join-Path $VenvScripts 'graphify-mcp.exe')
        args    = @($GraphJson)
    }
    Write-Ok 'graphify graph found - linked as an MCP server'
} else {
    if ($mcp.mcpServers.ContainsKey('graphify')) { $mcp.mcpServers.Remove('graphify') | Out-Null }
    Write-Info 'no graphify-out\graph.json yet - build the graph, then re-run to link it'
}

Write-JsonMap $McpFile $mcp '.mcp.json'

# ===========================================================================
# 4. PROJECT SCOPE — proxy wiring
# ===========================================================================
Write-Step 'Headroom proxy wiring'

if ($SkipProxy) {
    Write-Info 'skipped (-SkipProxy). Claude Code will not route through Headroom.'
} else {
    $settings = Read-JsonMap $SettingsFile
    if (-not $settings.env) { $settings.env = @{} }
    $settings.env['ANTHROPIC_BASE_URL'] = "http://127.0.0.1:$Port"
    Write-JsonMap $SettingsFile $settings '.claude/settings.local.json'
    Write-Warn "Claude Code in this project now REQUIRES the proxy on :$Port."
    Write-Warn 'If the proxy is down, Claude Code fails. Delete that file to opt out.'
}

# ===========================================================================
# 5. PROJECT SCOPE — gitignore
# ===========================================================================
Write-Step 'gitignore'

if (Test-Path $GitignoreF) {
    $existing = Get-Content $GitignoreF -Raw
    if ($existing -match '\.claude/settings\.local\.json') {
        Write-Ok 'entries already present'
    } else {
        Invoke-Action 'append machine-local entries' {
            $sep = if ($existing.EndsWith("`n")) { '' } else { "`n" }
            Write-TextFile $GitignoreF ($existing + $sep + ($GitignoreBlock -join "`n") + "`n")
        }
    }
} else {
    Invoke-Action 'create .gitignore' {
        Write-TextFile $GitignoreF (($GitignoreBlock -join "`n") + "`n")
    }
}

# ===========================================================================
# 6. Things that cannot be scripted from out here
# ===========================================================================
Write-Step 'Manual steps'

$cavemanInstalled = Test-Path (Join-Path $HOME '.claude\plugins\marketplaces\caveman')
if ($cavemanInstalled) {
    Write-Ok 'caveman plugin already installed'
} else {
    Write-Info 'caveman is a Claude Code plugin — install it from inside Claude Code:'
    Write-Host "      /plugin marketplace add $CavemanRepo" -ForegroundColor White
    Write-Host '      /plugin install caveman@caveman' -ForegroundColor White
    Write-Info 'It compresses OUTPUT tokens only and costs ~1-1.5k input tokens/turn.'
}

$isGit = Test-Path (Join-Path $ProjectPath '.git')
if (-not $isGit) {
    Write-Warn 'This project is not a git repo. collect.py scopes the corpus with'
    Write-Warn '`git ls-files`, so measurement will not work until it is one.'
}

# ===========================================================================
# 7. PROJECT SCOPE — graphify skill + interpreter
# ===========================================================================
Write-Step 'graphify skill'

# pip-installing graphifyy only puts the CLI in the venv. The `/graphify` slash
# command is a separate artifact: a skill directory under ~/.claude/skills that
# the package ships and copies into place on demand. Without this step the
# closing "run /graphify" instruction below names a command that does not exist
# on a fresh machine. `install` is also the documented way to refresh a skill
# left behind by an older graphifyy, so run it every time, not just when the
# directory is missing.
$graphifyExe = Join-Path $VenvScripts 'graphify.exe'
if (Test-Path $graphifyExe) {
    Invoke-Action 'install/update the /graphify skill for Claude Code' {
        $r = Invoke-Native $graphifyExe @('install', '--platform', 'claude')
        if ($r.ExitCode -eq 0) {
            Write-Ok '/graphify available in Claude Code'
        } else {
            Write-Warn "graphify install exited $($r.ExitCode) - /graphify may not exist."
            Write-Warn "Run manually: & '$graphifyExe' install --platform claude"
        }
    }
} else {
    Write-Info 'graphify.exe not in the venv yet - skipping'
}

Write-Step 'graphify interpreter'

# The /graphify skill resolves its interpreter by probing uv, then pipx, then
# whatever `python` is on PATH, and pip-installs graphifyy when none of them can
# import it. It knows nothing about this venv, so on a machine whose PATH Python
# lacks graphify it silently builds a second copy — a few hundred MB of duplicate
# download for a tool already sitting in the shared venv. Writing the marker it
# reads first makes it reuse ours. Both files are gitignored as machine-local.
if (Test-Path $VenvPython) {
    $graphifyOut = Join-Path $ProjectPath 'graphify-out'
    Invoke-Action 'pre-seed graphify-out\.graphify_python' {
        New-Item -ItemType Directory -Force -Path $graphifyOut | Out-Null
        # -NoNewline: the skill reads these files whole and uses them as paths.
        [System.IO.File]::WriteAllText((Join-Path $graphifyOut '.graphify_python'), $VenvPython)
        [System.IO.File]::WriteAllText((Join-Path $graphifyOut '.graphify_root'),   $ProjectPath)
    }
} else {
    Write-Info 'shared venv not built yet - skipping'
}

# ===========================================================================
# Next steps
# ===========================================================================
Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Write-Host '  1. Start the proxy (leave it running):' -ForegroundColor White
Write-Host "       & '$(Join-Path $VenvScripts 'headroom.exe')' proxy --port $Port"
Write-Host ''
# Name the shared venv's interpreter rather than a bare `python`. A standalone
# bundle is meant to work with no Python on PATH, so `python collect.py` is a
# command that cannot run on the machine the bundle was built for.
Write-Host '  2. Take a baseline measurement:' -ForegroundColor White
Write-Host "       & '$VenvPython' '$(Join-Path $MetricsDir 'collect.py')' --label baseline"
Write-Host ''
# Lead with the headless command, not /graphify. Code is extracted by local AST
# with no LLM at all, so `--code-only` builds a graph on any machine with no API
# key, no session, and no network — which is what most projects here need. The
# slash command runs the same pipeline but only from inside a session, and it
# falls back to the host agent for docs and images. Naming the session-only path
# first sent people looking for a command to type in a terminal.
Write-Host '  3. Build the knowledge graph (optional):' -ForegroundColor White
Write-Host "       & '$(Join-Path $VenvScripts 'graphify.exe')' '$ProjectPath' --code-only"
Write-Host '       Local AST only - no API key, no LLM, no network. Drop --code-only'
Write-Host '       to index docs and images too; that part does need an API key.'
Write-Host '       Or run /graphify from inside Claude Code in this project.'
Write-Host '       Then re-run this installer to link the graph as an MCP server.'
Write-Host ''
Write-Host '  4. After some real work, measure again and render:' -ForegroundColor White
Write-Host "       & '$VenvPython' '$(Join-Path $MetricsDir 'collect.py')' --label after"
Write-Host "       & '$VenvPython' '$(Join-Path $MetricsDir 'dashboard.py')' --open"
Write-Host ''
