<#
.SYNOPSIS
    Graphical control panel for the token-reduction stack.

.DESCRIPTION
    A WPF front end over install.ps1. It does not reimplement any of the
    install logic - it builds an argument list, runs install.ps1 in a
    background job, and streams the output into a log pane. Everything the
    GUI can do, the CLI can do; the GUI adds the part the CLI cannot: a live
    view of what is currently installed in the selected project.

    Deliberately ASCII-only. install.ps1 needs a UTF-8 BOM because it contains
    em-dashes that PowerShell 5.1 misreads as ANSI; this file avoids the issue
    entirely by using no non-ASCII characters, so an editor that strips the BOM
    cannot break it.

.PARAMETER ProjectPath
    Pre-fill the project box. Defaults to the current directory.

.EXAMPLE
    .\token-stack-gui.ps1
    .\token-stack-gui.ps1 -ProjectPath C:\code\my-app
#>
[CmdletBinding()]
param(
    [string] $ProjectPath = (Get-Location).Path
)

# WPF requires a single-threaded apartment. Windows PowerShell 5.1 is STA by
# default, but pwsh 7 is MTA and the ISE varies - relaunch instead of failing.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $self  = $MyInvocation.MyCommand.Definition
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $psExe -NoProfile -STA -File $self -ProjectPath $ProjectPath
    return
}

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$InstallScript = Join-Path $ScriptRoot 'install.ps1'
if (-not (Test-Path $InstallScript)) { throw "install.ps1 not found next to this script: $InstallScript" }

$PsExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

# ===========================================================================
# Layout
# ===========================================================================
[xml] $Xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Token stack - control panel"
        Width="960" Height="740" MinWidth="820" MinHeight="620"
        WindowStartupLocation="CenterScreen" Background="#F5F6F7">
  <Grid Margin="14">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- project -->
    <GroupBox Grid.Row="0" Header="Project" Padding="10" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox x:Name="ProjectBox" Grid.Column="0" Height="26" VerticalContentAlignment="Center" Padding="6,0"/>
        <Button x:Name="BrowseBtn" Grid.Column="1" Content="Browse..." Width="90" Height="26" Margin="8,0,0,0"/>
      </Grid>
    </GroupBox>

    <!-- options -->
    <GroupBox Grid.Row="1" Header="Options" Padding="10" Margin="0,0,0,10">
      <StackPanel Orientation="Horizontal">
        <CheckBox x:Name="DryRunChk"    Content="Dry run (write nothing)" VerticalAlignment="Center"/>
        <CheckBox x:Name="SkipProxyChk" Content="Skip proxy wiring"       VerticalAlignment="Center" Margin="20,0,0,0"/>
        <CheckBox x:Name="UpgradeChk"   Content="Upgrade tool packages"   VerticalAlignment="Center" Margin="20,0,0,0"/>
        <TextBlock Text="Port" VerticalAlignment="Center" Margin="28,0,6,0"/>
        <TextBox x:Name="PortBox" Text="8787" Width="60" Height="24" VerticalContentAlignment="Center" Padding="4,0"/>
        <TextBlock Text="Tools home" VerticalAlignment="Center" Margin="20,0,6,0"/>
        <TextBox x:Name="ToolsBox" Width="230" Height="24" VerticalContentAlignment="Center" Padding="4,0"/>
      </StackPanel>
    </GroupBox>

    <!-- install actions -->
    <GroupBox Grid.Row="2" Header="Install" Padding="10" Margin="0,0,0,10">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="PreviewBtn"   Content="Preview (dry run)" Width="130" Height="30"/>
        <Button x:Name="InstallBtn"   Content="Install"           Width="110" Height="30" Margin="8,0,0,0" FontWeight="SemiBold"/>
        <Button x:Name="UninstallBtn" Content="Uninstall"         Width="110" Height="30" Margin="8,0,0,0"/>
        <CheckBox x:Name="RemoveToolsChk" Content="also delete shared venv" VerticalAlignment="Center" Margin="10,0,0,0"/>
        <Button x:Name="CancelBtn"    Content="Cancel"            Width="90"  Height="30" Margin="24,0,0,0" IsEnabled="False"/>
      </StackPanel>
    </GroupBox>

    <!-- run actions -->
    <GroupBox Grid.Row="3" Header="Run and measure" Padding="10" Margin="0,0,0,10">
      <StackPanel Orientation="Horizontal">
        <Button x:Name="ProxyBtn"     Content="Start proxy"  Width="110" Height="30"/>
        <Button x:Name="BaselineBtn"  Content="Measure"      Width="90"  Height="30" Margin="8,0,0,0"/>
        <TextBlock Text="label" VerticalAlignment="Center" Margin="8,0,6,0"/>
        <TextBox x:Name="LabelBox" Text="baseline" Width="120" Height="24" VerticalContentAlignment="Center" Padding="4,0"/>
        <Button x:Name="DashboardBtn" Content="Dashboard"    Width="100" Height="30" Margin="16,0,0,0"/>
        <Button x:Name="GraphifyBtn"  Content="Link graphify" Width="110" Height="30" Margin="8,0,0,0"/>
        <Button x:Name="FolderBtn"    Content="Open folder"  Width="100" Height="30" Margin="8,0,0,0"/>
      </StackPanel>
    </GroupBox>

    <!-- status -->
    <GroupBox Grid.Row="4" Header="Current state" Padding="10" Margin="0,0,0,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel x:Name="StatusLeft"  Grid.Column="0"/>
        <StackPanel x:Name="StatusRight" Grid.Column="1"/>
        <Button x:Name="RefreshBtn" Grid.Column="2" Content="Refresh" Width="80" Height="26" VerticalAlignment="Top"/>
      </Grid>
    </GroupBox>

    <!-- log -->
    <GroupBox Grid.Row="5" Header="Output" Padding="6">
      <TextBox x:Name="LogBox" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
               Background="#1E1E1E" Foreground="#D4D4D4" BorderThickness="0"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
               TextWrapping="NoWrap" AcceptsReturn="True"/>
    </GroupBox>

    <!-- footer -->
    <Grid Grid.Row="6" Margin="0,10,0,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <ProgressBar x:Name="Progress" Grid.Column="0" Height="6" IsIndeterminate="False" Visibility="Hidden"/>
      <TextBlock x:Name="StatusText" Grid.Column="1" Text="Ready" Margin="12,0,0,0" Foreground="#5F6368"/>
    </Grid>
  </Grid>
