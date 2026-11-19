<#
.SYNOPSIS
    Local Claude usage collector for the Claude Usage Widget (Windows PowerShell 5.1).

.DESCRIPTION
    Reads the Claude Code sign-in from <CLAUDE_CONFIG_DIR or %USERPROFILE%\.claude>\.credentials.json on THIS PC,
    calls GET https://api.anthropic.com/api/oauth/usage and prints exactly ONE JSON document to stdout.
    It never prints or logs tokens, account identifiers or e-mail, never refreshes or rewrites credentials,
    and writes only its cache and state files under %LOCALAPPDATA%\ClaudeUsageWidget (or next to -CachePath).

    The access token lives ~8 hours and only Claude Code itself renews it (the desktop app signs in separately).
    When it has expired (or the service answers 401), the collector runs the official CLI's local command
    `claude -p "/usage" --no-session-persistence --strict-mcp-config` - no AI request, no quota - which makes
    Claude Code renew its own sign-in, then reads the renewed token. At most once per 10 minutes unless
    .credentials.json changes. If no CLI is found or renewal fails, it reports auth_expired with the last
    cached reading as stale. -NoRenew turns this off.

    HTTP 429/5xx from the usage service start a backoff (Retry-After, else 2 min doubling to 30 min) during
    which the last reading is shown as stale instead of calling again.

    Output (schema_version 1, same contract as the Codex widget):
      weekly / session   { used, left, window_seconds, resets_at } or null   (used = PERCENT USED)
      scoped             [ { id, name, kind, used, left, window_seconds, resets_at } ]  (e.g. Opus / Sonnet weekly)
      plan               subscription type string or null
      extra_usage        { enabled, utilization } or null
      fetched_at, status (ok|stale|unavailable), source (live|cache|none), stale, age_seconds,
      account_verified, unclassified, reset_passed, error, collected_at

    Exit codes: 0 fresh, 2 stale fallback, 3 unavailable, 4 internal error (JSON still printed).
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Diagnostics,
    [switch]$NoRenew,
    [string]$CachePath,
    # Claude Code CLI to use for renewal (default: ~\.local\bin\claude.exe, then PATH). Tests pass a fake.
    [string]$ClaudeCliPath,
    # TEST ONLY (simulated): JSON file used as the HTTP 200 body instead of the network.
    [string]$TestResponseFile,
    # TEST ONLY (simulated): pretend the request failed with this HTTP status (-1 = network error, -2 = offline: DNS or connect failure).
    [int]$TestHttpStatus = 0,
    # TEST ONLY: override "now" as Unix seconds.
    [double]$TestNowUnix = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:UsageUri        = 'https://api.anthropic.com/api/oauth/usage'
$script:RenewRetrySeconds = 600
$script:RenewTimeoutMs  = 40000
$script:WeekSeconds     = 604800
$script:SessionSeconds  = 18000
$script:CacheTtlSeconds = 60
$script:HttpCalls       = 0
$script:CacheResult     = 'none'
$script:RenewResult     = 'none'
$script:CliOutput       = $null
$script:CliRead         = 'none'
$script:Inv             = [Globalization.CultureInfo]::InvariantCulture
$script:Utf8NoBom       = New-Object System.Text.UTF8Encoding($false)
$script:Now = $(if ($TestNowUnix -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds([long]($TestNowUnix * 1000)).UtcDateTime } else { [DateTime]::UtcNow })

# Known usage keys -> meaning. Anything else that looks like a limit is kept as a scoped limit by its own key.
$script:ScopedNames = @{
    seven_day_opus        = 'Opus'
    seven_day_sonnet      = 'Sonnet'
    seven_day_oauth_apps  = 'OAuth apps'
    seven_day_claude_code = 'Claude Code'
}

# ---------------------------------------------------------------- helpers

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function ConvertTo-Number {
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    $d = 0.0
    if ($Value -is [string]) {
        if (-not [double]::TryParse($Value, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$d)) { return $null }
    } elseif ($Value -is [ValueType]) {
        try { $d = [double]$Value } catch { return $null }
    } else { return $null }
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return $null }
    return $d
}

function ConvertTo-UtcDate {
    param($Value)
    if ($null -eq $Value -or $Value -is [bool]) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) {
        if ($Value.Kind -eq [DateTimeKind]::Local) { return $Value.ToUniversalTime() }
        return [DateTime]::SpecifyKind($Value, [DateTimeKind]::Utc)
    }
    $n = ConvertTo-Number $Value
    if ($null -ne $n) {
        if ($n -le 0) { return $null }
        if ($n -gt 100000000000) { $n = $n / 1000.0 }
        try { return [DateTimeOffset]::FromUnixTimeMilliseconds([long][Math]::Round($n * 1000)).UtcDateTime } catch { return $null }
    }
    if ($Value -is [string] -and $Value.Trim().Length -gt 0) {
        $dto = [DateTimeOffset]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal
        if ([DateTimeOffset]::TryParse($Value, $script:Inv, $styles, [ref]$dto)) { return $dto.UtcDateTime }
    }
    return $null
}

function Format-Iso {
    param($Date)
    if ($null -eq $Date) { return $null }
    return $Date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $script:Inv)
}

