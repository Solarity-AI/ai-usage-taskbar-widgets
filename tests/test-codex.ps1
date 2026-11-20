# SIMULATED regression tests for the Codex widget fixes. Fake CODEX_HOME with placeholder values; no network.
param([string]$Dir, [string]$Root)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
# Reset times relative to now: fixed timestamps went stale on 2026-11-18 and dropped the 5-hour window (#52).
$rWeek = [string][DateTimeOffset]::UtcNow.AddDays(5).ToUnixTimeSeconds(); $rSession = [string][DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds()
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
$ch = Join-Path $Root 'codex-home'; [void](New-Item -ItemType Directory -Path $ch -Force)
[IO.File]::WriteAllText((Join-Path $ch 'auth.json'), '{"auth_mode":"chatgpt","tokens":{"access_token":"fixture-not-a-real-token","account_id":"fixture-acct"}}', $utf8)
$resp = Join-Path $Root 'resp.json'
[IO.File]::WriteAllText($resp, '{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":85,"limit_window_seconds":604800,"reset_at":1795057181}},"credits":{"balance":62500}}'.Replace('1795057181', $rWeek), $utf8)
$cache = Join-Path $Root 'cache\usage-cache.json'
$results = New-Object System.Collections.ArrayList
function Check($name, [bool]$ok, $detail) { [void]$results.Add([pscustomobject]@{ Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Check = $name; Detail = "$detail" }) }
function Run([string[]]$extra) {
    $env:CODEX_HOME = $ch
    # -NoCli: a live success also asks the CLI every 30 min, and on a dev PC that would start the real codex.exe (QA-07).
    $o = & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Dir 'codex-usage.ps1') -CachePath $cache -NoCli @extra
    $env:CODEX_HOME = $null
    return ($o | ConvertFrom-Json)
}
# Exit code, JSON and UTF-8 stderr, read the way the widget reads them.
function RunP([string]$home1, [string]$cachePath, [string[]]$extra) {
    $env:CODEX_HOME = $home1
    $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Diagnostics -CachePath "{1}" {2}' -f (Join-Path $Dir 'codex-usage.ps1'), $cachePath, ($extra -join ' '))
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
    $env:CODEX_HOME = $null
    $json = $null; try { $json = $o.Result | ConvertFrom-Json } catch { }
    [pscustomobject]@{ code = $p.ExitCode; json = $json; diag = $e.Result.Trim() }
}
$a = Run @('-TestResponseFile', $resp, '-Force'); Start-Sleep -Seconds 1
$b = Run @('-TestResponseFile', $resp, '-Force')
$stored = (Get-Content $cache -Raw | ConvertFrom-Json).observation.fetched_at
Check 'collector: 2nd cache write replaces atomically (no .tmp, newest kept)' ($stored -eq $b.fetched_at -and $a.fetched_at -ne $b.fetched_at -and @(Get-ChildItem (Split-Path $cache) -Filter '*.tmp').Count -eq 0) "a=$($a.fetched_at) b=$($b.fetched_at) stored=$stored"
Check 'collector: live result unchanged (85 used / 15 left)' ($b.weekly.used -eq 85 -and $b.weekly.left -eq 15 -and $b.credits.balance -eq 62500) ''
$c = Run @('-TestHttpStatus', '429', '-Force')
$st = Get-Content (Join-Path $Root 'cache\collector-state.json') -Raw | ConvertFrom-Json
Check 'collector: 429 -> stale cache + backoff saved, next try shown' ($c.error.code -eq 'http_429' -and $c.stale -eq $true -and $st.backoff_count -eq 1 -and $c.error.message -match 'next try at') $c.error.message
$d = Run @('-TestResponseFile', $resp, '-TestNowUnix', ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 90))
Check 'collector: during backoff no call, last reading shown stale' ($d.stale -eq $true -and $d.error.message -match 'asked to slow down') $d.error.message
$e = Run @('-TestResponseFile', $resp, '-Force')
$st = Get-Content (Join-Path $Root 'cache\collector-state.json') -Raw | ConvertFrom-Json
Check 'collector: Refresh now ignores backoff; success clears it' ($e.source -eq 'live' -and $st.backoff_count -eq 0) ''

