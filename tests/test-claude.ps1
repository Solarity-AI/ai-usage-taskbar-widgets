# SIMULATED tests for the Claude widget. Fake CLAUDE_CONFIG_DIR with non-credential placeholder values; no network.
param([string]$Dir, [string]$Root)
$ErrorActionPreference = 'Stop'
$Collector = Join-Path $Dir 'claude-usage.ps1'; $Widget = Join-Path $Dir 'claude-usage-widget.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
$cfg = Join-Path $Root 'claude-home'; [void](New-Item -ItemType Directory -Path $cfg -Force)
$cache = Join-Path $Root 'cache\usage-cache.json'
$results = New-Object System.Collections.ArrayList
function Check($name, [bool]$ok, $detail) { [void]$results.Add([pscustomobject]@{ Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Check = $name; Detail = "$detail" }) }
function Set-Creds([long]$expMs, [string]$acct = 'fixture-acct-A') {
    [IO.File]::WriteAllText((Join-Path $cfg '.credentials.json'), (ConvertTo-Json @{ claudeAiOauth = @{ accessToken = 'fixture-not-a-real-token-0000'; refreshToken = 'fixture-refresh'; expiresAt = $expMs; subscriptionType = 'team' } }), $utf8)
    [IO.File]::WriteAllText((Join-Path $cfg '.claude.json'), (ConvertTo-Json @{ oauthAccount = @{ accountUuid = $acct; organizationUuid = 'fixture-org'; emailAddress = 'fixture@example.invalid' } }), $utf8)
}
function Resp($name, $obj) { $p = Join-Path $Root "$name.json"; [IO.File]::WriteAllText($p, (ConvertTo-Json $obj -Depth 10), $utf8); $p }
# Fake Claude Code CLIs (never the real one): "renew" pushes the fixture expiry into the future, "fail" changes nothing.
$calls = Join-Path $Root 'cli-calls.txt'
$fakeOk = Join-Path $Root 'fake-claude-ok.cmd'
[IO.File]::WriteAllText($fakeOk, ("@echo off`r`necho %*>>""$calls""`r`npowershell -NoProfile -Command ""`$p = Join-Path `$env:CLAUDE_CONFIG_DIR '.credentials.json'; `$j = Get-Content `$p -Raw | ConvertFrom-Json; `$j.claudeAiOauth.expiresAt = 4102444800000; [IO.File]::WriteAllText(`$p, (`$j | ConvertTo-Json -Depth 5))""`r`n"))
$fakeFail = Join-Path $Root 'fake-claude-fail.cmd'
[IO.File]::WriteAllText($fakeFail, "@echo off`r`necho %*>>""$calls""`r`nexit /b 1`r`n")
function Run([string[]]$extra, [string]$home1 = $cfg, [string]$cli = $fakeFail) {
    $env:CLAUDE_CONFIG_DIR = $home1
    $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Diagnostics -CachePath "{1}" -ClaudeCliPath "{2}" {3}' -f $Collector, $cache, $cli, ($extra -join ' '))
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true; $psi.StandardOutputEncoding = $utf8
    $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
    $env:CLAUDE_CONFIG_DIR = $null
    $json = $null; try { $json = $o.Result | ConvertFrom-Json } catch { }
    [pscustomobject]@{ code = $p.ExitCode; raw = $o.Result.Trim(); lines = @($o.Result -split "`n" | Where-Object { $_.Trim() }).Count; json = $json; diag = $e.Result.Trim() }
}
$future = 4102444800000
Set-Creds $future
$full = Resp 'full' ([ordered]@{
    five_hour = [ordered]@{ utilization = 22.5; resets_at = '2030-11-13T01:59:59.912345+00:00' }
    seven_day = [ordered]@{ utilization = 61; resets_at = '2026-11-19T02:59:41.5+00:00' }
    seven_day_oauth_apps = $null
    seven_day_opus = [ordered]@{ utilization = 80; resets_at = '2026-11-19T02:59:41+00:00' }
    seven_day_sonnet = [ordered]@{ utilization = $null; resets_at = $null }
    extra_usage = [ordered]@{ is_enabled = $true; monthly_limit = 5000; used_credits = 1250; utilization = 25.0 } })

$r = Run @('-TestResponseFile', $full, '-Force')
Check 'stdout is exactly 1 JSON document' ($r.lines -eq 1 -and $null -ne $r.json) "lines=$($r.lines)"
Check 'seven_day -> weekly (604800), left = 100 - used' ($r.json.weekly.used -eq 61 -and $r.json.weekly.left -eq 39 -and $r.json.weekly.window_seconds -eq 604800) ($r.json.weekly | ConvertTo-Json -Compress)
Check 'five_hour -> session (18000)' ($r.json.session.used -eq 22.5 -and $r.json.session.window_seconds -eq 18000) ($r.json.session | ConvertTo-Json -Compress)
Check 'ISO +00:00 / fractional -> UTC Z' ($r.json.weekly.resets_at -eq '2026-11-19T02:59:41Z' -and $r.json.session.resets_at -eq '2030-11-13T01:59:59Z') "$($r.json.weekly.resets_at) $($r.json.session.resets_at)"
Check 'scoped Opus kept; null Sonnet skipped; weekly not overwritten' (@($r.json.scoped).Count -eq 1 -and $r.json.scoped[0].id -eq 'seven_day_opus' -and $r.json.scoped[0].name -eq 'Opus' -and $r.json.scoped[0].kind -eq 'weekly' -and $r.json.weekly.used -eq 61) ($r.json.scoped | ConvertTo-Json -Compress)
Check 'single scoped item serialized as array' ($r.raw.Contains('"scoped":[{')) ''
Check 'plan from local sign-in, extra usage %' ($r.json.plan -eq 'team' -and $r.json.extra_usage.enabled -eq $true -and $r.json.extra_usage.utilization -eq 25) ($r.json.extra_usage | ConvertTo-Json -Compress)
Check 'exit 0 live, verified' ($r.code -eq 0 -and $r.json.source -eq 'live' -and $r.json.account_verified -eq $true) $r.diag

$r = Run @('-TestResponseFile', (Resp 'no7' ([ordered]@{ five_hour = [ordered]@{ utilization = 40; resets_at = '2026-11-13T01:00:00+00:00' }; seven_day = $null })), '-Force')
Check 'missing weekly -> null (never the 5-hour value)' ($null -eq $r.json.weekly -and $r.json.session.used -eq 40 -and $r.raw.Contains('"scoped":[]')) $r.raw
$r = Run @('-TestResponseFile', (Resp 'zero' ([ordered]@{ five_hour = $null; seven_day = [ordered]@{ utilization = 0; resets_at = '2026-11-19T02:59:41+00:00' } })), '-Force')
Check 'used 0 -> left 100, no session' ($r.json.weekly.left -eq 100 -and $null -eq $r.json.session -and $r.json.limit_reached -eq $false) ''
$r = Run @('-TestResponseFile', (Resp 'max' ([ordered]@{ seven_day = [ordered]@{ utilization = 100; resets_at = '2026-11-19T02:59:41+00:00' } })), '-Force')
Check 'used 100 -> left 0, limit_reached' ($r.json.weekly.left -eq 0 -and $r.json.limit_reached -eq $true) ''
$r = Run @('-TestResponseFile', (Resp 'smax' ([ordered]@{ five_hour = [ordered]@{ utilization = 100; resets_at = '2030-11-13T01:00:00+00:00' }; seven_day = [ordered]@{ utilization = 40; resets_at = '2026-11-19T02:59:41+00:00' } })), '-Force')
Check '#39: 5-hour window at 100% -> limit_reached (weekly 40%)' ($r.json.session.left -eq 0 -and $r.json.limit_reached -eq $true) $r.raw

$a = Run @('-TestResponseFile', $full, '-Force'); Start-Sleep -Seconds 2
$b = Run @('-TestResponseFile', $full)
Check 'cache hit: 0 HTTP calls, same fetched_at' ($b.diag -match 'http_calls=0 cache=hit' -and $b.json.fetched_at -eq $a.json.fetched_at -and $b.json.age_seconds -ge 1) "$($b.diag) a=$($a.json.fetched_at) b=$($b.json.fetched_at)"
$c = Run @('-TestResponseFile', $full, '-Force')
Check '-Force bypasses cache' ($c.diag -match 'http_calls=1 cache=bypassed .*source=live') $c.diag
Check 'cache written via atomic replace (no .tmp left, updated)' (@(Get-ChildItem (Split-Path $cache) -Filter '*.tmp').Count -eq 0 -and ((Get-Content $cache -Raw | ConvertFrom-Json).observation.fetched_at -eq $c.json.fetched_at)) ''
$ct = Get-Content $cache -Raw
Check 'cache holds no token/account/email' (-not $ct.Contains('fixture-not-a-real') -and -not $ct.Contains('fixture-acct') -and -not $ct.Contains('@')) ''

