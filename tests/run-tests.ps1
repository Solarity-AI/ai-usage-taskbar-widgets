<#
.SYNOPSIS
    Runs every check: generated files up to date, then the Claude and Codex test suites.
.DESCRIPTION
    Simulated tests only: fake sign-in folders with placeholder values, fake CLIs, no network, nothing installed.
    Run it in Windows PowerShell 5.1 (it needs WPF):
        powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1 [-Suite All|Claude|Codex]
    -Suite runs one widget's suite (the shared checks always run). Exit the installed widget before running from a checkout.
#>
param([ValidateSet('All', 'Claude', 'Codex')][string]$Suite = 'All')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('usage-widget-tests-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$ps = Join-Path $PSHOME 'powershell.exe'
$fail = 0

& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\sync.ps1') -Check
if ($LASTEXITCODE -ne 0) { $fail++ }

# Website and README: every local link and image exists (the Website workflow checks it again before deploying).
$broken = @()
foreach ($page in @(@{ file = 'site\index.html'; base = 'site' }, @{ file = 'README.md'; base = '.' })) {
    $text = [IO.File]::ReadAllText((Join-Path $root $page.file))
    $refs = @([regex]::Matches($text, '(?:src|href)="([^"#:?]+)"|\]\(([^)#:?\s]+)\)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Groups[2].Value } } | Where-Object { $_ -and $_ -ne './' } | Sort-Object -Unique)
    foreach ($r in $refs) { if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $root $page.base) ([Uri]::UnescapeDataString($r))))) { $broken += "$($page.file) -> $r" } }
}
if ($broken.Count -gt 0) { $broken | ForEach-Object { Write-Host "FAIL missing link target: $_" }; $fail++ } else { Write-Host 'Links OK (website and README)' }
# Version check and packaging (the same step the release workflow runs).
& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\package.ps1') | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'FAIL packaging or version check (tools\package.ps1)'; $fail++ } else { Write-Host 'Package OK (version, changelog and zips)' }

$suites = @(
    @{ name = 'Claude'; file = 'test-claude.ps1'; dir = 'claude-usage-widget' },
    @{ name = 'Codex';  file = 'test-codex.ps1';  dir = 'codex-usage-widget' }
)
foreach ($s in @($suites | Where-Object { $Suite -eq 'All' -or $_.name -eq $Suite })) {
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