function Get-WindowKind {
    param($Seconds)
    if ($null -eq $Seconds) { return 'other' }
    if ([long]$Seconds -eq $script:WeekSeconds) { return 'weekly' }
    if ([long]$Seconds -eq $script:SessionSeconds) { return 'session' }
    return 'other'
}

function New-Window {
    param($Used, $WindowSeconds, $ResetsAt)
    $u = ConvertTo-Number $Used
    $s = ConvertTo-Number $WindowSeconds
    if ($null -eq $u -or $null -eq $s -or $s -le 0) { return $null }
    $left = [Math]::Min(100.0, [Math]::Max(0.0, 100.0 - $u))
    return [ordered]@{
        used           = $u
        left           = $left
        window_seconds = [long][Math]::Round($s)
        resets_at      = (Format-Iso (ConvertTo-UtcDate $ResetsAt))
    }
}

function New-Observation {
    return [ordered]@{
        weekly        = $null
        session       = $null
        scoped        = (New-Object System.Collections.ArrayList)
        unclassified  = (New-Object System.Collections.ArrayList)
        plan          = $null
        extra_usage   = $null
        limit_reached = $null
        fetched_at    = $null
        via           = $null     # 'cli' when the reading came from Claude Code's /usage text
    }
}

function Get-KeyWindowSeconds {
    # The usage API names windows by key; the duration is implied by the key prefix.
    param([string]$Key)
    if ($Key -match '^seven_day') { return $script:WeekSeconds }
    if ($Key -match '^five_hour') { return $script:SessionSeconds }
    return $null
}

function Get-ScopedName {
    param([string]$Key)
    if ($script:ScopedNames.ContainsKey($Key)) { return $script:ScopedNames[$Key] }
    $t = ($Key -replace '^(seven_day|five_hour)_?', '') -replace '_', ' '
    if (-not $t) { $t = $Key -replace '_', ' ' }
    return (Get-Culture).TextInfo.ToTitleCase($t)
}

function ConvertFrom-LiveUsage {
    param($Json)
    $obs = New-Observation
    $obs.fetched_at = Format-Iso $script:Now
    foreach ($p in $Json.PSObject.Properties) {
        $v = $p.Value
        if ($null -eq $v -or -not ($v -is [psobject]) -or $v -is [string]) { continue }
        if ($null -eq $v.PSObject.Properties['utilization']) { continue }
        $secs = Get-KeyWindowSeconds $p.Name
        if ($p.Name -eq 'seven_day') {
            $obs.weekly = New-Window (Get-Prop $v 'utilization') $script:WeekSeconds (Get-Prop $v 'resets_at')
        } elseif ($p.Name -eq 'five_hour') {
            $obs.session = New-Window (Get-Prop $v 'utilization') $script:SessionSeconds (Get-Prop $v 'resets_at')
        } elseif ($null -ne $secs) {
            $win = New-Window (Get-Prop $v 'utilization') $secs (Get-Prop $v 'resets_at')
            if ($null -eq $win) { continue }
            $item = [ordered]@{ id = $p.Name; name = (Get-ScopedName $p.Name); kind = (Get-WindowKind $secs) }
            foreach ($k in $win.Keys) { $item[$k] = $win[$k] }
            [void]$obs.scoped.Add($item)
        } elseif ($p.Name -ne 'extra_usage') {
            $u = ConvertTo-Number (Get-Prop $v 'utilization')
            if ($null -ne $u) { [void]$obs.unclassified.Add([ordered]@{ slot = $p.Name; kind = 'other'; used = $u; resets_at = (Format-Iso (ConvertTo-UtcDate (Get-Prop $v 'resets_at'))) }) }
        }
    }
    $ex = Get-Prop $Json 'extra_usage'
    if ($null -ne $ex) {
        $en = Get-Prop $ex 'is_enabled'
        $obs.extra_usage = [ordered]@{
            enabled       = $(if ($en -is [bool]) { $en } else { $null })
            utilization   = (ConvertTo-Number (Get-Prop $ex 'utilization'))
            used_credits  = (ConvertTo-Number (Get-Prop $ex 'used_credits'))
            monthly_limit = (ConvertTo-Number (Get-Prop $ex 'monthly_limit'))
        }
    }
    return $obs
}

function Import-Observation {
    param($Stored)
    if ($null -eq $Stored) { return $null }
    $obs = New-Observation
    $f = ConvertTo-UtcDate (Get-Prop $Stored 'fetched_at')
    if ($null -eq $f) { return $null }
    $obs.fetched_at = Format-Iso $f
    foreach ($k in @('weekly', 'session')) {
        $w = Get-Prop $Stored $k
        if ($null -ne $w) {
            $win = New-Window (Get-Prop $w 'used') (Get-Prop $w 'window_seconds') (Get-Prop $w 'resets_at')
            if ($null -ne $win -and (Get-WindowKind $win.window_seconds) -eq $k) { $obs[$k] = $win }
        }
    }
    foreach ($s in @(Get-Prop $Stored 'scoped')) {
        if ($null -eq $s) { continue }
        $win = New-Window (Get-Prop $s 'used') (Get-Prop $s 'window_seconds') (Get-Prop $s 'resets_at')
        if ($null -eq $win) { continue }
        $item = [ordered]@{ id = "$(Get-Prop $s 'id')"; name = "$(Get-Prop $s 'name')"; kind = (Get-WindowKind $win.window_seconds) }
        foreach ($k in $win.Keys) { $item[$k] = $win[$k] }
        [void]$obs.scoped.Add($item)
    }
    $plan = Get-Prop $Stored 'plan'
    if ($plan -is [string] -and $plan.Length -gt 0) { $obs.plan = $plan }
    $ex = Get-Prop $Stored 'extra_usage'
    if ($null -ne $ex) {
        $en = Get-Prop $ex 'enabled'
        $obs.extra_usage = [ordered]@{ enabled = $(if ($en -is [bool]) { $en } else { $null }); utilization = (ConvertTo-Number (Get-Prop $ex 'utilization'))
                                       used_credits = (ConvertTo-Number (Get-Prop $ex 'used_credits')); monthly_limit = (ConvertTo-Number (Get-Prop $ex 'monthly_limit')) }
    }
    if ((Get-Prop $Stored 'via') -eq 'cli') { $obs.via = 'cli' }
    return $obs
}

