<#
.SYNOPSIS
    Draws the website and README images from the current widget code (Windows only).
.DESCRIPTION
    Draws the pills, the cards (dark, light, with details), the right-click menu and the link preview (og.png)
    with made-up figures, using the widget's own drawing code. Nothing reads a real sign-in or calls the network:
    each collector reads a fixture reply (-TestResponseFile) with placeholder credentials.

    Run it in Windows PowerShell 5.1 (it needs WPF):
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\screenshots.ps1
    It writes site\images\*.png, site\og.png and docs\images\*.png under -OutDir (default: this repository).
    The Screenshots workflow runs it on a Windows runner and uploads the images.
#>
param(
    [string]$OutDir = (Split-Path -Parent $PSScriptRoot),
    [ValidateSet('all', 'claude', 'codex', 'og')][string]$Part = 'all'
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

if ($Part -eq 'all') {
    # One process per widget: each loads its own copy of the widget script.
    foreach ($p in 'claude', 'codex', 'og') {
        & (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath -OutDir $OutDir -Part $p
        if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: the $p images (exit $LASTEXITCODE)" -ForegroundColor Red; exit 1 }
    }
    Write-Host "OK: images written under $OutDir" -ForegroundColor Green
    exit 0
}

$utf8 = New-Object Text.UTF8Encoding($false)
$Scale = 700.0 / 330.0     # the card window is 330 DIP wide; the published card images are 700 px wide
$work = Join-Path ([IO.Path]::GetTempPath()) ('usage-widget-shots-' + $Part)
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
[void](New-Item -ItemType Directory -Path $work -Force)
$siteDir = Join-Path $OutDir 'site\images'
$docsDir = Join-Path $OutDir 'docs\images'
foreach ($d in $siteDir, $docsDir) { [void](New-Item -ItemType Directory -Path $d -Force) }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

function Invoke-Idle {
    # Lets WPF finish layout and rendering work queued so far.
    [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::ApplicationIdle)
}

function Get-Image {
    # Draws a visual at $S times its size; $Backdrop and $Pad (DIP) add a solid surround.
    param($Visual, [double]$W, [double]$H, [double]$S = $Scale, [string]$Backdrop = '', [double]$Pad = 0)
    $dpi = 96.0 * $S
    $raw = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int][Math]::Ceiling($W * $S)), ([int][Math]::Ceiling($H * $S)), $dpi, $dpi, ([Windows.Media.PixelFormats]::Pbgra32)
    $raw.Render($Visual)
    if (-not $Backdrop -and $Pad -eq 0) { return $raw }
    $fw = $W + 2 * $Pad; $fh = $H + 2 * $Pad
    $dv = New-Object Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    if ($Backdrop) {
        $b = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($Backdrop))
        $dc.DrawRectangle($b, $null, (New-Object Windows.Rect 0, 0, $fw, $fh))
    }
    $dc.DrawImage($raw, (New-Object Windows.Rect $Pad, $Pad, $W, $H))
    $dc.Close()
    $out = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int][Math]::Ceiling($fw * $S)), ([int][Math]::Ceiling($fh * $S)), $dpi, $dpi, ([Windows.Media.PixelFormats]::Pbgra32)
    $out.Render($dv)
    return $out
}

function Save-Png {
    param($Bitmap, [string]$Path)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
    $fs = [IO.File]::Create($Path)
    try { $enc.Save($fs) } finally { $fs.Dispose() }
    Write-Host ('  {0}  {1}x{2}' -f $Path, $Bitmap.PixelWidth, $Bitmap.PixelHeight)
}

function Save-Window {
    # A widget window (pill or card): its root visual at the window's size.
    param($Window, [string]$Path, [string]$Backdrop = '', [double]$Pad = 0)
    $Window.UpdateLayout(); Invoke-Idle
    $rootVisual = [Windows.Media.VisualTreeHelper]::GetChild($Window, 0)
    Save-Png (Get-Image $rootVisual $Window.ActualWidth $Window.ActualHeight $Scale $Backdrop $Pad) $Path
}

# ---------------------------------------------------------------- link preview (og.png)