# Official Codex CLI (fake app-server answering the two JSON-RPC requests; never the real CLI here)
$jsonl = Join-Path $Root 'appserver.jsonl'
[IO.File]::WriteAllLines($jsonl, @(
    '{"id":1,"result":{"userAgent":"x"}}',
    '{"method":"account/updated","params":{"authMode":"chatgpt"}}',
    ('{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":91,"windowDurationMins":10080,"resetsAt":1795057181},"secondary":{"usedPercent":40,"windowDurationMins":300,"resetsAt":1795000000},"credits":{"hasCredits":true,"unlimited":false,"balance":"61000.5"},"planType":"pro","rateLimitReachedType":null},"rateLimitsByLimitId":{"codex":{"limitId":"codex"},"codex_other":{"limitId":"codex_other","limitName":"GPT-5 Pro","primary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1795057181}}},"rateLimitResetCredits":{"availableCount":2},"accountId":"fixture-acct"}}').Replace('1795057181', $rWeek).Replace('1795000000', $rSession)))
$calls = Join-Path $Root 'cli-calls.txt'
$fakeCli = Join-Path $Root 'fake-codex.cmd'
[IO.File]::WriteAllText($fakeCli, "@echo off`r`necho %*>>""$calls""`r`ntype ""$jsonl""`r`n")
function RunCli([string[]]$extra) {
    $env:CODEX_HOME = $ch
    $o = & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Dir 'codex-usage.ps1') -CachePath $cache -CodexCliPath $fakeCli @extra
    $env:CODEX_HOME = $null
    return ($o | ConvertFrom-Json)
}
Remove-Item (Join-Path $Root 'cache\collector-state.json') -Force
$f = RunCli @('-TestHttpStatus', '401', '-Force')
Check 'cli: 401 -> limits from the official CLI (fresh, verified, notice)' ($f.source -eq 'cli' -and $f.stale -eq $false -and $f.weekly.used -eq 91 -and $f.session.used -eq 40 -and $f.account_verified -eq $true -and $f.notice -match 'own CLI') "$($f.source) $($f.weekly.used) $($f.notice)"
Check 'cli: credits, plan, free resets, other model limit' ($f.credits.balance -eq 61000.5 -and $f.plan -eq 'pro' -and $f.reset_credits -eq 2 -and @($f.scoped).Count -eq 1 -and $f.scoped[0].name -eq 'GPT-5 Pro' -and $f.scoped[0].used -eq 12) ($f.scoped | ConvertTo-Json -Compress)
Check 'cli: app-server started once, no secrets in cache/state' (@(Get-Content $calls).Count -eq 1 -and (Get-Content $calls -Raw) -match 'app-server' -and -not (Get-Content $cache -Raw).Contains('fixture') -and -not (Get-Content (Join-Path $Root 'cache\collector-state.json') -Raw).Contains('fixture')) (Get-Content $calls -Raw)
$g = RunCli @('-TestResponseFile', $resp, '-Force')
Check 'cli: live call ok -> free-reset count added, CLI not asked again within 30 min' ($g.source -eq 'live' -and $g.reset_credits -eq 2 -and @(Get-Content $calls).Count -eq 1) "calls=$(@(Get-Content $calls).Count)"
Remove-Item (Join-Path $Root 'cache\collector-state.json') -Force
$h = RunCli @('-TestResponseFile', $resp, '-Force')
Check 'cli: every 30 min the live run also asks the CLI (free resets)' ($h.source -eq 'live' -and $h.weekly.used -eq 85 -and $h.reset_credits -eq 2 -and @(Get-Content $calls).Count -eq 2) "calls=$(@(Get-Content $calls).Count)"
$n = RunCli @('-TestHttpStatus', '401', '-Force', '-NoCli')
Check 'cli: -NoCli -> stale cache, CLI not run' ($n.source -eq 'cache' -and $n.stale -eq $true -and @(Get-Content $calls).Count -eq 2) $n.source
$env:CODEX_HOME = $ch
$m = & (Join-Path $PSHOME 'powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $Dir 'codex-usage.ps1') -CachePath $cache -CodexCliPath (Join-Path $Root 'nope.exe') -TestHttpStatus 401 -Force | ConvertFrom-Json
$env:CODEX_HOME = $null
Check 'cli: no CLI found -> last reading shown stale' ($m.source -eq 'cache' -and $m.stale -eq $true) $m.source

# QA bug hunt 2026-11-20 regressions (each failed before its fix)
$nope = Join-Path $Root 'nope.exe'
$stPath = Join-Path $Root 'cache\collector-state.json'
$nowU = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
[IO.File]::WriteAllText($stPath, ('{{"backoff_until":{0},"backoff_count":3,"backoff_code":"http_503","cli_at":{0},"cli_fail_at":{0}}}' -f ($nowU + 86400)), $utf8)
$x = RunP $ch $cache @('-NoCli', '-TestResponseFile', "`"$resp`"", '-TestNowUnix', ($nowU + 90))
Check 'QA-02 #90: back-off a day ahead (clock jumped back) is dropped, live read' ($x.code -eq 0 -and $x.json.source -eq 'live' -and $x.diag -match 'http_calls=1') $x.diag
[IO.File]::WriteAllText($stPath, '{"backoff_until":"soon","backoff_count":"many","cli_at":[1],"reset_credits":"x"}', $utf8)
$x = RunP $ch $cache @('-NoCli', '-TestResponseFile', "`"$resp`"", '-TestNowUnix', ($nowU + 200))
Check 'QA-02 #90: non-number state values keep defaults, no internal error' ($x.code -eq 0 -and $x.json.source -eq 'live') "$($x.code) $($x.json.error.code)"
[IO.File]::WriteAllText($stPath, '{"backoff_until": Gül_Şahin}', $utf8)
$x = RunP $ch $cache @('-NoCli', '-TestResponseFile', "`"$resp`"", '-TestNowUnix', ($nowU + 300))
Check 'QA-17 #105: warnings reach the widget as UTF-8 (non-ASCII kept)' ($x.code -eq 0 -and $x.diag.Contains('Gül_Şahin')) $x.diag
Remove-Item $stPath -Force
$big = Join-Path $Root 'resp-big.json'
[IO.File]::WriteAllText($big, ('{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":85,"limit_window_seconds":604800,"reset_at":R},"secondary_window":{"used_percent":5,"limit_window_seconds":1e30,"reset_at":R}}}').Replace('R', $rWeek), $utf8)
$x = RunP $ch $cache @('-NoCli', '-TestResponseFile', "`"$big`"", '-Force')
Check 'QA-18 #106: absurd window length is skipped, the rest is shown' ($x.code -eq 0 -and $x.json.weekly.used -eq 85) "$($x.code) $($x.json.error.code)"
$x = RunP '"C:\quoted\.codex"' (Join-Path $Root 'c19\usage-cache.json') @('-NoCli', '-Force')
Check 'QA-19 #107: invalid CODEX_HOME -> folder not found, not internal' ($x.code -eq 3 -and $x.json.error.code -eq 'codex_home_missing') "$($x.code) $($x.json.error.code)"
$ch6 = Join-Path $Root 'codex-home-null'; [void](New-Item -ItemType Directory -Path $ch6 -Force)
foreach ($body in @('', 'null', '[1,2]')) {
    [IO.File]::WriteAllText((Join-Path $ch6 'auth.json'), $body, $utf8)
    $x = RunP $ch6 (Join-Path $Root 'c06\usage-cache.json') @('-NoCli', '-Force')
    Check "QA-06 #94: auth.json '$body' -> unreadable, not another sign-in mode" ($x.code -eq 3 -and $x.json.error.code -eq 'auth_unreadable') "$($x.code) $($x.json.error.code)"
}
$ch5 = Join-Path $Root 'codex-home-noauth'; [void](New-Item -ItemType Directory -Path $ch5 -Force)
$c5 = Join-Path $Root 'c05\usage-cache.json'
$before = @(Get-Content $calls).Count
$x = RunP $ch5 $c5 @('-CodexCliPath', "`"$fakeCli`"", '-Force')
$y = RunP $ch5 $c5 @('-CodexCliPath', "`"$fakeCli`"")
Check 'QA-05 #93: no auth.json -> CLI reading reused from the 60 s cache' ($x.json.source -eq 'cli' -and $y.json.source -eq 'cache' -and $y.json.stale -eq $false -and @(Get-Content $calls).Count -eq $before + 1) "$($x.json.source) $($y.json.source) $($y.diag)"
$z = RunP $ch5 $c5 @('-CodexCliPath', "`"$nope`"", '-TestNowUnix', ($nowU + 120))
Check 'QA-05 #93: CLI then fails -> last reading shown stale, not sign in needed' ($z.code -eq 2 -and $z.json.source -eq 'cache' -and $z.json.stale -eq $true) "$($z.code) $($z.json.source) $($z.diag)"

$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Dir 'codex-usage-widget.ps1'), [ref]$tok, [ref]$err)
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Write-AtomicText', 'Write-FlushedText', 'Get-PillFitHeight' }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
foreach ($x in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in '$script:PillXaml', '$script:CardXaml', '$script:MenuXaml' }, $true)) { . ([scriptblock]::Create($x.Extent.Text)) }
$sf = Join-Path $Root 'settings.json'
Write-AtomicText $sf '{"x":1}'; Write-AtomicText $sf '{"x":2}'; Write-AtomicText $sf '{"x":3}'
Check 'widget: settings saved 3x, 3rd persisted, no .tmp' (([IO.File]::ReadAllText($sf)) -eq '{"x":3}' -and @(Get-ChildItem $Root -Filter 'settings.json.*.tmp').Count -eq 0) ([IO.File]::ReadAllText($sf))
Check 'widget: pill fits 40px taskbar @125%' ((Get-PillFitHeight 40 1.25) * 1.25 -le 38) (Get-PillFitHeight 40 1.25)
Add-Type -AssemblyName PresentationFramework
foreach ($nm in 'PillXaml', 'CardXaml') {
    $xml = (Get-Variable -Scope Script -Name $nm).Value
    try { $d0 = New-Object Xml.XmlDocument; $d0.LoadXml($xml); $w = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$xml))); Check "widget: $nm XML + WPF load" ($w.Title -like 'Usage*') $w.Title } catch { Check "widget: $nm XML + WPF load" $false $_.Exception.Message }
}
$pill = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$script:PillXaml)))
Check 'widget: pill fits its text from 88 DIP (same as Claude)' ($pill.FindName('Pill').MinWidth -eq 88 -and [double]::IsNaN($pill.FindName('Pill').Width)) $pill.FindName('Pill').MinWidth
try { $mn = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$script:MenuXaml))); Check 'widget: settings menu loads (29 named items)' ((@('MenuRefresh','MenuOpen','MenuPillBudget','MenuPillCountdown','MenuCompact','MenuPoll60','MenuPoll120','MenuPoll300','MenuPoll600','MenuAlertsOn','MenuAlert50','MenuAlert25','MenuAlert10','MenuAlert5','MenuAlertRunOut','MenuAlertTest','MenuAllBars','MenuReset','MenuStartup','MenuLog','MenuUninstall','MenuExit','MenuSignIn','MenuSnooze','MenuSnooze1h','MenuSnoozeMorning','MenuSnoozeReset','MenuSnoozeOff','MenuDetails') | Where-Object { $null -eq $mn.FindName($_) }).Count -eq 0) '' } catch { Check 'widget: settings menu loads' $false $_.Exception.Message }
$cl = [IO.File]::ReadAllText((Join-Path $Dir '..\claude-usage-widget\claude-usage-widget.ps1'))
$cx = [IO.File]::ReadAllText((Join-Path $Dir 'codex-usage-widget.ps1'))
$strip = { param($t) ([regex]'(?s)# >>> product.*?# <<< product').Replace($t, '', 1) -replace '(?m)^    (Claude|Codex) usage taskbar widget.*$', '' }
Check 'widget: Codex file == Claude file except the product block' ((& $strip $cl) -ceq (& $strip $cx)) ''
Check 'widget: Codex anchors to the Claude pill' ($cx -match "AnchorTitle   = 'Claude usage'" -and $cx -match "AppName       = 'CodexUsageWidget'") ''
$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"PASS={0} FAIL={1}" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
