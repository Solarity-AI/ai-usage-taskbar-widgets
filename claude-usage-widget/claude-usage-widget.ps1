<#
.SYNOPSIS
    Claude usage taskbar widget (Windows PowerShell 5.1 + WPF).

.DESCRIPTION
    Small always-on-top pill on the taskbar showing the percentage of the WEEKLY allowance USED, with a
    pace forecast. Hover for details, click to pin the card, right-click for the menu (settings live there),
    drag the main pill horizontally to move it.

    The Claude and Codex widgets are the same script: only the "product" block below differs (the Codex file
    is generated from this one). Data comes only from the local collector next to this script, run in a
    separate hidden Windows PowerShell 5.1 process so the UI thread never blocks. No servers, no telemetry.

    Local files (in %LOCALAPPDATA%\<AppName>): settings.json, history.json (time, % used, reset time, credit /
    extra-usage figures; 15 days), alerts.json (which alerts were already shown), widget.log.

    Features: weekly ring + countdown or today's budget; burn-up chart of the current week; pace forecast;
    per-model limits with 24-hour change; credits / extra-usage spend; Windows notifications at chosen
    thresholds and when the allowance will run out early; a pill on every taskbar; hidden while a full-screen
    app is in front; settings, Start with Windows and Uninstall in the right-click menu.
#>
$ErrorActionPreference = 'Stop'

# >>> product (everything else in this file is identical in both widgets)
$script:ProductKey    = 'claude'
$script:ProductName   = 'Claude'
$script:AppName       = 'ClaudeUsageWidget'
$script:CollectorName = 'claude-usage.ps1'
$script:UsageUrl      = 'https://claude.ai/settings/usage'
$script:WindowTitle   = 'Claude usage'
$script:AnchorTitle   = $null    # this IS the Claude pill: no anchor (the Codex widget anchors to it)
$script:DefaultPollSeconds = 120 # Claude's usage service rate-limits frequent polling
$script:Accent        = '#D97757' # product accent (card mark, pill dot, menu checks)
$script:MarkText      = 'C'
# <<< product

# ---------------------------------------------------------------- single instance / STA

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    exit 0
}

$script:CreatedNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, ('Local\' + $script:AppName), [ref]$script:CreatedNew)
if (-not $script:CreatedNew) {
    $owned = $false
    try { $owned = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }
}

# ---------------------------------------------------------------- constants

$script:AppDir        = Join-Path $env:LOCALAPPDATA $script:AppName
$script:SettingsPath  = Join-Path $script:AppDir 'settings.json'
$script:HistoryPath   = Join-Path $script:AppDir 'history.json'
$script:AlertsPath    = Join-Path $script:AppDir 'alerts.json'
$script:LogPath       = Join-Path $script:AppDir 'widget.log'
$script:HeartbeatPath = Join-Path $script:AppDir 'heartbeat'        # rewritten by the UI thread; watchdog.ps1 replaces a hung widget
$script:ExitMarkerPath = Join-Path $script:AppDir 'exited-by-user'  # left by Exit: the watchdog keeps the widget closed
$script:CollectorPath = Join-Path $PSScriptRoot $script:CollectorName
$script:UninstallPath = Join-Path $PSScriptRoot 'uninstall.ps1'
$script:ShortcutPath  = Join-Path ([Environment]::GetFolderPath('Startup')) ('{0} Usage Widget.lnk' -f $script:ProductName)
$script:Version       = '1.5.0'          # release version (tools\package.ps1 and the release workflow check it)
$script:HomeUrl       = 'https://solarity-ai.github.io/ai-usage-taskbar-widgets/'
$script:CollectorTimeoutSeconds = 120   # the collector may run the official CLI
$script:AnchorGapPx   = 8               # physical pixels between neighbouring pills / the notification area
$script:HistoryDays   = 15
$script:PillWidth     = 88              # minimum pill width (DIP); the pill grows to fit its text
$script:CompactWidth  = 58
$script:ChartW        = 270.0           # card content width (DIP)
$script:ChartH        = 56.0
$script:Inv           = [Globalization.CultureInfo]::InvariantCulture
# Windows PowerShell's registered app id: lets toasts work without registering a new app.
$script:ToastAppId    = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

# Display thresholds on PERCENT LEFT (unrounded): >=50 green, >=25 amber, >=10 orange, else red.
$script:Thresholds = @(
    @{ min = 50; key = 'green' },
    @{ min = 25; key = 'amber' },
    @{ min = 10; key = 'orange' },
    @{ min = 0;  key = 'red' }
)
# Colors. Per level: <level> = text color (hero %, status words), <level>Lo/<level>Hi = bar gradient, <level>Ring = pill ring.
# pace.<level> = the tinted "Pace this week" box (also used for the status box): bg, edge, label, status, track, marker, text.
$script:Themes = @{
    dark  = @{ cardBg = '#FF1D2129'; border = '#FF3D4148'; fg = '#FFF5F8FF'; dim = '#FFA4AAB2'; line = '#FF30333B'; boxBg = '#FF232730'
               chipBg = '#FF2E3139'; chipFg = '#FFA3A6AE'; track = '#FF474B51'
               pillBg = '#F52A2F3C'; pillBgBottom = '#F51F242D'; pillEdgeTop = '#FF575D71'; pillEdgeBottom = '#FF40465A'; pillTrack = '#FF464A54'; pillFg = '#FFF1F6FF'; pillDim = '#FF989EA7'
               menuBg = '#FC1D2129'; menuHover = '#16FFFFFF'; warn = '#FFF2C97D'
               green  = '#FF5EEBD2'; greenLo  = '#FF3CCD9C'; greenHi  = '#FF28CFE4'; greenRing  = '#FF31D0CC'
               amber  = '#FFF5D06B'; amberLo  = '#FFF8D77A'; amberHi  = '#FFE9AE25'; amberRing  = '#FFF0C443'
               orange = '#FFFCBA75'; orangeLo = '#FFFEBA73'; orangeHi = '#FFF97419'; orangeRing = '#FFF99145'
               red    = '#FFF58A88'; redLo    = '#FFF9A4A6'; redHi    = '#FFE9494B'; redRing    = '#FFEE6567'
               gray   = '#FFA4AAB2'; grayLo   = '#FF8B949E'; grayHi   = '#FF6E7781'; grayRing   = '#FF8B949E'
               pace = @{
                   green = @{ bg = '#FF1E3B43'; edge = '#FF2F4F59'; label = '#FFA0B0BC'; status = '#FF6FD7CB'; track = '#FF4B6069'; marker = '#FFEEFBFF'; text = '#FFEEF8FF' }
                   amber = @{ bg = '#FF3A3324'; edge = '#FF574A2E'; label = '#FFBDB4A2'; status = '#FFF2CF85'; track = '#FF63593F'; marker = '#FFFFF6E0'; text = '#FFFAF5EA' }
                   red   = @{ bg = '#FF3F252B'; edge = '#FF542F37'; label = '#FFB3ABB7'; status = '#FFEAABAA'; track = '#FF624F53'; marker = '#FFFFE4E7'; text = '#FFF7F1F5' }
                   gray  = @{ bg = '#FF262A33'; edge = '#FF393E48'; label = '#FFA0A6B0'; status = '#FFC9CED6'; track = '#FF4A4F59'; marker = '#FFF3F5F8'; text = '#FFEEF1F5' }
               } }
    light = @{ cardBg = '#FFFBFCFD'; border = '#FFDADDE3'; fg = '#FF1B1F27'; dim = '#FF5E6570'; line = '#FFE4E7EB'; boxBg = '#FFF3F5F7'
               chipBg = '#FFECEEF2'; chipFg = '#FF4E5560'; track = '#FFE1E4E9'
               pillBg = '#F5FCFDFE'; pillBgBottom = '#F5EEF1F5'; pillEdgeTop = '#FFD5D9E0'; pillEdgeBottom = '#FFBDC3CD'; pillTrack = '#FFD9DDE3'; pillFg = '#FF1B1F27'; pillDim = '#FF5E6570'
               menuBg = '#FCFBFCFD'; menuHover = '#0F000000'; warn = '#FF94680A'
               green  = '#FF0E9C87'; greenLo  = '#FF23B98A'; greenHi  = '#FF10A9C6'; greenRing  = '#FF14AFA8'
               amber  = '#FFA87800'; amberLo  = '#FFF2C543'; amberHi  = '#FFD9A008'; amberRing  = '#FFDDA914'
               orange = '#FFC9620A'; orangeLo = '#FFF6A04D'; orangeHi = '#FFE46F0F'; orangeRing = '#FFEB8124'
               red    = '#FFCC2F35'; redLo    = '#FFF17C7F'; redHi    = '#FFD93A3D'; redRing    = '#FFE0484B'
               gray   = '#FF5E6570'; grayLo   = '#FFA3AAB3'; grayHi   = '#FF858D97'; grayRing   = '#FF959CA6'
               pace = @{
                   green = @{ bg = '#FFE7F6F5'; edge = '#FFBFE5E1'; label = '#FF4F6670'; status = '#FF0B8A7D'; track = '#FFCBE3E2'; marker = '#FF1B1F27'; text = '#FF1B2A30' }
                   amber = @{ bg = '#FFFCF4E3'; edge = '#FFEBD8AE'; label = '#FF776A4C'; status = '#FF94680A'; track = '#FFEADFC4'; marker = '#FF1B1F27'; text = '#FF2B2618' }
                   red   = @{ bg = '#FFFCECED'; edge = '#FFF2C6C9'; label = '#FF7A5A5E'; status = '#FFC42F36'; track = '#FFEFD3D5'; marker = '#FF1B1F27'; text = '#FF2D1C1F' }
                   gray  = @{ bg = '#FFF1F3F6'; edge = '#FFDDE1E7'; label = '#FF5E6570'; status = '#FF3C434D'; track = '#FFDADFE5'; marker = '#FF1B1F27'; text = '#FF1B1F27' }
               } }
}

# ---------------------------------------------------------------- pure helpers (tested in isolation)

function ConvertTo-UtcTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    if ($Value -is [string] -and $Value.Length -gt 0) {
        $dt = [DateTime]::MinValue
        $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        if ([DateTime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) {
            return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc)
        }
    }
    return $null
}

function ConvertTo-Unix {
    param([DateTime]$Utc)
    return [double]([DateTimeOffset][DateTime]::SpecifyKind($Utc, [DateTimeKind]::Utc)).ToUnixTimeSeconds()
}

function Get-Left {
    # Percent LEFT for a window, or $null when unavailable. Never turns missing data into 0 or 100.
    param($Window)
    if ($null -eq $Window) { return $null }
    $u = $Window.used
    if ($null -eq $u -or $u -is [bool] -or $u -is [string]) { return $null }
    $u = [double]$u
    if ([double]::IsNaN($u) -or [double]::IsInfinity($u)) { return $null }
    return [Math]::Min(100.0, [Math]::Max(0.0, 100.0 - $u))
}

function Format-Percent {
    param($Left)
    if ($null -eq $Left) { return [string][char]0x2014 }
    $r = [Math]::Round([double]$Left, [MidpointRounding]::AwayFromZero)
    if ($Left -gt 0 -and $r -eq 0) { return '<1%' }
    if ($Left -lt 100 -and $r -eq 100) { return '99%' }
    return ('{0}%' -f [int]$r)
}

function Get-LevelKey {
    param($Left)
    if ($null -eq $Left) { return 'gray' }
    foreach ($t in $script:Thresholds) { if ($Left -ge $t.min) { return $t.key } }
    return 'red'
}

function Format-Span {
    # Hours -> "6d 4h", "3h 12m", "12m", "<1m".
    param([double]$Hours)
    $totalMin = [long][Math]::Floor([Math]::Max(0.0, $Hours) * 60.0)
    $d = [long][Math]::Floor($totalMin / 1440)
    $h = [long][Math]::Floor(($totalMin % 1440) / 60)
    $m = [long]($totalMin % 60)
    if ($d -gt 0) { return ('{0}d {1}h' -f $d, $h) }
    if ($h -gt 0) { return ('{0}h {1}m' -f $h, $m) }
    if ($m -gt 0) { return ('{0}m' -f $m) }
    return '<1m'
}

function Get-ResetText {
    # Countdown until the reset, e.g. "6d 4h", "3h 12m", "12m", "<1m"; "reset due" once passed; $null if unknown.
    param($ResetsAt, $Now = [DateTime]::UtcNow)
    $r = ConvertTo-UtcTime $ResetsAt
    if ($null -eq $r) { return $null }
    $span = $r - (ConvertTo-UtcTime $Now)
    if ($span.TotalSeconds -le 0) { return 'reset due' }
    return (Format-Span $span.TotalHours)
}

function Format-LocalTime {
    param($Utc, $Now = [DateTime]::UtcNow)
    $u = ConvertTo-UtcTime $Utc
    if ($null -eq $u) { return '' }
    $l = $u.ToLocalTime()
    $today = (ConvertTo-UtcTime $Now).ToLocalTime().Date
    if ($l.Date -eq $today) { return ('today ' + $l.ToShortTimeString()) }
    if ($l.Date -eq $today.AddDays(1)) { return ('tomorrow ' + $l.ToShortTimeString()) }
    return ($l.ToString('ddd ', [Globalization.CultureInfo]::CurrentCulture) + $l.ToShortTimeString())
}

function Format-Rate {
    # "1.2%/h"; a WORD JOINER after the slash keeps WPF from wrapping "%/" and "h" onto two lines.
    param([double]$PerHour)
    $fmt = $(if ($PerHour -lt 0.095) { '0.00' } else { '0.0' })
    return ($PerHour.ToString($fmt, [Globalization.CultureInfo]::CurrentCulture) + '%/' + [char]0x2060 + 'h')
}

function Format-Number {
    param([double]$Value, [int]$Decimals = 1)
    $fmt = $(if ($Decimals -le 0) { '0' } else { '0.' + ('#' * $Decimals) })
    return $Value.ToString($fmt, [Globalization.CultureInfo]::CurrentCulture)
}

function Format-Share {
    # Percent figures: whole numbers from 10 up, one decimal below (so "4.5%" but "42%", never "41.6%").
    param([double]$Value)
    return (Format-Number $Value $(if ([Math]::Abs($Value) -ge 10) { 0 } else { 1 }))
}

function Format-Age {
    param($FetchedAt, $Now = [DateTime]::UtcNow)
    $f = ConvertTo-UtcTime $FetchedAt
    if ($null -eq $f) { return 'unknown time' }
    $s = ((ConvertTo-UtcTime $Now) - $f).TotalSeconds
    if ($s -lt 60) { return 'just now' }
    if ($s -lt 3600) { return ('{0}m ago' -f [int][Math]::Floor($s / 60)) }
    if ($s -lt 86400) { return ('{0}h {1}m ago' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60)) }
    return ('{0}d ago' -f [int][Math]::Floor($s / 86400))
}

function Format-Credits {
    param($Balance)
    if ($null -eq $Balance) { return $null }
    $b = [double]$Balance
    if ([Math]::Abs($b - [Math]::Round($b)) -lt 0.005) { return $b.ToString('N0', [Globalization.CultureInfo]::CurrentCulture) }
    return $b.ToString('N2', [Globalization.CultureInfo]::CurrentCulture)
}

