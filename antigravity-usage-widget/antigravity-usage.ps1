<#
.SYNOPSIS
    Local, read-only Antigravity usage collector for the Antigravity Usage Widget (Windows PowerShell 5.1).

.DESCRIPTION
    Antigravity's local language server writes %USERPROFILE%\.gemini\antigravity\daemon\hub_<port>.json
    (pid, httpPort, httpsPort, csrfToken, lsVersion) while Antigravity runs. Old files can stay behind, so each
    one is tried, newest first, until one answers:
        POST http://127.0.0.1:<httpPort>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary
        headers Content-Type: application/json, Connect-Protocol-Version: 1, X-Codeium-Csrf-Token: <csrfToken>
        body    {"metadata":{"ideName":"antigravity"}}   (5 s timeout)
    The answer has 2 pools, each with a weekly and a 5-hour bucket (remainingFraction 0-1, resetTime ISO):
    "Gemini Models" (gemini-weekly, gemini-5h) and "Claude and GPT models" (3p-weekly, 3p-5h).
    It prints exactly ONE JSON line on stdout. It only talks to 127.0.0.1, never prints, logs or stores the
    CSRF token, and never writes outside %LOCALAPPDATA%\AntigravityUsageWidget (or -CachePath).

    Output (schema_version 1, the same shape as codex-usage.ps1 and claude-usage.ps1):
      weekly / session         the Gemini pool: { used, left, window_seconds, resets_at } or null
                               (used = PERCENT USED = (1 - remainingFraction) x 100)
      scoped                   the Claude and GPT pool, 2 entries { id, name, kind, used, left, window_seconds, resets_at }:
                               claude-gpt-weekly "Claude and GPT · week" (weekly), claude-gpt-5h "Claude and GPT · 5 hours" (session)
      plan, credits            null (not reported by the language server)
      fetched_at               ISO-8601 UTC time of the OBSERVATION (not of this run)
      status                   ok | stale | unavailable
      source                   live | cache | none
      stale, age_seconds, account_verified, limit_reached, unclassified, reset_passed, reset_credits, notice,
      error ({ code, http_status, message }; code antigravity_closed when no language server answers), collected_at

    Exit codes: 0 = fresh data (live or fresh cache), 2 = stale fallback payload,
                3 = no usable observation (structured unavailable payload), 4 = internal error (JSON still printed).
#>
[CmdletBinding()]
param(
    # Bypass the 60-second fresh-cache shortcut.
    [switch]$Force,
    # Write one sanitized diagnostics line (http_calls, hub files, cache result, source) to STDERR.
    [switch]$Diagnostics,
    # Override the cache file (tests). Default: %LOCALAPPDATA%\AntigravityUsageWidget\usage-cache.json
    [string]$CachePath,
    # Override the folder holding hub_<port>.json (tests). Default: %USERPROFILE%\.gemini\antigravity\daemon
    [string]$DaemonDir,
    # TEST ONLY: override "now" as Unix seconds.
    [double]$TestNowUnix = 0
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:RpcPath         = '/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary'
$script:WeekSeconds     = 604800
$script:SessionSeconds  = 18000
$script:CacheTtlSeconds = 60
$script:TimeoutMs       = 5000
$script:HttpCalls       = 0
$script:HubFiles        = 0
$script:Warnings        = New-Object System.Collections.ArrayList   # one line each on stderr as "warn: ..."; the widget logs them
$script:CacheResult     = 'none'
$script:Inv             = [Globalization.CultureInfo]::InvariantCulture
$script:Utf8NoBom       = New-Object System.Text.UTF8Encoding($false)
$script:Dot             = [string][char]0x00B7

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
    # Accepts ISO strings, Unix seconds/milliseconds or DateTime objects.
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
    if ($null -eq $u -or $null -eq $s -or $s -le 0 -or $s -gt 1e9) { return $null }
    $u = [Math]::Min(100.0, [Math]::Max(0.0, $u))
    $r = ConvertTo-UtcDate $ResetsAt
    return [ordered]@{
        used           = $u
        left           = [Math]::Round(100.0 - $u, 2)
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
        limit_reached = $null
        fetched_at    = $null
    }
}