$e = Run @('-TestHttpStatus', '401', '-Force')
Check '401 -> stale cache, sanitized message, exit 2' ($e.code -eq 2 -and $e.json.source -eq 'cache' -and $e.json.stale -and $e.json.error.code -eq 'http_401' -and $e.json.fetched_at -eq $c.json.fetched_at) $e.json.error.message
$n = Run @('-TestHttpStatus', '-1', '-Force')
Check 'network failure -> stale cache' ($n.code -eq 2 -and $n.json.error.code -eq 'network') ''
Set-Creds 1000000000000
Remove-Item $calls, (Join-Path $Root 'cache\collector-state.json') -Force -ErrorAction SilentlyContinue   # the 401 tests above legitimately tried a renewal
$x = Run @('-Force', '-NoRenew')
Check 'expired token + -NoRenew: no HTTP, no CLI, auth_expired, stale cache' ($x.diag -match 'http_calls=0' -and $x.diag -match 'renew=none' -and $x.json.error.code -eq 'auth_expired' -and $x.json.source -eq 'cache' -and $x.code -eq 2 -and -not (Test-Path $calls)) $x.json.error.message
$x = Run @('-Force')
Check 'expired + CLI renewal fails: auth_expired stale, CLI called once' ($x.diag -match 'renew=exit_1' -and $x.json.error.code -eq 'auth_expired' -and $x.json.error.message -match 'retry within 10 minutes' -and @(Get-Content $calls).Count -eq 1) "$($x.diag) | $($x.json.error.message)"
Check 'renewal uses the local /usage command, no session saved, no MCP' ((Get-Content $calls -Raw) -match '-p "/usage" --no-session-persistence --strict-mcp-config') (Get-Content $calls -Raw)
$x = Run @('-Force')
Check 'failed renewal throttled: CLI not run again within 10 min' ($x.diag -match 'renew=throttled' -and @(Get-Content $calls).Count -eq 1) $x.diag
Remove-Item (Join-Path $Root 'cache\collector-state.json') -Force
$x = Run @('-TestResponseFile', $full, '-Force') $cfg $fakeOk
Check 'expired + CLI renews: live data in the same run' ($x.diag -match 'renew=renewed' -and $x.diag -match 'http_calls=1' -and $x.json.source -eq 'live' -and $x.code -eq 0) $x.diag
$x = Run @('-TestResponseFile', $full, '-Force') $cfg $fakeOk
Check 'valid token: CLI never run' ($x.diag -match 'renew=none' -and @(Get-Content $calls).Count -eq 2) $x.diag
Set-Creds 1000000000000
Remove-Item (Join-Path $Root 'cache\collector-state.json') -Force
$x = Run @('-Force') $cfg (Join-Path $Root 'no-such-claude.exe')
Check 'no CLI found: clear message' ($x.diag -match 'renew=no_cli' -and $x.json.error.message -match 'was not found') $x.json.error.message
Set-Creds $future
Remove-Item (Join-Path $Root 'cache\collector-state.json') -Force
$x = Run @('-TestHttpStatus', '401', '-Force') $cfg $fakeOk
Check '401: one CLI renewal then one retry' ($x.diag -match 'renew=renewed' -and $x.diag -match 'http_calls=2' -and $x.json.error.code -eq 'http_401') $x.diag
Remove-Item (Join-Path $Root 'cache\collector-state.json') -Force
$x = Run @('-TestHttpStatus', '429', '-Force')
$st = Get-Content (Join-Path $Root 'cache\collector-state.json') -Raw | ConvertFrom-Json
Check '429: backoff saved (~2 min), stale cache, next try time shown' ($x.code -eq 2 -and $x.json.error.code -eq 'http_429' -and $st.backoff_count -eq 1 -and ($st.backoff_until - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -gt 100 -and $x.json.error.message -match 'next try at') $x.json.error.message
Check 'state file holds no token/account' (-not (Get-Content (Join-Path $Root 'cache\collector-state.json') -Raw).Contains('fixture')) ''
$x = Run @('-TestResponseFile', $full, '-TestNowUnix', ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 90))   # cache older than 60 s, backoff still running
Check 'during backoff: 0 HTTP calls, stale cache' ($x.diag -match 'http_calls=0' -and $x.diag -match 'backoff' -and $x.json.stale -eq $true) $x.diag
$x = Run @('-TestResponseFile', $full, '-Force')
$st = Get-Content (Join-Path $Root 'cache\collector-state.json') -Raw | ConvertFrom-Json
Check 'Refresh now (-Force) ignores backoff; success clears it' ($x.diag -match 'http_calls=1' -and $x.json.source -eq 'live' -and $st.backoff_count -eq 0) $x.diag
$rb = Run @('-TestHttpStatus', '503', '-TestNowUnix', '1795057300')
Check 'reset passed -> weekly null + reset_passed' ($null -eq $rb.json.weekly -and @($rb.json.reset_passed) -contains 'weekly') ($rb.json.reset_passed -join ',')
Set-Creds $future 'fixture-acct-B'
$ac = Run @('-TestHttpStatus', '401')
Check 'account change -> cache not used, unavailable' ($ac.diag -match 'cache=incompatible' -and $ac.json.status -eq 'unavailable' -and $ac.code -eq 3) $ac.diag
Remove-Item (Join-Path $cfg '.credentials.json')
$m = Run @('-Force')
Check 'missing sign-in -> auth_missing, no HTTP' ($m.json.error.code -eq 'auth_missing' -and $m.diag -match 'http_calls=0') $m.json.error.message
$ch = Run @('-Force') (Join-Path $Root 'nope')
Check 'missing CLAUDE_CONFIG_DIR honored (no fallback)' ($ch.json.error.code -eq 'config_missing') $ch.json.error.message
$cb = Run @('-Force') 'C:\bad|dir?'
Check '#33: invalid CLAUDE_CONFIG_DIR path -> config_missing, 1 JSON document' ($cb.lines -eq 1 -and $cb.json.error.code -eq 'config_missing' -and $cb.code -eq 3) "$($cb.raw) | $($cb.diag)"
Set-Creds $future
$bad = Join-Path $Root 'bad.json'; [IO.File]::WriteAllText($bad, '<html>', $utf8)
$br = Run @('-TestResponseFile', $bad, '-Force')
Check 'non-JSON -> bad_response' ($br.json.error.code -eq 'bad_response') ''

# Widget functions loaded via AST only (widget is never run)
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Widget, [ref]$tok, [ref]$err)
$want = 'ConvertTo-UtcTime', 'ConvertTo-Unix', 'Get-Left', 'Format-Percent', 'Get-LevelKey', 'Format-Span', 'Get-ResetText', 'Format-LocalTime', 'Format-Rate',
    'Get-PaceInfo', 'Get-PaceView', 'Write-AtomicText', 'Get-PillFitHeight', 'New-History', 'Read-History', 'Add-HistorySample', 'ConvertTo-HistoryJson', 'Get-ClearX', 'Write-Log',
    'Format-Number', 'Format-Share', 'Test-Snoozed', 'Get-SnoozeUntil', 'Format-SnoozeEnd', 'Find-SignInCli', 'Get-SameWindowSamples', 'Get-DailyBudget', 'Get-ChartGeometry', 'Get-Trend', 'Get-AlertsDue', 'ConvertTo-Settings', 'Add-WindowSample', 'Get-SpendValue', 'Format-DayTime', 'Format-ResetLine', 'Format-UsedShare', 'Get-PaceSummary', 'Get-WindowLabel', 'Invoke-Alerts', 'Get-BindingLimit',
    'Read-JsonFile', 'Read-AlertsSent', 'Test-AlertSent', 'Get-ClampedPosition'