function Format-DayTime {
    # Local "Sat 01:11" (24-hour, English day names, like the rest of the card).
    param($Utc)
    $u = ConvertTo-UtcTime $Utc
    if ($null -eq $u) { return '' }
    return $u.ToLocalTime().ToString('ddd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-ResetLine {
    # "Resets Sat 14 Nov, 19:00 · in 23h 1m"; "Reset due" once passed; $null if unknown.
    param($ResetsAt, $Now = [DateTime]::UtcNow)
    $r = ConvertTo-UtcTime $ResetsAt
    if ($null -eq $r) { return $null }
    $span = Get-ResetText $r $Now
    if ($span -eq 'reset due') { return 'Reset due; waiting for a new reading' }
    $when = $r.ToLocalTime().ToString('ddd d MMM, HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    return ('Resets {0} {1} in {2}' -f $when, [char]0x00B7, ($span -replace ' ', [char]0x00A0))
}

function Format-UsedShare {
    # "45%" of the window used (whole numbers; "<1%" for a trace).
    param([double]$Used)
    $r = [Math]::Round($Used, [MidpointRounding]::AwayFromZero)
    if ($Used -gt 0 -and $r -eq 0) { return '<1%' }
    if ($Used -lt 100 -and $r -ge 100) { return '99%' }                 # never "100% used" while some is left
    return ('{0}%' -f [int][Math]::Min(100, [Math]::Max(0, $r)))
}

function Get-PaceSummary {
    # The card's pace boxes ("Pace this week", "Pace this 5-hour session") from Get-PaceInfo: box label, status
    # word, level, one line of text, bar fill (share used) and marker (share of the window gone).
    param($Pace, $Now = [DateTime]::UtcNow)
    if ($null -eq $Pace) { return $null }
    $dot = [string][char]0x00B7
    $gone = Format-UsedShare (100.0 * $Pace.elapsed_h / $Pace.window_h)
    $usedT = Format-UsedShare $Pace.used
    $week = ($Pace.window_h -gt 24)
    $period = $(if ($week) { 'the week' } else { 'the session' })
    $label = $(if ($week) { 'PACE THIS WEEK' } else { ('PACE THIS {0}-HOUR SESSION' -f [Math]::Round($Pace.window_h)) })
    $plain = ('{0} used {1} {2} of {3} gone' -f $usedT, $dot, $gone, $period)
    $s = [ordered]@{ label = $label; status = 'On pace'; level = 'green'; text = $plain
                     fill = [Math]::Min(1.0, [Math]::Max(0.0, $Pace.used / 100.0))
                     marker = [Math]::Min(1.0, [Math]::Max(0.0, $Pace.elapsed_h / $Pace.window_h)) }
    if ($Pace.limited) {
        $s.status = 'Limit reached'; $s.level = 'red'
        $s.text = ('Resets {0} {1} in {2}' -f (Format-DayTime $Pace.reset), $dot, (Format-Span $Pace.remaining_h))
    } elseif ($null -eq $Pace.speed_pct) {
        $s.status = 'Too early to tell'; $s.level = 'gray'                  # first hour of the window
    } elseif ($Pace.runs_out) {
        $s.status = 'Too fast'; $s.level = 'red'
        $s.text = ('At this rate it runs out {0} {1} {2} used, {3} of {4} gone' -f (Format-DayTime $Pace.run_out_at), $dot, $usedT, $gone, $period)
    } else {
        # Lasts until the reset: still say when it WOULD run out at this rate, so the finish time is always shown.
        if ($null -ne $Pace.left_at_reset -and $Pace.left_at_reset -lt 5) { $s.status = 'Cutting close'; $s.level = 'amber' }
        if ($null -ne $Pace.rate -and $Pace.rate -gt 0.0001) {
            $nowU = ConvertTo-UtcTime $Now
            $outH = $Pace.left / $Pace.rate
            $outAt = $nowU.AddHours($outH)
            $when = $(if ($outH -lt 144) { Format-DayTime $outAt } else { $outAt.ToLocalTime().ToString('ddd d MMM, HH:mm', [Globalization.CultureInfo]::InvariantCulture) })
            $s.text = ('At this rate it runs out {0}, after the reset {1} {2} used, {3} of {4} gone' -f $when, $dot, $usedT, $gone, $period)
        } else {
            $s.text = ('No use lately, so it lasts until the reset {0} {1} used, {2} of {3} gone' -f $dot, $usedT, $gone, $period)
        }
    }
    return [pscustomobject]$s
}

function Get-BindingLimit {
    # The limit that runs out first: the 5-hour session when less of it is left than of the weekly limit
    # (and it hasn't reset yet), else the weekly limit. Per-model limits apply to one model only and never bind.
    param($Data, $Now = [DateTime]::UtcNow)
    $w = $Data.weekly; $s = $Data.session
    $wl = Get-Left $w; $sl = Get-Left $s
    $sOk = ($null -ne $sl -and $null -ne $s -and $null -ne (ConvertTo-UtcTime $s.resets_at) -and (ConvertTo-UtcTime $s.resets_at) -gt (ConvertTo-UtcTime $Now))
    if ($sOk -and ($null -eq $wl -or $sl -lt $wl)) { return [pscustomobject]@{ kind = 'session'; window = $s; left = $sl } }
    return [pscustomobject]@{ kind = 'weekly'; window = $w; left = $wl }
}

function Get-WindowLabel {
    # Row title for a limit window: "Weekly · all models", "Current session · 5 hours", "Weekly · Fable".
    param([string]$Kind, [string]$Name = $null, $WindowSeconds = $null, [string]$Product = 'claude')
    $dot = [string][char]0x00B7
    $hours = $(if ($null -ne $WindowSeconds -and [double]$WindowSeconds -gt 0) { [Math]::Round([double]$WindowSeconds / 3600.0) } else { 5 })
    if ($Name) {
        switch ($Kind) { 'weekly' { return "Weekly $dot $Name" } 'session' { return "Session $dot $Name" } default { return $Name } }
    }
    if ($Kind -eq 'session') { return ('Current session {0} {1} hours' -f $dot, $hours) }
    if ($Product -eq 'claude') { return "Weekly $dot all models" }
    return 'Weekly limit'
}

function Get-SameWindowSamples {
    # Samples of the CURRENT window (same reset time +/- 1 h), oldest first.
    param($Samples, [double]$ResetUnix)
    return @(@($Samples) | Where-Object { $null -ne $_ -and [Math]::Abs([double]$_.r - $ResetUnix) -le 3600 } | Sort-Object { [double]$_.t })
}

function Get-PaceInfo {
    # Pace model for one limit window. Samples: earlier readings @{ t; u; r } (Unix seconds, % used, reset Unix).
    #   even speed  = 100 / window hours (uses exactly the whole allowance by the reset)
    #   recent rate = % used per hour since the oldest same-window sample 2-6 h old (weekly) or 0.5-2 h (5-hour)
    #   avg rate    = % used per hour since the window started
    # The forecast uses the recent rate when there is one, else the average. Not an official forecast.
    param($Window, $Samples, $Now = [DateTime]::UtcNow)
    if ($null -eq $Window) { return $null }
    $left = Get-Left $Window
    if ($null -eq $left) { return $null }
    $used = 100.0 - $left
    $reset = ConvertTo-UtcTime $Window.resets_at
    $secs = $Window.window_seconds
    if ($null -eq $reset -or $null -eq $secs -or [double]$secs -le 0) { return $null }
    $now = ConvertTo-UtcTime $Now
    $nowU = ConvertTo-Unix $now
    $remS = ($reset - $now).TotalSeconds
    if ($remS -le 0) { return $null }
    $winH = [double]$secs / 3600.0
    $remH = [Math]::Min($winH, $remS / 3600.0)
    $elH = $winH - $remH
    $evenRate = 100.0 / $winH
    $expUsed = 100.0 * $elH / $winH
    $avgRate = $(if ($elH -ge 0.25) { $used / $elH } else { $null })

    $long = ($winH -gt 24)
    $minSpanH = $(if ($long) { 2.0 } else { 0.5 })
    $maxSpanH = $(if ($long) { 6.0 } else { 2.0 })
    $resetU = ConvertTo-Unix $reset
    $recentRate = $null; $recentSpanH = $null
    $best = $null
    foreach ($s in @($Samples)) {
        if ($null -eq $s) { continue }
        if ([Math]::Abs([double]$s.r - $resetU) -gt 3600) { continue }
        $age = ($nowU - [double]$s.t) / 3600.0
        if ($age -lt $minSpanH -or $age -gt $maxSpanH) { continue }
        if ($null -eq $best -or [double]$s.t -lt [double]$best.t) { $best = $s }
    }
    if ($null -ne $best) {
        $recentSpanH = ($nowU - [double]$best.t) / 3600.0
        $recentRate = [Math]::Max(0.0, $used - [double]$best.u) / $recentSpanH
    }
    # Last window at the same point (weekly only): the sample from one window ago closest to now - window.
    $prevUsed = $null
    if ($long) {
        $prevBest = $null; $prevDist = 1e18
        foreach ($s in @($Samples)) {
            if ($null -eq $s) { continue }
            if ([Math]::Abs([double]$s.r - ($resetU - [double]$secs)) -gt 3600) { continue }
            $dist = [Math]::Abs([double]$s.t - ($nowU - [double]$secs))
            if ($dist -le 3600 -and $dist -lt $prevDist) { $prevBest = $s; $prevDist = $dist }
        }
        if ($null -ne $prevBest) { $prevUsed = [double]$prevBest.u }
    }

    $rate = $(if ($null -ne $recentRate) { $recentRate } else { $avgRate })
    $basis = $(if ($null -ne $recentRate) { 'recent' } elseif ($null -ne $avgRate) { 'average' } else { 'none' })
    $budget = $(if ($remH -gt 0) { $left / $remH } else { $null })
    $speedPct = $(if ($null -ne $rate -and $elH -ge [Math]::Min(1.0, $winH * 0.05)) { ($rate / $evenRate - 1.0) * 100.0 } else { $null })

    $info = [ordered]@{
        used = $used; left = $left; reset = $reset; window_h = $winH; remaining_h = $remH; elapsed_h = $elH
        even_rate = $evenRate; expected_used = $expUsed; ahead_points = ($used - $expUsed)
        avg_rate = $avgRate; recent_rate = $recentRate; recent_span_h = $recentSpanH
        rate = $rate; basis = $basis; speed_pct = $speedPct; budget_rate = $budget; prev_used = $prevUsed
        limited = ($left -le 0); runs_out = $false; run_out_at = $null; run_out_in_h = $null; spare_h = $null; left_at_reset = $null
        avg_runs_out = $false; avg_run_out_at = $null; avg_left_at_reset = $null
    }
    foreach ($pair in @(@('', $rate), @('avg_', $avgRate))) {
        $pre = $pair[0]; $rt = $pair[1]
        if ($left -le 0 -or $null -eq $rt) { continue }
        if ($rt -gt 0.0001 -and ($left / $rt) -lt $remH) {
            $info[$pre + 'runs_out'] = $true
            $info[$pre + 'run_out_at'] = $now.AddHours($left / $rt)
            if ($pre -eq '') { $info.run_out_in_h = $left / $rt; $info.spare_h = $remH - $left / $rt }
        } else {
            $info[$pre + 'left_at_reset'] = [Math]::Max(0.0, $left - $rt * $remH)
        }
    }
    return [pscustomobject]$info
}

function Get-DailyBudget {
    # Today's share of what is left: what was left at local midnight (or at the window start, if later), spread
    # evenly over the days until the reset. Needs a same-window reading from before midnight. $null otherwise.
    param($Window, $Samples, $Now = [DateTime]::UtcNow)
    $left = Get-Left $Window
    $reset = $(if ($null -ne $Window) { ConvertTo-UtcTime $Window.resets_at } else { $null })
    if ($null -eq $left -or $null -eq $reset -or $null -eq $Window.window_seconds) { return $null }
    $now = ConvertTo-UtcTime $Now
    $resetU = ConvertTo-Unix $reset
    if ($resetU -le (ConvertTo-Unix $now)) { return $null }
    $startU = $resetU - [double]$Window.window_seconds
    $midU = ConvertTo-Unix ($now.ToLocalTime().Date.ToUniversalTime())
    $used0 = $null
    if ($startU -ge $midU) { $used0 = 0.0; $fromU = $startU }
    else {
        $fromU = $midU
        # Only a reading from the last 6 h before midnight says what was left then; an older one (PC asleep or off)
        # would count earlier days' use as today's.
        $before = @(Get-SameWindowSamples $Samples $resetU | Where-Object { [double]$_.t -le $midU -and [double]$_.t -ge $midU - 6 * 3600 })
        if ($before.Count -gt 0) { $used0 = [double]$before[$before.Count - 1].u }
        else {
            # No reading before midnight: accept the first one in the first two hours after it.
            $after = @(Get-SameWindowSamples $Samples $resetU | Where-Object { [double]$_.t -gt $midU -and [double]$_.t -le $midU + 7200 })
            if ($after.Count -gt 0) { $used0 = [double]$after[0].u }
        }
    }
    if ($null -eq $used0) { return $null }
    $days = [Math]::Max(1.0, ($resetU - $fromU) / 86400.0)
    $budget = (100.0 - $used0) / $days
    $usedToday = [Math]::Max(0.0, (100.0 - $left) - $used0)
    return [pscustomobject]@{ used_today = $usedToday; budget = $budget; over = ($usedToday -gt $budget + 0.05); days = $days }
}

function Get-ChartGeometry {
    # Burn-up chart of the current window in a W x H box: actual % used (solid), even pace (dashed diagonal),
    # forecast (dashed, from now to run-out or reset). Returns point lists in box coordinates.
    param($Window, $Samples, $Pace, $Now = [DateTime]::UtcNow, [double]$W = 286, [double]$H = 58)
    $left = Get-Left $Window
    $reset = $(if ($null -ne $Window) { ConvertTo-UtcTime $Window.resets_at } else { $null })
    if ($null -eq $left -or $null -eq $reset -or $null -eq $Window.window_seconds) { return $null }
    $secs = [double]$Window.window_seconds
    $resetU = ConvertTo-Unix $reset
    $startU = $resetU - $secs
    $nowU = [Math]::Min($resetU, (ConvertTo-Unix (ConvertTo-UtcTime $Now)))
    $X = { param($t) [Math]::Round([Math]::Max(0.0, [Math]::Min($W, ($t - $startU) / $secs * $W)), 1) }
    $Y = { param($u) [Math]::Round($H - [Math]::Max(0.0, [Math]::Min(100.0, $u)) / 100.0 * $H, 1) }
    $pts = New-Object System.Collections.ArrayList
    [void]$pts.Add(@((& $X $startU), (& $Y 0.0)))
    foreach ($s in (Get-SameWindowSamples $Samples $resetU)) {
        if ([double]$s.t -lt $startU -or [double]$s.t -ge $nowU) { continue }
        [void]$pts.Add(@((& $X ([double]$s.t)), (& $Y ([double]$s.u))))
    }
    $used = 100.0 - $left
    [void]$pts.Add(@((& $X $nowU), (& $Y $used)))
    $proj = $null
    if ($null -ne $Pace -and $null -ne $Pace.rate -and -not $Pace.limited) {
        $endU = $(if ($Pace.runs_out) { ConvertTo-Unix $Pace.run_out_at } else { $resetU })
        $endUsed = $(if ($Pace.runs_out) { 100.0 } else { $used + $Pace.rate * (($resetU - $nowU) / 3600.0) })
        $proj = @(@((& $X $nowU), (& $Y $used)), @((& $X $endU), (& $Y $endUsed)))
    }
    return [pscustomobject]@{
        actual = $pts.ToArray(); even = @(@(0.0, $H), @($W, 0.0)); forecast = $proj
        now = @((& $X $nowU), (& $Y $used)); runs_out = ($null -ne $Pace -and $Pace.runs_out)
        start = [DateTimeOffset]::FromUnixTimeSeconds([long]$startU).UtcDateTime; reset = $reset
    }
}

function Get-Trend {
    # Change of a series over up to $SpanHours: current minus the oldest sample in that span (at least $MinHours
    # old). Samples: @{ t; u } or @{ t; v }. Returns @{ delta; hours } or $null.
    param($Samples, [double]$Current, [double]$NowUnix, [double]$SpanHours = 24, [double]$MinHours = 6, [double]$ResetUnix = 0)
    $best = $null
    foreach ($s in @($Samples)) {
        if ($null -eq $s) { continue }
        if ($ResetUnix -gt 0 -and $null -ne $s.r -and [Math]::Abs([double]$s.r - $ResetUnix) -gt 3600) { continue }
        $age = ($NowUnix - [double]$s.t) / 3600.0
        if ($age -lt $MinHours -or $age -gt $SpanHours) { continue }
        if ($null -eq $best -or [double]$s.t -lt [double]$best.t) { $best = $s }
    }
    if ($null -eq $best) { return $null }
    $v = $(if ($null -ne $best.u) { [double]$best.u } else { [double]$best.v })
    return [pscustomobject]@{ delta = ($Current - $v); hours = (($NowUnix - [double]$best.t) / 3600.0) }
}

function Get-PaceView {
    # Turns Get-PaceInfo results into the card's pace box and the pill's short hint.
    param($Weekly, $Session, $Now = [DateTime]::UtcNow, $Budget = $null)
    if ($null -eq $Weekly) { return $null }
    $p = $Weekly
    $lines = New-Object System.Collections.ArrayList
    $level = 'green'; $pill = $null
    $pts = [Math]::Round([Math]::Abs($p.ahead_points), [MidpointRounding]::AwayFromZero)
    if ($p.limited) {
        $title = 'Limit reached'
        $level = 'red'
        [void]$lines.Add(('The allowance is used up; it resets {0} (in {1}).' -f (Format-LocalTime $p.reset $Now), (Format-Span $p.remaining_h)))
    } else {
        if ($null -eq $p.speed_pct) { $title = 'Pace: too early to judge'; $level = 'gray' }
        elseif ([Math]::Abs($p.speed_pct) -lt 10) { $title = 'Pace: about even' }
        elseif ($p.speed_pct -gt 0) {
            $title = ('Pace: {0}% faster than even' -f [Math]::Round($p.speed_pct, [MidpointRounding]::AwayFromZero)); $level = 'amber'
            if ($p.speed_pct -ge 100) { $title += (' ({0}' -f (1 + $p.speed_pct / 100.0).ToString('0.0', [Globalization.CultureInfo]::CurrentCulture)) + [char]0x00D7 + ')' }
        }
        else { $title = ('Pace: {0}% slower than even' -f [Math]::Round(-$p.speed_pct, [MidpointRounding]::AwayFromZero)) }
        $speedLine = $null
        if ($p.runs_out -and $null -ne $p.speed_pct) {
            # Running out decides the headline; the speed comparison becomes a detail (it can be "slower" and still run out).
            if ($null -ne $p.speed_pct) { $speedLine = ('Speed right now: {0}.' -f ($title -replace '^Pace: ', '')) }
            $title = ('Pace: runs out {0} before the reset' -f (Format-Span $p.spare_h))
            $level = 'red'
        }

        if ($p.runs_out) {
            [void]$lines.Add(('At this speed you run out {0} (in {1}), {2} before the reset.' -f (Format-LocalTime $p.run_out_at $Now), (Format-Span $p.run_out_in_h), (Format-Span $p.spare_h)))
            if ($null -ne $p.speed_pct) { $pill = ('out ' + (Format-Span $p.run_out_in_h)) }   # no pill alarm in the first hour
            if ($speedLine) { [void]$lines.Add($speedLine) }
        } elseif ($null -ne $p.left_at_reset) {
            [void]$lines.Add(('At this speed it lasts until the reset ({0}) with about {1}% used.' -f (Format-LocalTime $p.reset $Now), [Math]::Round(100.0 - $p.left_at_reset, [MidpointRounding]::AwayFromZero)))
        }
        if ($null -ne $Budget) {
            $bt = ('Today: {0}% used of a {1}% daily budget' -f (Format-Share $Budget.used_today), (Format-Share $Budget.budget))
            if ($Budget.over) { $bt += (' (over by {0} points)' -f (Format-Share ($Budget.used_today - $Budget.budget))) }
            [void]$lines.Add(($bt + '.'))
        }
        $side = $(if ($p.ahead_points -ge 0.5) { ('{0} points more than even' -f $pts) } elseif ($p.ahead_points -le -0.5) { ('{0} points less than even' -f $pts) } else { 'right on even pace' })
        [void]$lines.Add(('{0}% used so far; even pace would be {1}% by now ({2}).' -f [Math]::Round($p.used, [MidpointRounding]::AwayFromZero), [Math]::Round($p.expected_used, [MidpointRounding]::AwayFromZero), $side))

        if ($p.basis -eq 'recent') {
            $sp = ('Speed: {0} over the last {1}' -f (Format-Rate $p.recent_rate), (Format-Span $p.recent_span_h))
            if ($null -ne $p.avg_rate) { $sp += ('; {0} on average this window' -f (Format-Rate $p.avg_rate)) }
            [void]$lines.Add(($sp + ('. Even pace is {0}.' -f (Format-Rate $p.even_rate))))
        } elseif ($p.basis -eq 'average') {
            [void]$lines.Add(('Speed: {0} on average this window. Even pace is {1}.' -f (Format-Rate $p.avg_rate), (Format-Rate $p.even_rate)))
        }
        if ($p.basis -eq 'recent' -and $null -ne $p.avg_rate -and $p.avg_runs_out -ne $p.runs_out) {
            if ($p.avg_runs_out) { [void]$lines.Add(('At the window average it would run out {0}.' -f (Format-LocalTime $p.avg_run_out_at $Now))) }
            elseif ($null -ne $p.avg_left_at_reset) { [void]$lines.Add(('At the window average it would last, with about {0}% used at the reset.' -f [Math]::Round(100.0 - $p.avg_left_at_reset, [MidpointRounding]::AwayFromZero))) }
        }
        if ($null -ne $p.budget_rate) {
            $b = ('To last until the reset: at most {0}' -f (Format-Rate $p.budget_rate))
            if ($p.window_h -gt 24) { $b += (' (about {0}% a day)' -f (Format-Share ($p.budget_rate * 24.0))) }
            [void]$lines.Add(($b + '.'))
        }
        if ($null -ne $p.prev_used) {
            $d = $p.used - $p.prev_used
            $cmp = $(if ([Math]::Abs($d) -lt 0.5) { 'about the same as now' } elseif ($d -gt 0) { ('{0} points less than now' -f [Math]::Round($d, [MidpointRounding]::AwayFromZero)) } else { ('{0} points more than now' -f [Math]::Round(-$d, [MidpointRounding]::AwayFromZero)) })
            [void]$lines.Add(('Last week at this point: {0}% used ({1}).' -f [Math]::Round($p.prev_used, [MidpointRounding]::AwayFromZero), $cmp))
        }
    }
    if ($null -ne $Session) {
        $s = $Session
        if ($s.limited) { [void]$lines.Add(('5-hour limit reached; it resets {0} (in {1}).' -f (Format-LocalTime $s.reset $Now), (Format-Span $s.remaining_h))) }
        elseif ($s.runs_out) { [void]$lines.Add(('5-hour window: {0}% used; at this speed it runs out {1} (in {2}).' -f [Math]::Round($s.used, [MidpointRounding]::AwayFromZero), (Format-LocalTime $s.run_out_at $Now), (Format-Span $s.run_out_in_h))) }
        elseif ($null -ne $s.rate) { [void]$lines.Add(('5-hour window: {0}% used; at this speed it lasts until it resets {1}.' -f [Math]::Round($s.used, [MidpointRounding]::AwayFromZero), (Format-LocalTime $s.reset $Now))) }
    }
    return [pscustomobject]@{ title = $title; level = $level; lines = $lines.ToArray(); pill = $pill }
}

function Test-AlertSent {
    # True when an alert was already shown for this limit window. Keys hold the reset time rounded to the hour,
    # and the reported reset drifts by minutes between readings: one drifting across :30 changes the rounded hour
    # by 1. So a key for the neighbouring hour counts as the same window (#36). Any drift under 30 minutes is
    # covered; different windows of one limit reset at least 5 hours apart, so they never match each other.
    param($Sent, [string]$Kind, [long]$Hour, [string]$Suffix = '')
    foreach ($h in @(($Hour - 1), $Hour, ($Hour + 1))) { if ($Sent.ContainsKey("$Kind`:$h$Suffix")) { return $true } }
    return $false
}

function Get-AlertsDue {
    # Alerts to show now, each at most once per limit window: weekly "% left" thresholds (only the lowest newly
    # crossed one is shown; higher ones are marked as done), 5-hour window at 10% left, and "runs out early".
    param($Data, $WeeklyPace, $Settings, $Sent, [string]$Product, $Now = [DateTime]::UtcNow)
    $out = New-Object System.Collections.ArrayList
    if ($null -eq $Data -or $Data.stale -eq $true -or -not $Settings.alerts) { return @() }
    if (Test-Snoozed $Settings $Now) { return @() }                 # snoozed: due alerts wait until it ends
    $w = $Data.weekly
    $left = Get-Left $w
    $reset = $(if ($null -ne $w) { ConvertTo-UtcTime $w.resets_at } else { $null })
    if ($null -ne $left -and $null -ne $reset) {
        $rk = [long][Math]::Round((ConvertTo-Unix $reset) / 3600.0)
        $crossed = @(@($Settings.alert_at) + 0 | Where-Object { $left -le [double]$_ } | Sort-Object -Unique)
        $new = @($crossed | Where-Object { -not (Test-AlertSent $Sent 'w' $rk ":$_") })
        if ($new.Count -gt 0) {
            $lowest = ($crossed | Measure-Object -Minimum).Minimum
            $when = ('Resets {0} (in {1}).' -f (Format-LocalTime $reset $Now), (Get-ResetText $reset $Now))
            if ($left -le 0) { $title = "$Product`: weekly limit reached" }
            else { $title = ('{0}: {1} of the weekly limit used' -f $Product, (Format-UsedShare (100.0 - $left))) }
            $text = $when
            if ($null -ne $WeeklyPace -and $WeeklyPace.runs_out) { $text += (' At this speed it runs out {0}.' -f (Format-LocalTime $WeeklyPace.run_out_at $Now)) }
            [void]$out.Add([pscustomobject]@{ title = $title; text = $text; keys = @($crossed | ForEach-Object { "w:$rk`:$_" }) })
        }
        if ($Settings.alert_runout -and $null -ne $WeeklyPace -and $WeeklyPace.runs_out -and $null -ne $WeeklyPace.speed_pct -and $WeeklyPace.spare_h -ge 6 -and $left -gt 0 -and -not (Test-AlertSent $Sent 'r' $rk)) {
            [void]$out.Add([pscustomobject]@{
                title = ('{0}: on track to run out early' -f $Product)
                text = ('At this speed the weekly limit runs out {0}, {1} before the reset. To last, keep to about {2}% a day.' -f (Format-LocalTime $WeeklyPace.run_out_at $Now), (Format-Span $WeeklyPace.spare_h), (Format-Share ($WeeklyPace.budget_rate * 24.0)))
                keys = @("r:$rk") })
        }
    }
    $s = $Data.session
    $sl = Get-Left $s
    $sr = $(if ($null -ne $s) { ConvertTo-UtcTime $s.resets_at } else { $null })
    if ($null -ne $sl -and $null -ne $sr -and $sl -le 10) {
        $sh = [long][Math]::Round((ConvertTo-Unix $sr) / 3600.0)
        $sk = "s:$sh"
        if (-not (Test-AlertSent $Sent 's' $sh)) {
            [void]$out.Add([pscustomobject]@{ title = ('{0}: 5-hour limit almost used ({1} used)' -f $Product, (Format-UsedShare (100.0 - $sl))); text = ('It resets {0} (in {1}).' -f (Format-LocalTime $sr $Now), (Get-ResetText $sr $Now)); keys = @($sk) })
        }
    }
    return $out.ToArray()
}

function ConvertTo-Settings {
    # Normalizes settings read from disk; unknown or invalid values fall back to defaults.
    # A hand-edited or damaged value (text where a number belongs, a far-future snooze) never throws: it falls back.
    param($Json, [int]$DefaultPoll = 60, $Now = [DateTime]::UtcNow)
    $s = @{ placement = 'auto'; x = $null; y = $null; poll = $DefaultPoll; pill = 'countdown'; compact = $false; details = $false
            alerts = $true; alert_at = @(25, 10); alert_runout = $true; all_taskbars = $true; snooze_until = 0.0; v = 2 }
    if ($null -eq $Json -or $Json -isnot [pscustomobject]) { return $s }
    $num = {
        param($v)
        if ($null -eq $v -or $v -is [bool]) { return $null }
        $d = 0.0
        if (-not [double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $null }
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
        return $d
    }
    $x = & $num $Json.x; $y = & $num $Json.y
    if ($Json.placement -eq 'manual' -and $null -ne $x -and $null -ne $y -and [Math]::Abs($x) -lt 1e6 -and [Math]::Abs($y) -lt 1e6) {
        $s.placement = 'manual'; $s.x = [int][Math]::Round($x); $s.y = [int][Math]::Round($y)
    }
    $poll = & $num $Json.poll
    if ($null -ne $poll -and @(60, 120, 300, 600) -contains $poll) { $s.poll = [int]$poll }
    # Settings from before v2 saved the old default "budget" without it being a choice: start them on the countdown.
    $ver = & $num $Json.v
    if ($null -ne $ver -and $ver -ge 2 -and @('countdown', 'budget') -contains [string]$Json.pill) { $s.pill = [string]$Json.pill }
    # A snooze never lasts beyond the longest choice (the weekly reset, under 8 days away); anything later is damage.
    $sn = & $num $Json.snooze_until
    if ($null -ne $sn -and $sn -gt 0 -and $sn -le (ConvertTo-Unix (ConvertTo-UtcTime $Now)) + 8 * 86400) { $s.snooze_until = $sn }
    foreach ($b in 'compact', 'details', 'alerts', 'alert_runout', 'all_taskbars') { if ($Json.$b -is [bool]) { $s[$b] = $Json.$b } }
    # Property test, not "$null -ne": an empty list (every threshold unchecked) must stay empty.
    if ($null -ne $Json.PSObject.Properties['alert_at']) {
        $s.alert_at = @(@($Json.alert_at) | ForEach-Object { & $num $_ } | Where-Object { $null -ne $_ -and @(50, 25, 10, 5) -contains $_ } | ForEach-Object { [int]$_ } | Sort-Object -Descending -Unique)
    }
    return $s
}

# ---------------------------------------------------------------- logging / settings / history / alerts

function Write-Log {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { [void](New-Item -ItemType Directory -Path $script:AppDir -Force) }
        if ((Test-Path -LiteralPath $script:LogPath) -and (Get-Item -LiteralPath $script:LogPath).Length -gt 262144) {
            Move-Item -LiteralPath $script:LogPath -Destination "$($script:LogPath).1" -Force
        }
        $line = '{0} {1}' -f [DateTime]::Now.ToString('s'), $Message
        [IO.File]::AppendAllText($script:LogPath, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Write-FlushedText {
    # UTF-8 without BOM, flushed to disk before the caller swaps the file in, so a power cut can't leave it empty.
    param([string]$Path, [string]$Text)
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Text)
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}

function Save-CorruptCopy {
    # Keep a file that failed to parse as <name>.corrupt (last one wins) before it gets rewritten with defaults.
    param([string]$Path)
    try { if (Test-Path -LiteralPath $Path -PathType Leaf) { Copy-Item -LiteralPath $Path -Destination "$Path.corrupt" -Force } } catch { Write-Log "could not keep $(Split-Path -Leaf $Path).corrupt: $($_.Exception.Message)" }
}

function Write-AtomicText {
    # Temp file + swap. [NullString]::Value is required: PowerShell passes $null to a .NET string parameter
    # as "", which makes File.Replace throw "The path is not of a legal form" whenever the target exists.
    param([string]$Path, [string]$Text)
    $tmp = "$Path.$PID.tmp"
    Write-FlushedText $tmp $Text
    for ($i = 0; $i -lt 4; $i++) {
        try {
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch { Start-Sleep -Milliseconds (60 * ($i + 1)) }
    }
    try { [IO.File]::Copy($tmp, $Path, $true) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Read-JsonFile {
    param([string]$Path)
    try { if (Test-Path -LiteralPath $Path) { return ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json) } } catch { Write-Log "unreadable: $(Split-Path -Leaf $Path), kept as .corrupt"; Save-CorruptCopy $Path }
    return $null
}

function Read-Settings { return (ConvertTo-Settings (Read-JsonFile $script:SettingsPath) $script:DefaultPollSeconds) }

function Save-Settings {
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { [void](New-Item -ItemType Directory -Path $script:AppDir -Force) }
        $s = $script:Settings
        $o = [ordered]@{ v = 2; placement = $s.placement; x = $s.x; y = $s.y; poll = $s.poll; pill = $s.pill; compact = $s.compact; details = [bool]$s.details
                         alerts = $s.alerts; alert_at = @($s.alert_at); alert_runout = $s.alert_runout; all_taskbars = $s.all_taskbars; snooze_until = [long]$s.snooze_until }
        Write-AtomicText $script:SettingsPath (ConvertTo-Json -InputObject $o)
    } catch { Write-Log "could not save settings: $($_.Exception.Message)" }
}

function New-History { return @{ w = (New-Object System.Collections.ArrayList); s = (New-Object System.Collections.ArrayList); m = @{}; c = (New-Object System.Collections.ArrayList) } }

function Read-History {
    param([string]$Path)
    $h = New-History
    try {
        if (Test-Path -LiteralPath $Path) {
            $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in 'w', 's') {
                foreach ($row in @($j.$k)) {
                    $a = @($row)
                    if ($a.Count -ge 3 -and $null -ne $a[0] -and $null -ne $a[1] -and $null -ne $a[2]) { [void]$h[$k].Add(@{ t = [double]$a[0]; u = [double]$a[1]; r = [double]$a[2] }) }
                }
            }
            if ($null -ne $j.m) {
                foreach ($p in $j.m.PSObject.Properties) {
                    $list = New-Object System.Collections.ArrayList
                    foreach ($row in @($p.Value)) { $a = @($row); if ($a.Count -ge 3) { [void]$list.Add(@{ t = [double]$a[0]; u = [double]$a[1]; r = [double]$a[2] }) } }
                    $h.m[$p.Name] = $list
                }
            }
            foreach ($row in @($j.c)) { $a = @($row); if ($a.Count -ge 2 -and $null -ne $a[0] -and $null -ne $a[1]) { [void]$h.c.Add(@{ t = [double]$a[0]; v = [double]$a[1] }) } }
        }
    } catch { Write-Log 'history unreadable; kept as .corrupt, starting a new one'; Save-CorruptCopy $Path }
    return $h
}

function Add-WindowSample {
    # One reading per window at most every 5 minutes (and at every reset). Returns $true if added.
    param($List, [double]$T, $Window)
    $left = Get-Left $Window
    if ($null -eq $left) { return $false }
    $r = ConvertTo-UtcTime $Window.resets_at
    if ($null -eq $r) { return $false }
    $rU = ConvertTo-Unix $r
    $last = $(if ($List.Count -gt 0) { $List[$List.Count - 1] } else { $null })
    if ($null -ne $last) {
        if ($T -le [double]$last.t) { return $false }
        if ([Math]::Abs([double]$last.r - $rU) -le 3600 -and ($T - [double]$last.t) -lt 300) { return $false }
    }
    [void]$List.Add(@{ t = $T; u = (100.0 - $left); r = $rU })
    return $true
}

function Get-SpendValue {
    # Codex: credit balance; Claude: extra-usage % of the monthly limit. $null when not available.
    param($Data)
    if ($null -ne $Data.credits -and $null -ne $Data.credits.balance) { return [double]$Data.credits.balance }
    $ex = $Data.extra_usage
    if ($null -ne $ex -and $ex.enabled -eq $true -and $null -ne $ex.utilization) { return [double]$ex.utilization }
    return $null
}

function Add-HistorySample {
    param($History, $Data)
    if ($null -eq $Data -or $Data.stale -eq $true) { return $false }
    $t = ConvertTo-UtcTime $Data.fetched_at
    if ($null -eq $t) { return $false }
    $tU = ConvertTo-Unix $t
    $added = $false
    if ($null -ne $Data.weekly -and (Add-WindowSample $History.w $tU $Data.weekly)) { $added = $true }
    if ($null -ne $Data.session -and (Add-WindowSample $History.s $tU $Data.session)) { $added = $true }
    foreach ($sc in @($Data.scoped)) {
        if ($null -eq $sc -or -not $sc.id) { continue }
        $id = ([string]$sc.id) -replace '[^A-Za-z0-9_.:-]', '_'
        if (-not $History.m.ContainsKey($id)) { $History.m[$id] = New-Object System.Collections.ArrayList }
        if (Add-WindowSample $History.m[$id] $tU $sc) { $added = $true }
    }
    $v = Get-SpendValue $Data
    if ($null -ne $v) {
        $c = $History.c
        $last = $(if ($c.Count -gt 0) { $c[$c.Count - 1] } else { $null })
        if ($null -eq $last -or ($tU -gt [double]$last.t -and ([Math]::Abs([double]$last.v - $v) -gt 0.0001 -or ($tU - [double]$last.t) -ge 1800))) {
            [void]$c.Add(@{ t = $tU; v = $v }); $added = $true
        }
    }
    return $added
}

function ConvertTo-HistoryJson {
    param($History, [double]$NowUnix)
    $keepW = $script:HistoryDays * 86400.0
    $rowsOf = {
        param($List, [double]$Keep)
        $r = foreach ($x in @($List)) {
            if ($NowUnix - [double]$x.t -gt $Keep) { continue }
            '[{0},{1},{2}]' -f [long]$x.t, ([double]$x.u).ToString('0.##', $script:Inv), [long]$x.r
        }
        return (@($r) -join ',')
    }
    $m = foreach ($k in @($History.m.Keys | Sort-Object)) {
        $rows = & $rowsOf $History.m[$k] $keepW
        if ($rows) { '"{0}":[{1}]' -f $k, $rows }
    }
    $c = foreach ($x in @($History.c)) {
        if ($NowUnix - [double]$x.t -gt $keepW) { continue }
        '[{0},{1}]' -f [long]$x.t, ([double]$x.v).ToString('0.####', $script:Inv)
    }
    return ('{"v":2,"w":[' + (& $rowsOf $History.w $keepW) + '],"s":[' + (& $rowsOf $History.s 86400.0) + '],"m":{' + (@($m) -join ',') + '},"c":[' + (@($c) -join ',') + ']}')
}

function Save-History {
    try {
        if (-not (Test-Path -LiteralPath $script:AppDir)) { [void](New-Item -ItemType Directory -Path $script:AppDir -Force) }
        $nowU = ConvertTo-Unix ([DateTime]::UtcNow)
        Write-AtomicText $script:HistoryPath (ConvertTo-HistoryJson $script:History $nowU)
        $script:History = Read-History $script:HistoryPath       # drops pruned rows from memory too
        $script:HistoryDirty = $false
        $script:HistorySavedAt = [DateTime]::UtcNow
    } catch { Write-Log "could not save history: $($_.Exception.Message)" }
}

function Read-AlertsSent {
    # A damaged alerts.json must never stop the widget from starting (#29): bad values are skipped, and anything
    # that is not a JSON object gives an empty set (at worst an alert shows once more).
    try {
        $h = @{}
        $j = Read-JsonFile $script:AlertsPath
        if ($null -eq $j -or -not ($j -is [Management.Automation.PSCustomObject])) { return @{} }
        foreach ($p in $j.PSObject.Properties) {
            $v = 0.0
            if ($null -ne $p.Value -and -not ($p.Value -is [Array]) -and [double]::TryParse([string]$p.Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and -not [double]::IsNaN($v) -and -not [double]::IsInfinity($v)) { $h[$p.Name] = $v }
        }
        return $h
    } catch {
        Write-Log "alerts.json ignored: $($_.Exception.Message)"
        return @{}
    }
}

function Save-AlertsSent {
    try {
        $cut = (ConvertTo-Unix ([DateTime]::UtcNow)) - 16 * 86400
        $o = [ordered]@{}
        foreach ($k in @($script:AlertsSent.Keys | Sort-Object)) { if ($script:AlertsSent[$k] -ge $cut) { $o[$k] = [long]$script:AlertsSent[$k] } }
        Write-AtomicText $script:AlertsPath (ConvertTo-Json -InputObject $o -Compress)
    } catch { Write-Log "could not save alerts: $($_.Exception.Message)" }
}

function Show-Toast {
    # Windows notification through Windows PowerShell's registered app id (no registration needed).
    param([string]$Title, [string]$Text)
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        # Clicking the notification opens the usage page; the attribution line names the widget (the app shown is PowerShell).
        $xml.LoadXml(('<toast activationType="protocol" launch="{2}"><visual><binding template="ToastGeneric"><text>{0}</text><text>{1}</text><text placement="attribution">{3}</text></binding></visual></toast>' -f
            [Security.SecurityElement]::Escape($Title), [Security.SecurityElement]::Escape($Text), [Security.SecurityElement]::Escape($script:UsageUrl), [Security.SecurityElement]::Escape("$($script:ProductName) usage widget")))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($script:ToastAppId).Show($toast)
        Write-Log "alert shown: $Title"
        return $true
    } catch { Write-Log "alert failed: $($_.Exception.Message)"; return $false }
}

function Invoke-Alerts {
    param($Data)
    $wp = $(if ($null -ne $Data.weekly) { Get-PaceInfo $Data.weekly (Get-WindowSamples 'w') } else { $null })
    $due = @(Get-AlertsDue $Data $wp $script:Settings $script:AlertsSent $script:ProductName)
    if ($due.Count -eq 0) { return }
    $nowU = ConvertTo-Unix ([DateTime]::UtcNow)
    if ($null -eq $script:AlertRetryAt) { $script:AlertRetryAt = @{} }
    $shown = $false
    foreach ($a in $due) {
        $key = (@($a.keys) -join '|')
        if ($script:AlertRetryAt.ContainsKey($key) -and $script:AlertRetryAt[$key] -gt $nowU) { continue }
        if (Show-Toast $a.title $a.text) {
            foreach ($k in $a.keys) { $script:AlertsSent[$k] = $nowU }
            $script:AlertRetryAt.Remove($key)
            $shown = $true
        } else {
            # Windows refused the notification: keep the alert due and try again in 15 minutes.
            $script:AlertRetryAt[$key] = $nowU + 900
        }
    }
    if ($shown) { Save-AlertsSent }
}

# ---------------------------------------------------------------- Win32 / WPF setup

function Initialize-Native {
    if (-not ('UsageWidget.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace UsageWidget {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    public class WinInfo { public IntPtr Handle; public uint Pid; public int Left, Top, Right, Bottom; }
    public static class Native {
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
        [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr MonitorFromRect(ref RECT r, uint flags);
        [DllImport("user32.dll")] public static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFO mi);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int index);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int index, int value);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr hWnd);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
        [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out int value, int size);
        delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);

        // Visible, non-minimized, non-cloaked top-level windows with exactly this title.
        public static List<WinInfo> FindVisibleByTitle(string title) {
            List<WinInfo> list = new List<WinInfo>();
            EnumWindows(delegate (IntPtr h, IntPtr l) {
                int len = GetWindowTextLength(h);
                if (len != title.Length) return true;
                StringBuilder sb = new StringBuilder(len + 1);
                GetWindowText(h, sb, sb.Capacity);
                if (sb.ToString() != title) return true;
                if (!IsWindowVisible(h) || IsIconic(h)) return true;
                int cloaked = 0;
                if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;
                RECT r;
                if (!GetWindowRect(h, out r) || r.Right <= r.Left || r.Bottom <= r.Top) return true;
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                WinInfo w = new WinInfo();
                w.Handle = h; w.Pid = pid; w.Left = r.Left; w.Top = r.Top; w.Right = r.Right; w.Bottom = r.Bottom;
                list.Add(w);
                return true;
            }, IntPtr.Zero);
            return list;
        }

        // Visible top-level windows of a class (e.g. the secondary taskbars "Shell_SecondaryTrayWnd").
        public static List<IntPtr> FindAllByClass(string cls) {
            List<IntPtr> list = new List<IntPtr>();
            EnumWindows(delegate (IntPtr h, IntPtr l) {
                StringBuilder sb = new StringBuilder(64);
                GetClassName(h, sb, 64);
                if (sb.ToString() == cls && IsWindowVisible(h)) list.Add(h);
                return true;
            }, IntPtr.Zero);
            return list;
        }

        public static RECT MonitorRect(RECT r, bool nearest) {
            RECT res = new RECT();
            IntPtr m = MonitorFromRect(ref r, nearest ? 2u : 0u);
            if (m == IntPtr.Zero) return res;
            MONITORINFO mi = new MONITORINFO();
            mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (GetMonitorInfo(m, ref mi)) res = mi.rcMonitor;
            return res;
        }

        // Shell surfaces that cover the whole monitor for a moment (Start, Search, Task View, Alt+Tab, the
        // notification center, taskbar thumbnails) but are not full-screen apps: the pills stay visible.
        static readonly string[] ShellClasses = { "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd",
            "MultitaskingViewFrame", "XamlExplorerHostIslandWindow", "TaskListThumbnailWnd", "ForegroundStaging",
            "Windows.UI.Input.InputSite.WindowClass", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland" };
        static readonly string[] ShellProcesses = { "explorer", "StartMenuExperienceHost", "SearchHost", "SearchApp",
            "ShellExperienceHost", "ShellHost", "TextInputHost" };

        public static bool IsShellSurface(string cls, string process) {
            if (Array.IndexOf(ShellClasses, cls) >= 0) return true;
            foreach (string p in ShellProcesses) if (string.Equals(p, process, StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }

        static string ProcessName(uint pid) {
            try { using (Process p = Process.GetProcessById((int)pid)) return p.ProcessName; } catch { return ""; }
        }

        // True when the foreground window (not the desktop, a taskbar, a shell overlay or our own process)
        // covers the whole monitor that contains rect r: a full-screen game, video, presentation or the lock screen.
        public static bool FullscreenInFront(RECT r, uint ownPid) {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return false;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == ownPid) return false;
            StringBuilder sb = new StringBuilder(128);
            GetClassName(h, sb, 128);
            string c = sb.ToString();
            if (Array.IndexOf(ShellClasses, c) >= 0) return false;
            RECT w;
            if (!GetWindowRect(h, out w)) return false;
            RECT m = MonitorRect(r, true);
            if (m.Right <= m.Left) return false;
            if (!(w.Left <= m.Left && w.Top <= m.Top && w.Right >= m.Right && w.Bottom >= m.Bottom)) return false;
            return !IsShellSurface(c, ProcessName(pid));
        }

        // Clicking the taskbar raises it above every topmost window until the pills re-assert themselves.
        // A foreground-change hook puts the pills back on top at once instead of up to 1.5 s later.
        delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
        [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
        static WinEventProc foregroundProc;
        static IntPtr foregroundHook = IntPtr.Zero;
        static IntPtr[] topmostHandles = new IntPtr[0];
        static int foregroundChanges;

        public static void SetTopmostHandles(IntPtr[] handles) { topmostHandles = handles ?? new IntPtr[0]; }

        public static void RaiseTopmost() {
            foreach (IntPtr h in topmostHandles) {
                if (h != IntPtr.Zero && IsWindow(h) && IsWindowVisible(h))
                    SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0200);   // NOSIZE NOMOVE NOACTIVATE NOOWNERZORDER
            }
        }

        public static bool WatchForeground() {
            if (foregroundHook != IntPtr.Zero) return true;
            foregroundProc = delegate (IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
                foregroundChanges++;
                RaiseTopmost();
            };
            // EVENT_SYSTEM_FOREGROUND, out of context: delivered on this (UI) thread's message loop.
            foregroundHook = SetWinEventHook(3, 3, IntPtr.Zero, foregroundProc, 0, 0, 0);
            return foregroundHook != IntPtr.Zero;
        }

        public static int TakeForegroundChanges() { int n = foregroundChanges; foregroundChanges = 0; return n; }
    }
}
'@
    }
}

# ---------------------------------------------------------------- UI construction

$script:PillXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Usage" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        ShowActivated="False" Opacity="0" Left="-32000" Top="-32000"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Border x:Name="Pill" CornerRadius="8" BorderThickness="1" Padding="5,0,11,0" Height="35" MinWidth="88" Cursor="Hand">
    <StackPanel x:Name="PillContent" Orientation="Horizontal" VerticalAlignment="Center">
      <Grid Width="26" Height="26" Margin="0,0,8,0" VerticalAlignment="Center">
        <Ellipse x:Name="RingTrack" StrokeThickness="3.5"/>
        <Path x:Name="Ring" StrokeThickness="3.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
        <TextBlock x:Name="Badge" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="9" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed" Text="&#xE708;"/>
      </Grid>
      <StackPanel VerticalAlignment="Center">
        <TextBlock x:Name="Hero" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="16" FontWeight="SemiBold" Margin="0,-3,0,0"><Run x:Name="HeroNum" Text="..."/><Run x:Name="HeroPct" FontSize="10.5" FontWeight="Normal" Text=""/><Run x:Name="HeroTag" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="10" FontWeight="Normal" Text=""/></TextBlock>
        <TextBlock x:Name="Sub" FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="10" Margin="0,-3,0,0" Text=""/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

$script:MenuXaml = @'
<ContextMenu xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="12.5" HasDropShadow="False">
  <ContextMenu.Resources>
    <Style x:Key="{x:Static MenuItem.SeparatorStyleKey}" TargetType="Separator">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Separator">
            <Border Height="1" Margin="12,4,12,4" Background="{DynamicResource MenuLine}"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="MenuItem">
      <Setter Property="Foreground" Value="{DynamicResource MenuFg}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Grid>
              <Border x:Name="Bd" Margin="5,1,5,1" Padding="8,7,10,7" CornerRadius="5" Background="Transparent" SnapsToDevicePixels="True">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="28"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <ContentPresenter x:Name="Ico" ContentSource="Icon" VerticalAlignment="Center" HorizontalAlignment="Left"
                                    TextElement.FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" TextElement.FontSize="14"
                                    TextElement.Foreground="{DynamicResource MenuDim}"/>
                  <TextBlock x:Name="Chk" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13"
                             VerticalAlignment="Center" Foreground="{DynamicResource MenuAccent}" Visibility="Collapsed"/>
                  <ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="True" VerticalAlignment="Center" Margin="0,0,22,0"/>
                  <TextBlock x:Name="Arrow" Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10"
                             VerticalAlignment="Center" Foreground="{DynamicResource MenuDim}" Visibility="Collapsed"/>
                </Grid>
              </Border>
              <Popup x:Name="PART_Popup" Placement="Right" HorizontalOffset="-4" VerticalOffset="-6" AllowsTransparency="True" Focusable="False"
                     PopupAnimation="Fade" IsOpen="{Binding IsSubmenuOpen, RelativeSource={RelativeSource TemplatedParent}}">
                <Border Margin="0,0,14,14" Background="{DynamicResource MenuBg}" BorderBrush="{DynamicResource MenuLine}" BorderThickness="1" CornerRadius="8" Padding="0,4,0,4">
                  <Border.Effect>
                    <DropShadowEffect BlurRadius="14" ShadowDepth="4" Direction="270" Opacity="0.32" Color="#000000"/>
                  </Border.Effect>
                  <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Cycle" KeyboardNavigation.TabNavigation="Cycle"/>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MenuHover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Chk" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Ico" Property="Visibility" Value="Collapsed"/>
              </Trigger>
              <Trigger Property="HasItems" Value="True">
                <Setter TargetName="Arrow" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </ContextMenu.Resources>
  <ContextMenu.Template>
    <ControlTemplate TargetType="ContextMenu">
      <Border Margin="0,0,16,16" Background="{DynamicResource MenuBg}" BorderBrush="{DynamicResource MenuLine}" BorderThickness="1" CornerRadius="8" Padding="0,4,0,4">
        <Border.Effect>
          <DropShadowEffect BlurRadius="18" ShadowDepth="5" Direction="270" Opacity="0.35" Color="#000000"/>
        </Border.Effect>
        <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Cycle"/>
      </Border>
    </ControlTemplate>
  </ContextMenu.Template>
  <MenuItem x:Name="MenuRefresh" Header="_Refresh now" Icon="&#xE72C;"/>
  <MenuItem x:Name="MenuOpen" Header="_Open usage page" Icon="&#xE8A7;"/>
  <MenuItem x:Name="MenuSignIn" Header="_Sign in again..." Icon="&#xE77B;"/>
  <Separator/>
  <MenuItem x:Name="MenuSnooze" Header="Snoo_ze alerts" Icon="&#xE708;">
    <MenuItem x:Name="MenuSnooze1h" Header="For 1 hour" Icon="&#xE916;"/>
    <MenuItem x:Name="MenuSnoozeMorning" Header="Until tomorrow morning" Icon="&#xE787;"/>
    <MenuItem x:Name="MenuSnoozeReset" Header="Until the weekly reset" Icon="&#xE72C;"/>
    <Separator/>
    <MenuItem x:Name="MenuSnoozeOff" Header="Resume alerts now" Icon="&#xE768;"/>
  </MenuItem>
  <MenuItem x:Name="MenuAlerts" Header="_Alerts" Icon="&#xEA8F;">
    <MenuItem x:Name="MenuAlertsOn" Header="Show alerts" IsCheckable="True"/>
    <Separator/>
    <MenuItem x:Name="MenuAlert50" Header="At 50% used" IsCheckable="True" Tag="50"/>
    <MenuItem x:Name="MenuAlert25" Header="At 75% used" IsCheckable="True" Tag="25"/>
    <MenuItem x:Name="MenuAlert10" Header="At 90% used" IsCheckable="True" Tag="10"/>
    <MenuItem x:Name="MenuAlert5" Header="At 95% used" IsCheckable="True" Tag="5"/>
    <MenuItem x:Name="MenuAlertRunOut" Header="When it will run out before the reset" IsCheckable="True"/>
    <Separator/>
    <MenuItem x:Name="MenuAlertTest" Header="Send a test alert" Icon="&#xE724;"/>
  </MenuItem>
  <MenuItem x:Name="MenuPill" Header="_Pill shows" Icon="&#xE890;">
    <MenuItem x:Name="MenuPillBudget" Header="Today's budget" IsCheckable="True" Tag="budget"/>
    <MenuItem x:Name="MenuPillCountdown" Header="Time until reset" IsCheckable="True" Tag="countdown"/>
  </MenuItem>
  <MenuItem x:Name="MenuPoll" Header="Refresh _every" Icon="&#xE916;">
    <MenuItem x:Name="MenuPoll60" Header="1 minute" IsCheckable="True" Tag="60"/>
    <MenuItem x:Name="MenuPoll120" Header="2 minutes" IsCheckable="True" Tag="120"/>
    <MenuItem x:Name="MenuPoll300" Header="5 minutes" IsCheckable="True" Tag="300"/>
    <MenuItem x:Name="MenuPoll600" Header="10 minutes" IsCheckable="True" Tag="600"/>
  </MenuItem>
  <MenuItem x:Name="MenuCompact" Header="_Compact pill" IsCheckable="True" Icon="&#xE73F;"/>
  <MenuItem x:Name="MenuDetails" Header="Show _details (chart, pace breakdown)" IsCheckable="True" Icon="&#xE9D2;"/>
  <MenuItem x:Name="MenuAllBars" Header="Show on every _taskbar" IsCheckable="True" Icon="&#xE7F4;"/>
  <Separator/>
  <MenuItem x:Name="MenuReset" Header="Reset _position" Icon="&#xE7A7;"/>
  <MenuItem x:Name="MenuStartup" Header="Start with _Windows" IsCheckable="True" Icon="&#xE7E8;"/>
  <MenuItem x:Name="MenuLog" Header="Open _data folder" Icon="&#xE8B7;"/>
  <MenuItem x:Name="MenuUninstall" Header="_Uninstall..." Icon="&#xE74D;"/>
  <Separator/>
  <MenuItem x:Name="MenuAbout" Header="About" Icon="&#xE946;"/>
  <MenuItem x:Name="MenuExit" Header="E_xit" Icon="&#xE8BB;"/>
</ContextMenu>
'@

$script:CardXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Usage details" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" ResizeMode="NoResize" SizeToContent="Height" Width="330"
        ShowActivated="False" Opacity="0" Left="-32000" Top="-32000" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display" IsHitTestVisible="False" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Border x:Name="Card" Margin="14" CornerRadius="8" BorderThickness="1" Padding="15,13,15,11">
    <Border.Effect>
      <DropShadowEffect BlurRadius="24" ShadowDepth="4" Direction="270" Opacity="0.35" Color="#000000"/>
    </Border.Effect>
    <StackPanel>
      <Grid>
        <TextBlock x:Name="CardTitle" Text="Usage" FontSize="13" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <Border x:Name="PlanBadge" HorizontalAlignment="Right" VerticalAlignment="Center" CornerRadius="10" Padding="8,2,8,3">
          <TextBlock x:Name="PlanText" FontSize="10.5"/>
        </Border>
      </Grid>
      <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
        <TextBlock x:Name="CardHero" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="30" Text="..." VerticalAlignment="Bottom"/>
        <TextBlock x:Name="CardHeroLabel" Text="used this week" FontSize="12" Margin="6,0,0,6" VerticalAlignment="Bottom"/>
      </StackPanel>
      <StackPanel x:Name="HeroLines"/>
      <Border x:Name="StatusBar" CornerRadius="7" BorderThickness="1" Padding="10,6,10,8" Margin="0,10,0,0" Visibility="Collapsed">
        <StackPanel>
          <TextBlock x:Name="StatusLabel" FontSize="10.5"/>
          <TextBlock x:Name="StatusText" TextWrapping="Wrap" FontSize="11" Margin="0,4,0,0"/>
        </StackPanel>
      </Border>
      <Border x:Name="PaceBox" CornerRadius="7" BorderThickness="1" Padding="10,6,10,8" Margin="0,10,0,0" Visibility="Collapsed">
        <StackPanel>
          <Grid>
            <TextBlock x:Name="PaceLabel" Text="PACE THIS WEEK" FontSize="10.5" VerticalAlignment="Center"/>
            <TextBlock x:Name="PaceStatus" FontSize="12" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
          <Border x:Name="PaceBarHost" Margin="0,7,0,0"/>
          <TextBlock x:Name="PaceText" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>
        </StackPanel>
      </Border>
      <Border x:Name="SessionPaceBox" CornerRadius="7" BorderThickness="1" Padding="10,6,10,8" Margin="0,8,0,0" Visibility="Collapsed">
        <StackPanel>
          <Grid>
            <TextBlock x:Name="SessionPaceLabel" Text="PACE THIS 5-HOUR SESSION" FontSize="10.5" VerticalAlignment="Center"/>
            <TextBlock x:Name="SessionPaceStatus" FontSize="12" HorizontalAlignment="Right" VerticalAlignment="Center"/>
          </Grid>
          <Border x:Name="SessionPaceBarHost" Margin="0,7,0,0"/>
          <TextBlock x:Name="SessionPaceText" FontSize="11" TextWrapping="Wrap" Margin="0,6,0,0"/>
        </StackPanel>
      </Border>
      <Border x:Name="TopDivider" Height="1" Margin="0,12,0,0"/>
      <StackPanel x:Name="Rows"/>
      <StackPanel x:Name="ChartPanel" Margin="0,14,0,0" Visibility="Collapsed">
        <Grid>
          <TextBlock x:Name="ChartTitle" Text="This week" FontSize="12.5" FontWeight="SemiBold"/>
          <TextBlock x:Name="ChartLegend" HorizontalAlignment="Right" FontSize="10.5" VerticalAlignment="Center"/>
        </Grid>
        <Border x:Name="ChartFrame" Margin="0,7,0,0" CornerRadius="6" BorderThickness="1" ClipToBounds="True">
          <Canvas x:Name="Chart" Width="268" Height="56" ClipToBounds="True"/>
        </Border>
        <Grid Margin="1,4,1,0">
          <TextBlock x:Name="ChartStart" FontSize="10.5"/>
          <TextBlock x:Name="ChartEnd" HorizontalAlignment="Right" FontSize="10.5"/>
        </Grid>
      </StackPanel>
      <StackPanel x:Name="PaceLines" Margin="0,8,0,0" Visibility="Collapsed"/>
      <Border x:Name="Divider" Height="1" Margin="0,13,0,0"/>
      <TextBlock x:Name="FooterText" FontSize="11" Margin="0,9,0,0" TextWrapping="Wrap"/>
    </StackPanel>
  </Border>
</Window>
'@

function New-FromXaml {
    param([string]$Xaml)
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
    return [Windows.Markup.XamlReader]::Load($reader)
}

function Get-Brush {
    param([string]$Hex)
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}

function Get-ThemeName {
    try {
        $v = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'SystemUsesLightTheme' -ErrorAction Stop
        if ($v -eq 1) { return 'light' }
    } catch { }
    return 'dark'
}

function Get-Hwnd {
    param($Window)
    return (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
}

function Set-ToolWindowStyle {
    param($Window)
    $h = Get-Hwnd $Window
    $GWL_EXSTYLE = -20; $WS_EX_TOOLWINDOW = 0x80; $WS_EX_NOACTIVATE = 0x08000000
    $ex = [UsageWidget.Native]::GetWindowLong($h, $GWL_EXSTYLE)
    [void][UsageWidget.Native]::SetWindowLong($h, $GWL_EXSTYLE, ($ex -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE))
}

function Get-WinRect {
    param([IntPtr]$Handle)
    $r = New-Object UsageWidget.RECT
    [void][UsageWidget.Native]::GetWindowRect($Handle, [ref]$r)
    return $r
}

function Move-WindowPx {
    # Position in PHYSICAL pixels; keeps the window topmost and never activates it.
    param([IntPtr]$Handle, [int]$X, [int]$Y)
    $SWP_NOSIZE = 0x1; $SWP_NOACTIVATE = 0x10
    [void][UsageWidget.Native]::SetWindowPos($Handle, [IntPtr](-1), $X, $Y, 0, 0, ($SWP_NOSIZE -bor $SWP_NOACTIVATE))
}

# ---------------------------------------------------------------- placement

function Get-PrimaryBar { return [UsageWidget.Native]::FindWindow('Shell_TrayWnd', $null) }

function Get-TaskbarRect {
    param([IntPtr]$Bar = [IntPtr]::Zero)
    if ($Bar -eq [IntPtr]::Zero) { $Bar = Get-PrimaryBar }
    if ($Bar -eq [IntPtr]::Zero -or -not [UsageWidget.Native]::IsWindow($Bar)) { return $null }
    return (Get-WinRect $Bar)
}

function Get-TrayRect {
    $tb = Get-PrimaryBar
    if ($tb -eq [IntPtr]::Zero) { return $null }
    $t = [UsageWidget.Native]::FindWindowEx($tb, [IntPtr]::Zero, 'TrayNotifyWnd', $null)
    if ($t -eq [IntPtr]::Zero) { return $null }
    $r = Get-WinRect $t
    if ($r.Right -le $r.Left) { return $null }
    return $r
}

function Find-AnchorPill {
    # Visible anchor pill ("Claude usage", for the Codex widget) on the given taskbar that is not ours.
    param($BarRect)
    if (-not $script:AnchorTitle) { return $null }
    $cands = @([UsageWidget.Native]::FindVisibleByTitle($script:AnchorTitle) | Where-Object { $_.Pid -ne $PID })
    if ($cands.Count -eq 0) { return $null }
    if ($null -ne $BarRect) {
        $cands = @($cands | Where-Object { $_.Left -lt $BarRect.Right -and $_.Right -gt $BarRect.Left -and $_.Top -lt $BarRect.Bottom -and $_.Bottom -gt $BarRect.Top })
        if ($cands.Count -eq 0) { return $null }
    }
    return ($cands | Sort-Object { $_.Bottom - $_.Top } | Select-Object -First 1)
}

function Get-TaskbarCenteredY {
    # Top Y (physical px) that centres a pill of height H on a horizontal taskbar spanning X; $null otherwise.
    param([int]$X, [int]$W, [int]$H, $Bar = $null)
    $tb = $(if ($null -ne $Bar) { $Bar } else { Get-TaskbarRect })
    if ($null -eq $tb -or ($tb.Right - $tb.Left) -lt ($tb.Bottom - $tb.Top)) { return $null }
    $mid = $X + [int]($W / 2)
    if ($mid -lt $tb.Left -or $mid -gt $tb.Right) { return $null }
    return ($tb.Top + [int][Math]::Round((($tb.Bottom - $tb.Top) - $H) / 2.0))
}

function Test-PointOnMonitor {
    param([int]$X, [int]$Y)
    $p = New-Object UsageWidget.POINT
    $p.X = $X; $p.Y = $Y
    return ([UsageWidget.Native]::MonitorFromPoint($p, 0) -ne [IntPtr]::Zero)
}

function Get-ClearX {
    # Shifts a pill left so it never covers the notification area or (Codex) the anchor pill on the same row.
    param([int]$X, [int]$Y, [int]$W, [int]$H, $Tray, $Anchor)
    $gap = $script:AnchorGapPx
    foreach ($ob in @($Tray, $Anchor)) {
        if ($null -eq $ob) { continue }
        $overlapY = ($Y -lt $ob.Bottom -and ($Y + $H) -gt $ob.Top)
        $overlapX = ($X -lt ($ob.Right + $gap) -and ($X + $W + $gap) -gt $ob.Left)
        if ($overlapY -and $overlapX) { $X = $ob.Left - $gap - $W }
    }
    # The anchor may itself sit left of the tray: one more pass keeps both rules.
    if ($null -ne $Tray -and $Y -lt $Tray.Bottom -and ($Y + $H) -gt $Tray.Top -and ($X + $W + $gap) -gt $Tray.Left -and $X -lt ($Tray.Right + $gap)) { $X = $Tray.Left - $gap - $W }
    return $X
}

function Get-ClampedPosition {
    # Moves a W x H rectangle at (X, Y) fully inside the monitor bounds (physical px). An empty monitor rect
    # (monitor not found) leaves the position as it is.
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$Left, [int]$Top, [int]$Right, [int]$Bottom)
    if ($Right -le $Left -or $Bottom -le $Top) { return @{ x = $X; y = $Y } }
    $nx = [Math]::Max($Left, [Math]::Min($X, $Right - $W))
    $ny = [Math]::Max($Top, [Math]::Min($Y, $Bottom - $H))
    return @{ x = [int]$nx; y = [int]$ny }
}

function Get-TargetPosition {
    # Where pill $P (W x H physical px) belongs. Primary: manual > anchor > tray. Other taskbars: anchor > right end.
    param($P, [int]$W, [int]$H)
    $bar = Get-TaskbarRect $P.Bar
    if ($null -eq $bar) { return @{ x = 100; y = 100; mode = 'fallback'; note = 'Taskbar not found; using a safe visible position.' } }
    $horizontal = (($bar.Right - $bar.Left) -ge ($bar.Bottom - $bar.Top))
    $tray = $(if ($P.Primary) { Get-TrayRect } else { $null })
    $anchor = Find-AnchorPill $bar
    # 1) saved manual position (main pill only), if still on a connected monitor
    if ($P.Primary -and $script:Settings.placement -eq 'manual') {
        $x = [int]$script:Settings.x; $y = [int]$script:Settings.y
        # Dragging is horizontal only: keep the saved X but re-centre on the taskbar it sits on, so a taskbar
        # that changed height (e.g. after a restart) never leaves the pill hanging off the screen edge.
        $cy = Get-TaskbarCenteredY $x $W $H $bar
        if ($null -ne $cy) { $y = $cy }
        $cx = Get-ClearX $x $y $W $H $tray $anchor
        if ((Test-PointOnMonitor ($cx + [int]($W / 2)) ($y + [int]($H / 2)))) {
            $note = $(if ($cx -ne $x) { 'Moved left so it does not cover the notification area or the Claude pill.' } else { $null })
            return @{ x = $cx; y = $y; mode = 'manual'; note = $note }
        }
    }
    # 2) immediately left of the visible anchor pill (Codex only). If the anchor just vanished (it hides for a
    #    full-screen app, or is restarting), hold the current spot for a few seconds instead of jumping.
    if ($null -ne $anchor) { $P.AnchorSeenAt = [DateTime]::UtcNow }
    elseif ($P.Mode -like 'anchor*' -and $null -ne $P.AnchorSeenAt -and $null -ne $P.Hwnd -and ([DateTime]::UtcNow - $P.AnchorSeenAt).TotalSeconds -lt 5) {
        $cur = Get-WinRect $P.Hwnd
        return @{ x = $cur.Left; y = $cur.Top; mode = $P.Mode; note = $P.Note }
    }
    if ($null -ne $anchor) {
        $x = $anchor.Left - $script:AnchorGapPx - $W
        $y = $anchor.Top + [int][Math]::Round((($anchor.Bottom - $anchor.Top) - $H) / 2.0)
        $cr = New-Object UsageWidget.RECT
        $cr.Left = $anchor.Left; $cr.Top = $anchor.Top; $cr.Right = $anchor.Right; $cr.Bottom = $anchor.Bottom
        $mon = [UsageWidget.Native]::MonitorRect($cr, $true)
        if ($x -ge $mon.Left) { return @{ x = $x; y = $y; mode = 'anchor'; note = $null } }
        # Not enough room to the left: sit just above the anchor instead of covering it.
        return @{ x = [Math]::Max($mon.Left, $anchor.Right - $W); y = $anchor.Top - $script:AnchorGapPx - $H; mode = 'anchor-above'
                  note = 'Not enough room left of the Claude widget; placed above it.' }
    }
    # 3) left of the notification area (main taskbar) / near the right end (other taskbars, which keep a clock there)
    if ($horizontal) {
        $scale = $(if ($null -ne $P.Win) { [Windows.Media.VisualTreeHelper]::GetDpi($P.Win).DpiScaleX } else { 1.0 })
        $right = $(if ($null -ne $tray) { $tray.Left } else { $bar.Right - [int](200 * $scale) })
        return @{ x = $right - $script:AnchorGapPx - $W; y = $bar.Top + [int][Math]::Round((($bar.Bottom - $bar.Top) - $H) / 2.0); mode = 'tray'; note = $null }
    }
    $bottom = $(if ($null -ne $tray -and $tray.Bottom -gt $tray.Top) { $tray.Top } else { $bar.Bottom - 220 })
    return @{ x = $bar.Left + [int][Math]::Round((($bar.Right - $bar.Left) - $W) / 2.0); y = $bottom - $script:AnchorGapPx - $H; mode = 'tray'; note = $null }
}

function Get-PillFitHeight {
    # Pill height in DIPs that fits inside a horizontal taskbar of TaskbarPx physical pixels (35 DIP max, 24 min).
    param([int]$TaskbarPx, [double]$Scale)
    if ($TaskbarPx -le 0 -or $Scale -le 0) { return 35.0 }
    return [Math]::Max(24.0, [Math]::Min(35.0, [Math]::Floor(($TaskbarPx - 2) / $Scale)))
}

function Set-PillFit {
    param($P)
    $tb = Get-TaskbarRect $P.Bar
    if ($null -eq $tb) { return }
    $target = 35.0
    if (($tb.Right - $tb.Left) -ge ($tb.Bottom - $tb.Top)) {
        $scale = [Windows.Media.VisualTreeHelper]::GetDpi($P.Win).DpiScaleY
        $target = Get-PillFitHeight ($tb.Bottom - $tb.Top) $scale
    }
    if ([Math]::Abs($P.UI.Pill.Height - $target) -gt 0.1) { $P.UI.Pill.Height = $target }
    $sub = $(if ($script:Settings.compact) { 'Collapsed' } else { 'Visible' })
    if ($P.UI.Sub.Visibility -ne $sub) { $P.UI.Sub.Visibility = $sub; $P.UI.HeroTag.Text = Get-PillTag; Set-PillWidth $P.UI }
}

function Get-PillTag {
    # The product name sits after the percentage on the top line, so the second line holds only the status
    # and the pill stays narrow. Compact mode shows the number alone.
    if ($script:Settings.compact) { return '' }
    return ' ' + $script:ProductKey
}

function Set-PillWidth {
    # The pill fits its text, but only grows at once and shrinks after losing 12+ DIP, so a ticking countdown
    # never makes it (and the Codex pill beside it) twitch.
    param($Ui)
    $Ui.PillContent.Measure((New-Object Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $need = [Math]::Ceiling($Ui.PillContent.DesiredSize.Width + $Ui.Pill.Padding.Left + $Ui.Pill.Padding.Right + 2)
    $floor = $(if ($script:Settings.compact) { $script:CompactWidth } else { $script:PillWidth })
    $need = [Math]::Max($floor, $need)
    $cur = $Ui.Pill.MinWidth
    if ($need -gt $cur -or $need -lt $cur - 12) { $Ui.Pill.MinWidth = $need }
}

function Set-PillHidden {
    # Truly hide (SW_HIDE) while a full-screen app is in front, so the pill never sits over games or video.
    param($P, [bool]$Hidden)
    if ($Hidden -eq $P.Hidden) { return }
    $P.Hidden = $Hidden
    if ($Hidden) {
        if ($script:CardOwner -eq $P) { $script:CardPinned = $false; Hide-Card }
        [void][UsageWidget.Native]::ShowWindow($P.Hwnd, 0)
        $P.HiddenAt = [DateTime]::UtcNow
    } else {
        [void][UsageWidget.Native]::ShowWindow($P.Hwnd, 8)      # SW_SHOWNA: show without activating
        # Back after a while (unlocked PC, closed full-screen app): fetch now instead of showing old numbers.
        if ($null -ne $P.HiddenAt -and ([DateTime]::UtcNow - $P.HiddenAt).TotalSeconds -ge 60) { Start-Refresh $false }
    }
}

function Update-PillPlacement {
    param($P)
    if ($null -eq $P.Hwnd -or ($script:Dragging -and $P.Primary)) { return }
    $pr = Get-WinRect $P.Hwnd
    # Hide only when full screen is seen on 2 checks in a row, so a window that covers the screen for a
    # moment (a launching app, a shell animation) never makes the pills blink.
    if ([UsageWidget.Native]::FullscreenInFront($pr, [uint32]$PID)) { $P.FullChecks = [int]$P.FullChecks + 1 } else { $P.FullChecks = 0 }
    $full = ($P.FullChecks -ge 2) -or ($P.Hidden -and $P.FullChecks -ge 1)
    Set-PillHidden $P $full
    if ($full) { return }
    Set-PillFit $P
    $r = Get-WinRect $P.Hwnd
    $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { return }
    $t = Get-TargetPosition $P $w $h
    # Keep the whole pill on the monitor it targets (#32): a pill wider than a left or right taskbar, or one
    # placed above an anchor near the top, would otherwise hang off the screen edge.
    $tr = New-Object UsageWidget.RECT
    $tr.Left = $t.x; $tr.Top = $t.y; $tr.Right = $t.x + $w; $tr.Bottom = $t.y + $h
    $mon = [UsageWidget.Native]::MonitorRect($tr, $true)
    $cl = Get-ClampedPosition $t.x $t.y $w $h $mon.Left $mon.Top $mon.Right $mon.Bottom
    $t.x = $cl.x; $t.y = $cl.y
    if ($t.mode -ne $P.Mode -or $t.note -ne $P.Note) {
        Write-Log ("placement{0}: {1}{2}" -f $(if ($P.Primary) { '' } else { ' (other taskbar)' }), $t.mode, $(if ($t.note) { " ($($t.note))" } else { '' }))
    }
    $P.Mode = $t.mode
    $P.Note = $t.note
    if ($r.Left -ne $t.x -or $r.Top -ne $t.y) { Move-WindowPx $P.Hwnd $t.x $t.y }
    else { Move-WindowPx $P.Hwnd $r.Left $r.Top }   # re-assert topmost above the taskbar
}

function Update-Placement {
    Sync-Pills
    foreach ($p in @($script:Pills)) { try { Update-PillPlacement $p } catch { Write-Log "placement error: $($_.Exception.Message)" } }
    [UsageWidget.Native]::SetTopmostHandles([IntPtr[]]@($script:Pills | Where-Object { $null -ne $_.Hwnd } | ForEach-Object { $_.Hwnd }))
}

# ---------------------------------------------------------------- pills (one per taskbar)

function Get-PillBySender {
    param($Sender)
    foreach ($p in @($script:Pills)) { if ($p.UI.Pill -eq $Sender -or $p.Win -eq $Sender) { return $p } }
    return $null
}

function New-Pill {
    param([IntPtr]$Bar, [bool]$Primary)
    $win = New-FromXaml $script:PillXaml
    $win.Title = $script:WindowTitle
    $ui = @{}
    foreach ($n in @([regex]::Matches($script:PillXaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })) { $ui[$n] = $win.FindName($n) }
    $ui.HeroTag.Text = Get-PillTag
    $ui.Pill.ContextMenu = $script:Menu
    $ui.Pill.MinWidth = $(if ($script:Settings.compact) { $script:CompactWidth } else { $script:PillWidth })
    $ui.Sub.Visibility = $(if ($script:Settings.compact) { 'Collapsed' } else { 'Visible' })
    [Windows.Automation.AutomationProperties]::SetName($ui.Pill, $script:WindowTitle)
    $p = @{ Win = $win; Hwnd = $null; Bar = $Bar; Primary = $Primary; UI = $ui; Hidden = $false; FullChecks = 0; Mode = $null; Note = $null; AnchorSeenAt = $null }
    [void]$script:Pills.Add($p)

    $ui.Pill.add_MouseEnter({ param($s, $e) $script:HideTimer.Stop(); if (-not $script:Dragging -and -not $script:Menu.IsOpen) { Show-Card (Get-PillBySender $s) } })
    $ui.Pill.add_MouseLeave({ $script:HideTimer.Stop(); $script:HideTimer.Start() })
    $ui.Pill.add_ContextMenuOpening({ param($s, $e) $script:MenuOwner = Get-PillBySender $s })
    # Horizontal drag of the main pill (physical pixels); a click without movement toggles the pinned card.
    $ui.Pill.add_MouseLeftButtonDown({
        param($s, $e)
        $pp = Get-PillBySender $s
        $pt = New-Object UsageWidget.POINT
        [void][UsageWidget.Native]::GetCursorPos([ref]$pt)
        $r = Get-WinRect $pp.Hwnd
        $script:DragStart = @{ cx = $pt.X; left = $r.Left; top = $r.Top; pill = $pp }
        $script:Dragging = $false
        [void]$s.CaptureMouse()
        $e.Handled = $true
    })
    $ui.Pill.add_MouseMove({
        param($s, $e)
        if ($null -eq $script:DragStart -or $e.LeftButton -ne 'Pressed' -or -not $script:DragStart.pill.Primary) { return }
        $pt = New-Object UsageWidget.POINT
        [void][UsageWidget.Native]::GetCursorPos([ref]$pt)
        $dx = $pt.X - $script:DragStart.cx
        if (-not $script:Dragging -and [Math]::Abs($dx) -lt 5) { return }
        if (-not $script:Dragging) { $script:Dragging = $true; Hide-Card }
        Move-WindowPx $script:DragStart.pill.Hwnd ($script:DragStart.left + $dx) $script:DragStart.top
    })
    $ui.Pill.add_MouseLeftButtonUp({
        param($s, $e)
        # Take the drag state first: releasing the capture raises LostMouseCapture, which must then do nothing.
        $ds = $script:DragStart; $wasDragging = $script:Dragging
        $script:DragStart = $null; $script:Dragging = $false
        $s.ReleaseMouseCapture()
        if ($wasDragging -and $null -ne $ds) {
            Complete-Drag $ds.pill
        } elseif ($null -ne $ds) {
            $pp = $ds.pill
            if ($script:CardPinned -and $script:CardOwner -eq $pp) { $script:CardPinned = $false; Hide-Card }
            else {
                # Click: pin the card and fetch a fresh reading (at most every 20 s, so clicks never hammer the service).
                $script:CardPinned = $true
                if ($null -eq $script:Proc -and ([DateTime]::UtcNow - $script:LastClickRefresh).TotalSeconds -ge 20) {
                    # During a rate-limit or server-error backoff a click must not force another request (each 429 doubles the wait).
                    $script:LastClickRefresh = [DateTime]::UtcNow; $script:ManualRefresh = $true; Start-Refresh (-not (Test-InBackoff $script:Data))
                }
                Show-Card $pp $true
            }
        }
        $e.Handled = $true
    })
    # Capture lost mid-drag (Alt+Tab, a UAC prompt, another window taking the mouse) with no button-up: end the
    # drag there, keep the spot reached so far, and never treat it as a click (#37).
    $ui.Pill.add_LostMouseCapture({
        param($s, $e)
        if ($null -eq $script:DragStart) { return }
        $ds = $script:DragStart; $wasDragging = $script:Dragging
        $script:DragStart = $null; $script:Dragging = $false
        if ($wasDragging) { try { Complete-Drag $ds.pill } catch { Write-Log "drag end error: $($_.Exception.Message)" } }
    })
    $win.add_SourceInitialized({ param($s, $e) $pp = Get-PillBySender $s; Set-ToolWindowStyle $s; $pp.Hwnd = Get-Hwnd $s })
    $win.add_ContentRendered({ param($s, $e) $pp = Get-PillBySender $s; Update-PillPlacement $pp; Start-Fade $s 1.0 180 })
    $win.add_SizeChanged({ param($s, $e) $pp = Get-PillBySender $s; if ($null -ne $pp) { Update-PillPlacement $pp } })
    $win.add_DpiChanged({ param($s, $e) $s.Dispatcher.BeginInvoke([Action]{ Update-Placement }) | Out-Null })
    $win.Show()
    Update-PillVisual $p
    return $p
}

function Complete-Drag {
    # Ends a horizontal drag of pill $P: saves where it is now as the manual position, then re-applies placement
    # (which keeps it clear of the notification area). Called with $script:Dragging already false.
    param($P)
    $r = Get-WinRect $P.Hwnd
    $script:Settings.placement = 'manual'; $script:Settings.x = $r.Left; $script:Settings.y = $r.Top
    Save-Settings
    $P.Mode = 'manual'
    Write-Log "placement: manual saved"
    Update-PillPlacement $P
}

function Remove-Pill {
    param($P)
    if ($script:CardOwner -eq $P) { $script:CardPinned = $false; Hide-Card; $script:CardOwner = $null }
    try { $P.Win.Close() } catch { }
    [void]$script:Pills.Remove($P)
}

function Sync-Pills {
    # One pill on the main taskbar always; one on each other taskbar when "Show on every taskbar" is on.
    $primaryBar = Get-PrimaryBar
    $main = @($script:Pills | Where-Object { $_.Primary })
    if ($main.Count -eq 0) { [void](New-Pill $primaryBar $true) } elseif ($main[0].Bar -ne $primaryBar) { $main[0].Bar = $primaryBar }  # Explorer restarted
    $want = $(if ($script:Settings.all_taskbars) { @([UsageWidget.Native]::FindAllByClass('Shell_SecondaryTrayWnd')) } else { @() })
    foreach ($p in @($script:Pills | Where-Object { -not $_.Primary })) {
        if ($want -notcontains $p.Bar -or -not [UsageWidget.Native]::IsWindow($p.Bar)) { Remove-Pill $p }
    }
    foreach ($b in $want) {
        if (@($script:Pills | Where-Object { $_.Bar -eq $b }).Count -eq 0) { [void](New-Pill $b $false); Write-Log 'pill added on another taskbar' }
    }
}

# ---------------------------------------------------------------- data refresh (off the UI thread)

function Stop-ProcessTree {
    # Stops a process and every descendant (the collector may run the official CLI, which runs its own children).
    # Works after the root has exited too: orphaned children still name it as their parent.
    param([int]$RootId, [switch]$SkipRoot)   # -SkipRoot: the root already exited; stop only what it left behind
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction SilentlyContinue)
    $ids = New-Object System.Collections.ArrayList
    [void]$ids.Add($RootId)
    for ($i = 0; $i -lt $ids.Count; $i++) {
        foreach ($c in $all) { if ($c.ParentProcessId -eq $ids[$i] -and $c.ProcessId -ne $PID -and -not $ids.Contains([int]$c.ProcessId)) { [void]$ids.Add([int]$c.ProcessId) } }
    }
    for ($i = $ids.Count - 1; $i -ge $(if ($SkipRoot) { 1 } else { 0 }); $i--) { try { Stop-Process -Id $ids[$i] -Force -ErrorAction Stop } catch { } }
    return $ids.Count
}

function Write-Heartbeat {
    try { [IO.File]::WriteAllText($script:HeartbeatPath, [DateTime]::UtcNow.ToString('o')) } catch { }
}

function Start-Refresh {
    param([bool]$Force = $false)
    if ($null -ne $script:Proc) { return }           # no overlapping refreshes
    if (-not (Test-Path -LiteralPath $script:CollectorPath -PathType Leaf)) {
        $msg = ('The collector file {0} is missing from {1}. An antivirus may have quarantined it: restore it from quarantine, or run install.ps1 again from the widget''s source folder (it reinstalls only what is missing).' -f $script:CollectorName, $PSScriptRoot)
        if ($script:CollectorFailure -ne $msg) { Write-Log "collector missing: $($script:CollectorPath)" }
        $script:CollectorFailure = $msg
        Update-View
        return
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $PSHOME 'powershell.exe'
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $script:CollectorPath
        if ($Force) { $argLine += ' -Force' }
        $psi.Arguments = $argLine
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = $env:USERPROFILE                     # never hold the install folder (uninstall must delete it)
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
        $p = [System.Diagnostics.Process]::Start($psi)
        $script:Proc = $p
        $script:ProcOut = $p.StandardOutput.ReadToEndAsync()
        $script:ProcErr = $p.StandardError.ReadToEndAsync()
        $script:ProcStarted = [DateTime]::UtcNow
        $script:Refreshing = $true
        Update-View
    } catch {
        $script:Proc = $null
        $script:CollectorFailure = 'The local collector could not be started.'
        Write-Log "collector start failed: $($_.Exception.GetType().Name)"
        Update-View
    }
}

function Reset-Refresh {
    # After an unexpected error while finishing a refresh: stop the collector and everything it started (#35),
    # release the process handle and clear the refresh state, so the next poll starts cleanly.
    $p = $script:Proc
    $script:Proc = $null; $script:Refreshing = $false; $script:ManualRefresh = $false
    if ($null -eq $p) { return }
    try { [void](Stop-ProcessTree $p.Id -SkipRoot:$p.HasExited) } catch { }
    try { $p.Dispose() } catch { }
}

function Write-CollectorLog {
    # Logs a collector outcome only when it changes, so a long outage is one line, not one per minute.
    param([string]$Signature, [string]$Line)
    if ($Signature -eq $script:LastCollectorSig) { return }
    $script:LastCollectorSig = $Signature
    Write-Log $Line
}

function Test-InBackoff {
    # A rate-limit or server-error reading: a click must not force another request then (each 429 doubles the wait).
    param($Data)
    return ($null -ne $Data -and $null -ne $Data.error -and [string]$Data.error.code -match '^http_(429|5\d\d)$')
}

function Test-CollectorBusy {
    # Still running, or exited while a child it left still holds the output pipe open (time that out too).
    param($Proc, $OutTask)
    return (-not $Proc.HasExited -or -not $OutTask.IsCompleted)
}

function Complete-Refresh {
    $p = $script:Proc
    if ($null -eq $p) { return }
    $elapsed = ([DateTime]::UtcNow - $script:ProcStarted).TotalSeconds
    # A child left holding the output pipe keeps ProcOut open after the collector exits: time that out too.
    if (Test-CollectorBusy $p $script:ProcOut) {
        if ($elapsed -lt $script:CollectorTimeoutSeconds) { return }
        try { [void](Stop-ProcessTree $p.Id -SkipRoot:$p.HasExited) } catch { }
        try { $p.Dispose() } catch { }
        $script:Proc = $null; $script:Refreshing = $false
        $script:CollectorFailure = 'The local collector timed out.'
        Write-CollectorLog 'timeout' 'collector timed out and was stopped'
        Update-View
        return
    }
    $out = $script:ProcOut.Result
    $code = $p.ExitCode
    $p.Dispose()
    $script:Proc = $null; $script:Refreshing = $false; $script:ManualRefresh = $false
    $data = $null
    try { $data = $out | ConvertFrom-Json } catch { $data = $null }
    if ($null -eq $data -or $null -eq $data.schema_version) {
        $script:CollectorFailure = 'The local collector returned no valid data.'
        Write-CollectorLog "invalid|$code" "collector output invalid (exit $code)"
    } else {
        $script:Data = $data
        $script:CollectorFailure = $null
        $errCode = $(if ($data.error) { $data.error.code } else { '-' })
        if ($code -ne 0) { Write-CollectorLog "$code|$($data.status)|$($data.source)|$errCode" ("collector exit {0}: status={1} source={2} error={3}" -f $code, $data.status, $data.source, $errCode) }
        else { Write-CollectorLog "ok|$($data.source)" ("collector ok: source={0}" -f $data.source) }
        if (Add-HistorySample $script:History $data) { $script:HistoryDirty = $true }
        if ($script:HistoryDirty -and ([DateTime]::UtcNow - $script:HistorySavedAt).TotalSeconds -ge 300) { Save-History }
        try { Invoke-Alerts $data } catch { Write-Log "alerts error: $($_.Exception.Message)" }
    }
    Update-View
}

# ---------------------------------------------------------------- rendering

function Set-Ring {
    # Arc for a fraction (0..1) in a Size x Size box with a Thick stroke (default: the pill ring).
    param($Ui, $Fraction, $Brush, $Path = $null, [double]$Size = 26, [double]$Thick = 3.5)
    if ($null -eq $Path) { $Path = $Ui.Ring }
    $c = $Size / 2.0; $r = $c - $Thick / 2.0
    $Path.Stroke = $Brush
    if ($null -eq $Fraction -or $Fraction -le 0) { $Path.Data = $null; return }
    if ($Fraction -ge 0.999) { $Path.Data = New-Object Windows.Media.EllipseGeometry((New-Object Windows.Point($c, $c)), $r, $r); return }
    $a = $Fraction * 2 * [Math]::PI
    $start = New-Object Windows.Point($c, ($c - $r))
    $end = New-Object Windows.Point(($c + $r * [Math]::Sin($a)), ($c - $r * [Math]::Cos($a)))
    $seg = New-Object Windows.Media.ArcSegment($end, (New-Object Windows.Size($r, $r)), 0, ($Fraction -gt 0.5), [Windows.Media.SweepDirection]::Clockwise, $true)
    $fig = New-Object Windows.Media.PathFigure
    $fig.StartPoint = $start
    $fig.IsClosed = $false
    [void]$fig.Segments.Add($seg)
    $geo = New-Object Windows.Media.PathGeometry
    [void]$geo.Figures.Add($fig)
    $Path.Data = $geo
}

function Get-TintBrush {
    # A theme or level color at a given alpha (0-255), e.g. a soft background tint.
    param([string]$Hex, [int]$Alpha)
    $c = [Windows.Media.ColorConverter]::ConvertFromString($Hex)
    $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromArgb([byte]$Alpha, $c.R, $c.G, $c.B))
    $b.Freeze()
    return $b
}

function Test-Snoozed {
    param($Settings, $Now = [DateTime]::UtcNow)
    return ($null -ne $Settings -and [double]$Settings.snooze_until -gt (ConvertTo-Unix (ConvertTo-UtcTime $Now)))
}

function Get-SnoozeUntil {
    # Unix time an alert snooze ends: '1h', 'morning' (8:00 local, tomorrow unless it is still before 5:00),
    # 'reset' (the weekly reset; $null if unknown), 'off' (0 = not snoozed).
    param([string]$Choice, $Weekly, $Now = [DateTime]::UtcNow)
    $now = ConvertTo-UtcTime $Now
    switch ($Choice) {
        '1h' { return (ConvertTo-Unix $now) + 3600 }
        'morning' {
            $l = $now.ToLocalTime()
            $day = $(if ($l.Hour -lt 5) { $l.Date } else { $l.Date.AddDays(1) })
            return (ConvertTo-Unix ([DateTime]::SpecifyKind($day.AddHours(8), [DateTimeKind]::Local).ToUniversalTime()))
        }
        'reset' {
            $r = $(if ($null -ne $Weekly) { ConvertTo-UtcTime $Weekly.resets_at } else { $null })
            if ($null -eq $r -or $r -le $now) { return $null }
            return (ConvertTo-Unix $r)
        }
        default { return 0.0 }
    }
}

function Format-SnoozeEnd {
    # "today 21:30", "tomorrow 08:00", "Wed 19:00" (24-hour, like the rest of the card).
    param([double]$Unix, $Now = [DateTime]::UtcNow)
    $l = [DateTimeOffset]::FromUnixTimeSeconds([long]$Unix).UtcDateTime.ToLocalTime()
    $today = (ConvertTo-UtcTime $Now).ToLocalTime().Date
    $hm = $l.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    if ($l.Date -eq $today) { return "today $hm" }
    if ($l.Date -eq $today.AddDays(1)) { return "tomorrow $hm" }
    return $l.ToString('ddd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function Find-BundledClaudeCli {
    # The Claude desktop app ships its own Claude Code (Code tab) but never puts it on PATH or in ~\.local\bin:
    # %LOCALAPPDATA%\Claude-Data\claude_<id>\claude-code\<version>\<hash>\claude.exe (Store/MSIX install) or
    # %APPDATA%\Claude\claude-code\<version>\<hash>\claude.exe. Newest version wins.
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Claude-Data\claude_*\claude-code'),
        (Join-Path $env:APPDATA 'Claude\claude-code'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Claude_*\LocalCache\Roaming\Claude\claude-code')
    )
    $found = foreach ($r in $roots) { Get-ChildItem -Path (Join-Path $r '*\*\claude.exe') -File -ErrorAction SilentlyContinue }
    $best = $found | Sort-Object @{ Expression = { $v = $null; if ([version]::TryParse($_.Directory.Parent.Name, [ref]$v)) { $v } else { [version]'0.0' } } }, LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -ne $best) { return $best.FullName }
    return $null
}

function Find-SignInCli {
    # The official CLI's interactive sign-in for this product: claude "auth login" / codex "login".
    if ($script:ProductKey -eq 'claude') {
        $c = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
        if (Test-Path -LiteralPath $c -PathType Leaf) { return @{ exe = $c; args = 'auth login'; name = 'Claude Code' } }
        $cmd = Get-Command 'claude.exe', 'claude.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { return @{ exe = $cmd.Source; args = 'auth login'; name = 'Claude Code' } }
        $b = Find-BundledClaudeCli
        if ($b) { return @{ exe = $b; args = 'auth login'; name = 'Claude Code' } }
        return $null
    }
    try {
        $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
        if ($null -ne $pkg) { $c = Join-Path $pkg.InstallLocation 'app\resources\codex.exe'; if (Test-Path -LiteralPath $c -PathType Leaf) { return @{ exe = $c; args = 'login'; name = 'Codex' } } }
    } catch { }
    $cmd = Get-Command 'codex.exe', 'codex.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return @{ exe = $cmd.Source; args = 'login'; name = 'Codex' } }
    return $null
}

function Start-SignIn {
    # Opens the official CLI's sign-in in its own console window; the widget refreshes when that window closes.
    if ($null -ne $script:SignInProc -and -not $script:SignInProc.HasExited) { return }
    $cli = Find-SignInCli
    if ($null -eq $cli) {
        [void][Windows.MessageBox]::Show(('The {0} command-line tool was not found on this PC, so the widget cannot open its sign-in. Sign in from the {0} app instead; the widget picks it up on its next refresh.' -f $script:ProductName), $script:WindowTitle, 'OK', 'Information')
        return
    }
    try {
        $script:SignInProc = Start-Process -FilePath $cli.exe -ArgumentList $cli.args -WorkingDirectory $env:USERPROFILE -PassThru
        Write-Log "sign-in opened ($($cli.name))"
    } catch {
        [void][Windows.MessageBox]::Show(("The sign-in could not be opened: {0}" -f $_.Exception.Message), $script:WindowTitle, 'OK', 'Warning')
    }
}

function Set-MenuTheme {
    $T = Get-ThemeBrushes
    $map = @{ MenuBg = 'menuBgB'; MenuLine = 'lineB'; MenuFg = 'fgB'; MenuDim = 'dimB'; MenuHover = 'menuHoverB'; MenuAccent = 'accentB' }
    # ResourceDictionary takes object: unwrap the PowerShell wrapper or WPF cannot use the brush.
    foreach ($k in $map.Keys) { $script:Menu.Resources[$k] = ([Windows.Media.Brush]$T[$map[$k]]).psobject.BaseObject }
}



function New-TextBlock {
    param([string]$Text, [double]$Size, $Brush, [string]$Weight = 'Normal')
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = $Size; $t.Foreground = $Brush
    $t.FontWeight = [Windows.FontWeights]::$Weight
    $t.TextWrapping = 'Wrap'
    return $t
}

function New-Bar {
    # Rounded progress bar: Fraction filled with Fill (a gradient) on Track; optional Marker tick at MarkerAt (0..1).
    param([double]$Fraction, $Fill, $Track, [double]$Height = 5, $MarkerAt = $null, $Marker = $null)
    $f = [Math]::Min(1.0, [Math]::Max(0.0, $Fraction))
    $g = New-Object Windows.Controls.Grid
    $g.Height = $(if ($null -ne $MarkerAt) { $Height + 6 } else { $Height })
    $tr = New-Object Windows.Controls.Border
    $tr.Height = $Height; $tr.CornerRadius = $Height / 2.0; $tr.Background = $Track; $tr.VerticalAlignment = 'Center'
    [void]$g.Children.Add($tr)
    if ($f -gt 0) {
        $fg = New-Object Windows.Controls.Grid
        foreach ($w in $f, (1.0 - $f)) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = New-Object Windows.GridLength($w, 'Star'); [void]$fg.ColumnDefinitions.Add($cd) }
        $fb = New-Object Windows.Controls.Border
        $fb.Height = $Height; $fb.CornerRadius = $Height / 2.0; $fb.Background = $Fill; $fb.VerticalAlignment = 'Center'
        $fb.MinWidth = $Height; $fb.HorizontalAlignment = 'Stretch'
        [void]$fg.Children.Add($fb)
        [void]$g.Children.Add($fg)
    }
    if ($null -ne $MarkerAt) {
        $m = [Math]::Min(1.0, [Math]::Max(0.0, [double]$MarkerAt))
        $mg = New-Object Windows.Controls.Grid
        foreach ($w in $m, (1.0 - $m)) { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = New-Object Windows.GridLength($w, 'Star'); [void]$mg.ColumnDefinitions.Add($cd) }
        $mk = New-Object Windows.Controls.Border
        $mk.Width = 2; $mk.Height = $Height + 6; $mk.CornerRadius = 1; $mk.Background = $Marker
        $mk.HorizontalAlignment = 'Left'; $mk.Margin = '-1,0,0,0'
        [Windows.Controls.Grid]::SetColumn($mk, 1)
        [void]$mg.Children.Add($mk)
        [void]$g.Children.Add($mg)
    }
    return $g
}

function Add-LimitRow {
    # One limit: title + "45% used", a bar of the share used (colored by what is left), "Resets Sat 14 Nov, 19:00 Â· in 23h 1m".
    param([string]$Label, $Window, $Theme, [bool]$First = $false)
    $left = Get-Left $Window
    $level = Get-LevelKey $left
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = $(if ($First) { '0,12,0,0' } else { '0,10,0,0' })
    $head = New-Object Windows.Controls.Grid
    $t = New-TextBlock $Label 12 $Theme.fgB 'SemiBold'
    $t.TextWrapping = 'NoWrap'; $t.TextTrimming = 'CharacterEllipsis'; $t.Margin = '0,0,64,0'
    $v = New-TextBlock $(if ($null -eq $left) { 'unavailable' } else { ('{0} used' -f (Format-UsedShare (100.0 - $left))) }) 11.5 $Theme.dimB
    $v.HorizontalAlignment = 'Right'; $v.VerticalAlignment = 'Center'; $v.TextWrapping = 'NoWrap'
    [void]$head.Children.Add($t); [void]$head.Children.Add($v)
    [void]$panel.Children.Add($head)
    $bar = New-Bar $(if ($null -eq $left) { 0 } else { (100.0 - $left) / 100.0 }) $Theme[$level + 'GradB'] $Theme.trackB 5
    $bar.Margin = '0,7,0,0'
    [void]$panel.Children.Add($bar)
    $rl = $(if ($null -ne $Window) { Format-ResetLine $Window.resets_at } else { $null })
    if ($rl) {
        $d = New-TextBlock $rl 11 $Theme.dimB
        $d.Margin = '0,6,0,0'
        [void]$panel.Children.Add($d)
    }
    [void]$script:UI.Rows.Children.Add($panel)
}

function Get-ThemeBrushes {
    $name = Get-ThemeName
    if ($script:ThemeCache.name -eq $name) { return $script:ThemeCache.t }
    $src = $script:Themes[$name]
    $t = @{}
    foreach ($k in $src.Keys) { if ($src[$k] -is [string]) { $t[$k + 'B'] = Get-Brush $src[$k] } }
    $col = { param($hex) [Windows.Media.ColorConverter]::ConvertFromString($hex) }
    # Pill edge: lighter at the top, like Windows 11 surfaces.
    $g = New-Object Windows.Media.LinearGradientBrush((& $col $src.pillEdgeTop), (& $col $src.pillEdgeBottom), 90.0)
    $g.Freeze()
    $t.pillBorderB = $g
    $bg = New-Object Windows.Media.LinearGradientBrush((& $col $src.pillBg), (& $col $src.pillBgBottom), 90.0)
    $bg.Freeze()
    $t.pillBgB = $bg                                                   # surface: a touch lighter at the top
    foreach ($lv in 'green', 'amber', 'orange', 'red', 'gray') {
        $lg = New-Object Windows.Media.LinearGradientBrush((& $col $src[$lv + 'Lo']), (& $col $src[$lv + 'Hi']), 0.0)
        $lg.Freeze()
        $t[$lv + 'GradB'] = $lg
        $t[$lv + 'EdgeB'] = Get-TintBrush $src[$lv + 'Hi'] 0x60          # pill edge when the level needs attention
    }
    $t.pace = @{}
    foreach ($lv in $src.pace.Keys) {
        $p = @{}
        foreach ($k in $src.pace[$lv].Keys) { $p[$k] = Get-Brush $src.pace[$lv][$k] }
        $t.pace[$lv] = $p
    }
    $t.accentB = Get-Brush $script:Accent
    $t.name = $name
    $script:ThemeCache = @{ name = $name; t = $t }
    return $t
}

function Get-WindowSamples {
    param([string]$Key)
    if ($null -eq $script:History) { return @() }
    return $script:History[$Key].ToArray()
}

function New-Polyline {
    param($Points, $Brush, [double]$Thickness, [bool]$Dashed)
    $pl = New-Object Windows.Shapes.Polyline
    foreach ($pt in $Points) { [void]$pl.Points.Add((New-Object Windows.Point([double]$pt[0], [double]$pt[1]))) }
    $pl.Stroke = $Brush; $pl.StrokeThickness = $Thickness
    $pl.StrokeLineJoin = 'Round'; $pl.StrokeStartLineCap = 'Round'; $pl.StrokeEndLineCap = 'Round'
    if ($Dashed) { $pl.StrokeDashArray = New-Object Windows.Media.DoubleCollection (, [double[]]@(2.5, 2.5)) }
    return $pl
}

function Update-Chart {
    param($Geo, $T, $LevelBrush, [string]$LevelKey = 'green')
    $ui = $script:UI
    $ui.Chart.Children.Clear()
    if ($null -eq $Geo) { $ui.ChartPanel.Visibility = 'Collapsed'; return }
    $W = $script:ChartW - 2; $H = $script:ChartH
    foreach ($gy in 0.25, 0.5, 0.75) {
        $ln = New-Object Windows.Shapes.Line
        $ln.X1 = 0; $ln.X2 = $W; $ln.Y1 = $H * $gy; $ln.Y2 = $ln.Y1
        $ln.Stroke = $T.lineB; $ln.StrokeThickness = 1
        [void]$ui.Chart.Children.Add($ln)
    }
    # Soft area under the "used" line, fading to transparent.
    $lc = [Windows.Media.ColorConverter]::ConvertFromString($script:Themes[$T.name][$LevelKey + 'Hi'])
    $area = New-Object Windows.Shapes.Polygon
    foreach ($pt in $Geo.actual) { [void]$area.Points.Add((New-Object Windows.Point([double]$pt[0], [double]$pt[1]))) }
    [void]$area.Points.Add((New-Object Windows.Point([double]$Geo.now[0], $H)))
    [void]$area.Points.Add((New-Object Windows.Point(0, $H)))
    $fillG = New-Object Windows.Media.LinearGradientBrush
    $fillG.StartPoint = New-Object Windows.Point(0, 0); $fillG.EndPoint = New-Object Windows.Point(0, 1)
    [void]$fillG.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Color]::FromArgb(0x59, $lc.R, $lc.G, $lc.B), 0)))
    [void]$fillG.GradientStops.Add((New-Object Windows.Media.GradientStop([Windows.Media.Color]::FromArgb(0x00, $lc.R, $lc.G, $lc.B), 1)))
    $area.Fill = $fillG
    [void]$ui.Chart.Children.Add($area)
    [void]$ui.Chart.Children.Add((New-Polyline $Geo.even $T.dimB 1.0 $true))
    $fcBrush = $(if ($Geo.runs_out) { $T.redB } else { $LevelBrush })
    if ($null -ne $Geo.forecast) { [void]$ui.Chart.Children.Add((New-Polyline $Geo.forecast $fcBrush 1.6 $true)) }
    [void]$ui.Chart.Children.Add((New-Polyline $Geo.actual $LevelBrush 2.2 $false))
    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 7; $dot.Height = 7; $dot.Fill = $LevelBrush
    [Windows.Controls.Canvas]::SetLeft($dot, [double]$Geo.now[0] - 3.5); [Windows.Controls.Canvas]::SetTop($dot, [double]$Geo.now[1] - 3.5)
    [void]$ui.Chart.Children.Add($dot)
    $ui.ChartFrame.BorderBrush = $T.lineB; $ui.ChartFrame.Background = $T.boxBgB
    $ui.ChartTitle.Foreground = $T.fgB
    $ui.ChartLegend.Foreground = $T.dimB; $ui.ChartStart.Foreground = $T.dimB; $ui.ChartEnd.Foreground = $T.dimB
    $ui.ChartStart.Text = 'Started ' + $Geo.start.ToLocalTime().ToString('ddd d MMM', [Globalization.CultureInfo]::InvariantCulture)
    $ui.ChartEnd.Text = 'Resets ' + $Geo.reset.ToLocalTime().ToString('ddd d MMM, HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    # Legend with colored line samples instead of words.
    $ui.ChartLegend.Inlines.Clear()
    $add = { param($text, $brush) $r = New-Object Windows.Documents.Run $text; if ($null -ne $brush) { $r.Foreground = $brush }; $ui.ChartLegend.Inlines.Add($r) }
    & $add ([string][char]0x2501 + ' ') $LevelBrush; & $add 'used   ' $null
    & $add ([string][char]0x2505 + ' ') $T.dimB; & $add 'even' $null
    if ($null -ne $Geo.forecast) { & $add ('   ' + [char]0x2505 + ' ') $fcBrush; & $add 'forecast' $null }
    $ui.ChartPanel.Visibility = 'Visible'
}