function New-ErrorInfo {
    param([string]$Code, [string]$Message, $HttpStatus = $null)
    return [ordered]@{ code = $Code; http_status = $HttpStatus; message = $Message }
}

function Add-Warning {
    # A failure that doesn't stop this run but should leave a trace in the widget log. Never exception text from
    # reading a hub file: it can quote the file, which holds the CSRF token.
    param([string]$Text)
    [void]$script:Warnings.Add(($Text -replace '[\r\n]+', ' '))
}

# ---------------------------------------------------------------- quota summary

function Get-BucketSeconds {
    # "weekly" / "5h" (also "<n>h", "<n>d", "daily") -> seconds; $null when unknown.
    param($Window)
    if (-not ($Window -is [string])) { return $null }
    $w = $Window.Trim().ToLowerInvariant()
    if ($w -eq 'weekly' -or $w -eq 'week') { return $script:WeekSeconds }
    if ($w -eq 'daily' -or $w -eq 'day') { return 86400 }
    $m = [regex]::Match($w, '^(\d{1,4})\s*(h|d)$')
    if ($m.Success) { return ([int]$m.Groups[1].Value) * $(if ($m.Groups[2].Value -eq 'd') { 86400 } else { 3600 }) }
    return $null
}

function ConvertFrom-QuotaSummary {
    # Maps buckets by their id (gemini-*, 3p-*) or pool name, never by position.
    param($Json)
    $obs = New-Observation
    $obs.fetched_at = Format-Iso $script:Now
    $resp = Get-Prop $Json 'response'
    if ($null -eq $resp) { $resp = $Json }
    $third = @{}
    foreach ($g in @(Get-Prop $resp 'groups')) {
        if ($null -eq $g) { continue }
        $gname = [string](Get-Prop $g 'displayName')
        foreach ($b in @(Get-Prop $g 'buckets')) {
            if ($null -eq $b) { continue }
            $id = [string](Get-Prop $b 'bucketId')
            $secs = Get-BucketSeconds (Get-Prop $b 'window')
            if ($null -eq $secs) { continue }
            # protobuf JSON leaves out zero values: a bucket without remainingFraction has nothing left.
            $frac = ConvertTo-Number (Get-Prop $b 'remainingFraction')
            if ($null -eq $frac) { $frac = 0.0 }
            $frac = [Math]::Min(1.0, [Math]::Max(0.0, $frac))
            $win = New-Window ([Math]::Round((1.0 - $frac) * 100.0, 2)) $secs (Get-Prop $b 'resetTime')
            if ($null -eq $win) { continue }
            $kind = Get-WindowKind $win.window_seconds
            $pool = $(if ($id -match '^gemini' -or ($id -eq '' -and $gname -match 'Gemini')) { 'gemini' }
                      elseif ($id -match '^3p' -or ($id -eq '' -and $gname -match 'Claude|GPT')) { '3p' }
                      else { 'other' })
            if ($pool -eq 'gemini' -and $kind -eq 'weekly' -and $null -eq $obs.weekly) { $obs.weekly = $win; continue }
            if ($pool -eq 'gemini' -and $kind -eq 'session' -and $null -eq $obs.session) { $obs.session = $win; continue }
            if ($pool -eq '3p' -and ($kind -eq 'weekly' -or $kind -eq 'session') -and -not $third.ContainsKey($kind)) { $third[$kind] = $win; continue }
            $u = [ordered]@{ slot = $(if ($id) { $id } else { $gname }); kind = $kind }
            foreach ($k in $win.Keys) { $u[$k] = $win[$k] }
            [void]$obs.unclassified.Add($u)
        }
    }
    foreach ($s in @(@{ kind = 'weekly'; id = 'claude-gpt-weekly'; name = "Claude and GPT $($script:Dot) week" },
                     @{ kind = 'session'; id = 'claude-gpt-5h'; name = "Claude and GPT $($script:Dot) 5 hours" })) {
        if (-not $third.ContainsKey($s.kind)) { continue }
        $item = [ordered]@{ id = $s.id; name = $s.name; kind = $s.kind }
        foreach ($k in $third[$s.kind].Keys) { $item[$k] = $third[$s.kind][$k] }
        [void]$obs.scoped.Add($item)
    }
    return $obs
}