$script:AppDir = $Root; $script:LogPath = Join-Path $Root 'widget.log'; $script:HistoryDays = 15; $script:AnchorGapPx = 8; $script:Inv = [Globalization.CultureInfo]::InvariantCulture
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($a2 in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$script:PillXaml', '$script:CardXaml', '$script:Thresholds' }, $true)) { . ([scriptblock]::Create($a2.Extent.Text)) }
Add-Type -AssemblyName PresentationFramework
foreach ($nm in 'PillXaml', 'CardXaml') {
    $xml = (Get-Variable -Scope Script -Name $nm).Value
    try { $d0 = New-Object Xml.XmlDocument; $d0.LoadXml($xml); $w = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$xml))); Check "$nm XML + WPF load" ($w.Title -like 'Usage*') $w.Title } catch { Check "$nm XML + WPF load" $false $_.Exception.Message }
}
# Regression: settings saved twice must persist the second value (File.Replace / $null bug)
$sf = Join-Path $Root 'settings.json'
Write-AtomicText $sf '{"x":1}'; Write-AtomicText $sf '{"x":2}'; Write-AtomicText $sf '{"x":3}'
Check 'Write-AtomicText: 3rd save persisted, no .tmp' (([IO.File]::ReadAllText($sf)) -eq '{"x":3}' -and @(Get-ChildItem $Root -Filter 'settings.json.*.tmp').Count -eq 0) ([IO.File]::ReadAllText($sf))
Check 'Pill fits 40px taskbar @125% (<=38px)' ((Get-PillFitHeight 40 1.25) * 1.25 -le 38 -and (Get-PillFitHeight 40 1.25) -ge 24) (Get-PillFitHeight 40 1.25)
Check 'Pill stays 35 DIP on 48px taskbar @100%' ((Get-PillFitHeight 48 1.0) -eq 35) ''
Check 'Pill stays 35 DIP on 60px taskbar @125%' ((Get-PillFitHeight 60 1.25) -eq 35) ''
$now = [DateTime]::SpecifyKind([DateTime]'2026-11-12T12:00:00', 'Utc')
$pw = [pscustomobject]@{ used = 61; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }
Check 'Get-Left / Get-ResetText on Claude shape' ((Get-Left $pw) -eq 39 -and (Get-ResetText $pw.resets_at $now) -eq '3d 0h') ''

# ---- pace model (weekly window, half-way: 84 h elapsed, 84 h left)
$rU = ConvertTo-Unix ([DateTime]::SpecifyKind([DateTime]'2026-11-15T12:00:00', 'Utc'))
$nowP = [DateTime]::SpecifyKind([DateTime]'2026-11-12T00:00:00', 'Utc'); $nU = ConvertTo-Unix $nowP
$wk = [pscustomobject]@{ used = 60; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }
$p = Get-PaceInfo $wk @() $nowP
Check 'pace: even pace 50% by half-way, 10 points ahead' ([Math]::Abs($p.expected_used - 50) -lt 1e-9 -and [Math]::Abs($p.ahead_points - 10) -lt 1e-9) "$($p.expected_used) $($p.ahead_points)"
Check 'pace: average 60/84 %/h = 20% faster than even (100/168)' ($p.basis -eq 'average' -and [Math]::Abs($p.speed_pct - 20) -lt 1e-6) $p.speed_pct
Check 'pace: runs out in 56 h, 28 h before reset' ($p.runs_out -and [Math]::Abs($p.run_out_in_h - 56) -lt 1e-6 -and [Math]::Abs($p.spare_h - 28) -lt 1e-6) "$($p.run_out_in_h) $($p.spare_h)"
Check 'pace: budget 40/84 %/h to last' ([Math]::Abs($p.budget_rate - 40 / 84.0) -lt 1e-9) $p.budget_rate
$samples = @(@{ t = $nU - 4 * 3600; u = 56; r = $rU }, @{ t = $nU - 3600; u = 59.5; r = $rU }, @{ t = $nU - 5 * 3600; u = 10; r = $rU - 604800 }, @{ t = $nU - 604800; u = 45; r = $rU - 604800 })
$p = Get-PaceInfo $wk $samples $nowP
Check 'pace: recent rate from oldest same-window sample 2-6 h old (4 %/4 h)' ($p.basis -eq 'recent' -and [Math]::Abs($p.recent_rate - 1.0) -lt 1e-9 -and [Math]::Abs($p.recent_span_h - 4) -lt 1e-9) "$($p.recent_rate) $($p.recent_span_h)"
Check 'pace: forecast follows recent rate (out in 40 h)' ([Math]::Abs($p.run_out_in_h - 40) -lt 1e-6) $p.run_out_in_h
Check 'pace: last week at this point = 45%' ($p.prev_used -eq 45) $p.prev_used
$v = Get-PaceView $p $null $nowP
Check 'view: title says % faster, red when running out, pill hint' ($v.title -eq 'Pace: runs out 1d 20h before the reset' -and ($v.lines -join ' ') -match 'Speed right now: 68% faster than even\.' -and $v.level -eq 'red' -and $v.pill -eq 'out 1d 16h') "$($v.title) | $($v.level) | $($v.pill)"
Check 'view: lines cover used-vs-even, speed, run-out time, budget, last week' (($v.lines -join "`n") -match 'even pace would be 50% by now \(10 points more than even\)' -and ($v.lines -join ' ') -match 'Speed: 1\.0%/\u2060h over the last 4h 0m' -and ($v.lines -join ' ') -match 'you run out .* \(in 1d 16h\), 1d 20h before the reset' -and ($v.lines -join ' ') -match 'at most 0\.5%/\u2060h \(about 11% a day\)' -and ($v.lines -join ' ') -match 'Last week at this point: 45% used \(15 points less than now\)') ($v.lines -join ' || ')
$slow = Get-PaceInfo ([pscustomobject]@{ used = 10; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }) @() $nowP
$vs = Get-PaceView $slow $null $nowP
Check 'pace: slow user lasts until reset with ~80% left' (-not $slow.runs_out -and [Math]::Abs($slow.left_at_reset - 80) -lt 1e-6 -and $vs.title -eq 'Pace: 80% slower than even' -and $vs.level -eq 'green' -and $null -eq $vs.pill) "$($slow.left_at_reset) $($vs.title)"
$early = Get-PaceInfo ([pscustomobject]@{ used = 3; window_seconds = 604800; resets_at = '2026-11-18T23:30:00Z' }) @() $nowP
$fast = Get-PaceInfo ([pscustomobject]@{ used = 88; window_seconds = 604800; resets_at = '2026-11-17T12:00:00Z' }) @() $nowP
Check 'view: >=100% faster also shows the multiplier' (((Get-PaceView $fast $null $nowP).lines -join ' ') -match 'Speed right now: \d+% faster than even \(\d\.\d\u00D7\)\.') (Get-PaceView $fast $null $nowP).title
Check 'pace: first hour of the week -> too early to judge' ((Get-PaceView $early $null $nowP).title -eq 'Pace: too early to judge') (Get-PaceView $early $null $nowP).title
$lim = Get-PaceInfo ([pscustomobject]@{ used = 100; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }) @() $nowP
Check 'pace: limit reached view' ($lim.limited -and (Get-PaceView $lim $null $nowP).title -eq 'Limit reached') ''
Check 'pace: past reset or missing data -> no pace' ($null -eq (Get-PaceInfo ([pscustomobject]@{ used = 5; window_seconds = 604800; resets_at = '2026-11-01T00:00:00Z' }) @() $nowP) -and $null -eq (Get-PaceInfo ([pscustomobject]@{ used = $null; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }) @() $nowP)) ''
$ses = Get-PaceInfo ([pscustomobject]@{ used = 90; window_seconds = 18000; resets_at = '2026-11-12T02:00:00Z' }) @() $nowP
$vs2 = Get-PaceView $slow $ses $nowP
Check 'pace: 5-hour window running out in 20m is reported' ($ses.runs_out -and [Math]::Abs($ses.run_out_in_h - 1 / 3.0) -lt 1e-6 -and ($vs2.lines -join ' ') -match '5-hour window: 90% used; at this speed it runs out .* \(in 20m\)') ($vs2.lines -join ' || ')