function Update-PillVisual {
    # Applies the last computed pill state ($script:PillState) to one pill.
    param($P)
    $st = $script:PillState
    if ($null -eq $st) { return }
    $ui = $P.UI
    $ui.Pill.Background = $st.bg; $ui.Pill.BorderBrush = $st.border
    $num = [string]$st.hero; $sign = ''
    if ($num.Length -gt 1 -and $num.EndsWith('%')) { $sign = '%'; $num = $num.Substring(0, $num.Length - 1) }
    $ui.HeroNum.Text = $num; $ui.HeroPct.Text = $sign; $ui.HeroTag.Text = Get-PillTag; $ui.HeroTag.Foreground = $st.tagBrush
    $ui.Hero.Foreground = $st.fg; $ui.Hero.Opacity = $st.opacity; $ui.Hero.FontStyle = $st.style
    $ui.Sub.Text = $st.sub; $ui.Sub.Foreground = $st.subBrush
    $ui.RingTrack.Stroke = $st.track
    $ui.RingTrack.StrokeDashArray = $(if ($st.stale) { New-Object Windows.Media.DoubleCollection (, [double[]]@(1.2, 1.2)) } else { $null })
    $ui.Badge.Foreground = $st.subBrush
    $ui.Badge.Visibility = $(if ($st.snoozed) { 'Visible' } else { 'Collapsed' })
    Set-Ring $ui $st.fraction $st.ring
    Set-PillWidth $ui
    [Windows.Automation.AutomationProperties]::SetName($ui.Pill, $st.a11y)
}

