<#
.SYNOPSIS
    Removes the Codex Usage Widget from this PC (Windows PowerShell 5.1, no admin).

.DESCRIPTION
    Removes the "Codex Usage Widget watchdog" scheduled task, stops only the Codex widget, removes its
    "Codex Usage Widget.lnk" Startup shortcut and Start menu entry, and deletes %LOCALAPPDATA%\CodexUsageWidget
    (scripts, settings, history, cache, logs). -KeepData keeps settings and history and removes only the scripts.
    Your Codex sign-in and the source folder are never touched.

    Like the installer, it re-runs itself once through a temporary Task Scheduler task when started from a shell
    whose %LOCALAPPDATA% is redirected by an app sandbox, so it removes the real files.

    Run from the unzipped release (or a clone of the repository):
        powershell -NoProfile -ExecutionPolicy Bypass -File .\codex-usage-widget\uninstall.ps1
    or the installed copy:
        powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CodexUsageWidget\uninstall.ps1"
#>
[CmdletBinding()]
param(
    # Started from the widget's menu: no console output expected; show a short confirmation box at the end.
    [switch]$Quiet,
    # Keep settings.json and history.json.
    [switch]$KeepData,
    # Internal: set when re-run through Task Scheduler (outside an app sandbox).
    [string]$TaskLog
)
$ErrorActionPreference = 'Stop'
if ($TaskLog) { try { Start-Transcript -LiteralPath $TaskLog -Force | Out-Null } catch { } }

$InstallDir   = Join-Path $env:LOCALAPPDATA 'CodexUsageWidget'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex Usage Widget.lnk'
$PsExe        = Join-Path $PSHOME 'powershell.exe'

function Say { param([string]$Text) Write-Host $Text }
function Exit-Uninstall {
    param([int]$Code, [string]$Summary)
    if ($Quiet -and -not $TaskLog) {
        try { [void](New-Object -ComObject WScript.Shell).Popup($Summary, 0, 'Codex usage widget', $(if ($Code -eq 0) { 64 } else { 48 })) } catch { }
    }
    if ($TaskLog) { Write-Host "UNINSTALLER-EXIT:$Code"; try { Stop-Transcript | Out-Null } catch { } }
    exit $Code
}

function Test-AppDataRedirected {
    $name = '.usage-widget-probe-' + [Guid]::NewGuid().ToString('N')
    $probe = Join-Path $env:LOCALAPPDATA $name
    try {
        [IO.File]::WriteAllText($probe, 'probe')
        $hits = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "LocalCache\Local\$name") })
        return ($hits.Count -gt 0)
    } catch { return $false }
    finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
}