# ---- card v3: pace box, reset lines, row labels
$dotc = [string][char]0x00B7
$sm = Get-PaceSummary $p $nowP
Check 'pace box: running out -> "Too fast" in red, run-out time, used and week gone' ($sm.status -eq 'Too fast' -and $sm.level -eq 'red' -and $sm.text -match "^At this rate it runs out \w{3} \d\d:\d\d $dotc 60% used, 50% of the week gone$" -and [Math]::Abs($sm.fill - 0.6) -lt 1e-9 -and [Math]::Abs($sm.marker - 0.5) -lt 1e-9) $sm.text
$ss = Get-PaceSummary $slow $nowP
Check 'pace box: lasting -> "On pace" and still the finish time at this rate (far off -> with the date)' ($ss.status -eq 'On pace' -and $ss.level -eq 'green' -and $ss.text -match "^At this rate it runs out \w{3} \d{1,2} \w{3}, \d\d:\d\d, after the reset $dotc 10% used, 50% of the week gone$") $ss.text
$cs = Get-PaceSummary (Get-PaceInfo ([pscustomobject]@{ used = 49; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }) @() $nowP) $nowP
Check 'pace box: cutting close -> finish time just after the reset (49/84 %/h -> 87.4 h)' ($cs.status -eq 'Cutting close' -and $cs.text -match "^At this rate it runs out \w{3} \d\d:\d\d, after the reset $dotc 49% used, 50% of the week gone$") $cs.text
$idle = Get-PaceInfo $wk @(@{ t = $nU - 4 * 3600; u = 60; r = $rU }) $nowP
Check 'pace box: no use in the last hours -> lasts until the reset, no fake time' ((Get-PaceSummary $idle $nowP).text -like 'No use lately, so it lasts until the reset*') (Get-PaceSummary $idle $nowP).text
$close = Get-PaceInfo ([pscustomobject]@{ used = 49; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }) @() $nowP
Check 'pace box: lasts with under 5% to spare -> "Cutting close" (amber)' ((Get-PaceSummary $close $nowP).status -eq 'Cutting close' -and (Get-PaceSummary $close $nowP).level -eq 'amber') (Get-PaceSummary $close $nowP).status
Check 'pace box: first hour -> "Too early to tell" (gray); limit -> "Limit reached" with reset' ((Get-PaceSummary $early $nowP).status -eq 'Too early to tell' -and (Get-PaceSummary $early $nowP).level -eq 'gray' -and (Get-PaceSummary $lim $nowP).status -eq 'Limit reached' -and (Get-PaceSummary $lim $nowP).text -match '^Resets ') ''
Check 'pace box: no pace -> no box' ($null -eq (Get-PaceSummary $null $nowP)) ''
$rl = Format-ResetLine '2026-11-15T12:00:00Z' $now
Check 'reset line: "Resets Sun 15 Nov, HH:mm · in 3d 0h" (no break inside the span)' ($rl -match ("^Resets \w{3} \d{1,2} \w{3}, \d\d:\d\d $dotc in 3d" + [char]0x00A0 + '0h$')) $rl
Check 'reset line: past -> reset due; unknown -> nothing' ((Format-ResetLine '2026-11-01T00:00:00Z' $now) -like 'Reset due*' -and $null -eq (Format-ResetLine $null $now)) ''
Check 'row labels match the card: weekly / session / per-model' ((Get-WindowLabel 'weekly' $null 604800 'claude') -eq "Weekly $dotc all models" -and (Get-WindowLabel 'weekly' $null 604800 'codex') -eq 'Weekly limit' -and (Get-WindowLabel 'session' $null 18000 'claude') -eq "Current session $dotc 5 hours" -and (Get-WindowLabel 'weekly' 'Fable' 604800 'claude') -eq "Weekly $dotc Fable") ''
Check 'used share: "<1%" for a trace, whole numbers otherwise' ((Format-UsedShare 0.3) -eq '<1%' -and (Format-UsedShare 44.5) -eq '45%' -and (Format-UsedShare 0) -eq '0%') ''
# QA-02 / 05 / 07 regressions
$q2now = [DateTime]::SpecifyKind([DateTime]'2026-11-18T03:20:00', 'Utc')
$q2w = [pscustomobject]@{ used = 2; window_seconds = 604800; resets_at = $q2now.AddHours(167.67).ToString('o') }
$q2p = Get-PaceInfo $q2w @() $q2now
Check 'QA-02: no "run out early" alert in the first hour (speed not judged yet)' ($q2p.runs_out -and $null -eq $q2p.speed_pct -and @(Get-AlertsDue ([pscustomobject]@{ stale = $false; weekly = $q2w; session = $null }) $q2p (ConvertTo-Settings $null 60 $q2now) @{} 'Claude' $q2now | Where-Object { $_.title -match 'run out early' }).Count -eq 0) ''
$q5now = [DateTime]::SpecifyKind([DateTime]'2026-11-18T15:00:00', 'Utc'); $q5r = ConvertTo-Unix ([DateTime]::SpecifyKind([DateTime]'2026-11-21T15:00:00', 'Utc'))
$q5b = Get-DailyBudget ([pscustomobject]@{ used = 60; window_seconds = 604800; resets_at = '2026-11-21T15:00:00Z' }) @(@{ t = $q5r - 5 * 86400 + 3600; u = 20; r = $q5r }) $q5now
Check 'QA-05: a reading from days before midnight does not count as today''s use' ($null -eq $q5b -or $q5b.used_today -lt 10) "$($q5b.used_today)"
Check 'QA-07: 99.6% used reads "99%" (matches "<1%" left), 100 reads "100%"' ((Format-UsedShare 99.6) -eq '99%' -and (Format-UsedShare 100) -eq '100%') (Format-UsedShare 99.6)
$wsrc = [IO.File]::ReadAllText($Widget); $usrc = [IO.File]::ReadAllText((Join-Path $Dir 'uninstall.ps1'))
Check 'QA-03: uninstall, collector and widget never hold the install folder as working directory' ($wsrc -match "-WorkingDirectory \`$env:USERPROFILE -ArgumentList @\('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File'" -and $wsrc -match '\$psi\.WorkingDirectory = \$env:USERPROFILE' -and $wsrc -match '\[Environment\]::CurrentDirectory = \$env:USERPROFILE' -and $usrc -match '\[Environment\]::CurrentDirectory = \$env:USERPROFILE') ''
Check 'QA-06: a click during a 429/5xx backoff does not force a request' ($wsrc -match 'Start-Refresh \(-not \$inBackoff\)') ''
# Pill/hero show the limit that runs out first
$bn = [DateTime]::SpecifyKind([DateTime]'2026-11-14T12:00:00', 'Utc')
$bw = { param($u) [pscustomobject]@{ used = $u; window_seconds = 604800; resets_at = '2026-11-18T12:00:00Z' } }
$bs = { param($u, $r = '2026-11-14T14:00:00Z') [pscustomobject]@{ used = $u; window_seconds = 18000; resets_at = $r } }
Check 'binding limit: 5-hour session with less left wins' ((Get-BindingLimit ([pscustomobject]@{ weekly = (& $bw 45); session = (& $bs 80) }) $bn).kind -eq 'session' -and (Get-BindingLimit ([pscustomobject]@{ weekly = (& $bw 45); session = (& $bs 80) }) $bn).left -eq 20) ''
Check 'binding limit: weekly when it has less left, on a tie, or when the session reset passed or is missing' ((Get-BindingLimit ([pscustomobject]@{ weekly = (& $bw 70); session = (& $bs 10) }) $bn).kind -eq 'weekly' -and (Get-BindingLimit ([pscustomobject]@{ weekly = (& $bw 50); session = (& $bs 50) }) $bn).kind -eq 'weekly' -and (Get-BindingLimit ([pscustomobject]@{ weekly = (& $bw 45); session = (& $bs 90 '2026-11-14T11:00:00Z') }) $bn).kind -eq 'weekly' -and (Get-BindingLimit ([pscustomobject]@{ weekly = (& $bw 45); session = $null }) $bn).kind -eq 'weekly') ''
# ---- history
$h = New-History
$d1 = [pscustomobject]@{ stale = $false; fetched_at = '2026-11-12T00:00:00Z'; weekly = $wk; session = $null }
$a1 = Add-HistorySample $h $d1
$a2 = Add-HistorySample $h ([pscustomobject]@{ stale = $false; fetched_at = '2026-11-12T00:02:00Z'; weekly = $wk; session = $null })
$a3 = Add-HistorySample $h ([pscustomobject]@{ stale = $true; fetched_at = '2026-11-12T00:09:00Z'; weekly = $wk; session = $null })
$a4 = Add-HistorySample $h ([pscustomobject]@{ stale = $false; fetched_at = '2026-11-12T00:06:00Z'; weekly = $wk; session = $null })
Check 'history: first kept, <5 min skipped, stale skipped, 5+ min kept' ($a1 -and -not $a2 -and -not $a3 -and $a4 -and $h.w.Count -eq 2 -and $h.s.Count -eq 0) "$a1 $a2 $a3 $a4 count=$($h.w.Count)"
[void]$h.w.Insert(0, @{ t = $nU - 20 * 86400; u = 1; r = $rU - 3 * 604800 })
$hp = Join-Path $Root 'history.json'
[IO.File]::WriteAllText($hp, (ConvertTo-HistoryJson $h $nU))
$h2 = Read-History $hp
Check 'history: JSON round trip keeps rows, prunes >15 days' ($h2.w.Count -eq 2 -and $h2.w[0].u -eq 60 -and $h2.w[0].r -eq $rU) ([IO.File]::ReadAllText($hp))
[IO.File]::WriteAllText($hp, 'not json')
Check 'history: corrupt file -> empty history, no crash' ((Read-History $hp).w.Count -eq 0) ''

