<#
.SYNOPSIS
    Local, read-only Codex usage collector for the Codex Usage Widget (Windows PowerShell 5.1).

.DESCRIPTION
    Reads Codex sign-in data from <CODEX_HOME or %USERPROFILE%\.codex>\auth.json on THIS PC, calls
    GET https://chatgpt.com/backend-api/wham/usage, and prints exactly ONE JSON document to stdout.
    It never prints tokens, account identifiers, e-mail or raw auth/session content, never touches
    credentials itself and never writes outside %LOCALAPPDATA%\CodexUsageWidget (or -CachePath).

    Official CLI: the Codex app ships the Codex CLI (codex.exe). When the direct call fails on sign-in
    (401/403, missing or incomplete auth.json) the collector asks that CLI for the limits through its
    app-server (JSON-RPC "account/rateLimits/read"; no AI request). The CLI renews its own sign-in as
    needed, so the widget does not go stale when the token ages out. Every 30 minutes it also asks the
    CLI once (in the same way) to learn how many free limit resets are available. -NoCli turns this off.

    Output (schema_version 1):
      weekly / session         { used, left, window_seconds, resets_at } or null   (used = PERCENT USED)
      scoped                   [ { id, name, kind, used, left, window_seconds, resets_at } ]
      plan                     plan_type string or null
      credits                  { balance, has_credits, unlimited } or null (balance may be null)
      fetched_at               ISO-8601 UTC time of the OBSERVATION (not of this run)
      status                   ok | stale | unavailable
      source                   live | cache | session_log | none
      stale, age_seconds, account_verified, limit_reached, unclassified, reset_passed, error, collected_at

    Exit codes: 0 = fresh data (live or fresh cache), 2 = stale fallback payload,
                3 = no usable observation (structured unavailable payload), 4 = internal error (JSON still printed).