function New-ErrorInfo {
    param([string]$Code, [string]$Message, $HttpStatus = $null)
    return [ordered]@{ code = $Code; http_status = $HttpStatus; message = $Message }
}

# ---------------------------------------------------------------- local files

function Read-SharedText {
    param([string]$Path)
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
}

function Resolve-ClaudeHome {
    $configured = $env:CLAUDE_CONFIG_DIR
    if ($configured -and $configured.Trim().Length -gt 0) {
        # A value that is not a valid path (e.g. "C:\bad|dir?") counts as a missing folder, not an internal error (#33).
        try { $p = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($configured.Trim())) }
        catch { return [ordered]@{ path = $configured; configured = $true; exists = $false } }
        $exists = $false
        try { $exists = Test-Path -LiteralPath $p -PathType Container } catch { }
        return [ordered]@{ path = $p; configured = $true; exists = $exists }
    }
    $p = Join-Path $env:USERPROFILE '.claude'
    return [ordered]@{ path = $p; configured = $false; exists = (Test-Path -LiteralPath $p -PathType Container) }
}

function Read-AuthContext {
    param($ClaudeHome)
    $renew = 'Right-click the widget and choose Sign in again (or run "claude" in a terminal), then retry.'
    $path = Join-Path $ClaudeHome.path '.credentials.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ ok = $false; error = (New-ErrorInfo 'auth_missing' "Claude Code sign-in data (.credentials.json) was not found on this PC. $renew") }
    }
    try { $j = (Read-SharedText $path) | ConvertFrom-Json }
    catch { return @{ ok = $false; error = (New-ErrorInfo 'auth_unreadable' "Claude Code sign-in data could not be read. $renew") } }
    $o = Get-Prop $j 'claudeAiOauth'
    $access = Get-Prop $o 'accessToken'
    if (-not ($access -is [string]) -or $access.Length -lt 8) {
        return @{ ok = $false; error = (New-ErrorInfo 'auth_mode_unsupported' "Claude Code is not signed in with a Claude account on this PC. $renew") }
    }
    $plan = Get-Prop $o 'subscriptionType'
    $exp = ConvertTo-UtcDate (Get-Prop $o 'expiresAt')
    # Account identity for cache compatibility (used only inside this process, never output).
    $account = $null
    $cfgPath = $(if ($ClaudeHome.configured) { Join-Path $ClaudeHome.path '.claude.json' } else { Join-Path $env:USERPROFILE '.claude.json' })
    try {
        if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
            $oa = Get-Prop ((Read-SharedText $cfgPath) | ConvertFrom-Json) 'oauthAccount'
            $a = Get-Prop $oa 'accountUuid'; $org = Get-Prop $oa 'organizationUuid'
            if ($a -is [string] -and $a.Length -gt 0) { $account = "$a|$org" }
        }
    } catch { $account = $null }
    $ctx = @{ ok = $true; access = $access; account = $account; plan = $(if ($plan -is [string] -and $plan.Length -gt 0) { $plan } else { $null }); expired = $false }
    if ($null -ne $exp -and $exp -le $script:Now.AddSeconds(30)) {
        $ctx.expired = $true
        $ctx.error = New-ErrorInfo 'auth_expired' ("The Claude Code sign-in on this PC expired {0}. $renew" -f $exp.ToLocalTime().ToString('g'))
    }
    return $ctx
}

function Get-AccountTag {
    param([string]$Account, [string]$SaltHex)
    $key = New-Object byte[] ($SaltHex.Length / 2)
    for ($i = 0; $i -lt $key.Length; $i++) { $key[$i] = [Convert]::ToByte($SaltHex.Substring($i * 2, 2), 16) }
    $h = [System.Security.Cryptography.HMACSHA256]::new($key)
    try { $bytes = $h.ComputeHash($script:Utf8NoBom.GetBytes("claude|$Account")) } finally { $h.Dispose() }
    return (-join ($bytes[0..11] | ForEach-Object { $_.ToString('x2') }))
}

function New-SaltHex {
    $b = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return (-join ($b | ForEach-Object { $_.ToString('x2') }))
}

function Read-Cache {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $c = (Read-SharedText $Path) | ConvertFrom-Json
        if ((Get-Prop $c 'schema_version') -ne 1) { return $null }
        $salt = Get-Prop $c 'salt'
        if (-not ($salt -is [string]) -or $salt -notmatch '^[0-9a-f]{32}$') { return $null }
        $obs = Import-Observation (Get-Prop $c 'observation')
        if ($null -eq $obs) { return $null }
        return @{ salt = $salt; account_tag = "$(Get-Prop $c 'account_tag')"; observation = $obs }
    } catch { return $null }
}

