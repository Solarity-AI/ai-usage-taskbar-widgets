# SIMULATED tests for the Antigravity widget. Fake hub_<port>.json files with a placeholder CSRF token and a fake
# language server on 127.0.0.1 (a TcpListener in this process); no other network, never the real Antigravity.
param([string]$Dir, [string]$Root)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$dot = [string][char]0x00B7
if (Test-Path $Root) { Remove-Item $Root -Recurse -Force }
[void](New-Item -ItemType Directory -Path $Root -Force)
$results = New-Object System.Collections.ArrayList
function Check($name, [bool]$ok, $detail) { [void]$results.Add([pscustomobject]@{ Result = $(if ($ok) { 'PASS' } else { 'FAIL' }); Check = $name; Detail = "$detail" }) }

# Reset times relative to now, so the fixture never goes stale.
$rWeek = [DateTime]::UtcNow.AddDays(6).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); $rWeek3p = [DateTime]::UtcNow.AddDays(6).AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$r5h = [DateTime]::UtcNow.AddHours(4).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); $r5h3p = [DateTime]::UtcNow.AddHours(4).AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
$token = 'fixture-csrf-not-a-real-token-0123'
$body = Join-Path $Root 'quota.json'
$good = ('{"response":{"groups":[' +
    '{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.9595,"resetTime":"RW"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.8616,"resetTime":"R5"}]},' +
    '{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.75,"resetTime":"PW"},{"bucketId":"3p-5h","window":"5h","resetTime":"P5"}]}]}}').Replace('RW', $rWeek).Replace('R5', $r5h).Replace('PW', $rWeek3p).Replace('P5', $r5h3p)
[IO.File]::WriteAllText($body, $good, $utf8)
$reqLog = Join-Path $Root 'requests.log'