function Test-HasLimits {
    param($Obs)
    return ($null -ne $Obs -and ($null -ne $Obs.weekly -or $null -ne $Obs.session -or $Obs.scoped.Count -gt 0))
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

function Get-HubList {
    # Usable hub files, newest first: @{ name; port; token }. A damaged file is skipped with a warning naming it only.
    param([string]$Dir)
    $list = New-Object System.Collections.ArrayList
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter 'hub_*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^hub_\d+\.json$' } | Sort-Object LastWriteTimeUtc -Descending)
    $script:HubFiles = $files.Count
    foreach ($f in $files) {
        $j = $null
        try { $j = (Read-SharedText $f.FullName) | ConvertFrom-Json } catch { $j = $null }
        if (-not ($j -is [System.Management.Automation.PSCustomObject])) { Add-Warning "hub file $($f.Name) unreadable, skipped"; continue }
        $port = ConvertTo-Number (Get-Prop $j 'httpPort')
        $token = Get-Prop $j 'csrfToken'
        if ($null -eq $port -or $port -lt 1 -or $port -gt 65535 -or $port -ne [Math]::Floor($port) -or
            -not ($token -is [string]) -or $token -notmatch '^[\x21-\x7E]{8,256}$') {
            Add-Warning "hub file $($f.Name) incomplete, skipped"; continue
        }
        [void]$list.Add(@{ name = $f.Name; port = [int]$port; token = $token })
    }
    return $list
}

function Invoke-QuotaRequest {
    # One call to the language server on 127.0.0.1. Returns @{ status; json } (status 0: no answer).
    param([int]$Port, [string]$Token)
    $script:HttpCalls++
    $resp = $null
    try {
        $req = [Net.HttpWebRequest]::Create(('http://127.0.0.1:{0}{1}' -f $Port, $script:RpcPath))
        $req.Method = 'POST'
        $req.Timeout = $script:TimeoutMs
        $req.ReadWriteTimeout = $script:TimeoutMs
        $req.AllowAutoRedirect = $false          # never send the token anywhere else
        $req.Proxy = $null                       # straight to the loopback port, never through a proxy
        $req.KeepAlive = $false
        $req.ServicePoint.Expect100Continue = $false
        $req.ContentType = 'application/json'
        $req.Accept = 'application/json'
        $req.UserAgent = 'antigravity-usage-widget/1.0 (Windows PowerShell 5.1)'
        $req.Headers.Add('Connect-Protocol-Version', '1')
        $req.Headers.Add('X-Codeium-Csrf-Token', $Token)
        $body = $script:Utf8NoBom.GetBytes('{"metadata":{"ideName":"antigravity"}}')
        $req.ContentLength = $body.Length
        $rs = $req.GetRequestStream()
        try { $rs.Write($body, 0, $body.Length) } finally { $rs.Dispose() }
        try { $resp = $req.GetResponse() }
        catch [Net.WebException] {
            if ($null -ne $_.Exception.Response) { $resp = $_.Exception.Response } else { return @{ status = 0; json = $null } }
        }
        $status = [int]$resp.StatusCode
        if ($status -lt 200 -or $status -ge 300) { return @{ status = $status; json = $null } }
        $sr = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }
        $json = $null
        try { $json = $text | ConvertFrom-Json } catch { $json = $null }
        return @{ status = $status; json = $json }
    } catch {
        return @{ status = 0; json = $null }
    } finally {
        if ($null -ne $resp) { $resp.Close() }
    }
}

function Write-FlushedText {
    # Flushed to disk before the swap, so a power cut can't leave an empty file behind.
    param([string]$Path, [string]$Text)
    $bytes = $script:Utf8NoBom.GetBytes($Text)
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $fs.Write($bytes, 0, $bytes.Length); $fs.Flush($true) } finally { $fs.Dispose() }
}