function Set-BoxColors {
    # Paints a tinted box (pace / status) with one of the theme's pace palettes.
    param($Box, $Palette, $Label, $Text, $Status = $null)
    $Box.Background = $Palette.bg; $Box.BorderBrush = $Palette.edge
    $Label.Foreground = $Palette.label; $Text.Foreground = $Palette.text
    if ($null -ne $Status) { $Status.Foreground = $Palette.status }
}

function Update-View {
    try {
        $T = Get-ThemeBrushes
        $ui = $script:UI
        $tag = $script:ProductKey
        $dot = [string][char]0x00B7
        $ui.Card.Background = $T.cardBgB; $ui.Card.BorderBrush = $T.borderB
        $ui.CardTitle.Foreground = $T.fgB; $ui.CardHeroLabel.Foreground = $T.dimB
        $ui.PlanBadge.Background = $T.chipBgB; $ui.PlanText.Foreground = $T.chipFgB
        $ui.TopDivider.Background = $T.lineB; $ui.Divider.Background = $T.lineB; $ui.FooterText.Foreground = $T.dimB

        $d = $script:Data
        $now = [DateTime]::UtcNow
        $snoozed = Test-Snoozed $script:Settings $now
        $details = [bool]$script:Settings.details
        $ui.Rows.Children.Clear()
        $ui.HeroLines.Children.Clear()
        $ui.PaceLines.Children.Clear()
        $st = @{ bg = $T.pillBgB; border = $T.pillBorderB; fg = $T.pillFgB; track = $T.pillTrackB; opacity = 1.0; style = [Windows.FontStyles]::Normal
                 subBrush = $T.pillDimB; tagBrush = $T.pillDimB; snoozed = $snoozed; stale = $false; fraction = $null; ring = $T.grayRingB }
        if ($null -eq $d) {
            $st.hero = $(if ($script:CollectorFailure) { [string][char]0x2014 } else { '...' })
            $st.sub = $(if ($script:CollectorFailure) { 'unavailable' } else { 'loading' })
            $st.a11y = "$($script:WindowTitle): $($st.sub)"
            $script:PillState = $st
            foreach ($p in @($script:Pills)) { Update-PillVisual $p }
            $ui.CardHero.Text = $st.hero; $ui.CardHero.Foreground = $T.grayB; $ui.CardHero.Opacity = 1.0
            $ui.CardHeroLabel.Text = $(if ($script:Refreshing) { "reading $($script:ProductName) usage..." } else { 'used this week' })
            foreach ($n in 'PlanBadge', 'PaceBox', 'SessionPaceBox', 'ChartPanel', 'PaceLines', 'TopDivider') { $ui[$n].Visibility = 'Collapsed' }
            $ui.StatusText.Text = $script:CollectorFailure
            $ui.StatusLabel.Text = 'NOT AVAILABLE'
            Set-BoxColors $ui.StatusBar $T.pace.amber $ui.StatusLabel $ui.StatusText
            $ui.StatusBar.Visibility = $(if ($script:CollectorFailure) { 'Visible' } else { 'Collapsed' })
            $ui.FooterText.Text = 'Click to refresh ' + $dot + ' right-click for settings'
            return
        }

        $weekly = $d.weekly
        $bind = Get-BindingLimit $d $now                                  # pill and hero follow the limit that runs out first
        $left = $bind.left
        $level = Get-LevelKey $left
        $stale = ($d.stale -eq $true) -or ($null -ne $script:CollectorFailure)
        $authCodes = @('auth_expired', 'auth_missing', 'auth_unreadable', 'auth_malformed', 'auth_mode_unsupported', 'http_401', 'http_403')
        $needsSignIn = ($null -ne $d.error -and $authCodes -contains [string]$d.error.code)
        $pct = $(if ($null -eq $left) { Format-Percent $null } else { Format-UsedShare (100.0 - $left) })   # the pill and hero show the share used
        $st.hero = $pct; $st.stale = $stale
        $st.opacity = $(if ($stale) { 0.6 } else { 1.0 })
        $st.style = $(if ($stale) { [Windows.FontStyles]::Italic } else { [Windows.FontStyles]::Normal })
        $st.fraction = $(if ($null -eq $left) { $null } else { (100.0 - $left) / 100.0 }); $st.ring = $T[$level + 'RingB']
        if ($level -ne 'green' -and $level -ne 'gray' -and -not $stale) { $st.border = $T[$level + 'EdgeB'] }   # the pill edge warns

        # Pace, today's budget and the chart, from the latest reading and the local history.
        $wSamples = Get-WindowSamples 'w'
        $wp = $(if ($null -ne $weekly) { Get-PaceInfo $weekly $wSamples $now } else { $null })
        $sp = $(if ($null -ne $d.session) { Get-PaceInfo $d.session (Get-WindowSamples 's') $now } else { $null })
        $budget = $(if ($null -ne $weekly) { Get-DailyBudget $weekly $wSamples $now } else { $null })

        $reset = $(if ($null -ne $weekly) { Get-ResetText $weekly.resets_at $now } else { $null })
        $subRight = $(if ($reset) { 'weekly ' + $reset } else { $null })   # name the limit: the pill shows only one
        if ($null -eq $weekly) {
            $subRight = $(if (@($d.reset_passed) -contains 'weekly') { 'reset, refreshing' } else { 'unavailable' })
        } elseif (-not $subRight) { $subRight = 'reset unknown' }
        if ($bind.kind -eq 'session') { $subRight = ('{0}-hour {1}' -f [Math]::Round([double]$bind.window.window_seconds / 3600.0), (Get-ResetText $bind.window.resets_at $now)) }
        if ($needsSignIn) { $subRight = 'sign in needed'; $st.subBrush = $T.warnB }
        elseif (-not $stale -and $bind.kind -eq 'weekly' -and $script:Settings.pill -eq 'budget' -and $null -ne $budget) {
            $subRight = ('today {0} of {1}%' -f (Format-Share $budget.used_today), (Format-Share $budget.budget))
            if ($budget.over) { $st.subBrush = $T.warnB }
        }
        if ($script:Refreshing -and $script:ManualRefresh) { $subRight = 'refreshing' + [char]0x2026; $st.subBrush = $T.pillDimB }
        $st.sub = $subRight
        $st.a11y = ('{0}: {1} of the {2} limit used; {3}' -f $script:WindowTitle, $pct, $(if ($bind.kind -eq 'session') { '5-hour session' } else { 'weekly' }), $subRight)
        $script:PillState = $st
        foreach ($p in @($script:Pills)) { Update-PillVisual $p }

        # Card header and hero
        $ui.CardHero.Text = $pct
        $ui.CardHero.Foreground = $T[$level + 'B']
        $exhausted = ($null -ne $left -and $left -le 0)
        $ui.CardHeroLabel.Text = $(if ($bind.kind -eq 'session') { ('used in this {0}-hour session' -f [Math]::Round([double]$bind.window.window_seconds / 3600.0)) }
                                   elseif ($null -eq $left) { 'weekly data unavailable' }
                                   elseif ($tag -eq 'claude') { "used this week $dot all models" } else { 'used this week' })
        if ($d.plan) {
            $ui.PlanText.Text = (Get-Culture).TextInfo.ToTitleCase(([string]$d.plan).ToLowerInvariant())
            $ui.PlanBadge.Visibility = 'Visible'
        } else { $ui.PlanBadge.Visibility = 'Collapsed' }

        # Small lines under the hero: credits / extra usage, free resets, snooze.
        $hero = New-Object System.Collections.ArrayList
        $nowU = ConvertTo-Unix $now
        $spend = Get-SpendValue $d
        $spendTrend = $(if ($details -and $null -ne $spend) { Get-Trend $script:History.c.ToArray() $spend $nowU 168 12 } else { $null })
        if ($null -ne $d.credits -and $null -ne $d.credits.balance) {
            $txt = ('Credits: {0} left' -f (Format-Credits $d.credits.balance))
            if ($null -ne $spendTrend -and $spendTrend.delta -lt -0.005) { $txt += (' ({0} used in {1})' -f (Format-Credits (-$spendTrend.delta)), (Format-Span $spendTrend.hours)) }
            [void]$hero.Add($txt)
        } elseif ($null -ne $d.extra_usage -and $d.extra_usage.enabled -eq $true -and $null -ne $d.extra_usage.utilization) {
            $txt = ('Extra usage: {0}% of the monthly limit used' -f (Format-Share ([double]$d.extra_usage.utilization)))
            if ($null -ne $spendTrend -and $spendTrend.delta -gt 0.05) { $txt += (' (+{0} pts in {1})' -f (Format-Share $spendTrend.delta), (Format-Span $spendTrend.hours)) }
            [void]$hero.Add($txt)
        }
        if ($null -ne $d.reset_credits -and [int]$d.reset_credits -gt 0) {
            $rc = [int]$d.reset_credits
            [void]$hero.Add(('{0} free limit reset{1} available in the Codex app' -f $rc, $(if ($rc -eq 1) { '' } else { 's' })))
        }
        if ($snoozed) { [void]$hero.Add(('Alerts snoozed until {0}' -f (Format-SnoozeEnd ([double]$script:Settings.snooze_until) $now))) }
        foreach ($h in $hero) { $tb = New-TextBlock $h 12 $T.dimB; $tb.Margin = '0,1,0,0'; [void]$ui.HeroLines.Children.Add($tb) }

        # Status box: stale data, errors, sign-in; an informational note (e.g. the /usage fallback) when nothing is wrong.
        $status = New-Object System.Collections.ArrayList
        if ($stale) {
            $srcLabel = switch ($d.source) { 'cache' { 'last saved reading' } 'session_log' { 'local session log' } default { 'last reading' } }
            if ($d.fetched_at) { [void]$status.Add(('Showing the {0} from {1} ({2}).' -f $srcLabel, (Format-DayTime $d.fetched_at), (Format-Age $d.fetched_at $now))) }
        }
        if ($d.source -eq 'session_log' -and $d.account_verified -ne $true) { [void]$status.Add('From a local session log whose account could not be confirmed.') }
        if (@($d.reset_passed).Count -gt 0) { [void]$status.Add('A limit window has reset since this reading; waiting for a new one.') }
        if ($d.error -and $d.error.message) { [void]$status.Add([string]$d.error.message) }
        if ($needsSignIn -and [string]$d.error.message -notmatch 'Sign in again') { [void]$status.Add(('To fix it: right-click the pill ' + [char]0x203A + ' Sign in again.')) }
        if ($script:CollectorFailure) { [void]$status.Add($script:CollectorFailure) }
        # Placement notes only when the pill could not go where it belongs (a small nudge left is not news).
        foreach ($n in @($script:Pills | Where-Object { $_.Note -and $_.Mode -ne 'manual' } | ForEach-Object { $_.Note } | Select-Object -Unique)) { [void]$status.Add($n) }
        $warn = ($status.Count -gt 0)
        if (-not $warn -and $d.notice) { [void]$status.Add([string]$d.notice) }
        $ui.StatusText.Text = ($status -join [Environment]::NewLine)
        $ui.StatusLabel.Text = $(if ($needsSignIn) { 'SIGN-IN NEEDED' } elseif ($stale) { 'NOT UP TO DATE' } elseif ($warn) { 'CHECK THIS' } else { 'NOTE' })
        Set-BoxColors $ui.StatusBar $(if ($warn) { $T.pace.amber } else { $T.pace.gray }) $ui.StatusLabel $ui.StatusText
        $ui.StatusBar.Visibility = $(if ($status.Count -gt 0) { 'Visible' } else { 'Collapsed' })

        # Pace this week, then pace this 5-hour session: each says when that limit runs out at the current pace.
        foreach ($pb in @(@{ pre = ''; pace = $wp }, @{ pre = 'Session'; pace = $sp })) {
            $box = $ui[$pb.pre + 'PaceBox']
            $ps = Get-PaceSummary $pb.pace $now
            if ($null -eq $ps) { $box.Visibility = 'Collapsed'; continue }
            $pal = $T.pace[$ps.level]
            Set-BoxColors $box $pal $ui[$pb.pre + 'PaceLabel'] $ui[$pb.pre + 'PaceText'] $ui[$pb.pre + 'PaceStatus']
            $ui[$pb.pre + 'PaceLabel'].Text = $ps.label
            $ui[$pb.pre + 'PaceStatus'].Text = $ps.status
            $ui[$pb.pre + 'PaceText'].Text = $ps.text
            $ui[$pb.pre + 'PaceBarHost'].Child = New-Bar $ps.fill $T[$ps.level + 'GradB'] $pal.track 4 $ps.marker $pal.marker
            $box.Visibility = 'Visible'
        }

        # Limit rows: weekly first, then the 5-hour session, then per-model limits.
        $first = $true
        if ($null -ne $weekly) { Add-LimitRow (Get-WindowLabel 'weekly' $null $weekly.window_seconds $tag) $weekly $T $first; $first = $false }
        if ($null -ne $d.session -and $null -ne (Get-Left $d.session)) { Add-LimitRow (Get-WindowLabel 'session' $null $d.session.window_seconds $tag) $d.session $T $first; $first = $false }
        foreach ($s in @($d.scoped)) {
            if ($null -eq $s) { continue }
            Add-LimitRow (Get-WindowLabel ([string]$s.kind) ([string]$s.name) $s.window_seconds $tag) $s $T $first; $first = $false
        }
        $ui.TopDivider.Visibility = $(if ($ui.Rows.Children.Count -gt 0) { 'Visible' } else { 'Collapsed' })

        # Details (menu > Show details): the week's chart and the full pace breakdown.
        if ($details -and $null -ne $weekly) {
            Update-Chart (Get-ChartGeometry $weekly $wSamples $wp $now ($script:ChartW - 2) $script:ChartH) $T $T[$level + 'RingB'] $level
            $view = Get-PaceView $wp $sp $now $budget
            if ($null -ne $view) {
                foreach ($line in $view.lines) { $tb = New-TextBlock $line 11.5 $T.dimB; $tb.Margin = '0,3,0,0'; [void]$ui.PaceLines.Children.Add($tb) }
                $note = New-TextBlock 'Estimates from readings on this PC; not an official forecast.' 10.5 $T.dimB
                $note.Margin = '0,6,0,0'; $note.Opacity = 0.8
                [void]$ui.PaceLines.Children.Add($note)
            }
            $ui.PaceLines.Visibility = $(if ($ui.PaceLines.Children.Count -gt 0) { 'Visible' } else { 'Collapsed' })
        } else {
            $ui.ChartPanel.Visibility = 'Collapsed'; $ui.PaceLines.Visibility = 'Collapsed'
        }

        # Stale: the whole card reads as "last known", like the dimmed pill, not as current numbers.
        $staleOpacity = $(if ($stale) { 0.55 } else { 1.0 })
        foreach ($n in 'CardHero', 'Rows', 'ChartPanel', 'PaceBox', 'SessionPaceBox', 'PaceLines', 'HeroLines') { $ui[$n].Opacity = $staleOpacity }

        $srcText = switch ($d.source) { 'live' { 'from this PC' } 'cache' { $(if ($stale) { '(saved reading)' } else { 'from this PC' }) } 'session_log' { 'from the local session log' } 'cli' { $(if ($tag -eq 'claude') { 'via Claude Code' } else { 'via the Codex CLI' }) } default { '' } }
        $f = ConvertTo-UtcTime $d.fetched_at
        $when = $(if ($null -eq $f) { $null } elseif ($f.ToLocalTime().Date -eq $now.ToLocalTime().Date) { $f.ToLocalTime().ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { Format-DayTime $f })
        $foot = $(if ($when) { ('Updated {0} {1}' -f $when, $srcText).TrimEnd() } else { 'No reading yet' })
        if ($script:Refreshing) { $foot = 'Refreshing' + [char]0x2026 }
        $ui.FooterText.Text = "$foot $dot click to refresh"
    } catch {
        Write-Log "render error: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------- hover card

function Show-Card {
    param($P, [bool]$Force = $false)
    if ($null -eq $P -or $P.Hidden) { return }
    if ($script:CardVisible -and $script:CardOwner -eq $P -and -not $Force) { return }
    $script:CardOwner = $P
    $script:CardVisible = $true
    Update-View
    $card = $script:CardWindow
    $pr = Get-WinRect $P.Hwnd
    if (-not $card.IsVisible) { $card.Show(); Set-ToolWindowStyle $card; $script:CardHwnd = Get-Hwnd $card }
    Move-WindowPx $script:CardHwnd $pr.Left $pr.Top                # same monitor first (DPI), then measure
    $card.UpdateLayout()
    $script:CardWindow.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Loaded, [Action]{ Set-CardPosition; Start-Fade $script:CardWindow 1.0 120 }) | Out-Null
}

function Set-CardPosition {
    if ($null -eq $script:CardOwner) { return }
    $pr = Get-WinRect $script:CardOwner.Hwnd
    $cr = Get-WinRect $script:CardHwnd
    $cw = $cr.Right - $cr.Left; $ch = $cr.Bottom - $cr.Top
    $scale = [Windows.Media.VisualTreeHelper]::GetDpi($script:CardWindow).DpiScaleX
    $m = [int][Math]::Round(14 * $scale)                              # shadow margin inside the card window
    $mon = [UsageWidget.Native]::MonitorRect($pr, $true)
    $x = $pr.Right - $cw - [int][Math]::Round(1 * $scale)            # card edge 15 DIP inside the pill's right edge
    $above = (($pr.Top + $pr.Bottom) / 2) -gt (($mon.Top + $mon.Bottom) / 2)
    $gap = [int][Math]::Round(5 * $scale)
    $y = $(if ($above) { $pr.Top - $ch + $m - $gap } else { $pr.Bottom - $m + $gap })
    $x = [Math]::Max($mon.Left, [Math]::Min($x, $mon.Right - $cw))
    $y = [Math]::Max($mon.Top, [Math]::Min($y, $mon.Bottom - $ch))
    Move-WindowPx $script:CardHwnd $x $y
}

function Hide-Card {
    if (-not $script:CardVisible) { return }
    $script:CardVisible = $false
    Start-Fade $script:CardWindow 0.0 90
}

function Start-Fade {
    param($Window, [double]$To, [int]$Ms)
    $anim = New-Object Windows.Media.Animation.DoubleAnimation($To, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds($Ms))))
    $Window.BeginAnimation([Windows.Window]::OpacityProperty, $anim)
}