# Fake language server: answers RetrieveUserQuotaSummary with quota.json when the CSRF header matches, else 401.
# The log records what arrived (path, headers, body) but only whether the token matched, never the token.
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = $listener.LocalEndpoint.Port
$serve = {
    param($Listener, [string]$Token, [string]$BodyPath, [string]$LogPath)
    try {
        while ($true) {
            $c = $Listener.AcceptTcpClient()
            try {
                $s = $c.GetStream(); $s.ReadTimeout = 5000
                $ms = New-Object IO.MemoryStream; $buf = New-Object byte[] 8192; $text = ''
                do { $n = $s.Read($buf, 0, $buf.Length); $ms.Write($buf, 0, $n); $text = [Text.Encoding]::UTF8.GetString($ms.ToArray()) } while ($n -gt 0 -and $text.IndexOf("`r`n`r`n") -lt 0)
                $he = $text.IndexOf("`r`n`r`n")
                $head = $text.Substring(0, $he)
                $len = 0; if ($head -match '(?im)^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] }
                while ($ms.Length -lt $he + 4 + $len) { $n = $s.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $ms.Write($buf, 0, $n) }
                $all = [Text.Encoding]::UTF8.GetString($ms.ToArray())
                $reqBody = $all.Substring([Math]::Min($all.Length, $he + 4))
                $tokOk = ($head -match ('(?im)^X-Codeium-Csrf-Token: ' + [regex]::Escape($Token) + '\r?$'))
                $first = ($head -split "`r`n")[0]
                $ct = $(if ($head -match '(?im)^Content-Type:\s*(.+?)\r?$') { $Matches[1] } else { '' })
                $cp = $(if ($head -match '(?im)^Connect-Protocol-Version:\s*(.+?)\r?$') { $Matches[1] } else { '' })
                [IO.File]::AppendAllText($LogPath, ("{0}|token_ok={1}|ct={2}|cpv={3}|body={4}`n" -f $first, $tokOk, $ct, $cp, $reqBody))
                if ($tokOk -and $first -match '^POST /exa\.language_server_pb\.LanguageServerService/RetrieveUserQuotaSummary ') { $code = '200 OK'; $out = [IO.File]::ReadAllText($BodyPath) }
                else { $code = '401 Unauthorized'; $out = '{"code":"unauthenticated","message":"unauthenticated: invalid CSRF token"}' }
                $ob = [Text.Encoding]::UTF8.GetBytes($out)
                $hb = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $code`r`nContent-Type: application/json`r`nContent-Length: $($ob.Length)`r`nConnection: close`r`n`r`n")
                $s.Write($hb, 0, $hb.Length); $s.Write($ob, 0, $ob.Length); $s.Flush()
            } catch { } finally { $c.Close() }
        }
    } catch { }   # the listener was stopped
}
$ps = [PowerShell]::Create()
[void]$ps.AddScript($serve).AddArgument($listener).AddArgument($token).AddArgument($body).AddArgument($reqLog)
$async = $ps.BeginInvoke()

# A loopback port with nothing listening on it (the language server that wrote an old hub file is gone).
$t = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $t.Start(); $deadPort = $t.LocalEndpoint.Port; $t.Stop()

function New-Hub([string]$HubDir, [int]$HubPort, [string]$HubToken, [int]$AgeMinutes = 0) {
    if (-not (Test-Path $HubDir)) { [void](New-Item -ItemType Directory -Path $HubDir -Force) }
    $f = Join-Path $HubDir "hub_$HubPort.json"
    [IO.File]::WriteAllText($f, ('{{"pid":1,"httpsPort":{0},"httpPort":{1},"csrfToken":"{2}","lsVersion":"0.0.0-test"}}' -f ($HubPort - 1), $HubPort, $HubToken), $utf8)
    (Get-Item $f).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes)
}
# Exit code, JSON and UTF-8 stderr, read the way the widget reads them; the raw text too, for the token checks.
function RunP([string]$HubDir, [string]$CachePath, [string[]]$Extra) {
    $psi = New-Object Diagnostics.ProcessStartInfo (Join-Path $PSHOME 'powershell.exe'), ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Diagnostics -DaemonDir "{1}" -CachePath "{2}" {3}' -f (Join-Path $Dir 'antigravity-usage.ps1'), $HubDir, $CachePath, ($Extra -join ' '))
    $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    $p = [Diagnostics.Process]::Start($psi); $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync(); $p.WaitForExit()
    $json = $null; try { $json = $o.Result | ConvertFrom-Json } catch { }
    [pscustomobject]@{ code = $p.ExitCode; json = $json; out = $o.Result; diag = $e.Result.Trim(); lines = @($o.Result.Trim() -split "`n").Count }
}
$seen = New-Object System.Collections.ArrayList   # every stdout/stderr text, for the token check
function Keep($r) { [void]$seen.Add($r.out); [void]$seen.Add($r.diag); return $r }