function Write-FlushedText {
    # Flushed to disk before the swap, so a power cut can't leave an empty file behind.
    param([string]$Path, [string]$Text)
    $bytes = $script:Utf8NoBom.GetBytes($Text)
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}

function Write-AtomicText {
    # Write via a temp file then swap it in. [NullString]::Value is required: PowerShell turns $null into ""
    # for .NET string parameters, which makes File.Replace throw "The path is not of a legal form".
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

function Write-Cache {
    param([string]$Path, [string]$Salt, [string]$Tag, $Obs)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $doc = [ordered]@{ schema_version = 1; salt = $Salt; account_tag = $Tag; observation = $Obs }
    Write-AtomicText $Path (ConvertTo-Json -InputObject $doc -Depth 12)
}

# ---------------------------------------------------------------- collector state (backoff, renewal throttle)

function Get-UnixNow { return [double]([DateTimeOffset][DateTime]::SpecifyKind($script:Now, [DateTimeKind]::Utc)).ToUnixTimeSeconds() }

function Read-State {
    # Small non-secret state file: no tokens, no identifiers.
    param([string]$Path)
    $s = @{ backoff_until = 0.0; backoff_count = 0; backoff_code = ''; renew_at = 0.0; renew_cred_ticks = 0.0; cli_read_at = 0.0 }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $j = (Read-SharedText $Path) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { $v = Get-Prop $j $k; if ($null -ne $v) { $s[$k] = $v } }
        }
    } catch { }
    return $s
}

function Write-State {
    param([string]$Path, $State)
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Write-AtomicText $Path (ConvertTo-Json -InputObject ([pscustomobject]$State) -Compress)
    } catch { }
}

function Get-RetryAfterSeconds {
    param($Header)
    if (-not $Header) { return $null }
    $n = 0
    if ([int]::TryParse(([string]$Header).Trim(), [ref]$n)) { return [double]$n }
    $d = ConvertTo-UtcDate ([string]$Header)
    if ($null -ne $d) { return [Math]::Max(0.0, ($d - $script:Now).TotalSeconds) }
    return $null
}

function Set-Backoff {
    # Retry-After when given (clamped to 1-30 min), else 2 min doubling per consecutive failure, max 30 min.
    param($State, [string]$Code, $RetryAfter)
    $n = [int]$State.backoff_count + 1
    $secs = $(if ($null -ne $RetryAfter -and $RetryAfter -gt 0) { [Math]::Min(1800.0, [Math]::Max(60.0, [double]$RetryAfter)) }
              else { [Math]::Min(1800.0, 120.0 * [Math]::Pow(2, [Math]::Min(10, $n - 1))) })
    $State.backoff_count = $n; $State.backoff_code = $Code; $State.backoff_until = (Get-UnixNow) + $secs
}

function Format-UnixLocal {
    param([double]$Unix)
    return [DateTimeOffset]::FromUnixTimeSeconds([long]$Unix).LocalDateTime.ToShortTimeString()
}

# ---------------------------------------------------------------- sign-in renewal through the official CLI

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

function Find-ClaudeCli {
    if ($ClaudeCliPath) { if (Test-Path -LiteralPath $ClaudeCliPath -PathType Leaf) { return $ClaudeCliPath }; return $null }
    $c = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    if (Test-Path -LiteralPath $c -PathType Leaf) { return $c }
    $cmd = Get-Command 'claude.exe', 'claude.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $cmd) { return $cmd.Source }
    return (Find-BundledClaudeCli)
}

function Get-CredTicks {
    param($ClaudeHome)
    # Last-write time in Unix ms (exact in a double, unlike .NET ticks).
    try { return [double]([DateTimeOffset](Get-Item -LiteralPath (Join-Path $ClaudeHome.path '.credentials.json')).LastWriteTimeUtc).ToUnixTimeMilliseconds() } catch { return 0.0 }
}

function Invoke-CliRenewal {
    # Lets Claude Code renew ITS OWN sign-in: runs its local /usage command (no AI request, no quota, no saved
    # session). Returns $true when .credentials.json changed. Throttled to one try per RenewRetrySeconds unless
    # the file changed since the last try. Output is discarded (never logged).
    param($ClaudeHome, $State)
    $before = Get-CredTicks $ClaudeHome
    $nowU = Get-UnixNow
    if ([double]$State.renew_cred_ticks -eq $before -and ($nowU - [double]$State.renew_at) -lt $script:RenewRetrySeconds) { $script:RenewResult = 'throttled'; return $false }
    $State.renew_at = $nowU
    $State.renew_cred_ticks = $before
    $r = Invoke-ClaudeCli
    $script:RenewResult = $r.result
    $after = Get-CredTicks $ClaudeHome
    $State.renew_cred_ticks = $after
    if ($after -ne $before) { $script:RenewResult = 'renewed'; return $true }
    return $false
}

function Invoke-TreeKill {
    # Ends a process and every child it started (claude.cmd -> node), so a hung CLI never leaves orphans (#35).
    param($Process)
    try {
        $tk = [IO.Path]::Combine($env:SystemRoot, 'System32', 'taskkill.exe')
        if (Test-Path -LiteralPath $tk) { & cmd.exe /d /c ('"{0}" /T /F /PID {1} >nul 2>nul' -f $tk, $Process.Id) }
    } catch { }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
}