# ---- placement clearance (physical px; tray from 1541, anchor pill 1378-1533)
$tray = [pscustomobject]@{ Left = 1541; Top = 1140; Right = 1920; Bottom = 1200 }
$anc = [pscustomobject]@{ Left = 1378; Top = 1146; Right = 1533; Bottom = 1194 }
Check 'clear: pill over the tray chevron moves left of it' ((Get-ClearX 1445 1146 155 48 $tray $null) -eq (1541 - 8 - 155)) (Get-ClearX 1445 1146 155 48 $tray $null)
Check 'clear: pill already clear is not moved' ((Get-ClearX 900 1146 155 48 $tray $null) -eq 900) ''
Check 'clear: Codex over the Claude pill moves left of it' ((Get-ClearX 1300 1146 155 48 $tray $anc) -eq (1378 - 8 - 155)) (Get-ClearX 1300 1146 155 48 $tray $anc)
Check 'clear: other rows (vertical taskbar etc.) untouched' ((Get-ClearX 1445 100 155 48 $tray $anc) -eq 1445) ''

# ---- /usage text fallback (collector, fake CLI printing Claude Code's /usage text)
$usageTxt = Join-Path $Root 'usage.txt'
[IO.File]::WriteAllText($usageTxt, "You are currently using your subscription`r`n`r`nCurrent session: 35% used - resets 11:39pm (America/Chicago)`r`nCurrent week (all models): 29% used - resets Dec 30, 6:59pm (America/Chicago)`r`nCurrent week (Fable): 2% used - resets Dec 30, 6:59pm (America/Chicago)`r`n`r`nWhat's contributing to your usage?`r`n")
$fakeUsage = Join-Path $Root 'fake-claude-usage.cmd'
[IO.File]::WriteAllText($fakeUsage, "@echo off`r`necho %*>>""$calls""`r`ntype ""$usageTxt""`r`n")
Set-Creds $future
Remove-Item $calls, (Join-Path $Root 'cache\collector-state.json') -Force -ErrorAction SilentlyContinue
$off = Run @('-TestHttpStatus', '-2', '-Force') $cfg $fakeUsage
Check '#34: offline (DNS/connect failure) -> CLI fallback not run, network error' ($off.diag -match 'cli=none' -and -not (Test-Path $calls) -and $off.json.error.code -eq 'network' -and $off.code -ge 2) $off.diag
Remove-Item (Join-Path $Root 'cache\collector-state.json') -Force -ErrorAction SilentlyContinue
$u = Run @('-TestHttpStatus', '429', '-Force') $cfg $fakeUsage
Check '/usage fallback on 429: fresh reading from Claude Code, with notice' ($u.code -eq 0 -and $u.json.source -eq 'cli' -and $u.json.stale -eq $false -and $u.json.weekly.used -eq 29 -and $u.json.session.used -eq 35 -and $u.json.notice -match 'rate limiting') "$($u.diag) | $($u.json.notice)"
Check '/usage fallback: per-model limit (Fable) kept as scoped weekly' (@($u.json.scoped).Count -eq 1 -and $u.json.scoped[0].name -eq 'Fable' -and $u.json.scoped[0].kind -eq 'weekly' -and $u.json.scoped[0].used -eq 2) ($u.json.scoped | ConvertTo-Json -Compress)
$exp = [DateTime]::SpecifyKind((New-Object DateTime ((Get-Date).Year, 12, 30, 18, 59, 0)), 'Local').ToUniversalTime()
if ($exp -lt (Get-Date).ToUniversalTime().AddDays(-2)) { $exp = $exp.AddYears(1) }
Check '/usage fallback: reset "Dec 30, 6:59pm" read as local time' ($u.json.weekly.resets_at -eq $exp.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")) $u.json.weekly.resets_at
$u2 = Run @('-TestHttpStatus', '429', '-Force') $cfg $fakeUsage
Check '/usage fallback: reading reused for 3 min (CLI not run again)' ($u2.json.source -eq 'cli' -and $u2.diag -match 'cli=reused') $u2.diag
Remove-Item (Join-Path $Root 'cache\collector-state.json') -Force
$u3 = Run @('-TestHttpStatus', '503', '-Force', '-TestNowUnix', ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 400)) $cfg $fakeFail
Check '/usage fallback: unreadable CLI output -> last reading shown stale' ($u3.code -eq 2 -and $u3.json.stale -eq $true -and $u3.diag -match 'cli=unparsed') $u3.diag
# QA-04 regression: during a 5xx backoff the /usage fallback is used, like during a 429 backoff
$q4a = Run @('-TestHttpStatus', '503', '-Force') $cfg $fakeUsage
$q4 = Run @('-TestNowUnix', [string]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 100)) $cfg $fakeUsage   # cache expired, backoff still on
Check 'QA-04: 5xx backoff -> reading from Claude Code /usage, not stale' ($q4.json.source -eq 'cli' -and $q4.json.stale -eq $false -and $q4.diag -match 'backoff' -and $q4.json.notice -match 'unavailable') "$($q4a.diag) || $($q4.diag) | $($q4.json.source)"
$u4 = Run @('-TestHttpStatus', '429', '-Force', '-NoRenew') $cfg $fakeUsage
Check '-NoRenew also disables the /usage fallback' ($u4.json.source -ne 'cli') $u4.diag

# ---- settings
$sd = ConvertTo-Settings $null 120
Check 'settings: defaults (2 min, countdown pill, no details, alerts at 25/10, every taskbar)' ($sd.poll -eq 120 -and $sd.pill -eq 'countdown' -and -not $sd.details -and $sd.alerts -and (@($sd.alert_at) -join ',') -eq '25,10' -and $sd.all_taskbars -and -not $sd.compact) ''
$sj = '{"placement":"manual","x":5,"y":6,"poll":7,"pill":"nonsense","compact":true,"alerts":false,"alert_at":[],"alert_runout":false,"all_taskbars":false}' | ConvertFrom-Json
$sv = ConvertTo-Settings $sj 120
Check 'settings: invalid values fall back; empty threshold list stays empty' ($sv.placement -eq 'manual' -and $sv.x -eq 5 -and $sv.poll -eq 120 -and $sv.pill -eq 'countdown' -and $sv.compact -and -not $sv.alerts -and @($sv.alert_at).Count -eq 0 -and -not $sv.all_taskbars) (@($sv.alert_at).Count)