# ---------------------------------------------------------------- menu actions

function Set-StartWithWindows {
    param([bool]$On)
    try {
        if ($On) {
            $sh = New-Object -ComObject WScript.Shell
            try {
                $lnk = $sh.CreateShortcut($script:ShortcutPath)
                $lnk.TargetPath = Join-Path $PSHOME 'powershell.exe'
                $lnk.Arguments = ('-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath)
                $lnk.WorkingDirectory = $PSScriptRoot
                $lnk.WindowStyle = 7
                $lnk.Description = "$($script:ProductName) usage taskbar widget"
                $lnk.Save()
            } finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }
            Write-Log 'start with Windows: on'
        } else {
            Remove-Item -LiteralPath $script:ShortcutPath -Force -ErrorAction Stop
            Write-Log 'start with Windows: off'
        }
    } catch { Write-Log "start with Windows change failed: $($_.Exception.Message)" }
}

function Update-MenuChecks {
    Set-MenuTheme
    $m = $script:MenuItems; $s = $script:Settings
    $m.MenuPillBudget.IsChecked = ($s.pill -eq 'budget'); $m.MenuPillCountdown.IsChecked = ($s.pill -eq 'countdown')
    $m.MenuCompact.IsChecked = [bool]$s.compact
    $m.MenuDetails.IsChecked = [bool]$s.details
    foreach ($v in 60, 120, 300, 600) { $m["MenuPoll$v"].IsChecked = ($s.poll -eq $v) }
    $m.MenuAlertsOn.IsChecked = [bool]$s.alerts
    foreach ($v in 50, 25, 10, 5) { $m["MenuAlert$v"].IsChecked = (@($s.alert_at) -contains $v); $m["MenuAlert$v"].IsEnabled = [bool]$s.alerts }
    $m.MenuAlertRunOut.IsChecked = [bool]$s.alert_runout; $m.MenuAlertRunOut.IsEnabled = [bool]$s.alerts
    $m.MenuAllBars.IsChecked = [bool]$s.all_taskbars
    $m.MenuReset.IsEnabled = ($s.placement -eq 'manual')
    $m.MenuStartup.IsChecked = (Test-Path -LiteralPath $script:ShortcutPath)
    $m.MenuUninstall.IsEnabled = (Test-Path -LiteralPath $script:UninstallPath)
    $m.MenuAbout.Header = ('About (version {0})' -f $script:Version)
    $m.MenuSignIn.IsEnabled = ($null -eq $script:SignInProc -or $script:SignInProc.HasExited)
    $snoozed = Test-Snoozed $s
    $m.MenuSnooze.IsEnabled = [bool]$s.alerts
    $m.MenuSnoozeOff.Visibility = $(if ($snoozed) { 'Visible' } else { 'Collapsed' })
    $m.MenuSnoozeReset.IsEnabled = ($null -ne (Get-SnoozeUntil 'reset' $(if ($null -ne $script:Data) { $script:Data.weekly } else { $null })))
    # Show the current choice in each submenu's own label, so it can be read without opening it.
    $polls = @{ 60 = '1 minute'; 120 = '2 minutes'; 300 = '5 minutes'; 600 = '10 minutes' }
    $m.MenuPill.Header = '_Pill shows: ' + $(if ($s.pill -eq 'budget') { "today's budget" } else { 'time until reset' })
    $m.MenuPoll.Header = 'Refresh _every: ' + $polls[[int]$s.poll]
    $m.MenuAlerts.Header = '_Alerts: ' + $(if (-not $s.alerts) { 'off' } else { $at = @($s.alert_at | ForEach-Object { "$_%" }) -join ', '; $(if ($at) { "on ($at)" } else { 'on' }) })
    $m.MenuSnooze.Header = $(if ($snoozed) { 'Snoo_zed until ' + (Format-SnoozeEnd ([double]$s.snooze_until)) } else { 'Snoo_ze alerts' })
}