function Write-Cache {
    # The cache holds only the observation (percentages and reset times): no token, no port, no account.
    param([string]$Path, $Obs)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $json = ConvertTo-Json -InputObject ([ordered]@{ schema_version = 1; observation = $Obs }) -Depth 12
    $tmp = "$Path.$PID.tmp"
    Write-FlushedText $tmp $json
    for ($i = 0; $i -lt 4; $i++) {
        try {
            if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
            return
        } catch { Start-Sleep -Milliseconds (60 * ($i + 1)) }
    }
    try { [IO.File]::Copy($tmp, $Path, $true) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Import-Window {
    param($W)
    if ($null -eq $W) { return $null }
    return (New-Window (Get-Prop $W 'used') (Get-Prop $W 'window_seconds') (Get-Prop $W 'resets_at'))
}

function Read-Cache {
    # The saved observation, rebuilt field by field (a damaged or hand-edited file gives $null, never an error).
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $c = (Read-SharedText $Path) | ConvertFrom-Json
        if ((Get-Prop $c 'schema_version') -ne 1) { return $null }
        $o = Get-Prop $c 'observation'
        $fetched = ConvertTo-UtcDate (Get-Prop $o 'fetched_at')
        if ($null -eq $fetched) { return $null }
        $obs = New-Observation
        $obs.fetched_at = Format-Iso $fetched
        $obs.weekly = Import-Window (Get-Prop $o 'weekly')
        $obs.session = Import-Window (Get-Prop $o 'session')
        foreach ($s in @(Get-Prop $o 'scoped')) {
            $w = Import-Window $s
            $id = Get-Prop $s 'id'; $name = Get-Prop $s 'name'
            if ($null -eq $w -or -not ($id -is [string]) -or -not ($name -is [string])) { continue }
            $item = [ordered]@{ id = $id; name = $name; kind = (Get-WindowKind $w.window_seconds) }
            foreach ($k in $w.Keys) { $item[$k] = $w[$k] }
            [void]$obs.scoped.Add($item)
        }
        if (-not (Test-HasLimits $obs)) { return $null }
        return $obs
    } catch { return $null }
}

# ---------------------------------------------------------------- output

function Test-ResetPassed {
    param($Window)
    if ($null -eq $Window -or $null -eq $Window.resets_at) { return $false }
    $r = ConvertTo-UtcDate $Window.resets_at
    return ($null -ne $r -and $r -le $script:Now)
}

function New-Output {
    param($Obs, [string]$Source, [bool]$Stale, $ErrorInfo)
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
        account_verified = $false
        limit_reached    = $null
        unclassified     = @()
        reset_passed     = @()
        reset_credits    = $null
        notice           = $null
        error            = $ErrorInfo
        collected_at     = (Format-Iso $script:Now)
    }
    if ($null -eq $Obs) { return $out }
    $resetPassed = New-Object System.Collections.ArrayList
    $scoped = New-Object System.Collections.ArrayList
    $uncl = New-Object System.Collections.ArrayList
    if ($Source -ne 'live') {
        # A saved reading must not be shown as current past its known reset time.
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
    $out.weekly           = $Obs.weekly
    $out.session          = $Obs.session
    $out.scoped           = $scoped.ToArray()
    $out.fetched_at       = $Obs.fetched_at
    $out.age_seconds      = [long][Math]::Max(0.0, [Math]::Floor(($script:Now - $fetched).TotalSeconds))
    $out.account_verified = $true            # the language server answers for the account signed in to Antigravity
    $out.limit_reached    = $Obs.limit_reached
    $out.unclassified     = $uncl.ToArray()
    $out.reset_passed     = $resetPassed.ToArray()
    $out.status           = $(if ($Stale) { 'stale' } else { 'ok' })
    return $out
}

function Write-Result {
    param($Output, [int]$Code)
    $json = ConvertTo-Json -InputObject $Output -Depth 12 -Compress
    $bytes = $script:Utf8NoBom.GetBytes($json + "`n")
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
    # UTF-8 bytes, like stdout: [Console]::Error uses the OEM code page and garbles non-ASCII text.
    $stderr = [Console]::OpenStandardError()
    $lines = @($script:Warnings | ForEach-Object { "warn: $_" })
    if ($Diagnostics) {
        $lines += ("diag: http_calls=$($script:HttpCalls) hub_files=$($script:HubFiles) cache=$($script:CacheResult) source=$($Output.source) status=$($Output.status) exit=$Code")
    }
    if ($lines.Count -gt 0) {
        $eb = $script:Utf8NoBom.GetBytes((($lines -join "`n") + "`n"))
        $stderr.Write($eb, 0, $eb.Length)
        $stderr.Flush()
    }
    exit $Code
}

# ---------------------------------------------------------------- main

try {
    if (-not $CachePath) { $CachePath = Join-Path $env:LOCALAPPDATA 'AntigravityUsageWidget\usage-cache.json' }
    if (-not $DaemonDir) { $DaemonDir = Join-Path $env:USERPROFILE '.gemini\antigravity\daemon' }
    $cache = Read-Cache $CachePath

    # Fresh-cache shortcut: < 60 s old and no reset time crossed.
    if (-not $Force -and $null -ne $cache) {
        $age = ($script:Now - (ConvertTo-UtcDate $cache.fetched_at)).TotalSeconds
        $crossed = (Test-ResetPassed $cache.weekly) -or (Test-ResetPassed $cache.session) -or @($cache.scoped | Where-Object { Test-ResetPassed $_ }).Count -gt 0
        if ($age -ge -5 -and $age -lt $script:CacheTtlSeconds -and -not $crossed) {
            $script:CacheResult = 'hit'
            Write-Result (New-Output $cache 'cache' $false $null) 0
        }
        $script:CacheResult = 'expired'
    } elseif ($Force) { $script:CacheResult = 'bypassed' }

    $err = $null
    if (-not (Test-Path -LiteralPath $DaemonDir -PathType Container)) {
        $err = New-ErrorInfo 'antigravity_closed' 'Antigravity was not found running on this PC (no language server folder in %USERPROFILE%\.gemini\antigravity\daemon). Install Antigravity, open it and sign in; the widget reads it on its next refresh.'
    } else {
        $httpStatus = $null; $badAnswer = $false
        foreach ($h in @(Get-HubList $DaemonDir)) {
            $r = Invoke-QuotaRequest $h.port $h.token
            $h.token = $null
            if ($r.status -ge 200 -and $r.status -lt 300) {
                $obs = $(if ($null -ne $r.json) { ConvertFrom-QuotaSummary $r.json } else { $null })
                if (Test-HasLimits $obs) {
                    try { Write-Cache $CachePath $obs } catch { Add-Warning "cache not saved: $($_.Exception.Message)" }
                    Write-Result (New-Output $obs 'live' $false $null) 0
                }
                $badAnswer = $true
            } elseif ($r.status -eq 401 -or $r.status -eq 403) {
                continue   # an old hub file: its CSRF token belongs to a language server that has since restarted
            } elseif ($r.status -gt 0) {
                $httpStatus = $r.status
            }
        }
        if ($badAnswer) {
            $err = New-ErrorInfo 'bad_response' 'Antigravity answered, but its quota summary had no limits the widget knows. Update the widget if Antigravity was updated.'
        } elseif ($null -ne $httpStatus) {
            $err = New-ErrorInfo "http_$httpStatus" "The Antigravity language server returned HTTP $httpStatus." $httpStatus
        } else {
            $err = New-ErrorInfo 'antigravity_closed' 'Antigravity is not running on this PC (no language server answered). Open Antigravity; the widget reads it on its next refresh.'
        }
    }

    # No live reading: the last saved one, marked stale.
    if ($null -ne $cache) {
        Write-Result (New-Output $cache 'cache' $true $err) 2
    }
    Write-Result (New-Output $null 'none' $true $err) 3
} catch {
    $out = New-Output $null 'none' $true (New-ErrorInfo 'internal' 'The Antigravity usage collector hit an internal error.')
    Write-Result $out 4
}
