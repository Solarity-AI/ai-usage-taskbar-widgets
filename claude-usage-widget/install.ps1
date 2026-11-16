<#
.SYNOPSIS
    Local installer for the Claude Usage Widget (Windows PowerShell 5.1, no admin, no downloads).

.DESCRIPTION
    Installs claude-usage.ps1, claude-usage-widget.ps1, install.ps1 and uninstall.ps1 from this script's folder into
    %LOCALAPPDATA%\ClaudeUsageWidget, creates/updates the "Claude Usage Widget.lnk" Startup shortcut and the
    per-user "Claude Usage Widget watchdog" scheduled task (every 5 minutes it starts the widget again if it
    crashed or stopped responding; never after you chose Exit), then restarts only the Claude widget. Saved placement (settings.json), history and the usage cache are
    kept. Files that are already identical are not rewritten.

    Sandboxed shells: some desktop apps run their built-in terminals with a private, redirected
    copy of %LOCALAPPDATA%. Files written there are invisible to Windows at sign-in, so the widget would never
    autostart. The installer detects this and re-runs itself once through a temporary Task Scheduler task
    (outside the sandbox, as you, no admin), shows that run's output, and removes the task.

    Run from the unzipped release (or a clone of the repository):
        powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-usage-widget\install.ps1
#>
[CmdletBinding()]
param(
    # Install and create the shortcut, but do not start the widget.
    [switch]$NoLaunch,
    # Internal: set when the installer re-runs itself through Task Scheduler (outside an app sandbox).
    [string]$TaskLog
)
$ErrorActionPreference = 'Stop'
if ($TaskLog) { try { Start-Transcript -LiteralPath $TaskLog -Force | Out-Null } catch { } }

$Package      = @('claude-usage.ps1', 'claude-usage-widget.ps1', 'install.ps1', 'uninstall.ps1')
$SourceDir    = $PSScriptRoot
$InstallDir   = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'
$WidgetPath   = Join-Path $InstallDir 'claude-usage-widget.ps1'
$Collector    = Join-Path $InstallDir 'claude-usage.ps1'
$ShortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage Widget.lnk'
$StartMenuPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Usage Widget.lnk'
$PsExe        = Join-Path $PSHOME 'powershell.exe'
$ShortcutArgs = ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $WidgetPath)
$WatchdogTask = 'Claude Usage Widget watchdog'

# Under -TaskLog the output goes to a transcript, which splits -NoNewline segments: write whole lines there.
function Write-Tag  { param([string]$Tag, [string]$Color, [string]$Text) if ($TaskLog) { Write-Host ($Tag + $Text) } else { Write-Host $Tag -ForegroundColor $Color -NoNewline; Write-Host $Text } }
function Write-Step { param([int]$N, [string]$Text) Write-Host ''; Write-Tag ('[{0}/5] ' -f $N) 'Cyan' $Text }
function Write-Ok   { param([string]$Text) Write-Tag '      OK   ' 'Green' $Text }
function Write-Note { param([string]$Text) Write-Tag '      NOTE ' 'Yellow' $Text }
function Exit-Install {
    param([int]$Code)
    if ($TaskLog) { Write-Host "INSTALLER-EXIT:$Code"; try { Stop-Transcript | Out-Null } catch { } }
    exit $Code
}
function Stop-Install {
    param([string]$Text)
    Write-Tag '      FAIL ' 'Red' $Text
    Write-Host ''
    Write-Host 'Installation stopped.' -ForegroundColor Red
    Exit-Install 1
}