function Invoke-ClaudeCli {
    # Runs `claude -p "/usage"` (local command: no AI request, no quota, no saved session). Keeps the text output
    # in memory for ConvertFrom-UsageText (never written anywhere). Returns @{ result; output }.
    $exe = Find-ClaudeCli
    if (-not $exe) { return @{ result = 'no_cli'; output = $null } }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo $exe
        $psi.Arguments = '-p "/usage" --no-session-persistence --strict-mcp-config'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $script:Utf8NoBom
        $psi.WorkingDirectory = $env:USERPROFILE
        # Use the CLI's own stored sign-in, never a host app's session (e.g. when started from the Claude app).
        foreach ($k in @($psi.EnvironmentVariables.Keys)) { if ($k -match '^(ANTHROPIC_|CLAUDE_CODE_|CLAUDECODE$|CLAUDE_AGENT_SDK)') { $psi.EnvironmentVariables.Remove($k) } }
        $p = [Diagnostics.Process]::Start($psi)
        $o = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($script:RenewTimeoutMs)) { Invoke-TreeKill $p; $p.Dispose(); return @{ result = 'timeout'; output = $null } }
        $code = $p.ExitCode
        $p.Dispose()
        $text = $(if ($o.Wait(2000)) { $o.Result } else { $null })
        $script:CliOutput = $text
        $script:CliOutputAt = $script:Now
        return @{ result = "exit_$code"; output = $text }
    } catch { return @{ result = 'start_failed'; output = $null } }
}

function ConvertFrom-ResetText {
    # "Nov 14, 6:59pm (America/Chicago)" / "6:59pm" / "Nov 14 at 6:59pm" -> UTC. The CLI prints the PC's own
    # time zone, so the text is read as local time; the year is the next occurrence.
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = ($Text -replace '\([^)]*\)', '').Trim() -replace '\s+at\s+', ', '
    $t = [regex]::Replace($t, '(\d)\s*([ap])\.?m\.?\b', { param($m) $m.Groups[1].Value + ' ' + $m.Groups[2].Value.ToUpperInvariant() + 'M' }, 'IgnoreCase')
    $t = ($t -replace '\s+', ' ').Trim()
    $nowLocal = $script:Now.ToLocalTime()
    foreach ($f in @('MMM d, h:mm tt', 'MMM d, h tt', 'MMM d h:mm tt', 'MMMM d, h:mm tt', 'MMM d, H:mm', 'h:mm tt', 'h tt', 'H:mm')) {
        $dt = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($t, $f, $script:Inv, [Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$dt)) { continue }
        if ($f -notmatch 'MMM') {
            $dt = $nowLocal.Date.Add($dt.TimeOfDay)
            if ($dt -lt $nowLocal.AddMinutes(-5)) { $dt = $dt.AddDays(1) }
        } else {
            $dt = New-Object DateTime ($nowLocal.Year, $dt.Month, $dt.Day, $dt.Hour, $dt.Minute, 0)
            if ($dt -lt $nowLocal.AddDays(-2)) { $dt = $dt.AddYears(1) }
        }
        return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Local).ToUniversalTime()
    }
    return $null
}

