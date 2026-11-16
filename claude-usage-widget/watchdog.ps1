<#
.SYNOPSIS
    Watchdog for the Claude Usage Widget: brings the widget back when it died or hung (Windows PowerShell 5.1, no admin).

.DESCRIPTION
    install.ps1 registers the per-user scheduled task "Claude Usage Widget watchdog", which runs this script every
    5 minutes while you are signed in. It changes nothing unless the widget should be running:
      - the user chose Exit (the widget leaves an "exited-by-user" marker; the next start removes it),
      - Start with Windows is off (no Startup shortcut), or the widget is not installed  -> nothing happens.
    Otherwise it starts the widget when no widget process is running, and replaces a widget whose UI heartbeat
    (the "heartbeat" file, rewritten every 20 s by the UI thread) is stale and that is either not responding or was
    already stale on the previous check. Right after sleep the heartbeat is always old, so one stale check alone never
    replaces a healthy widget. Actions are logged to watchdog.log in the widget folder.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$script:AppName      = 'ClaudeUsageWidget'
$script:WidgetFile   = 'claude-usage-widget.ps1'
$script:ProductName  = 'Claude'
$script:StaleSeconds = 180   # heartbeat older than this counts as stale (the UI writes it every 20 s)

function Get-WatchdogAction {
    # Pure decision: 'none', 'start' or 'replace', plus whether this check saw a stale heartbeat.
    param(
        [bool]$Installed,          # widget script present
        [bool]$StartupOn,          # Startup shortcut present (Start with Windows)
        [bool]$ExitedByUser,       # the user chose Exit
        [bool]$Running,            # a widget process exists
        [double]$HeartbeatAge,     # seconds since the UI last wrote its heartbeat (-1 = no heartbeat file)
        [bool]$Responding,         # Windows says the widget's window answers messages
        [bool]$WasStale,           # the previous check also saw a stale heartbeat
        [double]$StaleSeconds = 180
    )
    if (-not $Installed -or -not $StartupOn -or $ExitedByUser) { return @{ action = 'none'; stale = $false } }
    if (-not $Running) { return @{ action = 'start'; stale = $false } }
    $stale = ($HeartbeatAge -ge $StaleSeconds)
    if ($stale -and (-not $Responding -or $WasStale)) { return @{ action = 'replace'; stale = $true } }
    return @{ action = 'none'; stale = $stale }
}

function Write-WatchdogLog {
    param([string]$Line)
    try {
        $log = Join-Path $script:AppDir 'watchdog.log'
        if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 65536) { Move-Item -LiteralPath $log -Destination "$log.1" -Force }
        [IO.File]::AppendAllText($log, ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Line) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Invoke-Watchdog {
    $script:AppDir = Join-Path $env:LOCALAPPDATA $script:AppName
    $widget    = Join-Path $script:AppDir $script:WidgetFile
    $shortcut  = Join-Path ([Environment]::GetFolderPath('Startup')) ('{0} Usage Widget.lnk' -f $script:ProductName)
    $marker    = Join-Path $script:AppDir 'exited-by-user'
    $heartbeat = Join-Path $script:AppDir 'heartbeat'
    $statePath = Join-Path $script:AppDir 'watchdog-state'
    $pattern   = '(?i)[\\/"\s]' + [regex]::Escape($script:WidgetFile)

    $procs = @()
    $installed = Test-Path -LiteralPath $widget -PathType Leaf
    if ($installed) {
        # A failed query must not read as "not running", or a second widget would start (#38).
        try {
            $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction Stop |
                Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match $pattern })
        } catch {
            Write-WatchdogLog "could not list processes ($($_.Exception.Message)); skipped this check"
            return
        }
    }
    $age = -1.0
    if (Test-Path -LiteralPath $heartbeat) { $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $heartbeat).LastWriteTimeUtc).TotalSeconds }
    $responding = $true
    foreach ($p in $procs) { try { if (-not (Get-Process -Id $p.ProcessId -ErrorAction Stop).Responding) { $responding = $false } } catch { } }
    $wasStale = Test-Path -LiteralPath $statePath

    $d = Get-WatchdogAction -Installed $installed -StartupOn (Test-Path -LiteralPath $shortcut) -ExitedByUser (Test-Path -LiteralPath $marker) `
        -Running ($procs.Count -gt 0) -HeartbeatAge $(if ($age -lt 0) { [double]::MaxValue } else { $age }) -Responding $responding -WasStale $wasStale -StaleSeconds $script:StaleSeconds
    if ($d.stale) { try { [IO.File]::WriteAllText($statePath, 'stale') } catch { } }
    elseif ($wasStale) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
    if ($d.action -eq 'none') { return }

    if ($d.action -eq 'replace') {
        # End each widget with its whole tree (the collector and the CLI it runs), so nothing is left behind (#35).
        foreach ($p in $procs) {
            try { & cmd.exe /d /c ('"{0}" /T /F /PID {1} >nul 2>nul' -f [IO.Path]::Combine($env:SystemRoot, 'System32', 'taskkill.exe'), $p.ProcessId) } catch { }
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch { }
        }
        Write-WatchdogLog ('replaced a hung widget (pid {0}; heartbeat {1:N0} s old, responding={2})' -f (($procs | ForEach-Object { $_.ProcessId }) -join ','), $age, $responding)
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    } else {
        Write-WatchdogLog 'widget was not running; started it'
    }
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -WorkingDirectory $env:USERPROFILE -ArgumentList @(
        '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $widget))
}

if ($MyInvocation.InvocationName -ne '.') { try { Invoke-Watchdog } catch { Write-WatchdogLog "watchdog error: $($_.Exception.Message)" } }