function Initialize-Menu {
    $script:Menu = New-FromXaml $script:MenuXaml
    $script:MenuItems = @{}
    foreach ($n in @([regex]::Matches($script:MenuXaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })) { $script:MenuItems[$n] = $script:Menu.FindName($n) }
    Set-MenuTheme
    $m = $script:MenuItems
    $script:Menu.add_Opened({ Update-MenuChecks; Hide-Card })
    $m.MenuRefresh.add_Click({ $script:ManualRefresh = $true; Start-Refresh $true; Update-View })
    $m.MenuOpen.add_Click({ try { Start-Process $script:UsageUrl } catch { Write-Log 'could not open usage page' } })
    $m.MenuSignIn.add_Click({ Start-SignIn })
    foreach ($pair in @(@('MenuSnooze1h', '1h'), @('MenuSnoozeMorning', 'morning'), @('MenuSnoozeReset', 'reset'), @('MenuSnoozeOff', 'off'))) {
        $m[$pair[0]].Tag = $pair[1]
        $m[$pair[0]].add_Click({
            param($s, $e)
            $until = Get-SnoozeUntil ([string]$s.Tag) $(if ($null -ne $script:Data) { $script:Data.weekly } else { $null })
            if ($null -eq $until) { return }
            $script:Settings.snooze_until = [double]$until
            Save-Settings
            Write-Log $(if ($until -gt 0) { "alerts snoozed until $(Format-SnoozeEnd $until)" } else { 'alerts resumed' })
            Update-View
        })
    }
    foreach ($n in 'MenuPillBudget', 'MenuPillCountdown') { $m[$n].add_Click({ param($s, $e) $script:Settings.pill = [string]$s.Tag; Save-Settings; Update-View }) }
    $m.MenuCompact.add_Click({ $script:Settings.compact = -not $script:Settings.compact; Save-Settings; Update-Placement; Update-View })
    $m.MenuDetails.add_Click({ $script:Settings.details = -not $script:Settings.details; Save-Settings; Update-View })
    foreach ($v in 60, 120, 300, 600) {
        $m["MenuPoll$v"].add_Click({ param($s, $e) $script:Settings.poll = [int]$s.Tag; Save-Settings; $script:PollTimer.Interval = [TimeSpan]::FromSeconds($script:Settings.poll) })
    }
    $m.MenuAlertsOn.add_Click({ $script:Settings.alerts = -not $script:Settings.alerts; Save-Settings })
    foreach ($v in 50, 25, 10, 5) {
        $m["MenuAlert$v"].add_Click({
            param($s, $e)
            $val = [int]$s.Tag
            $cur = @($script:Settings.alert_at)
            $script:Settings.alert_at = $(if ($cur -contains $val) { @($cur | Where-Object { $_ -ne $val }) } else { @($cur + $val | Sort-Object -Descending -Unique) })
            Save-Settings
        })
    }
    $m.MenuAlertRunOut.add_Click({ $script:Settings.alert_runout = -not $script:Settings.alert_runout; Save-Settings })
    $m.MenuAlertTest.add_Click({
        $at = @($script:Settings.alert_at | ForEach-Object { "$_%" }) -join ', '
        $ok = Show-Toast ('{0} usage alerts work' -f $script:ProductName) ('You will be told at {0} left{1}.' -f $(if ($at) { $at } else { 'no threshold' }), $(if ($script:Settings.alert_runout) { ' and when you are on track to run out early' } else { '' }))
        if (-not $ok) { [void][Windows.MessageBox]::Show('Windows did not accept the notification. Check that notifications are on for Windows PowerShell (Settings > System > Notifications).', $script:WindowTitle) }
    })
    $m.MenuAllBars.add_Click({ $script:Settings.all_taskbars = -not $script:Settings.all_taskbars; Save-Settings; Update-Placement })
    $m.MenuReset.add_Click({
        $script:Settings.placement = 'auto'; $script:Settings.x = $null; $script:Settings.y = $null
        Save-Settings
        Update-Placement
    })
    $m.MenuStartup.add_Click({ Set-StartWithWindows (-not (Test-Path -LiteralPath $script:ShortcutPath)) })
    $m.MenuLog.add_Click({ try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:AppDir) } catch { Write-Log 'could not open data folder' } })
    $m.MenuUninstall.add_Click({
        $msg = ('Remove the {0} usage widget from this PC?{1}{1}This stops it, removes it from Windows startup and the Start menu, and deletes its folder (settings and history included). Your {0} sign-in is not touched.' -f $script:ProductName, [Environment]::NewLine)
        if ([Windows.MessageBox]::Show($msg, $script:WindowTitle, 'YesNo', 'Question') -ne 'Yes') { return }
        try {
            Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden -WorkingDirectory $env:USERPROFILE -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:UninstallPath), '-Quiet')
            Write-Log 'uninstall started from the menu'
        } catch { [void][Windows.MessageBox]::Show("The uninstaller could not be started: $($_.Exception.Message)", $script:WindowTitle) }
    })
    $m.MenuAbout.add_Click({ try { Start-Process $script:HomeUrl } catch { Write-Log 'could not open the website' } })
    $m.MenuExit.add_Click({ Stop-Widget })
}