$sm1 = ConvertTo-Settings ('{"pill":"budget","details":true}' | ConvertFrom-Json) 60
$sm2 = ConvertTo-Settings ('{"v":2,"pill":"budget"}' | ConvertFrom-Json) 60
Check 'settings: pre-v2 file moves to the countdown pill; a v2 choice of budget stays; details persists' ($sm1.pill -eq 'countdown' -and $sm1.details -and $sm2.pill -eq 'budget') "$($sm1.pill) $($sm2.pill)"
# QA-01 regression: damaged settings values never stop the widget from starting
$bad = $null; $bs = $null
try { $bs = ConvertTo-Settings ('{"placement":"manual","x":"abc","y":5,"poll":"abc","v":"abc","pill":"budget","alert_at":["abc",25,"10"]}' | ConvertFrom-Json) 60 $nowP } catch { $bad = $_.Exception.Message }
Check 'QA-01: text where numbers belong -> defaults, no exception' ($null -eq $bad -and $bs.placement -eq 'auto' -and $bs.poll -eq 60 -and $bs.pill -eq 'countdown' -and (@($bs.alert_at) -join ',') -eq '25,10') "$bad"
$bad2 = $null; try { $bs2 = ConvertTo-Settings ('{"snooze_until":1e30,"x":1e300,"y":1,"placement":"manual"}' | ConvertFrom-Json) 60 $nowP; $f2 = Format-SnoozeEnd $bs2.snooze_until $nowP } catch { $bad2 = $_.Exception.Message }
Check 'QA-01: far-future snooze / huge position -> ignored, no exception' ($null -eq $bad2 -and $bs2.snooze_until -eq 0 -and $bs2.placement -eq 'auto') "$bad2"
Check 'QA-01: JSON that is not an object (array root) -> defaults' ((ConvertTo-Settings ('[1,2]' | ConvertFrom-Json) 60 $nowP).poll -eq 60) ''
# Invoke-Alerts: an alert Windows refused is not marked as shown; it is retried after 15 minutes
function Show-Toast { param($Title, $Text) $script:ToastCalls++; return $script:ToastOk }
function Get-WindowSamples { param($Key) return @() }
function Save-AlertsSent { $script:AlertSaves++ }
$script:Settings = ConvertTo-Settings $null 60; $script:ProductName = 'Claude'; $script:AlertsSent = @{}; $script:AlertRetryAt = @{}
$script:ToastCalls = 0; $script:AlertSaves = 0; $script:ToastOk = $false
$iaData = [pscustomobject]@{ stale = $false; weekly = [pscustomobject]@{ used = 95; window_seconds = 604800; resets_at = [DateTime]::UtcNow.AddHours(30).ToString('o') }; session = $null }
Invoke-Alerts $iaData; $iaFirst = $script:ToastCalls; Invoke-Alerts $iaData
Check 'alerts: a refused toast stays due (not marked shown) and is not retried within 15 min' ($iaFirst -ge 1 -and $script:AlertsSent.Count -eq 0 -and $script:ToastCalls -eq $iaFirst -and $script:AlertSaves -eq 0) "calls=$($script:ToastCalls) sent=$($script:AlertsSent.Count)"
$script:AlertRetryAt = @{}; $script:ToastOk = $true
Invoke-Alerts $iaData
Check 'alerts: once Windows shows it, the alert is recorded and saved' ($script:AlertsSent.Count -ge 1 -and $script:ToastCalls -eq 2 * $iaFirst -and $script:AlertSaves -eq 1) "calls=$($script:ToastCalls) sent=$($script:AlertsSent.Count)"
# ---- alerts
$aset = ConvertTo-Settings $null 60
$rk = [long][Math]::Round($rU / 3600.0)
$dat = { param($u, $su = $null, [bool]$stale = $false) [pscustomobject]@{ stale = $stale; weekly = [pscustomobject]@{ used = $u; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }; session = $(if ($null -ne $su) { [pscustomobject]@{ used = $su; window_seconds = 18000; resets_at = '2026-11-12T02:00:00Z' } } else { $null }) } }
$sent = @{}
$a1 = @(Get-AlertsDue (& $dat 89) $null $aset $sent 'Claude' $nowP)
Check 'alerts: 11% left -> one alert, marks the 25% threshold' ($a1.Count -eq 1 -and $a1[0].title -eq 'Claude: 89% of the weekly limit used' -and (@($a1[0].keys) -join ',') -eq "w:$rk`:25") "$($a1[0].title) | $($a1[0].keys -join ',')"
foreach ($k in $a1[0].keys) { $sent[$k] = 1 }
Check 'alerts: same level again -> nothing' (@(Get-AlertsDue (& $dat 89.5) $null $aset $sent 'Claude' $nowP).Count -eq 0) ''
$a2 = @(Get-AlertsDue (& $dat 92) $null $aset $sent 'Claude' $nowP)
Check 'alerts: crossing 10% -> one more alert' ($a2.Count -eq 1 -and $a2[0].title -match ': 92% of the weekly limit used' -and (@($a2[0].keys) -contains "w:$rk`:10")) ($a2 | ForEach-Object { $_.title })
$a3 = @(Get-AlertsDue (& $dat 95) $null $aset @{} 'Claude' $nowP)
Check 'alerts: first reading already below 10% -> a single alert, both thresholds marked' ($a3.Count -eq 1 -and @($a3[0].keys).Count -eq 2) ($a3[0].keys -join ',')
$fastP = Get-PaceInfo ([pscustomobject]@{ used = 60; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }) @() $nowP
$a4 = @(Get-AlertsDue (& $dat 60) $fastP $aset @{} 'Claude' $nowP)
Check 'alerts: on track to run out early (28 h before reset) -> run-out alert' ($a4.Count -eq 1 -and $a4[0].title -eq 'Claude: on track to run out early' -and $a4[0].text -match 'about 11% a day') "$($a4[0].title) | $($a4[0].text)"
$a5 = @(Get-AlertsDue (& $dat 20 92) $null $aset @{} 'Claude' $nowP)
Check 'alerts: 5-hour window at 8% left -> alert' ($a5.Count -eq 1 -and $a5[0].title -match '5-hour limit almost used \(92% used\)') ($a5 | ForEach-Object { $_.title })
$aoff = ConvertTo-Settings ('{"alerts":false}' | ConvertFrom-Json) 60
# #36 regression: the reported reset drifting across :30 is still the same window (no second alert)
$datR = { param($u, $reset) [pscustomobject]@{ stale = $false; weekly = [pscustomobject]@{ used = $u; window_seconds = 604800; resets_at = $reset }; session = $null } }
$dr1 = @(Get-AlertsDue (& $datR 89.5 '2026-11-15T12:35:00Z') $null $aset $sent 'Claude' $nowP)
$dr2 = @(Get-AlertsDue (& $datR 89.5 '2026-11-15T11:25:00Z') $null $aset $sent 'Claude' $nowP)
Check '#36: reset drifting 35 min later or earlier -> no repeat alert' ($dr1.Count -eq 0 -and $dr2.Count -eq 0) (($dr1 + $dr2) | ForEach-Object { $_.title })
$dr3 = @(Get-AlertsDue (& $datR 89 '2026-11-22T12:00:00Z') $null $aset $sent 'Claude' $nowP)
Check '#36: the next window still alerts' ($dr3.Count -eq 1) ''
Check '#36: Test-AlertSent matches only the neighbouring hours' ((Test-AlertSent @{ 's:100' = 1 } 's' 101) -and (Test-AlertSent @{ 's:100' = 1 } 's' 99) -and -not (Test-AlertSent @{ 's:100' = 1 } 's' 102) -and -not (Test-AlertSent @{ 'w:100:25' = 1 } 'w' 100 ':10')) ''
# #29 regression: a damaged alerts.json never stops the widget from starting
$script:AlertsPath = Join-Path $Root 'alerts.json'
[IO.File]::WriteAllText($script:AlertsPath, '{"w:1:25":"abc","w:1:10":1795000000,"s:2":null,"s:3":[1,2]}', $utf8)
$as1 = $null; $ase = $null; try { $as1 = Read-AlertsSent } catch { $ase = $_.Exception.Message }
Check '#29: bad values in alerts.json skipped, valid ones kept' ($null -eq $ase -and $as1.Count -eq 1 -and $as1['w:1:10'] -eq 1795000000) "$ase $($as1.Keys -join ',')"
[IO.File]::WriteAllText($script:AlertsPath, '[1,2]', $utf8)
$as2 = $null; $ase = $null; try { $as2 = Read-AlertsSent } catch { $ase = $_.Exception.Message }
Check '#29: alerts.json that is not an object -> empty set, no error' ($null -eq $ase -and $as2 -is [hashtable] -and $as2.Count -eq 0) $ase
# #32 regression: a saved or computed position is pulled back onto its monitor
$cp1 = Get-ClampedPosition 3000 900 160 40 0 0 1920 1080
$cp2 = Get-ClampedPosition -200 -50 160 40 0 0 1920 1080
$cp3 = Get-ClampedPosition 100 200 160 40 0 0 1920 1080
$cp4 = Get-ClampedPosition 5000 5000 160 40 0 0 0 0
Check '#32: off-screen pill clamped onto the monitor; inside or unknown monitor unchanged' ($cp1.x -eq 1760 -and $cp1.y -eq 900 -and $cp2.x -eq 0 -and $cp2.y -eq 0 -and $cp3.x -eq 100 -and $cp3.y -eq 200 -and $cp4.x -eq 5000) "$($cp1.x),$($cp1.y) $($cp2.x),$($cp2.y)"
Check 'alerts: off, or stale data -> nothing' (@(Get-AlertsDue (& $dat 95) $fastP $aoff @{} 'Claude' $nowP).Count -eq 0 -and @(Get-AlertsDue (& $dat 95 95 $true) $fastP $aset @{} 'Claude' $nowP).Count -eq 0) ''