#>
[CmdletBinding()]
param(
    # Bypass the 60-second fresh-cache shortcut.
    [switch]$Force,
    # Write one sanitized diagnostics line (http_calls, cache result, source) to STDERR.
    [switch]$Diagnostics,
    # Never run the official Codex CLI.
    [switch]$NoCli,
    # Codex CLI to use (default: the Codex app's bundled codex.exe, then PATH). Tests pass a fake.
    [string]$CodexCliPath,
    # Override the cache file (tests). Default: %LOCALAPPDATA%\CodexUsageWidget\usage-cache.json
    [string]$CachePath,
    # TEST ONLY (simulated): use this JSON file as the HTTP 200 body instead of calling the network.
    [string]$TestResponseFile,
    # TEST ONLY (simulated): pretend the HTTP request failed with this status (0 = disabled, -1 = network error).
    [int]$TestHttpStatus = 0,
    # TEST ONLY: override "now" as Unix seconds.
    [double]$TestNowUnix = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:UsageUri        = 'https://chatgpt.com/backend-api/wham/usage'
$script:WeekSeconds     = 604800
$script:SessionSeconds  = 18000
$script:CacheTtlSeconds = 60
$script:HttpCalls       = 0
$script:Warnings       = New-Object System.Collections.ArrayList   # one line each on stderr as "warn: ..."; the widget logs them
$script:CacheResult     = 'none'
$script:CliResult       = 'none'
$script:CliTimeoutMs    = 30000
$script:CliRetrySeconds = 600
$script:CliInfoSeconds  = 1800
$script:Inv           = [Globalization.CultureInfo]::InvariantCulture
$script:Utf8NoBom       = New-Object System.Text.UTF8Encoding($false)

if ($TestNowUnix -gt 0) {
    $script:Now = [DateTimeOffset]::FromUnixTimeMilliseconds([long]($TestNowUnix * 1000)).UtcDateTime
} else {
    $script:Now = [DateTime]::UtcNow
}

# ---------------------------------------------------------------- helpers

function Get-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
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
    # Accepts Unix seconds/milliseconds (number or numeric string), ISO strings, or DateTime objects.
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
        if ($n -gt 100000000000) { $n = $n / 1000.0 }   # milliseconds
        try { return [DateTimeOffset]::FromUnixTimeMilliseconds([long][Math]::Round($n * 1000)).UtcDateTime } catch { return $null }
    }
    if ($Value -is [string] -and $Value.Trim().Length -gt 0) {
        $dt = [DateTime]::MinValue
        $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        if ([DateTime]::TryParse($Value, $script:Inv, $styles, [ref]$dt)) { return [DateTime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
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
    # Returns a normalized window or $null when used% or the duration is missing/invalid.
    param($Used, $WindowSeconds, $ResetsAt)
    $u = ConvertTo-Number $Used
    $s = ConvertTo-Number $WindowSeconds
    if ($null -eq $u -or $null -eq $s -or $s -le 0) { return $null }
    $left = [Math]::Min(100.0, [Math]::Max(0.0, 100.0 - $u))
    $r = ConvertTo-UtcDate $ResetsAt
    return [ordered]@{
        used           = $u
        left           = $left
        window_seconds = [long][Math]::Round($s)
        resets_at      = (Format-Iso $r)
    }
}

function New-Observation {
    return [ordered]@{
        weekly        = $null
        session       = $null
        scoped        = (New-Object System.Collections.ArrayList)
        unclassified  = (New-Object System.Collections.ArrayList)
        plan          = $null
        credits       = $null
        limit_reached = $null
        fetched_at    = $null
        reset_credits = $null     # free limit resets available (known only through the official CLI)
        via           = $null     # 'cli' when the reading came from the official Codex CLI
    }
}

function Add-AccountWindow {
    # Map a window by DURATION (never by primary/secondary position).
    param($Obs, $Window, [string]$Slot)
    if ($null -eq $Window) { return }
    $kind = Get-WindowKind $Window.window_seconds
    if ($kind -eq 'weekly' -and $null -eq $Obs.weekly) { $Obs.weekly = $Window; return }
    if ($kind -eq 'session' -and $null -eq $Obs.session) { $Obs.session = $Window; return }
    $u = [ordered]@{ slot = $Slot; kind = $kind }
    foreach ($k in $Window.Keys) { $u[$k] = $Window[$k] }
    [void]$Obs.unclassified.Add($u)
}

function Get-FirstText {
    param($Object, [string[]]$Names)
    foreach ($n in $Names) {
        $v = Get-Prop $Object $n
        if ($null -ne $v -and ($v -is [string] -or ($v -is [ValueType] -and $v -isnot [bool])) -and "$v".Trim().Length -gt 0) { return "$v".Trim() }
    }
    return $null
}

function Add-ScopedLimit {
    param($Obs, $Entry, [string]$DefaultId, [string]$DefaultName)
    if ($null -eq $Entry) { return }
    $id   = Get-FirstText $Entry @('metered_feature', 'limit_id', 'id', 'feature', 'limit_name', 'name')
    $name = Get-FirstText $Entry @('limit_name', 'display_name', 'name', 'metered_feature', 'limit_id', 'id')
    if (-not $id) { $id = $DefaultId }
    if (-not $name) { $name = $(if ($DefaultName) { $DefaultName } else { $id }) }
    $rl = Get-Prop $Entry 'rate_limit'
    if ($null -eq $rl) { $rl = $Entry }
    foreach ($slot in @('primary_window', 'secondary_window')) {
        $w = Get-Prop $rl $slot
        if ($null -eq $w) { continue }
        $secs = ConvertTo-Number (Get-Prop $w 'limit_window_seconds')
        $reset = Get-Prop $w 'reset_at'
        if ($null -eq $reset) {
            $after = ConvertTo-Number (Get-Prop $w 'reset_after_seconds')
            if ($null -ne $after) { $reset = $script:Now.AddSeconds($after) }
        }
        $win = New-Window (Get-Prop $w 'used_percent') $secs $reset
        if ($null -eq $win) { continue }
        $item = [ordered]@{ id = $id; name = $name; kind = (Get-WindowKind $win.window_seconds) }
        foreach ($k in $win.Keys) { $item[$k] = $win[$k] }
        [void]$Obs.scoped.Add($item)
    }
}

function Set-Credits {
    param($Obs, $Credits)
    if ($null -eq $Credits) { return }
    $hc = Get-Prop $Credits 'has_credits'
    $un = Get-Prop $Credits 'unlimited'
    $Obs.credits = [ordered]@{
        balance     = (ConvertTo-Number (Get-Prop $Credits 'balance'))
        has_credits = $(if ($hc -is [bool]) { $hc } else { $null })
        unlimited   = $(if ($un -is [bool]) { $un } else { $null })
    }
}

function ConvertFrom-LiveUsage {
    param($Json)
    $obs = New-Observation
    $obs.fetched_at = Format-Iso $script:Now
    $rl = Get-Prop $Json 'rate_limit'
    foreach ($slot in @('primary_window', 'secondary_window')) {
        $w = Get-Prop $rl $slot
        if ($null -eq $w) { continue }
        $reset = Get-Prop $w 'reset_at'
        if ($null -eq $reset) {
            $after = ConvertTo-Number (Get-Prop $w 'reset_after_seconds')
            if ($null -ne $after) { $reset = $script:Now.AddSeconds($after) }
        }
        $win = New-Window (Get-Prop $w 'used_percent') (Get-Prop $w 'limit_window_seconds') $reset
        Add-AccountWindow $obs $win $slot
    }
    $lr = Get-Prop $rl 'limit_reached'
    if ($lr -is [bool]) { $obs.limit_reached = $lr }
    $extra = Get-Prop $Json 'additional_rate_limits'
    if ($null -ne $extra) { foreach ($e in @($extra)) { Add-ScopedLimit $obs $e 'additional' $null } }
    $cr = Get-Prop $Json 'code_review_rate_limit'
    if ($null -ne $cr) { Add-ScopedLimit $obs ([pscustomobject]@{ id = 'code_review'; name = 'Code review'; rate_limit = $cr }) 'code_review' 'Code review' }
    $plan = Get-Prop $Json 'plan_type'
    if ($plan -is [string] -and $plan.Trim().Length -gt 0) { $obs.plan = $plan.Trim() }
    Set-Credits $obs (Get-Prop $Json 'credits')
    return $obs
}

function ConvertFrom-RolloutRateLimits {
    param($RateLimits, [DateTime]$EventTime)
    $obs = New-Observation
    $obs.fetched_at = Format-Iso $EventTime
    foreach ($slot in @('primary', 'secondary')) {
        $w = Get-Prop $RateLimits $slot
        if ($null -eq $w) { continue }
        $mins = ConvertTo-Number (Get-Prop $w 'window_minutes')
        $secs = $(if ($null -ne $mins) { $mins * 60 } else { $null })
        $reset = Get-Prop $w 'resets_at'
        if ($null -eq $reset) {
            $inSec = ConvertTo-Number (Get-Prop $w 'resets_in_seconds')
            if ($null -ne $inSec) { $reset = $EventTime.AddSeconds($inSec) }
        }
        Add-AccountWindow $obs (New-Window (Get-Prop $w 'used_percent') $secs $reset) $slot
    }
    $plan = Get-Prop $RateLimits 'plan_type'
    if ($plan -is [string] -and $plan.Trim().Length -gt 0) { $obs.plan = $plan.Trim() }
    Set-Credits $obs (Get-Prop $RateLimits 'credits')
    return $obs
}

function Import-Observation {
    # Re-validate an observation read back from the cache (never trust stored numbers blindly).
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
    foreach ($u in @(Get-Prop $Stored 'unclassified')) {
        if ($null -eq $u) { continue }
        $win = New-Window (Get-Prop $u 'used') (Get-Prop $u 'window_seconds') (Get-Prop $u 'resets_at')
        if ($null -eq $win) { continue }
        $item = [ordered]@{ slot = "$(Get-Prop $u 'slot')"; kind = (Get-WindowKind $win.window_seconds) }
        foreach ($k in $win.Keys) { $item[$k] = $win[$k] }
        [void]$obs.unclassified.Add($item)
    }
    $plan = Get-Prop $Stored 'plan'
    if ($plan -is [string] -and $plan.Length -gt 0) { $obs.plan = $plan }
    Set-Credits $obs (Get-Prop $Stored 'credits')
    $lr = Get-Prop $Stored 'limit_reached'
    if ($lr -is [bool]) { $obs.limit_reached = $lr }
    $rc = ConvertTo-Number (Get-Prop $Stored 'reset_credits')
    if ($null -ne $rc -and $rc -ge 0) { $obs.reset_credits = [int]$rc }
    if ((Get-Prop $Stored 'via') -eq 'cli') { $obs.via = 'cli' }
    return $obs
}

function ConvertFrom-AppServerLimits {
    # Result of the CLI app-server's account/rateLimits/read (camelCase; minutes; Unix seconds).
    param($Result)
    if ($null -eq $Result) { return $null }
    $rl = Get-Prop $Result 'rateLimits'
    if ($null -eq $rl) { return $null }
    $obs = New-Observation
    $obs.fetched_at = Format-Iso $script:Now
    $obs.via = 'cli'
    foreach ($slot in @('primary', 'secondary')) {
        $w = Get-Prop $rl $slot
        if ($null -eq $w) { continue }
        $mins = ConvertTo-Number (Get-Prop $w 'windowDurationMins')
        Add-AccountWindow $obs (New-Window (Get-Prop $w 'usedPercent') $(if ($null -ne $mins) { $mins * 60 } else { $null }) (Get-Prop $w 'resetsAt')) $slot
    }
    $byId = Get-Prop $Result 'rateLimitsByLimitId'
    if ($null -ne $byId) {
        foreach ($p in $byId.PSObject.Properties) {
            if ($p.Name -eq (Get-Prop $rl 'limitId')) { continue }
            $v = $p.Value
            foreach ($slot in @('primary', 'secondary')) {
                $w = Get-Prop $v $slot
                if ($null -eq $w) { continue }
                $mins = ConvertTo-Number (Get-Prop $w 'windowDurationMins')
                $win = New-Window (Get-Prop $w 'usedPercent') $(if ($null -ne $mins) { $mins * 60 } else { $null }) (Get-Prop $w 'resetsAt')
                if ($null -eq $win) { continue }
                $name = Get-FirstText $v @('limitName', 'limitId')
                $item = [ordered]@{ id = $p.Name; name = $(if ($name) { $name } else { $p.Name }); kind = (Get-WindowKind $win.window_seconds) }
                foreach ($k in $win.Keys) { $item[$k] = $win[$k] }
                [void]$obs.scoped.Add($item)
            }
        }
    }
    $plan = Get-Prop $rl 'planType'
    if ($plan -is [string] -and $plan.Trim().Length -gt 0) { $obs.plan = $plan.Trim() }
    $cr = Get-Prop $rl 'credits'
    if ($null -ne $cr) { Set-Credits $obs ([pscustomobject]@{ balance = (Get-Prop $cr 'balance'); has_credits = (Get-Prop $cr 'hasCredits'); unlimited = (Get-Prop $cr 'unlimited') }) }
    $rt = Get-Prop $rl 'rateLimitReachedType'
    if ($null -ne $rt) { $obs.limit_reached = $true }
    $rc = ConvertTo-Number (Get-Prop (Get-Prop $Result 'rateLimitResetCredits') 'availableCount')
    if ($null -ne $rc -and $rc -ge 0) { $obs.reset_credits = [int]$rc }
    return $obs
}

function New-ErrorInfo {
    param([string]$Code, [string]$Message, $HttpStatus = $null)
    return [ordered]@{ code = $Code; http_status = $HttpStatus; message = $Message }
}

# ---------------------------------------------------------------- local files

function Read-SharedText {
    param([string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
}

function Resolve-CodexHome {
    $configured = $env:CODEX_HOME
    if ($configured -and $configured.Trim().Length -gt 0) {
        $p = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($configured.Trim()))
        return [ordered]@{ path = $p; configured = $true; exists = (Test-Path -LiteralPath $p -PathType Container) }
    }
    $p = Join-Path $env:USERPROFILE '.codex'
    return [ordered]@{ path = $p; configured = $false; exists = (Test-Path -LiteralPath $p -PathType Container) }
}

function Read-AuthContext {
    param([string]$CodexHome)
    $signIn = 'Open Codex on this PC and sign in with ChatGPT, then retry.'
    $path = Join-Path $CodexHome 'auth.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @{ ok = $false; error = (New-ErrorInfo 'auth_missing' "Codex sign-in data (auth.json) was not found in the Codex folder on this PC. Codex may be using the OS credential store, or is signed out. $signIn") }
    }
    try { $j = (Read-SharedText $path) | ConvertFrom-Json }
    catch { return @{ ok = $false; error = (New-ErrorInfo 'auth_unreadable' "Codex sign-in data could not be read. $signIn") } }
    $mode = Get-Prop $j 'auth_mode'
    if ($mode -ne 'chatgpt') {
        $safeMode = $(if ($mode -is [string] -and $mode -match '^[A-Za-z0-9_-]{1,32}$') { $mode } else { 'unknown' })
        return @{ ok = $false; error = (New-ErrorInfo 'auth_mode_unsupported' "Codex is not signed in with a ChatGPT account (auth mode: $safeMode). Usage limits need ChatGPT sign-in. $signIn") }
    }
    $tokens = Get-Prop $j 'tokens'
    $access = Get-Prop $tokens 'access_token'
    $acct   = Get-Prop $tokens 'account_id'
    if (-not ($access -is [string]) -or $access.Length -lt 8 -or -not ($acct -is [string]) -or $acct.Length -lt 1) {
        return @{ ok = $false; error = (New-ErrorInfo 'auth_malformed' "Codex sign-in data is incomplete. $signIn") }
    }
    return @{ ok = $true; access = $access; account = $acct; mode = $mode }
}

function Get-AccountTag {
    # Keyed, truncated hash so the cache can detect an account change without storing the identifier.
    param([string]$Account, [string]$Mode, [string]$SaltHex)
    $key = New-Object byte[] ($SaltHex.Length / 2)
    for ($i = 0; $i -lt $key.Length; $i++) { $key[$i] = [Convert]::ToByte($SaltHex.Substring($i * 2, 2), 16) }
    $h = [System.Security.Cryptography.HMACSHA256]::new($key)
    try { $bytes = $h.ComputeHash($script:Utf8NoBom.GetBytes("$Mode|$Account")) } finally { $h.Dispose() }
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

function Add-Warning {
    # A failure that doesn't stop this run (the reading is still good) but should leave a trace in the widget log.
    param([string]$Text)
    [void]$script:Warnings.Add(($Text -replace '[\r\n]+', ' '))
}

function Write-FlushedText {
    # Flushed to disk before the swap, so a power cut can't leave an empty file behind.
    param([string]$Path, [string]$Text)
    $bytes = $script:Utf8NoBom.GetBytes($Text)
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}

function Write-Cache {
    param([string]$Path, [string]$Salt, [string]$Tag, $Obs)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $doc = [ordered]@{ schema_version = 1; salt = $Salt; account_tag = $Tag; observation = $Obs }
    $json = ConvertTo-Json -InputObject $doc -Depth 12
    $tmp = "$Path.$PID.tmp"
    Write-FlushedText $tmp $json
    for ($i = 0; $i -lt 4; $i++) {
        try {
            # [NullString]::Value, not $null: PowerShell would pass "" and File.Replace would always throw.
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch { Start-Sleep -Milliseconds (60 * ($i + 1)) }
    }
    try { [IO.File]::Copy($tmp, $Path, $true) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------- collector state (HTTP backoff)

function Get-UnixNow { return [double]([DateTimeOffset][DateTime]::SpecifyKind($script:Now, [DateTimeKind]::Utc)).ToUnixTimeSeconds() }

function Read-State {
    # Small non-secret state file: no tokens, no identifiers.
    param([string]$Path)
    $s = @{ backoff_until = 0.0; backoff_count = 0; backoff_code = ''; cli_at = 0.0; cli_fail_at = 0.0; reset_credits = -1; cli_path = '' }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $j = (Read-SharedText $Path) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { $v = Get-Prop $j $k; if ($null -ne $v) { $s[$k] = $v } }
        }
    } catch { Add-Warning "state file unreadable: $($_.Exception.Message)" }
    return $s
}

function Write-State {
    param([string]$Path, $State)
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $tmp = "$Path.$PID.tmp"
        Write-FlushedText $tmp (ConvertTo-Json -InputObject ([pscustomobject]$State) -Compress)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    } catch { Add-Warning "state file not saved: $($_.Exception.Message)"; Remove-Item -LiteralPath "$Path.$PID.tmp" -Force -ErrorAction SilentlyContinue }
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

# ---------------------------------------------------------------- official Codex CLI (app-server)

function Find-CodexCli {
    param($State)
    if ($CodexCliPath) { if (Test-Path -LiteralPath $CodexCliPath -PathType Leaf) { return $CodexCliPath }; return $null }
    $known = [string]$State.cli_path
    if ($known -and (Test-Path -LiteralPath $known -PathType Leaf)) { return $known }
    $found = $null
    try {
        $pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop | Sort-Object Version -Descending | Select-Object -First 1
        if ($null -ne $pkg) { $c = Join-Path $pkg.InstallLocation 'app\resources\codex.exe'; if (Test-Path -LiteralPath $c -PathType Leaf) { $found = $c } }
    } catch { }
    if (-not $found) {
        $cmd = Get-Command 'codex.exe', 'codex.cmd' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $cmd) { $found = $cmd.Source }
    }
    if ($found) { $State.cli_path = $found }
    return $found
}

function Invoke-TreeKill {
    # Ends a process and every child it started (codex.cmd -> node -> codex.exe), so a hung CLI never leaves orphans (#35).
    param($Process)
    try {
        $tk = [IO.Path]::Combine($env:SystemRoot, 'System32', 'taskkill.exe')
        if (Test-Path -LiteralPath $tk) { & cmd.exe /d /c ('"{0}" /T /F /PID {1} >nul 2>nul' -f $tk, $Process.Id) }
    } catch { }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { }
}

function Invoke-CodexAppServer {
    # Asks the official Codex CLI for the rate limits over its stdio JSON-RPC app-server. The CLI uses and
    # renews its own sign-in; this process never sees a token. Returns the "result" object or $null.
    param($State)
    $exe = Find-CodexCli $State
    if (-not $exe) { $script:CliResult = 'no_cli'; return $null }
    $p = $null
    try {
        try { [Console]::InputEncoding = New-Object Text.UTF8Encoding($false) } catch { }   # no BOM on the child's stdin
        $psi = New-Object Diagnostics.ProcessStartInfo $exe, 'app-server'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $env:USERPROFILE                     # never hold the install folder (uninstall must delete it)
        $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $script:Utf8NoBom
        $p = [Diagnostics.Process]::Start($psi)
        $null = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.NewLine = "`n"
        $deadline = [DateTime]::UtcNow.AddMilliseconds($script:CliTimeoutMs)
        $send = { param($line) $p.StandardInput.WriteLine($line); $p.StandardInput.Flush() }
        $read = {
            param([int]$Id)
            while ([DateTime]::UtcNow -lt $deadline) {
                $t = $p.StandardOutput.ReadLineAsync()
                $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
                if ($left -le 0 -or -not $t.Wait($left)) { return $null }
                $l = $t.Result
                if ($null -eq $l) { return $null }
                if ($l -notmatch ('"id"\s*:\s*' + $Id + '\s*[,}]')) { continue }
                try { return ($l | ConvertFrom-Json) } catch { return $null }
            }
            return $null
        }
        & $send '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"usage_widget","title":"Usage widget","version":"1.0.0"}}}'
        $init = & $read 1
        if ($null -eq $init -or $null -eq (Get-Prop $init 'result')) { $script:CliResult = 'init_failed'; return $null }
        & $send '{"method":"initialized"}'
        & $send '{"id":2,"method":"account/rateLimits/read"}'
        $resp = & $read 2
        if ($null -eq $resp -or $null -eq (Get-Prop $resp 'result')) { $script:CliResult = $(if ($null -ne $resp) { 'error' } else { 'timeout' }); return $null }
        $script:CliResult = 'ok'
        return (Get-Prop $resp 'result')
    } catch {
        $script:CliResult = 'start_failed'
        return $null
    } finally {
        if ($null -ne $p) {
            try { $p.StandardInput.Close() } catch { }
            try { if (-not $p.WaitForExit(3000)) { Invoke-TreeKill $p } } catch { }
            $p.Dispose()
        }
    }
}

function Get-CliObservation {
    # Throttled: after a failed attempt, waits CliRetrySeconds before asking the CLI again.
    param($State, [bool]$Throttle)
    if ($NoCli) { $script:CliResult = 'disabled'; return $null }
    $nowU = Get-UnixNow
    if ($Throttle -and ($nowU - [double]$State.cli_fail_at) -lt $script:CliRetrySeconds) { $script:CliResult = 'throttled'; return $null }
    $res = Invoke-CodexAppServer $State
    $State.cli_at = $nowU
    $obs = ConvertFrom-AppServerLimits $res
    if ($null -eq $obs) { $State.cli_fail_at = $nowU; if ($script:CliResult -eq 'ok') { $script:CliResult = 'bad_result' }; return $null }
    $State.cli_fail_at = 0.0
    if ($null -ne $obs.reset_credits) { $State.reset_credits = $obs.reset_credits }
    $acct = Get-Prop $res 'accountId'
    return @{ obs = $obs; account = $(if ($acct -is [string] -and $acct.Length -gt 0) { $acct } else { $null }) }
}

function Read-FileTail {
    param([string]$Path, [long]$MaxBytes)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $len = $fs.Length
        $start = [Math]::Max([long]0, $len - $MaxBytes)
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ($len - $start)
        $read = 0
        while ($read -lt $buf.Length) {
            $n = $fs.Read($buf, $read, $buf.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $text = [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        $lines = $text -split "`n"
        if ($start -gt 0) {
            # drop the partial first line (guard against PowerShell's reverse range 1..0)
            if ($lines.Count -le 1) { $lines = @() } else { $lines = $lines[1..($lines.Count - 1)] }
        }
        return @{ lines = $lines; whole = ($start -eq 0) }
    } finally { $fs.Dispose() }
}

function Get-RolloutOwner {
    # Returns $true/$false when ownership can be established, $null when it cannot. Never outputs the id.
    param([string]$Path, $Account)
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)
            try { $first = $sr.ReadLine() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
        if (-not $first) { return $null }
        $meta = $first | ConvertFrom-Json
        if ((Get-Prop $meta 'type') -ne 'session_meta') { return $null }
        $p = Get-Prop $meta 'payload'
        $owner = Get-FirstText $p @('creator_account_id', 'account_id')
        if (-not $owner -or -not $Account) { return $null }
        return ($owner -ceq $Account)
    } catch { return $null }
}

function Find-RolloutObservation {
    # Newest valid account-wide rate-limit event (by EVENT timestamp) from the most recently written rollouts.
    param([string]$CodexHome, $Account)
    $dir = Join-Path $CodexHome 'sessions'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Filter 'rollout-*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 12)
    $best = $null
    foreach ($f in $files) {
        if ($null -ne $best -and $f.LastWriteTimeUtc.AddSeconds(5) -lt $best.time) { break }
        $owned = Get-RolloutOwner $f.FullName $Account
        if ($owned -eq $false) { continue }   # belongs to another account
        foreach ($limit in @(1MB, 8MB)) {
            $tail = Read-FileTail $f.FullName $limit
            $found = $false
            for ($i = $tail.lines.Count - 1; $i -ge 0; $i--) {
                $line = $tail.lines[$i]
                if (-not $line.Contains('"rate_limits"')) { continue }
                try { $ev = $line | ConvertFrom-Json } catch { continue }   # malformed or truncated record
                $payload = Get-Prop $ev 'payload'
                $rl = Get-Prop $payload 'rate_limits'
                if ($null -eq $rl) { continue }
                $lid = Get-Prop $rl 'limit_id'
                if ($lid -and $lid -ne 'codex') { continue }   # model/feature-scoped event, not account-wide
                $t = ConvertTo-UtcDate (Get-Prop $ev 'timestamp')
                if ($null -eq $t -or $t -gt $script:Now.AddMinutes(5)) { continue }
                $obs = ConvertFrom-RolloutRateLimits $rl $t
                if ($null -eq $obs.weekly -and $null -eq $obs.session) { continue }
                $found = $true
                if ($null -eq $best -or $t -gt $best.time) { $best = @{ time = $t; obs = $obs; verified = ($owned -eq $true) } }
            }
            if ($found -or $tail.whole) { break }
        }
    }
    return $best
}

# ---------------------------------------------------------------- HTTP

function Invoke-UsageRequest {
    param($Auth)
    if ($TestResponseFile) {
        $script:HttpCalls++
        try { return @{ ok = $true; json = ((Read-SharedText $TestResponseFile) | ConvertFrom-Json) } }
        catch { return @{ ok = $false; error = (New-ErrorInfo 'bad_response' 'Codex usage service returned an unexpected response.') } }
    }
    if ($TestHttpStatus -ne 0) {
        $script:HttpCalls++
        if ($TestHttpStatus -lt 0) { return @{ ok = $false; error = (New-ErrorInfo 'network' 'Could not reach the Codex usage service from this PC (network, DNS, TLS or timeout).') } }
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
        $resp = $null
        $status = 0
        $retryAfter = $null
        try {
            $req = [Net.HttpWebRequest]::Create($script:UsageUri)
            $req.Method = 'GET'
            $req.Timeout = 12000
            $req.ReadWriteTimeout = 12000
            $req.AllowAutoRedirect = $false          # never forward Authorization to another origin
            $req.Accept = 'application/json'
            $req.UserAgent = 'codex-usage-widget/1.0 (Windows PowerShell 5.1)'
            $req.Headers.Add('Authorization', 'Bearer ' + $Auth.access)
            $req.Headers.Add('chatgpt-account-id', $Auth.account)
            try { $resp = $req.GetResponse() }
            catch [Net.WebException] {
                if ($null -ne $_.Exception.Response) { $resp = $_.Exception.Response }
                else { throw }
            }
            $status = [int]$resp.StatusCode
            $retryAfter = Get-RetryAfterSeconds $resp.Headers['Retry-After']
            if ($status -ge 200 -and $status -lt 300) {
                $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                try { $body = $sr.ReadToEnd() } finally { $sr.Dispose() }
                try { $json = $body | ConvertFrom-Json } catch { $json = $null }
                if ($null -eq $json -or ($null -eq (Get-Prop $json 'rate_limit') -and $null -eq (Get-Prop $json 'plan_type'))) {
                    return @{ ok = $false; error = (New-ErrorInfo 'bad_response' 'Codex usage service returned an unexpected response.' $status) }
                }
                return @{ ok = $true; json = $json }
            }
        } catch {
            $last = @{ ok = $false; error = (New-ErrorInfo 'network' 'Could not reach the Codex usage service from this PC (network, DNS, TLS or timeout).') }
            continue
        } finally {
            if ($null -ne $resp) { $resp.Close() }
        }
        $last = Get-HttpError $status
        $last.retry_after = $retryAfter
        # 429: stop at once and let the backoff decide when to call again; 5xx: retry briefly.
        if ($status -lt 500) { return $last }
    }
    return $last
}

function Get-HttpError {
    param([int]$Status)
    if ($Status -eq 401 -or $Status -eq 403) {
        return @{ ok = $false; error = (New-ErrorInfo "http_$Status" "Codex authentication or access failed (HTTP $Status). Open Codex on this PC and sign in if required, then retry." $Status) }
    }
    if ($Status -ge 300 -and $Status -lt 400) {
        return @{ ok = $false; error = (New-ErrorInfo 'redirect_refused' "Codex usage service redirected the request (HTTP $Status); the redirect was not followed." $Status) }
    }
    if ($Status -eq 429) {
        return @{ ok = $false; error = (New-ErrorInfo 'http_429' 'Codex usage service is rate limiting requests (HTTP 429). It will retry later.' $Status) }
    }
    return @{ ok = $false; error = (New-ErrorInfo "http_$Status" "Codex usage service returned HTTP $Status." $Status) }
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
    $resetPassed = New-Object System.Collections.ArrayList
    $out = [ordered]@{
        schema_version   = 1
        weekly           = $null
        session          = $null
        scoped           = @()
        plan             = $null
        credits          = $null
        fetched_at       = $null
        status           = 'unavailable'
        source           = $Source
        stale            = $Stale
        age_seconds      = $null
        account_verified = $AccountVerified
        limit_reached    = $null
        unclassified     = @()
        reset_passed     = @()
        reset_credits    = $null
        notice           = $null
        error            = $ErrorInfo
        collected_at     = (Format-Iso $script:Now)
    }
    if ($null -eq $Obs) { return $out }
    $out.reset_credits = $Obs.reset_credits
    $scoped = New-Object System.Collections.ArrayList
    $uncl = New-Object System.Collections.ArrayList
    if ($Source -ne 'live') {
        # A non-live observation must not be shown as current past its known reset boundary.
        foreach ($k in @('weekly', 'session')) {
            if (Test-ResetPassed $Obs[$k]) { [void]$resetPassed.Add($k); $Obs[$k] = $null }
        }
        foreach ($s in $Obs.scoped) { if (Test-ResetPassed $s) { [void]$resetPassed.Add("scoped:$($s.id)") } else { [void]$scoped.Add($s) } }
        foreach ($u in $Obs.unclassified) { if (-not (Test-ResetPassed $u)) { [void]$uncl.Add($u) } }
    } else {
        foreach ($s in $Obs.scoped) { [void]$scoped.Add($s) }
        foreach ($u in $Obs.unclassified) { [void]$uncl.Add($u) }
    }
    $fetched = ConvertTo-UtcDate $Obs.fetched_at
    $out.weekly        = $Obs.weekly
    $out.session       = $Obs.session
    $out.scoped        = $scoped.ToArray()
    $out.plan          = $Obs.plan
    $out.credits       = $Obs.credits
    $out.fetched_at    = $Obs.fetched_at
    $out.age_seconds   = [long][Math]::Max(0.0, [Math]::Floor(($script:Now - $fetched).TotalSeconds))
    $out.limit_reached = $Obs.limit_reached
    $out.unclassified  = $uncl.ToArray()
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
    foreach ($w in $script:Warnings) { [Console]::Error.WriteLine("warn: $w") }
    if ($Diagnostics) {
        [Console]::Error.WriteLine("diag: http_calls=$($script:HttpCalls) cache=$($script:CacheResult) cli=$($script:CliResult) source=$($Output.source) status=$($Output.status) exit=$Code")
    }
    exit $Code
}

# ---------------------------------------------------------------- main

try {
    if (-not $CachePath) { $CachePath = Join-Path $env:LOCALAPPDATA 'CodexUsageWidget\usage-cache.json' }
    $codexHome = Resolve-CodexHome
    if (-not $codexHome.exists) {
        $msg = $(if ($codexHome.configured) { 'CODEX_HOME is set, but that folder does not exist on this PC.' } else { 'The Codex folder (%USERPROFILE%\.codex) was not found on this PC. Install Codex and sign in, then retry.' })
        $auth = @{ ok = $false; error = (New-ErrorInfo 'codex_home_missing' $msg) }
    } else {
        $auth = Read-AuthContext $codexHome.path
    }

    $cache = Read-Cache $CachePath
    $salt = $(if ($null -ne $cache) { $cache.salt } else { New-SaltHex })
    $tag = $(if ($auth.ok) { Get-AccountTag $auth.account $auth.mode $salt } else { $null })
    $cacheCompatible = ($null -ne $cache -and $null -ne $tag -and $cache.account_tag -ceq $tag)
    if ($null -ne $cache -and -not $cacheCompatible) { $script:CacheResult = 'incompatible' }

    # Fresh-cache shortcut: same auth context, < 60 s old, no reset boundary crossed.
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
    $err = $null
    if ($auth.ok) {
        if (-not $Force -and [double]$state.backoff_until -gt (Get-UnixNow)) {
            $auth.access = $null
            $script:CacheResult += '+backoff'
            $err = New-ErrorInfo ([string]$state.backoff_code) ('Codex usage service asked to slow down; showing the last reading. Next try at {0} (or right-click > Refresh now).' -f (Format-UnixLocal ([double]$state.backoff_until)))
        } else {
            $r = Invoke-UsageRequest $auth
            $auth.access = $null
            if ($r.ok) {
                $state.backoff_count = 0; $state.backoff_until = 0.0; $state.backoff_code = ''
                $obs = ConvertFrom-LiveUsage $r.json
                # Every 30 min ask the official CLI too: free-reset count, and it keeps its own sign-in fresh.
                if (-not $NoCli -and ((Get-UnixNow) - [double]$state.cli_at) -ge $script:CliInfoSeconds) { [void](Get-CliObservation $state $true) }
                if ([int]$state.reset_credits -ge 0) { $obs.reset_credits = [int]$state.reset_credits }
                Write-State $statePath $state
                try { Write-Cache $CachePath $salt $tag $obs } catch { Add-Warning "cache not saved: $($_.Exception.Message)" }
                Write-Result (New-Output $obs 'live' $false $true $null) 0
            }
            $err = $r.error
            $hs = $err.http_status
            if ($null -ne $hs -and ([int]$hs -eq 429 -or [int]$hs -ge 500)) {
                Set-Backoff $state $err.code $r.retry_after
                Write-State $statePath $state
                $err.message = '{0} Showing the last reading; next try at {1}.' -f $err.message, (Format-UnixLocal ([double]$state.backoff_until))
            }
        }
    } else {
        $err = $auth.error
    }

    # Sign-in problem: ask the official Codex CLI, which renews its own sign-in (or uses the OS credential store).
    $authCodes = @('http_401', 'http_403', 'auth_missing', 'auth_malformed', 'auth_unreadable')
    if ($null -ne $err -and $authCodes -contains $err.code -and $codexHome.exists) {
        $c = Get-CliObservation $state $true
        Write-State $statePath $state
        if ($null -ne $c) {
            $ctag = $(if ($c.account) { Get-AccountTag $c.account 'chatgpt' $salt } else { $null })
            if ($null -ne $ctag) { try { Write-Cache $CachePath $salt $ctag $c.obs } catch { Add-Warning "cache not saved: $($_.Exception.Message)" } }
            $out = New-Output $c.obs 'cli' $false ($null -ne $ctag) $null
            $out.notice = 'Read through the Codex app''s own CLI, which renews its sign-in when needed.'
            Write-Result $out 0
        }
    }

    # Live failed: freshest usable, account-compatible observation (verified sources first).
    $candidates = New-Object System.Collections.ArrayList
    if ($cacheCompatible) {
        [void]$candidates.Add(@{ time = (ConvertTo-UtcDate $cache.observation.fetched_at); obs = $cache.observation; source = 'cache'; verified = $true })
    }
    if ($codexHome.exists) {
        $acct = $(if ($auth.ok) { $auth.account } else { $null })
        $ro = Find-RolloutObservation $codexHome.path $acct
        if ($null -ne $ro) { [void]$candidates.Add(@{ time = $ro.time; obs = $ro.obs; source = 'session_log'; verified = $ro.verified }) }
    }
    $pool = @($candidates | Where-Object { $_.verified })
    if ($pool.Count -eq 0) { $pool = @($candidates) }
    $pick = $pool | Sort-Object { $_.time } -Descending | Select-Object -First 1
    if ($null -ne $pick) {
        Write-Result (New-Output $pick.obs $pick.source $true $pick.verified $err) 2
    }
    Write-Result (New-Output $null 'none' $true $false $err) 3
} catch {
    $out = New-Output $null 'none' $true $false (New-ErrorInfo 'internal' 'The Codex usage collector hit an internal error.')
    Write-Result $out 4
}