</Window>
'@

$Window = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $Xaml))

foreach ($n in @('ProjectBox','BrowseBtn','DryRunChk','SkipProxyChk','UpgradeChk','PortBox','ToolsBox',
                 'PreviewBtn','InstallBtn','UninstallBtn','RemoveToolsChk','CancelBtn',
                 'ProxyBtn','BaselineBtn','LabelBox','DashboardBtn','GraphifyBtn','FolderBtn',
                 'StatusLeft','StatusRight','RefreshBtn','LogBox','Progress','StatusText')) {
    Set-Variable -Name $n -Value $Window.FindName($n) -Scope Script
}

$ProjectBox.Text = $ProjectPath
$ToolsBox.Text   = Join-Path $HOME '.token-tools'

# ===========================================================================
# Helpers
# ===========================================================================
function Add-Log {
    param([string] $Text)
    if ($null -eq $Text) { return }
    # A long install can emit thousands of lines; keep the box from growing
    # without bound or the UI starts to stutter on append.
    if ($LogBox.LineCount -gt 4000) { $LogBox.Clear(); $LogBox.AppendText("[log trimmed]`r`n") }
    $LogBox.AppendText($Text.TrimEnd() + "`r`n")
    $LogBox.ScrollToEnd()
}

function Set-Busy {
    param([bool] $Busy, [string] $Message = 'Ready')
    foreach ($b in @($PreviewBtn,$InstallBtn,$UninstallBtn,$ProxyBtn,$BaselineBtn,
                     $DashboardBtn,$GraphifyBtn,$RefreshBtn,$BrowseBtn)) {
        $b.IsEnabled = -not $Busy
    }
    $CancelBtn.IsEnabled = $Busy
    $Progress.IsIndeterminate = $Busy
    $Progress.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    $StatusText.Text = $Message
}