function Test-AppDataRedirected {
    # True when this process sees a private, app-redirected %LOCALAPPDATA% (an MSIX-style sandbox): a probe file
    # written to %LOCALAPPDATA% then shows up under %LOCALAPPDATA%\Packages\<app>\LocalCache\Local.
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

function Invoke-OutsideSandbox {
    # Re-runs this installer through a temporary on-demand scheduled task (runs as the signed-in user, no admin),
    # waits for it, prints its output and removes the task. Returns the installer's exit code.
    $log = Join-Path $SourceDir 'install-last.log'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $task = 'Usage widget installer ' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $argLine = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}" -TaskLog "{1}"' -f $PSCommandPath, $log
    if ($NoLaunch) { $argLine += ' -NoLaunch' }
    try {
        $action = New-ScheduledTaskAction -Execute $PsExe -Argument $argLine -WorkingDirectory $SourceDir
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
        [void](Register-ScheduledTask -TaskName $task -Action $action -Settings $settings -Description 'Temporary: installs the usage widget outside an app sandbox. Removed automatically.' -Force)
        Start-ScheduledTask -TaskName $task
        $deadline = [DateTime]::UtcNow.AddSeconds(150)
        $code = $null
        while ([DateTime]::UtcNow -lt $deadline -and $null -eq $code) {
            Start-Sleep -Milliseconds 800
            if (Test-Path -LiteralPath $log) {
                $text = ''
                try { $text = [IO.File]::ReadAllText($log) } catch { }
                $m = [regex]::Match($text, 'INSTALLER-EXIT:(\d+)')
                if ($m.Success) { $code = [int]$m.Groups[1].Value }
            }
        }
    } finally {
        try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop } catch { }
    }
    if (Test-Path -LiteralPath $log) {
        $lines = [IO.File]::ReadAllLines($log)
        $stars = 0
        foreach ($l in $lines) {
            if ($l -match '^\*{10}') { $stars++; continue }                 # transcript header = stars 1-2, footer = 3-4
            if ($stars -eq 2 -and $l -notmatch '^(Transcript started|INSTALLER-EXIT:|PS>)') { Write-Host $l }
        }
    }
    if ($null -eq $code) { Write-Host '      FAIL ' -ForegroundColor Red -NoNewline; Write-Host "The installer run through Task Scheduler did not finish in time. See $log"; return 1 }
    return $code
}

function Get-WidgetProcesses {
    # Only Windows PowerShell processes running a claude-usage-widget.ps1 script (never other PowerShell windows, never the other widget).
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -match '(?i)[\\/"\s]claude-usage-widget\.ps1' -and $_.CommandLine -notmatch '(?i)\s-Watchdog\b' })
}

function Test-WidgetWindow {
    param([int[]]$ProcessIds)
    if (-not ('ClaudeInstall.Win' -as [type])) {
        Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
namespace ClaudeInstall { public static class Win {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static List<uint> OwnersOf(string title) {
        List<uint> owners = new List<uint>();
        EnumWindows(delegate (IntPtr h, IntPtr l) {
            StringBuilder sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            if (sb.ToString() == title && IsWindowVisible(h)) { uint pid; GetWindowThreadProcessId(h, out pid); owners.Add(pid); }
            return true; }, IntPtr.Zero);
        return owners;
    } } }
'@
    }
    $owners = [ClaudeInstall.Win]::OwnersOf('Claude usage')
    return @($owners | Where-Object { $ProcessIds -contains [int]$_ }).Count -gt 0
}

if (-not $TaskLog -and (Test-AppDataRedirected)) {
    Write-Host ''
    Write-Host 'This shell runs in an app sandbox that redirects %LOCALAPPDATA%; files written from here would be' -ForegroundColor Yellow
    Write-Host 'invisible to Windows at sign-in. Re-running the installer through Task Scheduler (outside the sandbox)...' -ForegroundColor Yellow
    exit (Invoke-OutsideSandbox)
}

Write-Host ''
Write-Host 'Claude Usage Widget - local installer' -ForegroundColor Cyan
Write-Host ('Package: {0}' -f $SourceDir) -ForegroundColor DarkGray
Write-Host ('Target:  {0}' -f $InstallDir) -ForegroundColor DarkGray

# ------------------------------------------------------------------ 1
Write-Step 1 'Checking Windows, PowerShell 5.1, WPF and package files'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $env:WSL_DISTRO_NAME) { Stop-Install 'This installer must run on native Windows.' }
Write-Ok ('Windows {0}' -f [Environment]::OSVersion.Version)
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -lt 1) {
    Stop-Install ('Windows PowerShell 5.1 is required (this is {0} {1}). Use powershell.exe, not pwsh.' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
}
Write-Ok ('Windows PowerShell {0}' -f $PSVersionTable.PSVersion)
try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase } catch { Stop-Install 'WPF (PresentationFramework) could not be loaded.' }
Write-Ok 'WPF available'
foreach ($f in $Package) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $f) -PathType Leaf)) { Stop-Install "Missing package file: $f (expected next to install.ps1)" }
}
Write-Ok ('Package files present: {0}' -f ($Package -join ', '))