function Stop-Widget {
    foreach ($t in @($script:PollTimer, $script:TickTimer, $script:PlaceTimer, $script:RenderTimer, $script:HideTimer)) { if ($null -ne $t) { $t.Stop() } }
    if ($null -ne $script:Proc) { try { [void](Stop-ProcessTree $script:Proc.Id) } catch { } }
    try { [IO.File]::WriteAllText($script:ExitMarkerPath, 'Exit chosen in the menu') } catch { }   # the watchdog keeps it closed
    if ($script:HistoryDirty) { Save-History }
    try { $script:CardWindow.Close() } catch { }
    foreach ($p in @($script:Pills)) { try { $p.Win.Close() } catch { } }
    [Windows.Application]::Current.Shutdown()
}

# ---------------------------------------------------------------- main

function Start-Widget {
    [Environment]::CurrentDirectory = $env:USERPROFILE                 # never hold the install folder open
    # Per-monitor DPI so Win32 coordinates are physical pixels and WPF scales per monitor.
    [AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
    Initialize-Native
    try { [void][UsageWidget.Native]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    $script:Settings = Read-Settings
    $script:History = Read-History $script:HistoryPath
    $script:AlertsSent = Read-AlertsSent
    $script:HistoryDirty = $false
    $script:HistorySavedAt = [DateTime]::UtcNow
    $script:Data = $null
    $script:Proc = $null
    $script:Refreshing = $false
    $script:CollectorFailure = $null
    $script:LastCollectorSig = $null
    $script:Dragging = $false
    $script:DragStart = $null
    $script:CardVisible = $false
    $script:CardPinned = $false
    $script:ManualRefresh = $false
    $script:LastClickRefresh = [DateTime]::MinValue
    $script:SignInProc = $null
    $script:CardOwner = $null
    $script:PillState = $null
    $script:ThemeCache = @{ name = $null }
    $script:Pills = New-Object System.Collections.ArrayList

    $app = New-Object Windows.Application
    $app.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown
    $app.add_DispatcherUnhandledException({ param($s, $e) Write-Log "unhandled: $($e.Exception.Message)"; $e.Handled = $true })
    $app.add_SessionEnding({ if ($script:HistoryDirty) { Save-History } })

    Initialize-Menu
    $card = New-FromXaml $script:CardXaml
    $card.Title = $script:WindowTitle + ' details'
    $script:CardWindow = $card
    $script:UI = @{}
    foreach ($n in @([regex]::Matches($script:CardXaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })) { $script:UI[$n] = $card.FindName($n) }
    $script:UI.CardTitle.Text = $script:WindowTitle

    # Hover card: hides shortly after the pointer leaves every pill, unless pinned by a click.
    $script:HideTimer = New-Object Windows.Threading.DispatcherTimer
    $script:HideTimer.Interval = [TimeSpan]::FromMilliseconds(180)
    $script:HideTimer.add_Tick({
        $script:HideTimer.Stop()
        $over = @($script:Pills | Where-Object { $_.Win.IsMouseOver }).Count -gt 0
        if (-not $script:CardPinned -and -not $over) { Hide-Card }
    })

    # Timers: collector cadence, collector completion check, placement follow, countdown re-render.
    $script:PollTimer = New-Object Windows.Threading.DispatcherTimer
    $script:PollTimer.Interval = [TimeSpan]::FromSeconds($script:Settings.poll)
    $script:PollTimer.add_Tick({ Start-Refresh $false })
    $script:TickTimer = New-Object Windows.Threading.DispatcherTimer
    $script:TickTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:TickTimer.add_Tick({ if ($null -ne $script:SignInProc -and $script:SignInProc.HasExited) { $script:SignInProc = $null; Write-Log 'sign-in window closed; refreshing'; $script:ManualRefresh = $true; Start-Refresh $true } })
    $script:TickTimer.add_Tick({ try { Complete-Refresh } catch { Write-Log "refresh error: $($_.Exception.Message)"; Reset-Refresh } })
    # A foreground change already re-raised the pills (in the hook); a hidden pill re-checks at once so it
    # comes back as soon as the full-screen app loses focus instead of up to 1.5 s later.
    $script:TickTimer.add_Tick({
        if ([UsageWidget.Native]::TakeForegroundChanges() -gt 0 -and @($script:Pills | Where-Object { $_.Hidden }).Count -gt 0) {
            try { Update-Placement } catch { Write-Log "placement error: $($_.Exception.Message)" }
        }
    })
    if (-not [UsageWidget.Native]::WatchForeground()) { Write-Log 'foreground hook unavailable; the pills re-assert topmost every 1.5 s only' }
    $script:PlaceTimer = New-Object Windows.Threading.DispatcherTimer
    $script:PlaceTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $script:PlaceTimer.add_Tick({ try { Update-Placement } catch { Write-Log "placement error: $($_.Exception.Message)" } })
    $script:RenderTimer = New-Object Windows.Threading.DispatcherTimer
    $script:RenderTimer.Interval = [TimeSpan]::FromSeconds(20)
    $script:RenderTimer.add_Tick({
        $nowT = [DateTime]::UtcNow
        # A long gap between 20-second ticks means the PC slept: refresh at once instead of waiting a full poll.
        if (($nowT - $script:LastRenderTick).TotalSeconds -ge 90) { Write-Log 'resumed after a pause; refreshing'; Start-Refresh $false }
        $script:LastRenderTick = $nowT
        Write-Heartbeat
        # A pinned card closes by itself 90 s after the pointer last left the pills.
        $over = @($script:Pills | Where-Object { $_.Win.IsMouseOver }).Count -gt 0
        if ($over) { $script:LastPillHover = $nowT }
        elseif ($script:CardPinned -and ($nowT - $script:LastPillHover).TotalSeconds -ge 90) { $script:CardPinned = $false; Hide-Card }
        Update-View
    })
    $script:LastRenderTick = [DateTime]::UtcNow
    $script:LastPillHover = [DateTime]::UtcNow

    Remove-Item -LiteralPath $script:ExitMarkerPath -Force -ErrorAction SilentlyContinue   # started again: the watchdog may restart it
    Write-Heartbeat
    Update-View
    Sync-Pills
    Start-Refresh $false
    foreach ($t in @($script:PollTimer, $script:TickTimer, $script:PlaceTimer, $script:RenderTimer)) { $t.Start() }
    Write-Log "started v$($script:Version) (pid $PID) from $PSScriptRoot"
    [void]$app.Run()
    if ($script:HistoryDirty) { Save-History }
    try { $script:Mutex.ReleaseMutex() } catch { }
}

Start-Widget