function Read-JsonSafe {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Test-ProxyPort {
    param([int] $Port)
    try {
        $client = New-Object Net.Sockets.TcpClient
        $ok = $client.ConnectAsync('127.0.0.1', $Port).Wait(400)
        $client.Close()
        return $ok
    } catch { return $false }
}

# The shared venv carries tiktoken, so it can run collect.py and dashboard.py
# without involving the project's own interpreter - which is the whole point of
# keeping the two apart. Fall back to PATH only if the venv is not built yet.
function Get-MetricsPython {
    $venvPy = Join-Path $ToolsBox.Text 'venv\Scripts\python.exe'
    if (Test-Path $venvPy) { return $venvPy }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ===========================================================================
# Status panel
# ===========================================================================
$StateColors = @{ ok = '#2E9E5B'; warn = '#C98A00'; bad = '#C0392B'; off = '#9AA0A6' }

function New-StatusRow {
    param([string] $Label, [string] $Value, [string] $State)

    $row = New-Object Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = New-Object Windows.Thickness 0, 3, 0, 3

    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 9; $dot.Height = 9
    $dot.VerticalAlignment = 'Center'
    $dot.Margin = New-Object Windows.Thickness 0, 0, 8, 0
    $dot.Fill = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($StateColors[$State]))

    $lbl = New-Object Windows.Controls.TextBlock
    $lbl.Text = $Label
    $lbl.Width = 110
    $lbl.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#5F6368'))

    $val = New-Object Windows.Controls.TextBlock
    $val.Text = $Value
    $val.TextTrimming = 'CharacterEllipsis'

    $row.Children.Add($dot) | Out-Null
    $row.Children.Add($lbl) | Out-Null
    $row.Children.Add($val) | Out-Null
    return $row
}

function Update-Status {
    $StatusLeft.Children.Clear()
    $StatusRight.Children.Clear()

    $proj  = $ProjectBox.Text.Trim()
    $tools = $ToolsBox.Text.Trim()
    $port  = 8787
    [void][int]::TryParse($PortBox.Text.Trim(), [ref] $port)

    $venvScripts = Join-Path $tools 'venv\Scripts'
    $rows = New-Object Collections.ArrayList

    # -- project ------------------------------------------------------------
    if (-not (Test-Path $proj)) {
        [void] $rows.Add((New-StatusRow 'Project' 'path does not exist' 'bad'))
        $InstallBtn.IsEnabled = $false
    } elseif (Test-Path (Join-Path $proj '.git')) {
        [void] $rows.Add((New-StatusRow 'Project' "git repo: $(Split-Path -Leaf $proj)" 'ok'))
        $InstallBtn.IsEnabled = $true
    } else {
        [void] $rows.Add((New-StatusRow 'Project' 'not a git repo - measurement will not work' 'warn'))
        $InstallBtn.IsEnabled = $true
    }

    # -- shared venv --------------------------------------------------------
    if (Test-Path (Join-Path $venvScripts 'python.exe')) {
        $found = @('headroom.exe','token-savior.exe','graphify.exe') |
                 Where-Object { Test-Path (Join-Path $venvScripts $_) } |
                 ForEach-Object { $_ -replace '\.exe$', '' }
        $state = if ($found.Count -eq 3) { 'ok' } elseif ($found.Count) { 'warn' } else { 'bad' }
        [void] $rows.Add((New-StatusRow 'Tool venv' "$($found.Count)/3 tools: $($found -join ', ')" $state))
    } else {
        [void] $rows.Add((New-StatusRow 'Tool venv' 'not built yet' 'off'))
    }

    # -- MCP servers --------------------------------------------------------
    $mcp = Read-JsonSafe (Join-Path $proj '.mcp.json')
    if ($mcp -and $mcp.mcpServers) {
        $names = @($mcp.mcpServers.PSObject.Properties.Name)
        [void] $rows.Add((New-StatusRow 'MCP servers' ($names -join ', ') 'ok'))
    } else {
        [void] $rows.Add((New-StatusRow 'MCP servers' 'none configured' 'off'))
    }

    # -- proxy wiring -------------------------------------------------------
    $settings = Read-JsonSafe (Join-Path $proj '.claude\settings.local.json')
    $baseUrl = if ($settings -and $settings.env) { $settings.env.ANTHROPIC_BASE_URL } else { $null }
    if ($baseUrl) {
        [void] $rows.Add((New-StatusRow 'Proxy wiring' $baseUrl 'ok'))
    } else {
        [void] $rows.Add((New-StatusRow 'Proxy wiring' 'not set (Claude Code goes direct)' 'off'))
    }

    # -- proxy process ------------------------------------------------------
    if (Test-ProxyPort $port) {
        [void] $rows.Add((New-StatusRow 'Proxy process' "listening on :$port" 'ok'))
    } elseif ($baseUrl) {
        # Wired but down is the one combination that actively breaks Claude Code
        # in this project, so it is called out rather than shown as neutral.
        [void] $rows.Add((New-StatusRow 'Proxy process' "DOWN - Claude Code will fail here" 'bad'))
    } else {
        [void] $rows.Add((New-StatusRow 'Proxy process' 'not running' 'off'))
    }

    # -- graphify graph -----------------------------------------------------
    $graph = Join-Path $proj 'graphify-out\graph.json'
    if (Test-Path $graph) {
        $mb = [math]::Round((Get-Item $graph).Length / 1MB, 1)
        $linked = $mcp -and $mcp.mcpServers -and $mcp.mcpServers.PSObject.Properties.Name -contains 'graphify'
        if ($linked) {
            [void] $rows.Add((New-StatusRow 'graphify' "graph built ($mb MB), linked" 'ok'))
        } else {
            [void] $rows.Add((New-StatusRow 'graphify' "graph built ($mb MB) - not linked, click Link graphify" 'warn'))
        }
    } else {
        [void] $rows.Add((New-StatusRow 'graphify' 'no graph yet - run /graphify in the project' 'off'))
    }

    # -- caveman ------------------------------------------------------------
    if (Test-Path (Join-Path $HOME '.claude\plugins\marketplaces\caveman')) {
        [void] $rows.Add((New-StatusRow 'caveman' 'plugin installed (all projects)' 'ok'))
    } else {
        [void] $rows.Add((New-StatusRow 'caveman' 'not installed - /plugin install caveman@caveman' 'off'))
    }

    # -- metrics ------------------------------------------------------------
    $metrics = Join-Path $proj 'tools\token-metrics\metrics.jsonl'
    if (Test-Path $metrics) {
        $n = @(Get-Content $metrics | Where-Object { $_.Trim() }).Count
        [void] $rows.Add((New-StatusRow 'Measurements' "$n record(s)" 'ok'))
    } else {
        [void] $rows.Add((New-StatusRow 'Measurements' 'none yet' 'off'))
    }

    $split = [math]::Ceiling($rows.Count / 2)
    for ($i = 0; $i -lt $rows.Count; $i++) {
        if ($i -lt $split) { $StatusLeft.Children.Add($rows[$i]) | Out-Null }
        else               { $StatusRight.Children.Add($rows[$i]) | Out-Null }
    }
}

# ===========================================================================
# Background job plumbing
# ===========================================================================
$script:Job = $null

$Timer = New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(250)

$Timer.Add_Tick({
    if (-not $script:Job) { $Timer.Stop(); return }

    $new = Receive-Job $script:Job -ErrorAction SilentlyContinue
    foreach ($line in @($new)) { Add-Log ([string] $line) }

    if (@('Completed','Failed','Stopped') -contains $script:Job.State) {
        $Timer.Stop()
        $state = $script:Job.State
        Remove-Job $script:Job -Force -ErrorAction SilentlyContinue
        $script:Job = $null
        Set-Busy $false ("Finished ($state)")
        Add-Log ''
        Update-Status
    }
})

function Start-BackgroundRun {
    param([string] $Exe, [string[]] $Arguments, [string] $Caption)

    if ($script:Job) { return }
    Add-Log "==> $Caption"
    Add-Log "    $Exe $($Arguments -join ' ')"
    Add-Log ''

    $script:Job = Start-Job -ScriptBlock {
        param($exe, $argv)
        # 2>&1 folds stderr in so pip warnings land in the log instead of
        # vanishing. No -ExecutionPolicy override: if a file is blocked we want
        # to see that and unblock it deliberately, not paper over it.
        & $exe @argv 2>&1 | ForEach-Object { $_.ToString() }
        "[exit code $LASTEXITCODE]"
    } -ArgumentList $Exe, $Arguments

    Set-Busy $true $Caption
    $Timer.Start()
}

function Get-InstallerArgs {
    param([string[]] $Extra)
    $port = 8787
    [void][int]::TryParse($PortBox.Text.Trim(), [ref] $port)
    $a = @('-NoProfile', '-File', $InstallScript,
           '-ProjectPath', $ProjectBox.Text.Trim(),
           '-ToolsHome',   $ToolsBox.Text.Trim(),
           '-Port',        "$port")
    if ($SkipProxyChk.IsChecked) { $a += '-SkipProxy' }
    if ($UpgradeChk.IsChecked)   { $a += '-Upgrade' }
    return $a + $Extra
}

# ===========================================================================
# Handlers
# ===========================================================================
$BrowseBtn.Add_Click({
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Select the project to configure'
    if (Test-Path $ProjectBox.Text) { $dlg.SelectedPath = $ProjectBox.Text }
    if ($dlg.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        $ProjectBox.Text = $dlg.SelectedPath
        Update-Status
    }
})

$ProjectBox.Add_LostFocus({ Update-Status })
$ToolsBox.Add_LostFocus({ Update-Status })
$PortBox.Add_LostFocus({ Update-Status })
$RefreshBtn.Add_Click({ Update-Status; $StatusText.Text = 'Refreshed' })

$PreviewBtn.Add_Click({
    Start-BackgroundRun $PsExe (Get-InstallerArgs @('-DryRun')) 'Preview (dry run)'
})

$InstallBtn.Add_Click({
    $extra = @()
    if ($DryRunChk.IsChecked) { $extra += '-DryRun' }
    Start-BackgroundRun $PsExe (Get-InstallerArgs $extra) 'Install'
})

$UninstallBtn.Add_Click({
    $msg = "Remove the token stack configuration from`n`n$($ProjectBox.Text)`n`n" +
           "metrics.jsonl is kept either way."
    if ($RemoveToolsChk.IsChecked) { $msg += "`n`nThe shared venv will ALSO be deleted - other projects use it." }
    $answer = [Windows.MessageBox]::Show($msg, 'Confirm uninstall', 'YesNo', 'Warning')
    if ($answer -ne 'Yes') { return }

    $extra = @('-Uninstall')
    if ($RemoveToolsChk.IsChecked) { $extra += '-RemoveTools' }
    if ($DryRunChk.IsChecked)      { $extra += '-DryRun' }
    Start-BackgroundRun $PsExe (Get-InstallerArgs $extra) 'Uninstall'
})

$CancelBtn.Add_Click({
    if (-not $script:Job) { return }
    Stop-Job $script:Job -ErrorAction SilentlyContinue
    Add-Log '[cancelled - a partially finished install can be repaired by running Install again]'
})

# The proxy is long-lived, so it gets its own visible console rather than a
# background job: the user needs somewhere to watch it and press Ctrl+C.
$ProxyBtn.Add_Click({
    $port = 8787
    [void][int]::TryParse($PortBox.Text.Trim(), [ref] $port)
    $headroom = Join-Path $ToolsBox.Text 'venv\Scripts\headroom.exe'
    if (-not (Test-Path $headroom)) {
        [void][Windows.MessageBox]::Show('headroom.exe not found. Install first.', 'Not installed', 'OK', 'Warning')
        return
    }
    if (Test-ProxyPort $port) {
        Add-Log "Proxy already listening on :$port - not starting a second one."
        return
    }
    Start-Process $PsExe -ArgumentList @('-NoExit','-NoProfile','-Command', "& '$headroom' proxy --port $port")
    Add-Log "Started the proxy in its own window on :$port. Leave it running."
    $StatusText.Text = 'Proxy starting'
})

$BaselineBtn.Add_Click({
    $py = Get-MetricsPython
    $collect = Join-Path $ProjectBox.Text.Trim() 'tools\token-metrics\collect.py'
    if (-not $py -or -not (Test-Path $collect)) {
        [void][Windows.MessageBox]::Show('collect.py or a Python interpreter is missing. Install first.', 'Not ready', 'OK', 'Warning')
        return
    }
    $label = $LabelBox.Text.Trim()
    if (-not $label) { $label = 'run' }
    Start-BackgroundRun $py @($collect, '--label', $label) "Measure ($label)"
})

$DashboardBtn.Add_Click({
    $py = Get-MetricsPython
    $dash = Join-Path $ProjectBox.Text.Trim() 'tools\token-metrics\dashboard.py'
    if (-not $py -or -not (Test-Path $dash)) {
        [void][Windows.MessageBox]::Show('dashboard.py or a Python interpreter is missing. Install first.', 'Not ready', 'OK', 'Warning')
        return
    }
    Start-BackgroundRun $py @($dash, '--open') 'Render dashboard'
})

# Linking graphify is just a re-run: install.ps1 wires it only when the graph
# already exists, so this is the documented second pass with a button on it.
$GraphifyBtn.Add_Click({
    $graph = Join-Path $ProjectBox.Text.Trim() 'graphify-out\graph.json'
    if (-not (Test-Path $graph)) {
        [void][Windows.MessageBox]::Show(
            "No graphify-out\graph.json in this project yet.`n`nBuild it first by running /graphify inside Claude Code, then click this again.",
            'Graph not built', 'OK', 'Information')
        return
    }
    Start-BackgroundRun $PsExe (Get-InstallerArgs @()) 'Link graphify (re-run installer)'
})

$FolderBtn.Add_Click({
    $p = $ProjectBox.Text.Trim()
    if (Test-Path $p) { Start-Process explorer.exe $p }
})

$Window.Add_Closing({
    if ($script:Job) {
        Stop-Job $script:Job -ErrorAction SilentlyContinue
        Remove-Job $script:Job -Force -ErrorAction SilentlyContinue
    }
    $Timer.Stop()
})

# ===========================================================================
Add-Log 'Token stack control panel'
Add-Log "installer : $InstallScript"
Add-Log ''
Add-Log 'Pick a project, click Preview to see the plan, then Install.'
Add-Log ''
Update-Status
[void] $Window.ShowDialog()