# ------------------------------------------------------------------ 2
Write-Step 2 'Validating the Claude files'
foreach ($f in $Package) {
    $src = Join-Path $SourceDir $f
    $bytes = [IO.File]::ReadAllBytes($src)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { Stop-Install "$f is not UTF-8 with BOM." }
    $tokens = $null; $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { Stop-Install ("{0} has {1} parse error(s); first at line {2}: {3}" -f $f, $errors.Count, $errors[0].Extent.StartLineNumber, $errors[0].Message) }
    Write-Ok ('{0}  ({1:N0} bytes, BOM, 0 parse errors)' -f $f, $bytes.Length)
}

# ------------------------------------------------------------------ 3
Write-Step 3 'Installing into %LOCALAPPDATA%\ClaudeUsageWidget'
try {
    if (-not (Test-Path -LiteralPath $InstallDir)) { [void](New-Item -ItemType Directory -Path $InstallDir -Force); Write-Ok 'Created install folder' }
} catch { Stop-Install ('Could not create {0}: {1}' -f $InstallDir, $_.Exception.Message) }
foreach ($f in $Package) {
    $src = Join-Path $SourceDir $f
    $dst = Join-Path $InstallDir $f
    if ((Test-Path -LiteralPath $dst) -and (Get-FileHash -LiteralPath $src).Hash -eq (Get-FileHash -LiteralPath $dst).Hash) {
        Write-Ok "$f already up to date"
        continue
    }
    $tmp = $dst + '.new'
    try {
        Copy-Item -LiteralPath $src -Destination $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $dst -Force
        Write-Ok "Installed $f"
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Stop-Install ("Could not write {0}: {1} If security software restored or protects this file, allow the folder {2} and run the installer again." -f $dst, $_.Exception.Message, $InstallDir)
    }
}
# Files from a downloaded zip carry Windows' "from the internet" mark; clear it on the installed copies.
foreach ($f in $Package) { try { Unblock-File -LiteralPath (Join-Path $InstallDir $f) -ErrorAction Stop } catch { } }
foreach ($keep in @('settings.json', 'history.json', 'usage-cache.json')) {
    if (Test-Path -LiteralPath (Join-Path $InstallDir $keep)) { Write-Ok "Preserved $keep" }
}
# Leftover temp files from interrupted saves (older than 10 minutes, so a running save is never touched).
$stale = @(Get-ChildItem -LiteralPath $InstallDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-10) })
foreach ($t in $stale) { Remove-Item -LiteralPath $t.FullName -Force -ErrorAction SilentlyContinue }
if ($stale.Count -gt 0) { Write-Ok ('Removed {0} leftover temp file(s)' -f $stale.Count) }

# ------------------------------------------------------------------ 4
Write-Step 4 'Creating the Startup shortcut (Claude Usage Widget.lnk)'
$shell = New-Object -ComObject WScript.Shell
try {
    $lnk = $shell.CreateShortcut($ShortcutPath)
    $upToDate = (Test-Path -LiteralPath $ShortcutPath) -and $lnk.TargetPath -ieq $PsExe -and $lnk.Arguments -eq $ShortcutArgs -and $lnk.WorkingDirectory -ieq $InstallDir
    if ($upToDate) {
        Write-Ok "$ShortcutPath (already up to date)"
    } else {
        $lnk.TargetPath = $PsExe
        $lnk.Arguments = $ShortcutArgs
        $lnk.WorkingDirectory = $InstallDir
        $lnk.WindowStyle = 7
        $lnk.Description = 'Claude usage taskbar widget'
        try { $lnk.Save() } catch { Stop-Install ('Could not save {0}: {1}' -f $ShortcutPath, $_.Exception.Message) }
        Write-Ok $ShortcutPath
    }
    # Start menu entry, so the widget can be started again after Exit without waiting for the next sign-in.
    try {
        $menuLnk = $shell.CreateShortcut($StartMenuPath)
        $menuLnk.TargetPath = $PsExe
        $menuLnk.Arguments = $ShortcutArgs
        $menuLnk.WorkingDirectory = $InstallDir
        $menuLnk.WindowStyle = 7
        $menuLnk.Description = 'Start the Claude usage taskbar widget'
        $menuLnk.Save()
        Write-Ok "Start menu: $StartMenuPath"
    } catch { Write-Note ('Start menu entry not created: {0}' -f $_.Exception.Message) }
} finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
# Watchdog: a per-user task (no admin) that runs the widget with -Watchdog every 5 minutes, through
# conhost --headless so no window flashes. The widget decides what to do (see Invoke-Watchdog).
try {
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $wdArgs = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Watchdog' -f $WidgetPath)
    $action = if (Test-Path -LiteralPath $conhost) { New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "{0}" {1}' -f $PsExe, $wdArgs) -WorkingDirectory $InstallDir }
              else { New-ScheduledTaskAction -Execute $PsExe -Argument ('-WindowStyle Hidden ' + $wdArgs) -WorkingDirectory $InstallDir }
    $trigger = New-ScheduledTaskTrigger -Once -At ([DateTime]::Now.AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    [void](Register-ScheduledTask -TaskName $WatchdogTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'Starts the Claude usage taskbar widget again if it crashed or stopped responding. Never after you chose Exit. Removed by uninstall.ps1.' -Force)
    Write-Ok "Watchdog task: $WatchdogTask (every 5 minutes)"
} catch { Write-Note ('Watchdog task not created ({0}); the widget still starts at sign-in.' -f $_.Exception.Message) }

# ------------------------------------------------------------------ 5
Write-Step 5 'Starting the Claude widget'
$old = @(Get-WidgetProcesses)
foreach ($p in $old) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Write-Ok ('Stopped previous Claude widget (PID {0})' -f $p.ProcessId) } catch { Write-Note ('Could not stop PID {0}' -f $p.ProcessId) }
}
if ($old.Count -gt 0) { Start-Sleep -Milliseconds 800 }

