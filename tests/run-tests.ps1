<#
.SYNOPSIS
    Runs every check: generated files up to date, then the Claude and Codex test suites.
.DESCRIPTION
    Simulated tests only: fake sign-in folders with placeholder values, fake CLIs, no network, nothing installed.
    Run it in Windows PowerShell 5.1 (it needs WPF):
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('usage-widget-tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$ps = Join-Path $PSHOME 'powershell.exe'
$fail = 0

& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\sync.ps1') -Check
if ($LASTEXITCODE -ne 0) { $fail++ }

$suites = @(
    @{ name = 'Claude'; file = 'test-claude.ps1'; dir = 'claude-usage-widget' },
    @{ name = 'Codex';  file = 'test-codex.ps1';  dir = 'codex-usage-widget' }
)
foreach ($s in $suites) {
    $out = & $ps -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $s.file) -Dir (Join-Path $root $s.dir) -Root (Join-Path $work $s.dir) 2>&1 | Out-String -Width 250
    $sum = [regex]::Match($out, 'PASS=(\d+) FAIL=(\d+)')
    if (-not $sum.Success) { Write-Host $out; Write-Host "FAIL $($s.name) suite did not finish"; $fail++; continue }
    ($out -split "`r?`n") | Where-Object { $_ -match '^FAIL\s' } | ForEach-Object { Write-Host $_.TrimEnd() }
    Write-Host ('{0,-7} {1} passed, {2} failed' -f $s.name, $sum.Groups[1].Value, $sum.Groups[2].Value)
    if ([int]$sum.Groups[2].Value -gt 0) { $fail++ }
}
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { Write-Host 'Some checks failed.'; exit 1 }
'All checks passed.'