function ConvertFrom-UsageText {
    # Parses Claude Code's /usage text, e.g. "Current week (all models): 26% used · resets Nov 14, 6:59pm (...)".
    param([string]$Text)
    if (-not $Text) { return $null }
    $obs = New-Observation
    $obs.fetched_at = Format-Iso $script:Now
    $obs.via = 'cli'
    $found = $false
    foreach ($raw in ($Text -split "`r?`n")) {
        $m = [regex]::Match($raw.Trim(), '^Current (session|week)(?:\s*\(([^)]+)\))?\s*:\s*(\d+(?:\.\d+)?)\s*%\s*used(?:.*?resets?\s+(.+?))?\s*$', 'IgnoreCase')
        if (-not $m.Success) { continue }
        $isWeek = ($m.Groups[1].Value -ieq 'week')
        $scope = $m.Groups[2].Value.Trim()
        $secs = $(if ($isWeek) { $script:WeekSeconds } else { $script:SessionSeconds })
        $win = New-Window ([double]::Parse($m.Groups[3].Value, $script:Inv)) $secs (ConvertFrom-ResetText $m.Groups[4].Value)
        if ($null -eq $win) { continue }
        if (-not $scope -or $scope -match '^all models?$') {
            if ($isWeek) { $obs.weekly = $win } else { $obs.session = $win }
        } else {
            $id = $(if ($isWeek) { 'seven_day_' } else { 'five_hour_' }) + ($scope.ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_')
            $item = [ordered]@{ id = $id; name = $scope; kind = (Get-WindowKind $secs) }
            foreach ($k in $win.Keys) { $item[$k] = $win[$k] }
            [void]$obs.scoped.Add($item)
        }
        $found = $true
    }
    if (-not $found -or $null -eq $obs.weekly) { return $null }
    return $obs
}

# ---------------------------------------------------------------- HTTP

function Get-HttpError {
    param([int]$Status, $RetryAfter = $null)
    if ($Status -eq 401 -or $Status -eq 403) {
        return @{ ok = $false; error = (New-ErrorInfo "http_$Status" "Claude authentication or access failed (HTTP $Status). Right-click the widget and choose Sign in again (or run ""claude"" in a terminal), then retry." $Status) }
    }
    if ($Status -ge 300 -and $Status -lt 400) {
        return @{ ok = $false; error = (New-ErrorInfo 'redirect_refused' "Claude usage service redirected the request (HTTP $Status); the redirect was not followed." $Status) }
    }
    if ($Status -eq 429) { return @{ ok = $false; retry_after = $RetryAfter; error = (New-ErrorInfo 'http_429' 'Claude usage service is rate limiting requests (HTTP 429). It will retry later.' $Status) } }
    return @{ ok = $false; retry_after = $RetryAfter; error = (New-ErrorInfo "http_$Status" "Claude usage service returned HTTP $Status." $Status) }
}

function Invoke-UsageRequest {
    param($Auth)
    if ($TestResponseFile) {
        $script:HttpCalls++
        try { return @{ ok = $true; json = ((Read-SharedText $TestResponseFile) | ConvertFrom-Json) } }
        catch { return @{ ok = $false; error = (New-ErrorInfo 'bad_response' 'Claude usage service returned an unexpected response.') } }
    }
    if ($TestHttpStatus -ne 0) {
        $script:HttpCalls++
        if ($TestHttpStatus -eq -2) { return @{ ok = $false; offline = $true; error = (New-ErrorInfo 'network' 'Could not reach the Claude usage service from this PC (network, DNS, TLS or timeout).') } }
        if ($TestHttpStatus -lt 0) { return @{ ok = $false; error = (New-ErrorInfo 'network' 'Could not reach the Claude usage service from this PC (network, DNS, TLS or timeout).') } }
        return (Get-HttpError $TestHttpStatus)
    }
    if ([Net.ServicePointManager]::SecurityProtocol -ne [Net.SecurityProtocolType]::SystemDefault) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    $delays = @(0, 1500, 4000)
    $last = $null
    for ($attempt = 0; $attempt -lt $delays.Count; $attempt++) {
        if ($delays[$attempt] -gt 0) { Start-Sleep -Milliseconds $delays[$attempt] }
        $script:HttpCalls++
        $resp = $null; $status = 0; $retryAfter = $null
        try {
            $req = [Net.HttpWebRequest]::Create($script:UsageUri)
            $req.Method = 'GET'
            $req.Timeout = 12000
            $req.ReadWriteTimeout = 12000
            $req.AllowAutoRedirect = $false
            $req.Accept = 'application/json'
            $req.UserAgent = 'claude-usage-widget/1.0 (Windows PowerShell 5.1)'
            $req.Headers.Add('Authorization', 'Bearer ' + $Auth.access)
            $req.Headers.Add('anthropic-beta', 'oauth-2025-04-20')
            try { $resp = $req.GetResponse() }
            catch [Net.WebException] {
                if ($null -ne $_.Exception.Response) { $resp = $_.Exception.Response }
                elseif (@('NameResolutionFailure', 'ConnectFailure', 'ProxyNameResolutionFailure') -contains [string]$_.Exception.Status) {
                    # Offline (no DNS, no route): retrying or running the CLI fallback cannot help, so report it at once (#34).
                    return @{ ok = $false; offline = $true; error = (New-ErrorInfo 'network' 'Could not reach the Claude usage service from this PC (network, DNS, TLS or timeout).') }
                } else { throw }
            }
            $status = [int]$resp.StatusCode
            $retryAfter = Get-RetryAfterSeconds $resp.Headers['Retry-After']
            if ($status -ge 200 -and $status -lt 300) {
                $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                try { $body = $sr.ReadToEnd() } finally { $sr.Dispose() }
                try { $json = $body | ConvertFrom-Json } catch { $json = $null }
                if ($null -eq $json -or -not ($json -is [psobject]) -or ($null -eq (Get-Prop $json 'seven_day') -and $null -eq (Get-Prop $json 'five_hour') -and $null -eq $json.PSObject.Properties['seven_day'])) {
                    return @{ ok = $false; error = (New-ErrorInfo 'bad_response' 'Claude usage service returned an unexpected response.' $status) }
                }
                return @{ ok = $true; json = $json }
            }
        } catch {
            $last = @{ ok = $false; error = (New-ErrorInfo 'network' 'Could not reach the Claude usage service from this PC (network, DNS, TLS or timeout).') }
            continue
        } finally {
            if ($null -ne $resp) { $resp.Close() }
        }
        $last = Get-HttpError $status $retryAfter
        # 429: stop at once and let the backoff decide when to call again; 5xx: retry briefly.
        if ($status -lt 500) { return $last }
    }
    return $last
}

# ---------------------------------------------------------------- output

function Test-ResetPassed {
    param($Window)
    if ($null -eq $Window -or $null -eq $Window.resets_at) { return $false }
    $r = ConvertTo-UtcDate $Window.resets_at
    return ($null -ne $r -and $r -le $script:Now)
}

function New-Output {
    param($Obs, [string]$Source, [bool]$Stale, $AccountVerified, $ErrorInfo)
    $out = [ordered]@{
        schema_version   = 1
        weekly           = $null
        session          = $null
        scoped           = @()
        plan             = $null
        extra_usage      = $null
        fetched_at       = $null
        status           = 'unavailable'
        source           = $Source
        stale            = $Stale
        age_seconds      = $null
        account_verified = $AccountVerified
        limit_reached    = $null
        unclassified     = @()
        reset_passed     = @()
        notice           = $null
        error            = $ErrorInfo
        collected_at     = (Format-Iso $script:Now)
    }
    if ($null -eq $Obs) { return $out }
    $resetPassed = New-Object System.Collections.ArrayList
    $scoped = New-Object System.Collections.ArrayList
    if ($Source -ne 'live') {
        foreach ($k in @('weekly', 'session')) { if (Test-ResetPassed $Obs[$k]) { [void]$resetPassed.Add($k); $Obs[$k] = $null } }
        foreach ($s in $Obs.scoped) { if (Test-ResetPassed $s) { [void]$resetPassed.Add("scoped:$($s.id)") } else { [void]$scoped.Add($s) } }
    } else {
        foreach ($s in $Obs.scoped) { [void]$scoped.Add($s) }
    }
    $fetched = ConvertTo-UtcDate $Obs.fetched_at
    $out.weekly        = $Obs.weekly
    $out.session       = $Obs.session
    $out.scoped        = $scoped.ToArray()
    $out.plan          = $Obs.plan
    $out.extra_usage   = $Obs.extra_usage
    $out.fetched_at    = $Obs.fetched_at
    $out.age_seconds   = [long][Math]::Max(0.0, [Math]::Floor(($script:Now - $fetched).TotalSeconds))
    # Either window at 100% means no more use until it resets (#39); $null only when neither window is known.
    $out.limit_reached = $(if ($null -ne $Obs.weekly -or $null -ne $Obs.session) { (($null -ne $Obs.weekly -and $Obs.weekly.used -ge 100) -or ($null -ne $Obs.session -and $Obs.session.used -ge 100)) } else { $null })
    $out.unclassified  = @($Obs.unclassified)
    $out.reset_passed  = $resetPassed.ToArray()
    $out.status        = $(if ($Stale) { 'stale' } else { 'ok' })
    return $out
}

function Write-Result {
    param($Output, [int]$Code)
    $json = ConvertTo-Json -InputObject $Output -Depth 12 -Compress
    $bytes = $script:Utf8NoBom.GetBytes($json + "`n")
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
    if ($Diagnostics) { [Console]::Error.WriteLine("diag: http_calls=$($script:HttpCalls) cache=$($script:CacheResult) renew=$($script:RenewResult) cli=$($script:CliRead) source=$($Output.source) status=$($Output.status) exit=$Code") }
    exit $Code
}

# ---------------------------------------------------------------- main

try {
    if (-not $CachePath) { $CachePath = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget\usage-cache.json' }
    $claudeHome = Resolve-ClaudeHome
    if (-not $claudeHome.exists) {
        $msg = $(if ($claudeHome.configured) { 'CLAUDE_CONFIG_DIR is set, but that folder does not exist on this PC.' } else { 'The Claude Code folder (%USERPROFILE%\.claude) was not found on this PC. Install Claude Code and sign in, then retry.' })
        $auth = @{ ok = $false; error = (New-ErrorInfo 'config_missing' $msg) }
    } else {
        $auth = Read-AuthContext $claudeHome
    }

    $cache = Read-Cache $CachePath
    $salt = $(if ($null -ne $cache) { $cache.salt } else { New-SaltHex })
    $tag = $(if ($auth.ok -and $auth.account) { Get-AccountTag $auth.account $salt } else { $null })
    $cacheCompatible = ($null -ne $cache -and $null -ne $tag -and $cache.account_tag -ceq $tag)
    if ($null -ne $cache -and -not $cacheCompatible) { $script:CacheResult = 'incompatible' }

    if (-not $Force -and $cacheCompatible) {
        $obs = $cache.observation
        $age = ($script:Now - (ConvertTo-UtcDate $obs.fetched_at)).TotalSeconds
        $crossed = (Test-ResetPassed $obs.weekly) -or (Test-ResetPassed $obs.session)
        if ($age -ge -5 -and $age -lt $script:CacheTtlSeconds -and -not $crossed) {
            $script:CacheResult = 'hit'
            Write-Result (New-Output $obs 'cache' $false $true $null) 0
        }
        $script:CacheResult = 'expired'
    } elseif ($Force) { $script:CacheResult = 'bypassed' }

    $statePath = Join-Path (Split-Path -Parent $CachePath) 'collector-state.json'
    $state = Read-State $statePath
    $stateBefore = ConvertTo-Json -InputObject ([pscustomobject]$state) -Compress

    # Expired sign-in: let Claude Code renew it, then read the renewed token.
    if ($auth.ok -and $auth.expired -and -not $NoRenew) {
        if (Invoke-CliRenewal $claudeHome $state) { $a2 = Read-AuthContext $claudeHome; if ($a2.ok) { $auth = $a2 } }
    }

    $err = $null
    $offline = $false
    if ($auth.ok -and -not $auth.expired) {
        if (-not $Force -and [double]$state.backoff_until -gt (Get-UnixNow)) {
            $script:CacheResult += '+backoff'
            $why = $(if ([string]$state.backoff_code -match '^http_5\d\d$') { 'Claude usage service is having trouble' } else { 'Claude usage service asked to slow down' })
            $err = New-ErrorInfo ([string]$state.backoff_code) ('{0}; showing the last reading. Next try at {1} (or right-click > Refresh now).' -f $why, (Format-UnixLocal ([double]$state.backoff_until)))
        } else {
            $r = Invoke-UsageRequest $auth
            if (-not $r.ok -and $r.error.http_status -eq 401 -and -not $NoRenew) {
                # Token revoked or expired early: one renewal through the CLI, then one retry.
                if (Invoke-CliRenewal $claudeHome $state) { $a2 = Read-AuthContext $claudeHome; if ($a2.ok -and -not $a2.expired) { $auth = $a2; $r = Invoke-UsageRequest $auth } }
            }
            $auth.access = $null
            if ($r.ok) {
                if ([int]$state.backoff_count -gt 0 -or [double]$state.backoff_until -gt 0) { $state.backoff_count = 0; $state.backoff_until = 0.0; $state.backoff_code = '' }
                if ((ConvertTo-Json -InputObject ([pscustomobject]$state) -Compress) -ne $stateBefore) { Write-State $statePath $state }
                $obs = ConvertFrom-LiveUsage $r.json
                $obs.plan = $auth.plan
                if ($tag) { try { Write-Cache $CachePath $salt $tag $obs } catch { } }
                Write-Result (New-Output $obs 'live' $false ($null -ne $tag) $null) 0
            }
            $err = $r.error
            $offline = [bool]$r.offline
            $hs = $err.http_status
            if ($null -ne $hs -and ([int]$hs -eq 429 -or [int]$hs -ge 500)) {
                Set-Backoff $state $err.code $r.retry_after
                $err.message = '{0} Showing the last reading; next try at {1}.' -f $err.message, (Format-UnixLocal ([double]$state.backoff_until))
            }
        }
    } else {
        $err = $auth.error
        $auth.access = $null
        if ($null -ne $err -and $err.code -eq 'auth_expired' -and -not $NoRenew) {
            $why = switch -Wildcard ($script:RenewResult) {
                'no_cli'    { ' Automatic renewal needs the Claude Code CLI (claude.exe), which was not found.' }
                'throttled' { ' Automatic renewal will try again within 10 minutes.' }
                default     { ' Automatic renewal through Claude Code did not succeed; it will retry within 10 minutes.' }
            }
            $err.message += $why
        }
    }

    # Usage API unavailable (rate limited, server error, network) or sign-in not renewable: read Claude Code's
    # own /usage text instead. Reuses a CLI reading up to 3 minutes old; runs the CLI at most every 3 minutes.
    # A backoff error carries only its code (e.g. "http_503"), so 5xx is matched by code as well as by status.
    # Offline (DNS or connect failure): the CLI cannot reach the service either, so it is not run (#34).
    $apiDown = (-not $offline) -and ($null -ne $err) -and (@('http_429', 'network', 'bad_response') -contains $err.code -or [string]$err.code -match '^http_5\d\d$' -or ($null -ne $err.http_status -and [int]$err.http_status -ge 500))
    if (-not $NoRenew -and $auth.ok -and ($apiDown -or $null -ne $script:CliOutput)) {
        $notice = $(if ($err.code -eq 'http_429') { 'The usage service is rate limiting, so this reading comes from Claude Code''s /usage.' } else { 'The usage service is unavailable, so this reading comes from Claude Code''s /usage.' })
        $cliObs = $null
        if ($cacheCompatible -and $cache.observation.via -eq 'cli' -and ($script:Now - (ConvertTo-UtcDate $cache.observation.fetched_at)).TotalSeconds -lt 180) {
            $cliObs = $cache.observation
            $script:CliRead = 'reused'
        } else {
            $text = $script:CliOutput
            if ($null -eq $text -and ((Get-UnixNow) - [double]$state.cli_read_at) -ge 180) {
                $state.cli_read_at = Get-UnixNow
                $text = (Invoke-ClaudeCli).output
            }
            $cliObs = ConvertFrom-UsageText $text
            $script:CliRead = $(if ($null -ne $cliObs) { 'parsed' } elseif ($null -ne $text) { 'unparsed' } else { 'throttled' })
            if ($null -ne $cliObs) {
                $cliObs.plan = $auth.plan
                if ($cacheCompatible) { $cliObs.extra_usage = $cache.observation.extra_usage }   # /usage text has no extra-usage figures
                if ($tag) { try { Write-Cache $CachePath $salt $tag $cliObs } catch { } }
            }
        }
        if ($null -ne $cliObs) {
            if ((ConvertTo-Json -InputObject ([pscustomobject]$state) -Compress) -ne $stateBefore) { Write-State $statePath $state }
            $out = New-Output $cliObs 'cli' $false ($null -ne $tag) $null
            $out.notice = $notice
            Write-Result $out 0
        }
    }
    if ((ConvertTo-Json -InputObject ([pscustomobject]$state) -Compress) -ne $stateBefore) { Write-State $statePath $state }

    # Live failed: the last verified reading for this same account, marked stale.
    if ($cacheCompatible) { Write-Result (New-Output $cache.observation 'cache' $true $true $err) 2 }
    Write-Result (New-Output $null 'none' $true $false $err) 3
} catch {
    Write-Result (New-Output $null 'none' $true $false (New-ErrorInfo 'internal' 'The Claude usage collector hit an internal error.')) 4
}