if ($NoLaunch) {
    Write-Note 'Skipped launch (-NoLaunch).'
} else {
    Start-Process -FilePath $PsExe -WindowStyle Hidden -WorkingDirectory $InstallDir -ArgumentList @(
        '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $WidgetPath))
    $running = @(); $windowOk = $false
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $running = @(Get-WidgetProcesses)
        if ($running.Count -gt 0 -and (Test-WidgetWindow ([int[]]@($running | ForEach-Object { [int]$_.ProcessId })))) { $windowOk = $true; break }
    }
    if ($running.Count -eq 0) { Stop-Install ('The widget process did not stay running. See {0}' -f (Join-Path $InstallDir 'widget.log')) }
    if ($running.Count -gt 1) { Write-Note ('{0} Claude widget processes found; expected 1.' -f $running.Count) } else { Write-Ok ('Widget running (PID {0}), exactly 1 instance' -f $running[0].ProcessId) }
    if ($windowOk) { Write-Ok 'Window "Claude usage" is visible on the desktop' } else { Write-Note 'Process started, but its window could not be confirmed (no interactive desktop?).' }
}

# Data status from the installed collector (may use the 60-second cache; never prints secrets).
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $PsExe
$psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $Collector)
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
$cp = [System.Diagnostics.Process]::Start($psi)
$outTask = $cp.StandardOutput.ReadToEndAsync(); [void]$cp.StandardError.ReadToEndAsync()
if (-not $cp.WaitForExit(90000)) { try { $cp.Kill() } catch { }; Write-Note 'Data check timed out.' }
else {
    $code = $cp.ExitCode
    $data = $null
    try { $data = $outTask.Result | ConvertFrom-Json } catch { }
    if ($null -eq $data) { Write-Note "Collector returned no valid data (exit $code)." }
    elseif ($code -eq 0 -and $null -ne $data.weekly) {
        Write-Ok ('Live data OK: {0:0.#}% of the weekly allowance left ({1})' -f $data.weekly.left, $data.source)
    } elseif ($code -eq 0) {
        Write-Note 'Connected, but the service reported no weekly window; the widget shows it as unavailable.'
    } else {
        $authCodes = @('auth_missing', 'auth_unreadable', 'auth_mode_unsupported', 'auth_malformed', 'auth_expired', 'http_401', 'http_403', 'config_missing', 'codex_home_missing')
        $msg = $(if ($data.error) { $data.error.message } else { 'unknown error' })
        if ($data.error -and $authCodes -contains $data.error.code) { Write-Note ('Installed, authentication unavailable: {0}' -f $msg) }
        elseif ($data.status -eq 'stale') { Write-Note ('Installed, showing stale data ({0}): {1}' -f $data.source, $msg) }
        else { Write-Note ('Installed, usage data unavailable: {0}' -f $msg) }
    }
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Exit-Install 0