# ---- today's budget (local midnight baseline)
$nowL = (Get-Date).Date.AddHours(15)
$nowB = $nowL.ToUniversalTime()
$resetB = $nowB.AddHours(84)
$rUB = ConvertTo-Unix $resetB
$midUB = ConvertTo-Unix ((Get-Date).Date.ToUniversalTime())
$wb = [pscustomobject]@{ used = 46; window_seconds = 604800; resets_at = $resetB.ToString('o') }
$b1 = Get-DailyBudget $wb @(@{ t = $midUB - 3600; u = 40; r = $rUB }, @{ t = $midUB + 3600; u = 42; r = $rUB }) $nowB
$expBudget = 60 / ((84 + 15) / 24.0)
Check 'budget: 60% left at midnight over 4.1 days = 14.5%/day; 6% used today' ($null -ne $b1 -and [Math]::Abs($b1.budget - $expBudget) -lt 1e-6 -and [Math]::Abs($b1.used_today - 6) -lt 1e-9 -and -not $b1.over) "$($b1.budget) $($b1.used_today)"
Check 'budget: no reading near midnight -> none (pill falls back to the countdown)' ($null -eq (Get-DailyBudget $wb @(@{ t = $midUB + 5 * 3600; u = 44; r = $rUB }) $nowB)) ''
$b2 = Get-DailyBudget ([pscustomobject]@{ used = 80; window_seconds = 604800; resets_at = $resetB.ToString('o') }) @(@{ t = $midUB - 60; u = 40; r = $rUB }) $nowB
Check 'budget: 40% used today -> over budget' ($b2.over) "$($b2.used_today) of $($b2.budget)"
$pvB = Get-PaceView (Get-PaceInfo $wb @() $nowB) $null $nowB $b1
Check 'view: today line in the pace box' (($pvB.lines -join ' ') -match 'Today: 6% used of a 15% daily budget\.') ($pvB.lines -join ' || ')

# ---- chart geometry (286 x 58, half-way through the week, 60% used, running out)
$g = Get-ChartGeometry $wk @(@{ t = $nU - 4 * 3600; u = 56; r = $rU }) $fastP $nowP 286 58
Check 'chart: starts at 0% at the window start, ends at now (x=143, y=23.2)' ($g.actual[0][0] -eq 0 -and $g.actual[0][1] -eq 58 -and $g.now[0] -eq 143 -and $g.now[1] -eq 23.2 -and @($g.actual).Count -eq 3) (($g.actual | ForEach-Object { "($($_[0]),$($_[1]))" }) -join ' ')
Check 'chart: even pace diagonal and a forecast to 100% at run-out' ($g.even[1][0] -eq 286 -and $g.even[1][1] -eq 0 -and $g.forecast[1][1] -eq 0 -and $g.forecast[1][0] -lt 286 -and $g.runs_out) (($g.forecast | ForEach-Object { "($($_[0]),$($_[1]))" }) -join ' ')

# ---- trends (per-model 24 h change, credit spend)
$tr = Get-Trend @(@{ t = $nU - 30 * 3600; u = 5; r = $rU }, @{ t = $nU - 20 * 3600; u = 10; r = $rU }, @{ t = $nU - 2 * 3600; u = 15; r = $rU }) 18 $nU 24 6 $rU
Check 'trend: +8 pts vs the oldest reading 6-24 h old' ([Math]::Abs($tr.delta - 8) -lt 1e-9 -and [Math]::Abs($tr.hours - 20) -lt 1e-9) "$($tr.delta) $($tr.hours)"
$tc = Get-Trend @(@{ t = $nU - 72 * 3600; v = 63750 }, @{ t = $nU - 3600; v = 62600 }) 62500 $nU 168 12
Check 'trend: credits spent over 3 days = -1,250' ($tc.delta -eq -1250) $tc.delta
$hm = New-History
$dm = [pscustomobject]@{ stale = $false; fetched_at = '2026-11-12T00:00:00Z'; weekly = $wk; session = $null; scoped = @([pscustomobject]@{ id = 'seven_day_fable'; name = 'Fable'; used = 2; window_seconds = 604800; resets_at = '2026-11-15T12:00:00Z' }); credits = [pscustomobject]@{ balance = 62500 }; extra_usage = $null }
[void](Add-HistorySample $hm $dm)
$hp2 = Join-Path $Root 'history2.json'
[IO.File]::WriteAllText($hp2, (ConvertTo-HistoryJson $hm $nU))
$hm2 = Read-History $hp2
Check 'history v2: per-model and credit series round-trip' ($hm2.m['seven_day_fable'].Count -eq 1 -and $hm2.m['seven_day_fable'][0].u -eq 2 -and $hm2.c.Count -eq 1 -and $hm2.c[0].v -eq 62500 -and $hm2.w.Count -eq 1) ([IO.File]::ReadAllText($hp2))
Check 'history v1 files still load' ((Read-History $hp).w.Count -ge 0) ''

# ---- alert snooze
$sz = ConvertTo-Settings $null 60
$sz.snooze_until = $nU + 3600
Check 'snooze: due alerts are held while snoozed' (@(Get-AlertsDue (& $dat 95) $fastP $sz @{} 'Claude' $nowP).Count -eq 0 -and (Test-Snoozed $sz $nowP)) ''
$sz.snooze_until = $nU - 1
Check 'snooze: once it ends the held alert shows' (@(Get-AlertsDue (& $dat 95) $fastP $sz @{} 'Claude' $nowP).Count -ge 1 -and -not (Test-Snoozed $sz $nowP)) ''
Check 'snooze: 1 hour = now + 3600 s' ((Get-SnoozeUntil '1h' $null $nowP) -eq $nU + 3600) ''
$mo = [DateTimeOffset]::FromUnixTimeSeconds([long](Get-SnoozeUntil 'morning' $null $nowP)).LocalDateTime
Check 'snooze: "tomorrow morning" ends at 08:00 local, in the future, within 1 day 8 h' ($mo.Hour -eq 8 -and $mo.Minute -eq 0 -and $mo -gt $nowP.ToLocalTime() -and ($mo - $nowP.ToLocalTime()).TotalHours -le 32) $mo
Check 'snooze: "until the weekly reset" = reset time; unknown reset -> not offered' ((Get-SnoozeUntil 'reset' $wk $nowP) -eq $rU -and $null -eq (Get-SnoozeUntil 'reset' $null $nowP)) ''
Check 'snooze: resume = 0' ((Get-SnoozeUntil 'off' $null $nowP) -eq 0) ''
$sj2 = ConvertTo-Settings ('{"snooze_until":1795000000}' | ConvertFrom-Json) 60 $nowP
Check 'snooze: saved end time survives a restart' ($sj2.snooze_until -eq 1795000000) $sj2.snooze_until
# ---- sign in again
$script:ProductKey = 'claude'
$si = Find-SignInCli
$expected = Test-Path (Join-Path $env:USERPROFILE '.local\bin\claude.exe')
Check 'sign in: Claude uses the official CLI "auth login"' ((-not $expected) -or ($si.args -eq 'auth login' -and $si.exe -like '*claude.exe')) "$($si.exe) $($si.args)"