if ($Part -eq 'og') {
    $xaml = @'
<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1200" Height="630" Background="#0D1014" UseLayoutRounding="True">
  <TextBlock Canvas.Left="72" Canvas.Top="128" FontFamily="Segoe UI" FontSize="20" FontWeight="SemiBold"
             Foreground="#9AA4B2" Text="AI USAGE TASKBAR WIDGETS"/>
  <TextBlock Canvas.Left="72" Canvas.Top="176" FontFamily="Segoe UI Variable Display, Segoe UI" FontSize="58" FontWeight="Bold"
             LineHeight="76" LineStackingStrategy="BlockLineHeight" Foreground="#F5F8FF"><Run Foreground="#5EEAD4" Text="Claude and Codex"/><LineBreak/><Run Foreground="#5EEAD4" Text="limits,"/><Run Text=" always on"/><LineBreak/><Run Text="your taskbar"/></TextBlock>
  <TextBlock Canvas.Left="72" Canvas.Top="428" Width="480" FontFamily="Segoe UI" FontSize="24" Foreground="#9AA4B2"
             LineHeight="34" LineStackingStrategy="BlockLineHeight" TextWrapping="Wrap"
             Text="How much is used, your pace, and when it runs out. Free for Windows 10 and 11."/>
  <Image x:Name="Back" Canvas.Left="590" Canvas.Top="178" Width="320"/>
  <Image x:Name="Front" Canvas.Left="830" Canvas.Top="58" Width="320"/>
</Canvas>
'@
    $canvas = [Windows.Markup.XamlReader]::Parse($xaml)
    foreach ($pair in @(@('Back', 'codex-card.png'), @('Front', 'claude-card.png'))) {
        $bi = New-Object Windows.Media.Imaging.BitmapImage
        $bi.BeginInit(); $bi.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.UriSource = New-Object Uri (Join-Path $siteDir $pair[1]); $bi.EndInit()
        $canvas.FindName($pair[0]).Source = $bi
    }
    $canvas.Measure((New-Object Windows.Size 1200, 630))
    $canvas.Arrange((New-Object Windows.Rect 0, 0, 1200, 630))
    $canvas.UpdateLayout(); Invoke-Idle
    Save-Png (Get-Image $canvas 1200 630 1.0) (Join-Path $OutDir 'site\og.png')
    exit 0
}

# ---------------------------------------------------------------- one reading from a fixture reply