try {
    # 1) normal reading: Gemini pool -> weekly/session, Claude and GPT pool -> 2 scoped rows
    $h1 = Join-Path $Root 'hub-good'; New-Hub $h1 $port $token
    $c1 = Join-Path $Root 'c1\usage-cache.json'
    $a = Keep (RunP $h1 $c1 @('-Force'))
    $j = $a.json
    Check 'live: exit 0, 1 JSON line, source live, status ok, not stale' ($a.code -eq 0 -and $a.lines -eq 1 -and $j.schema_version -eq 1 -and $j.source -eq 'live' -and $j.status -eq 'ok' -and $j.stale -eq $false -and $null -eq $j.error) "$($a.code) $($j.source) $($a.diag)"
    Check 'live: Gemini weekly -> weekly (used = (1 - remainingFraction) x 100)' ($j.weekly.used -eq 4.05 -and $j.weekly.left -eq 95.95 -and $j.weekly.window_seconds -eq 604800 -and $j.weekly.resets_at -eq $rWeek) ($j.weekly | ConvertTo-Json -Compress)
    Check 'live: Gemini 5 hours -> session' ($j.session.used -eq 13.84 -and $j.session.window_seconds -eq 18000 -and $j.session.resets_at -eq $r5h) ($j.session | ConvertTo-Json -Compress)
    $sw = @($j.scoped)[0]; $s5 = @($j.scoped)[1]
    Check 'live: Claude and GPT week -> scoped claude-gpt-weekly' (@($j.scoped).Count -eq 2 -and $sw.id -eq 'claude-gpt-weekly' -and $sw.name -eq "Claude and GPT $dot week" -and $sw.kind -eq 'weekly' -and $sw.used -eq 25 -and $sw.window_seconds -eq 604800 -and $sw.resets_at -eq $rWeek3p) ($sw | ConvertTo-Json -Compress)
    Check 'live: Claude and GPT 5 hours -> scoped claude-gpt-5h (no remainingFraction = all used)' ($s5.id -eq 'claude-gpt-5h' -and $s5.name -eq "Claude and GPT $dot 5 hours" -and $s5.kind -eq 'session' -and $s5.used -eq 100 -and $s5.left -eq 0 -and $s5.window_seconds -eq 18000 -and $s5.resets_at -eq $r5h3p) ($s5 | ConvertTo-Json -Compress)
    $log = @(Get-Content $reqLog)
    Check 'live: 1 POST to RetrieveUserQuotaSummary with the CSRF header, JSON body, Connect protocol 1' ($log.Count -eq 1 -and $log[0] -match '^POST /exa\.language_server_pb\.LanguageServerService/RetrieveUserQuotaSummary HTTP/1\.1\|token_ok=True\|ct=application/json\|cpv=1\|body=\{"metadata":\{"ideName":"antigravity"\}\}$') ($log -join ' / ')
    $b = Keep (RunP $h1 $c1 @())
    Check 'cache: a 2nd run within 60 s uses the saved reading, no call' ($b.code -eq 0 -and $b.json.source -eq 'cache' -and $b.json.stale -eq $false -and $b.diag -match 'http_calls=0' -and @(Get-Content $reqLog).Count -eq 1) $b.diag

    # 2) stale hub files next to a good one: a dead port and a restarted server's old token are tried first
    $h2 = Join-Path $Root 'hub-mixed'
    New-Hub $h2 $port $token 30
    New-Hub $h2 $deadPort 'fixture-old-token-of-a-closed-server' 0
    [IO.File]::WriteAllText((Join-Path $h2 'hub_1.json'), ('{"httpPort":' + $port + ',"csrfToken":"' + $token + '"'), $utf8)   # cut short: unreadable
    $c = Keep (RunP $h2 (Join-Path $Root 'c2\usage-cache.json') @('-Force'))
    Check 'stale hub: dead port tried first, then the good one answers' ($c.code -eq 0 -and $c.json.source -eq 'live' -and $c.json.weekly.used -eq 4.05 -and $c.diag -match 'http_calls=2' -and $c.diag -match 'hub_files=3') $c.diag
    Check 'stale hub: an unreadable hub file is named in a warning, nothing from inside it' ($c.diag -match 'warn: hub file hub_1\.json unreadable, skipped' -and -not $c.diag.Contains($token)) $c.diag
    $h3 = Join-Path $Root 'hub-oldtoken'
    New-Hub $h3 $port $token 30
    $f3 = Join-Path $h3 'hub_9.json'
    [IO.File]::WriteAllText($f3, ('{{"pid":1,"httpPort":{0},"csrfToken":"fixture-token-from-before-a-restart"}}' -f $port), $utf8)
    $d = Keep (RunP $h3 (Join-Path $Root 'c3\usage-cache.json') @('-Force'))
    Check 'stale hub: a 401 (old CSRF token) is skipped, never sign in needed' ($d.code -eq 0 -and $d.json.source -eq 'live' -and $d.diag -match 'http_calls=2' -and $null -eq $d.json.error) "$($d.code) $($d.diag)"

    # 3) Antigravity closed: no hub file answers
    $h4 = Join-Path $Root 'hub-closed'; New-Hub $h4 $deadPort $token
    $e = Keep (RunP $h4 (Join-Path $Root 'c4\usage-cache.json') @('-Force'))
    Check 'closed: no saved reading -> exit 3, antigravity_closed, source none' ($e.code -eq 3 -and $e.json.error.code -eq 'antigravity_closed' -and $e.json.source -eq 'none' -and $e.json.status -eq 'unavailable' -and $null -eq $e.json.weekly -and $e.json.schema_version -eq 1) "$($e.code) $($e.json.error.code)"
    $f = Keep (RunP $h4 $c1 @('-Force'))
    Check 'closed: saved reading -> exit 2, stale, antigravity_closed, both pools kept' ($f.code -eq 2 -and $f.json.stale -eq $true -and $f.json.status -eq 'stale' -and $f.json.source -eq 'cache' -and $f.json.error.code -eq 'antigravity_closed' -and $f.json.weekly.used -eq 4.05 -and @($f.json.scoped).Count -eq 2 -and @($f.json.scoped)[0].name -eq "Claude and GPT $dot week") "$($f.code) $($f.json.error.code)"
    $g = Keep (RunP (Join-Path $Root 'no-such-folder') (Join-Path $Root 'c5\usage-cache.json') @('-Force'))
    Check 'closed: no daemon folder (not installed or never opened) -> antigravity_closed' ($g.code -eq 3 -and $g.json.error.code -eq 'antigravity_closed' -and $g.json.error.message -match 'Install Antigravity') "$($g.code) $($g.json.error.code)"
    $later = [DateTimeOffset]::UtcNow.AddDays(8).ToUnixTimeSeconds()
    $k = Keep (RunP $h4 $c1 @('-Force', '-TestNowUnix', $later))
    Check 'closed: a saved reading past its resets is not shown as current' ($k.code -eq 2 -and $null -eq $k.json.weekly -and $null -eq $k.json.session -and @($k.json.scoped).Count -eq 0 -and @($k.json.reset_passed) -contains 'weekly' -and @($k.json.reset_passed) -contains 'scoped:claude-gpt-weekly') (@($k.json.reset_passed) -join ',')

    # 4) an answer without known limits; a server error
    [IO.File]::WriteAllText($body, '{"response":{"groups":[]}}', $utf8)
    $m = Keep (RunP $h1 (Join-Path $Root 'c6\usage-cache.json') @('-Force'))
    Check 'bad answer: no known limits -> bad_response, exit 3' ($m.code -eq 3 -and $m.json.error.code -eq 'bad_response') "$($m.code) $($m.json.error.code)"
    [IO.File]::WriteAllText($body, 'not json', $utf8)
    $n = Keep (RunP $h1 (Join-Path $Root 'c6\usage-cache.json') @('-Force'))
    Check 'bad answer: not JSON -> bad_response, exit 3' ($n.code -eq 3 -and $n.json.error.code -eq 'bad_response') "$($n.code) $($n.json.error.code)"
    [IO.File]::WriteAllText($body, $good, $utf8)

    # 5) the CSRF token never leaves the collector
    $cacheText = (Get-ChildItem $Root -Recurse -Filter 'usage-cache.json' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    $outText = $seen -join "`n"
    Check 'token: never on stdout or stderr (all runs), never in the cache' (-not $outText.Contains($token) -and -not $outText.Contains('fixture-old-token') -and -not $outText.Contains('fixture-token-from-before') -and -not $cacheText.Contains($token) -and $cacheText.Length -gt 0 -and -not $cacheText.Contains('csrf')) "out=$($outText.Length) chars, cache=$($cacheText.Length) chars"
    Check 'token: the request log saw the right token without recording it' (-not ([IO.File]::ReadAllText($reqLog)).Contains($token)) ''
} finally {
    $listener.Stop()
    try { [void]$ps.EndInvoke($async) } catch { }
    $ps.Dispose()
}

# ---- widget: generated from the Claude file, product block and the Antigravity branches of the shared code
$tok = $null; $err = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Dir 'antigravity-usage-widget.ps1'), [ref]$tok, [ref]$err)
foreach ($fn in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -in 'Get-WindowLabel', 'Get-NoReadingText', 'Find-SignInCli', 'Get-PillFitHeight' }, $true)) { . ([scriptblock]::Create($fn.Extent.Text)) }
foreach ($x in $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text -in '$script:PillXaml', '$script:CardXaml', '$script:MenuXaml', '$script:ProductKey', '$script:AnchorTitle' }, $true)) { . ([scriptblock]::Create($x.Extent.Text)) }
Check 'widget: rows read Gemini week / Gemini 5 hours / Claude and GPT week / Claude and GPT 5 hours' ((Get-WindowLabel 'weekly' $null 604800 $script:ProductKey) -eq "Gemini $dot week" -and (Get-WindowLabel 'session' $null 18000 $script:ProductKey) -eq "Gemini $dot 5 hours" -and (Get-WindowLabel 'weekly' "Claude and GPT $dot week" 604800 $script:ProductKey) -eq "Claude and GPT $dot week" -and (Get-WindowLabel 'session' "Claude and GPT $dot 5 hours" 18000 $script:ProductKey) -eq "Claude and GPT $dot 5 hours") $script:ProductKey
Check 'widget: closed -> pill says open Antigravity' ((Get-NoReadingText ([pscustomobject]@{ error = [pscustomobject]@{ code = 'antigravity_closed' } }) $null) -eq 'open Antigravity') ''
Check 'widget: no sign-in command for Antigravity (never runs codex login)' ($null -eq (Find-SignInCli)) ''
Check 'widget: anchors to the Codex pill, else the Claude pill' ((@($script:AnchorTitle) -join ',') -eq 'Codex usage,Claude usage') (@($script:AnchorTitle) -join ',')
Check 'widget: pill fits 40px taskbar @125%' ((Get-PillFitHeight 40 1.25) * 1.25 -le 38) (Get-PillFitHeight 40 1.25)
Add-Type -AssemblyName PresentationFramework
foreach ($nm in 'PillXaml', 'CardXaml') {
    $xml = (Get-Variable -Scope Script -Name $nm).Value
    try { $w = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$xml))); Check "widget: $nm XML + WPF load" ($w.Title -like 'Usage*') $w.Title } catch { Check "widget: $nm XML + WPF load" $false $_.Exception.Message }
}
try { $mn = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader ([xml]$script:MenuXaml))); Check 'widget: settings menu loads (MenuOpen, MenuSignIn kept)' ($null -ne $mn.FindName('MenuOpen') -and $null -ne $mn.FindName('MenuSignIn')) '' } catch { Check 'widget: settings menu loads' $false $_.Exception.Message }
$cl = [IO.File]::ReadAllText((Join-Path $Dir '..\claude-usage-widget\claude-usage-widget.ps1'))
$ag = [IO.File]::ReadAllText((Join-Path $Dir 'antigravity-usage-widget.ps1'))
$strip = { param($t) ([regex]'(?s)# >>> product.*?# <<< product').Replace($t, '', 1) -replace '(?m)^    (Claude|Antigravity) usage taskbar widget.*$', '' }
Check 'widget: Antigravity file == Claude file except the product block' ((& $strip $cl) -ceq (& $strip $ag)) ''
Check 'widget: product block names Antigravity' ($ag -match "AppName       = 'AntigravityUsageWidget'" -and $ag -match "CollectorName = 'antigravity-usage.ps1'" -and $ag -match "WindowTitle   = 'Antigravity usage'") ''
$inst = [IO.File]::ReadAllText((Join-Path $Dir 'install.ps1'))
Check 'install: installs the Antigravity files into AntigravityUsageWidget' ($inst -match "'antigravity-usage\.ps1', 'antigravity-usage-widget\.ps1'" -and $inst -match "LOCALAPPDATA 'AntigravityUsageWidget'" -and $inst -cnotmatch 'Claude|claude|Codex widget') ''
$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"PASS={0} FAIL={1}" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