if (-not $TaskLog -and (Test-AppDataRedirected)) {
    Say 'This shell runs in an app sandbox that redirects %LOCALAPPDATA%; re-running the uninstaller through Task Scheduler...'
    $log = Join-Path $env:USERPROFILE ('usage-widget-uninstall-{0}.log' -f [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $task = 'Usage widget uninstaller ' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -TaskLog "{1}"' -f $PSCommandPath, $log
    if ($KeepData) { $argLine += ' -KeepData' }
    $code = $null
    try {
        $action = New-ScheduledTaskAction -Execute $PsExe -Argument $argLine -WorkingDirectory $env:USERPROFILE
        # Battery-safe settings: the defaults never start the task on battery power (#31).
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        [void](Register-ScheduledTask -TaskName $task -Action $action -Settings $settings -Description 'Temporary: removes the usage widget outside an app sandbox. Removed automatically.' -Force)
        Start-ScheduledTask -TaskName $task
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while ([DateTime]::UtcNow -lt $deadline -and $null -eq $code) {
            Start-Sleep -Milliseconds 700
            if (Test-Path -LiteralPath $log) { $m = [regex]::Match(([IO.File]::ReadAllText($log)), 'UNINSTALLER-EXIT:(\d+)'); if ($m.Success) { $code = [int]$m.Groups[1].Value } }
        }
    } finally { try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop } catch { } }
    if (Test-Path -LiteralPath $log) {
        $stars = 0
        foreach ($l in [IO.File]::ReadAllLines($log)) { if ($l -match '^\*{10}') { $stars++; continue }; if ($stars -eq 2 -and $l -notmatch '^(Transcript started|UNINSTALLER-EXIT:|PS>)') { Say $l } }
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $code) { Say 'FAIL: the uninstaller run through Task Scheduler did not finish in time.'; exit 1 }
    exit $code
}

Say ''
Say 'Codex Usage Widget - uninstaller'
Set-Location -LiteralPath $env:USERPROFILE      # never hold the folder we are about to delete
[Environment]::CurrentDirectory = $env:USERPROFILE   # Set-Location alone leaves the process directory inside it

# 0) watchdog task first, so it cannot start the widget again while it is being removed
$WatchdogTask = 'Codex Usage Widget watchdog'
try {
    if (Get-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $WatchdogTask -Confirm:$false -ErrorAction Stop; Say '  OK   Removed the watchdog task' }
    else { Say '  OK   No watchdog task' }
} catch { Say "  NOTE Could not remove the task $WatchdogTask : $($_.Exception.Message)" }

function Stop-ProcessTree {
    # Stops a process and every descendant: a refresh in flight has a collector child (and maybe the official CLI)
    # that would otherwise keep running and write its state file back into the folder being removed.
    param([int]$RootId)
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
    $ids = New-Object System.Collections.ArrayList
    [void]$ids.Add($RootId)
    for ($i = 0; $i -lt $ids.Count; $i++) {
        foreach ($c in $all) { if ($c.ParentProcessId -eq $ids[$i] -and $c.ProcessId -ne $PID -and -not $ids.Contains([int]$c.ProcessId)) { [void]$ids.Add([int]$c.ProcessId) } }
    }
    for ($i = $ids.Count - 1; $i -ge 1; $i--) { try { Stop-Process -Id $ids[$i] -Force -ErrorAction Stop } catch { } }
    Stop-Process -Id $RootId -Force -ErrorAction Stop   # the caller reports whether the widget itself stopped
}

# 1) stop only this widget (and the collector it may be running)
$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match '(?i)[\\/"\s]codex-usage-widget\.ps1' })
foreach ($p in $procs) { try { Stop-ProcessTree ([int]$p.ProcessId); Say ("  OK   Stopped the widget (PID {0})" -f $p.ProcessId) } catch { Say ("  NOTE Could not stop PID {0}" -f $p.ProcessId) } }
if ($procs.Count -eq 0) { Say '  OK   Widget was not running' } else { Start-Sleep -Milliseconds 800 }

# 2) Startup shortcut
if (Test-Path -LiteralPath $ShortcutPath) {
    try { Remove-Item -LiteralPath $ShortcutPath -Force; Say '  OK   Removed it from Windows startup' } catch { Say "  FAIL Could not remove $ShortcutPath : $($_.Exception.Message)"; Exit-Uninstall 1 'The Codex usage widget could not be removed from Windows startup.' }
} else { Say '  OK   Was not in Windows startup' }
$StartMenuPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Codex Usage Widget.lnk'
if (Test-Path -LiteralPath $StartMenuPath) { try { Remove-Item -LiteralPath $StartMenuPath -Force; Say '  OK   Removed the Start menu entry' } catch { Say "  NOTE Could not remove $StartMenuPath" } }

# 3) files
if (Test-Path -LiteralPath $InstallDir) {
    try {
        if ($KeepData) {
            Get-ChildItem -LiteralPath $InstallDir -File | Where-Object { $_.Extension -in '.ps1', '.tmp' -or $_.Name -like 'usage-cache*' -or $_.Name -like 'collector-state*' } | Remove-Item -Force
            Say "  OK   Removed the program files; kept settings and history in $InstallDir"
        } else {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
            Say "  OK   Deleted $InstallDir"
        }
    } catch { Say "  FAIL Could not delete $InstallDir : $($_.Exception.Message)"; Exit-Uninstall 1 "Some files could not be deleted: $InstallDir" }
} else { Say '  OK   Install folder was already gone' }

Say ''
Say 'Done. The Codex usage widget is removed. Reinstall any time with install.ps1.'
Exit-Uninstall 0 'The Codex usage widget was removed from this PC.'