$isClaude = $Part -eq 'claude'
$dir = Join-Path $Root "$Part-usage-widget"
$now = [DateTimeOffset]::UtcNow
$respPath = Join-Path $work 'reply.json'
$cache = Join-Path $work 'cache\usage-cache.json'
if ($isClaude) {
    # Claude: 45% of the week used with 23 h to go (on pace), 21% of the 5-hour session used.
    $cfg = Join-Path $work 'claude-home'; [void](New-Item -ItemType Directory -Path $cfg -Force)
    [IO.File]::WriteAllText((Join-Path $cfg '.credentials.json'), (ConvertTo-Json @{ claudeAiOauth = @{ accessToken = 'fixture-not-a-real-token-0000'; refreshToken = 'fixture-refresh'; expiresAt = 4102444800000; subscriptionType = 'team' } }), $utf8)
    [IO.File]::WriteAllText((Join-Path $cfg '.claude.json'), (ConvertTo-Json @{ oauthAccount = @{ accountUuid = 'fixture-acct'; organizationUuid = 'fixture-org'; emailAddress = 'fixture@example.invalid' } }), $utf8)
    $fakeCli = Join-Path $work 'fake-claude.cmd'
    [IO.File]::WriteAllText($fakeCli, "@echo off`r`nexit /b 1`r`n")
    $weekReset = $now.AddHours(23).AddMinutes(1).AddSeconds(40)
    $sessionReset = $now.AddHours(3).AddMinutes(41).AddSeconds(40)
    $reply = [ordered]@{
        five_hour = [ordered]@{ utilization = 21; resets_at = $sessionReset.ToString('o') }
        seven_day = [ordered]@{ utilization = 45; resets_at = $weekReset.ToString('o') }
        seven_day_oauth_apps = $null; seven_day_opus = $null; seven_day_sonnet = $null
        extra_usage = [ordered]@{ is_enabled = $false } }
    [IO.File]::WriteAllText($respPath, (ConvertTo-Json $reply -Depth 5), $utf8)
    $env:CLAUDE_CONFIG_DIR = $cfg
    $collectorArgs = @('-Force', '-NoRenew', '-ClaudeCliPath', $fakeCli, '-CachePath', $cache, '-TestResponseFile', $respPath)
    $collector = Join-Path $dir 'claude-usage.ps1'
} else {
    # Codex: 90% of the week used with 5 days to go (too fast), 62,500 credits.
    $ch = Join-Path $work 'codex-home'; [void](New-Item -ItemType Directory -Path $ch -Force)
    [IO.File]::WriteAllText((Join-Path $ch 'auth.json'), '{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-not-a-real-token","account_id":"fixture-acct"}}', $utf8)
    $weekReset = $now.AddDays(5).AddHours(1).AddSeconds(40)
    $reply = '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":90,"limit_window_seconds":604800,"reset_at":RESET}},"credits":{"balance":62500}}'.Replace('RESET', [string]$weekReset.ToUnixTimeSeconds())
    [IO.File]::WriteAllText($respPath, $reply, $utf8)
    $env:CODEX_HOME = $ch
    $collectorArgs = @('-Force', '-NoCli', '-CachePath', $cache, '-TestResponseFile', $respPath)
    $collector = Join-Path $dir 'codex-usage.ps1'
}
$json = & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $collector @collectorArgs
$data = ($json -join "`n") | ConvertFrom-Json
if ($null -eq $data.schema_version -or $null -eq $data.weekly) { Write-Host "FAIL: the $Part collector gave no reading: $json" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- the widget's own drawing code

# Load the widget without its single-instance block and without starting it; its files go to a scratch folder.
$env:LOCALAPPDATA = Join-Path $work 'appdata'
[void](New-Item -ItemType Directory -Path (Join-Path $env:LOCALAPPDATA ($(if ($isClaude) { 'ClaudeUsageWidget' } else { 'CodexUsageWidget' }))) -Force)
$src = [IO.File]::ReadAllText((Join-Path $dir "$Part-usage-widget.ps1"))
$a = $src.IndexOf('# ---------------------------------------------------------------- single instance / STA')
$b = $src.IndexOf('# ---------------------------------------------------------------- constants')
$c = $src.LastIndexOf("`nStart-Widget")
if ($a -lt 0 -or $b -le $a -or $c -le $b) { Write-Host 'FAIL: the widget script layout changed; update tools\screenshots.ps1' -ForegroundColor Red; exit 1 }
$src = ($src.Substring(0, $a) + $src.Substring($b, $c - $b)).Replace('$PSScriptRoot', ("'" + $dir.Replace("'", "''") + "'"))
. ([ScriptBlock]::Create($src))
$script:ShotTheme = 'dark'
function Get-ThemeName { return $script:ShotTheme }   # the theme comes from this tool, not from Windows

[AppContext]::SetSwitch('Switch.System.Windows.DoNotScaleForDpiChanges', $false)
Initialize-Native
$script:Settings = ConvertTo-Settings $null $script:DefaultPollSeconds
$script:History = New-History
$script:AlertsSent = @{}
$script:Data = $null; $script:Proc = $null; $script:Refreshing = $false; $script:CollectorFailure = $null
$script:Dragging = $false; $script:DragStart = $null; $script:CardVisible = $false; $script:CardPinned = $false
$script:ManualRefresh = $false; $script:SignInProc = $null; $script:CardOwner = $null; $script:PillState = $null
$script:ThemeCache = @{ name = $null }
$script:Pills = New-Object System.Collections.ArrayList
$app = New-Object Windows.Application
$app.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown
$script:HideTimer = New-Object Windows.Threading.DispatcherTimer
$script:PollTimer = New-Object Windows.Threading.DispatcherTimer
Initialize-Menu
$card = New-FromXaml $script:CardXaml
$script:CardWindow = $card
$script:UI = @{}
foreach ($n in @([regex]::Matches($script:CardXaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })) { $script:UI[$n] = $card.FindName($n) }
$script:UI.CardTitle.Text = $script:WindowTitle

# Readings since the window started, so the pace box, the chart and the speed lines have something to show.
function Add-Ramp {
    param($List, [double]$From, [double]$To, [double]$U0, [double]$U1, [double]$Reset)
    for ($t = $From; $t -lt $To; $t += 1800) { [void]$List.Add(@{ t = $t; u = $U0 + ($U1 - $U0) * ($t - $From) / ($To - $From); r = $Reset }) }
}
$nowU = ConvertTo-Unix (ConvertTo-UtcTime $data.fetched_at)
$wr = ConvertTo-Unix (ConvertTo-UtcTime $data.weekly.resets_at)
if ($isClaude) {
    Add-Ramp $script:History.w ($wr - 7 * 86400) ($nowU - 6 * 3600) 0 42 $wr      # 0.3%/h on average,
    Add-Ramp $script:History.w ($nowU - 6 * 3600) ($nowU - 600) 42 44.9 $wr       # 0.5%/h over the last 6 hours
    if ($null -ne $data.session) {
        $sr = ConvertTo-Unix (ConvertTo-UtcTime $data.session.resets_at)
        Add-Ramp $script:History.s ($sr - 5 * 3600) ($nowU - 600) 0 20.5 $sr
    }
} else {
    Add-Ramp $script:History.w ($wr - 7 * 86400) ($nowU - 600) 0 89.6 $wr
}
[void](Add-HistorySample $script:History $data)
$script:Data = $data

# A pill like New-Pill makes, without the taskbar placement and mouse handling.
$pillWin = New-FromXaml $script:PillXaml
$pui = @{}
foreach ($n in @([regex]::Matches($script:PillXaml, 'x:Name="(\w+)"') | ForEach-Object { $_.Groups[1].Value })) { $pui[$n] = $pillWin.FindName($n) }
$pui.Pill.MinWidth = $script:PillWidth
[void]$script:Pills.Add(@{ Win = $pillWin; Hwnd = $null; Bar = [IntPtr]::Zero; Primary = $true; UI = $pui; Hidden = $false; FullChecks = 0; Mode = $null; Note = $null; AnchorSeenAt = $null })
foreach ($w in $pillWin, $card) { $w.Opacity = 1.0; $w.Show() }

function Update-Shot { $script:ThemeCache = @{ name = $null }; Update-View; Invoke-Idle }

$taskbarDark = '#FF1C1C1C'; $taskbarLight = '#FFEEEEEE'; $docsDark = '#FF1E1E1E'; $docsLight = '#FFE9EBEF'
Write-Host "$Part images:"
Update-Shot
Save-Window $card (Join-Path $siteDir "$Part-card.png")
Save-Window $card (Join-Path $docsDir "$Part-card.png") $docsDark
Save-Window $pillWin (Join-Path $siteDir "$Part-pill.png") $taskbarDark 8
Save-Window $pillWin (Join-Path $docsDir "$Part-pill.png") $taskbarDark 8

if ($isClaude) {
    # Right-click menu, laid out on its own (no popup needed).
    Set-MenuTheme; Update-MenuChecks
    $menu = $script:Menu
    $menu.Measure((New-Object Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
    $menu.Arrange((New-Object Windows.Rect 0, 0, $menu.DesiredSize.Width, $menu.DesiredSize.Height))
    $menu.UpdateLayout(); Invoke-Idle
    Save-Png (Get-Image $menu $menu.ActualWidth $menu.ActualHeight) (Join-Path $siteDir 'claude-menu.png')
    Save-Png (Get-Image $menu $menu.ActualWidth $menu.ActualHeight $Scale $docsDark) (Join-Path $docsDir 'claude-menu.png')

    $script:Settings.details = $true; Update-Shot
    Save-Window $card (Join-Path $siteDir 'claude-details-card.png')
    Save-Window $card (Join-Path $docsDir 'claude-details-card.png') $docsDark
    $script:Settings.details = $false

    $script:ShotTheme = 'light'; Update-Shot
    Save-Window $card (Join-Path $siteDir 'claude-light-card.png')
    Save-Window $card (Join-Path $docsDir 'claude-light-card.png') $docsLight
    Save-Window $pillWin (Join-Path $docsDir 'claude-light-pill.png') $taskbarLight 8
}

$log = Join-Path $script:AppDir 'widget.log'
if (Test-Path -LiteralPath $log) {
    $errors = @(Get-Content -LiteralPath $log | Where-Object { $_ -match 'error' })
    if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Host "FAIL: widget log: $_" -ForegroundColor Red }; exit 1 }
}
foreach ($w in $pillWin, $card) { $w.Close() }
exit 0