# ---- watchdog (#23): a widget that died or hung comes back; never after Exit, Start with Windows off or uninstall
$src = [IO.File]::ReadAllText($Widget)
$wdAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Dir 'watchdog.ps1'), [ref]$tok, [ref]$err)
foreach ($f in $wdAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WatchdogAction' }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$ok = @{ Installed = $true; StartupOn = $true; ExitedByUser = $false; Running = $true; HeartbeatAge = 20; Responding = $true; WasStale = $false }
function Wd($over) { $a = $ok.Clone(); foreach ($k in $over.Keys) { $a[$k] = $over[$k] }; (Get-WatchdogAction @a).action }
Check 'watchdog: widget gone -> start it' ((Wd @{ Running = $false }) -eq 'start') (Wd @{ Running = $false })
Check 'watchdog: healthy widget -> nothing' ((Wd @{}) -eq 'none') (Wd @{})
Check 'watchdog: after Exit -> stays closed' ((Wd @{ Running = $false; ExitedByUser = $true }) -eq 'none') ''
Check 'watchdog: Start with Windows off -> stays closed' ((Wd @{ Running = $false; StartupOn = $false }) -eq 'none') ''
Check 'watchdog: uninstalled -> nothing' ((Wd @{ Running = $false; Installed = $false }) -eq 'none') ''
Check 'watchdog: stale heartbeat once after sleep, responding -> wait (no restart)' ((Wd @{ HeartbeatAge = 3600 }) -eq 'none' -and (& { $a = $ok.Clone(); $a.HeartbeatAge = 3600; (Get-WatchdogAction @a).stale })) ''
Check 'watchdog: stale twice in a row -> replace' ((Wd @{ HeartbeatAge = 600; WasStale = $true }) -eq 'replace') ''
Check 'watchdog: stale and not responding -> replace' ((Wd @{ HeartbeatAge = 600; Responding = $false }) -eq 'replace') ''
Check 'watchdog: not responding but heartbeat fresh -> nothing' ((Wd @{ Responding = $false }) -eq 'none') ''
Check 'widget: Exit leaves the marker, start clears it, UI writes a heartbeat' ($src -match '(?s)function Stop-Widget \{.*?ExitMarkerPath.*?\n\}' -and $src -match 'Remove-Item -LiteralPath \$script:ExitMarkerPath' -and $src -match '(?s)RenderTimer\.add_Tick\(\{.*?Write-Heartbeat') ''
Check 'widget: collector timeout also covers an exited collector whose output pipe is still held' ($src -match 'if \(-not \$p\.HasExited -or -not \$script:ProcOut\.IsCompleted\)') ''

# ---- collector timeout stops the whole process tree (#23), including children left by an exited collector
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-ProcessTree' }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$ps = Join-Path $PSHOME 'powershell.exe'
function Get-Children([int]$id) { @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $id" -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.ProcessId }) }
function Start-Tree([int]$parentSeconds) {
    $p = Start-Process -FilePath $ps -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command', "Start-Process -FilePath '$ps' -WindowStyle Hidden -ArgumentList '-NoProfile','-Command','Start-Sleep 90'; Start-Sleep $parentSeconds")
    $kids = @(); $deadline = [DateTime]::UtcNow.AddSeconds(20)
    while ($kids.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 300; $kids = Get-Children $p.Id }
    return @{ root = $p; kids = $kids }
}
$t1 = Start-Tree 90
$n1 = Stop-ProcessTree $t1.root.Id; Start-Sleep -Milliseconds 700
$alive1 = @(@($t1.root.Id) + $t1.kids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
Check 'collector timeout: parent and child both stopped' ($t1.kids.Count -ge 1 -and $n1 -ge 2 -and $alive1.Count -eq 0) "kids=$($t1.kids -join ',') stopped=$n1 alive=$($alive1 -join ',')"
$t2 = Start-Tree 2
[void]$t2.root.WaitForExit(15000)
$n2 = Stop-ProcessTree $t2.root.Id -SkipRoot; Start-Sleep -Milliseconds 700
$alive2 = @($t2.kids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
Check 'collector timeout: child left by an exited collector stopped' ($t2.kids.Count -ge 1 -and $t2.root.HasExited -and $alive2.Count -eq 0) "kids=$($t2.kids -join ',') alive=$($alive2 -join ',')"
foreach ($id in @($t1.kids + $t2.kids)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }

# #35 regression: a collector's CLI timeout ends the CLI and every child it started (Claude and Codex collectors)
foreach ($cp in @($Collector, (Join-Path (Split-Path $Dir) 'codex-usage-widget\codex-usage.ps1'))) {
    $cAst = [System.Management.Automation.Language.Parser]::ParseFile($cp, [ref]$tok, [ref]$err)
    foreach ($f in $cAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-TreeKill' }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
    $t3 = Start-Tree 90
    Invoke-TreeKill $t3.root; Start-Sleep -Milliseconds 700
    $alive3 = @(@($t3.root.Id) + $t3.kids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    Check ('#35: {0} timeout ends the CLI and its children' -f (Split-Path -Leaf $cp)) ($t3.kids.Count -ge 1 -and $alive3.Count -eq 0) "kids=$($t3.kids -join ',') alive=$($alive3 -join ',')"
    foreach ($id in $t3.kids) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Remove-Item function:Invoke-TreeKill -ErrorAction SilentlyContinue
}

# ---- QA bug hunt 2026-11-16 (#30, #31, #35, #37, #38): code paths that need Windows, checked in the source
$colSrc = [IO.File]::ReadAllText($Collector)
$cxSrc = [IO.File]::ReadAllText((Join-Path (Split-Path $Dir) 'codex-usage-widget\codex-usage.ps1'))
$insSrc = [IO.File]::ReadAllText((Join-Path $Dir 'install.ps1')); $unSrc = [IO.File]::ReadAllText((Join-Path $Dir 'uninstall.ps1')); $wdSrc = [IO.File]::ReadAllText((Join-Path $Dir 'watchdog.ps1'))
Check '#35: collectors end the whole CLI tree on timeout (taskkill /T)' ($colSrc -match 'Invoke-TreeKill \$p' -and $colSrc -match '/T /F /PID' -and $cxSrc -match 'WaitForExit\(3000\)\) \{ Invoke-TreeKill \$p' -and $cxSrc -match '/T /F /PID') ''
Check '#35: widget tick error stops the collector tree (Reset-Refresh)' ($src -match '(?s)function Reset-Refresh \{.*?Stop-ProcessTree' -and $src -match 'catch \{[^}]*Reset-Refresh') ''
Check '#35: watchdog replace ends each widget tree' ($wdSrc -match '/T /F /PID') ''
Check '#37: lost mouse capture ends a drag (LostMouseCapture -> Complete-Drag)' ($src -match '(?s)add_LostMouseCapture\(\{.*?Complete-Drag') ''
Check '#30: reinstall keeps Start with Windows off' ($insSrc -match '\$HadShortcut\s*=\s*Test-Path' -and $insSrc -match 'if \(\$WasInstalled -and -not \$HadShortcut\)') ''
Check '#31: uninstaller task may start on battery' ($unSrc -match 'Register-ScheduledTask[^\n]*-Settings \$settings' -and $unSrc -match 'AllowStartIfOnBatteries') ''
# #38 regression: a failed process query never starts a second widget
foreach ($f in $wdAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Invoke-Watchdog', 'Write-WatchdogLog' }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$saveAppDir = $script:AppDir; $saveLad = $env:LOCALAPPDATA
$wdLad = Join-Path $Root 'wd-lad'; [void](New-Item -ItemType Directory -Path (Join-Path $wdLad 'ClaudeUsageWidget') -Force)
[IO.File]::WriteAllText((Join-Path $wdLad 'ClaudeUsageWidget\claude-usage-widget.ps1'), '#', $utf8)
$script:AppName = 'ClaudeUsageWidget'; $script:WidgetFile = 'claude-usage-widget.ps1'; $script:ProductName = 'Claude'; $script:StaleSeconds = 180
$script:WdStarts = 0
function Get-CimInstance { throw 'WMI is not available (simulated)' }
function Start-Process { $script:WdStarts++ }
try { $env:LOCALAPPDATA = $wdLad; Invoke-Watchdog } finally { $env:LOCALAPPDATA = $saveLad; Remove-Item function:Get-CimInstance, function:Start-Process; $script:AppDir = $saveAppDir }
$wdLog = Join-Path $wdLad 'ClaudeUsageWidget\watchdog.log'
Check '#38: watchdog process query failed -> no start, logged, no state change' ($script:WdStarts -eq 0 -and (Test-Path $wdLog) -and ([IO.File]::ReadAllText($wdLog) -match 'skipped this check') -and -not (Test-Path (Join-Path $wdLad 'ClaudeUsageWidget\watchdog-state'))) "starts=$($script:WdStarts)"

# ---- pills stay visible over shell overlays (#24)
foreach ($fn in 'Initialize-Native') { foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) } }
Initialize-Native
Check 'full screen: Start, Search, Task View and Alt+Tab never hide the pills' ([UsageWidget.Native]::IsShellSurface('Windows.UI.Core.CoreWindow', 'SearchHost') -and [UsageWidget.Native]::IsShellSurface('Windows.UI.Core.CoreWindow', 'StartMenuExperienceHost') -and [UsageWidget.Native]::IsShellSurface('XamlExplorerHostIslandWindow', 'explorer') -and [UsageWidget.Native]::IsShellSurface('MultitaskingViewFrame', '')) ''
Check 'full screen: a game, video or the lock screen still hides them' (-not [UsageWidget.Native]::IsShellSurface('UnityWndClass', 'game') -and -not [UsageWidget.Native]::IsShellSurface('Chrome_WidgetWin_1', 'chrome') -and -not [UsageWidget.Native]::IsShellSurface('Windows.UI.Core.CoreWindow', 'LockApp')) ''

$results | Format-Table -AutoSize -Wrap | Out-String -Width 220
"PASS={0} FAIL={1}" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
