<#
.SYNOPSIS
    The repo's 1 verify command, the same as CI: tests\run-tests.ps1, then the PSScriptAnalyzer gate (tools\lint.ps1).
.DESCRIPTION
    Run it in Windows PowerShell 5.1 (the tests need WPF):
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify.ps1
    Lint needs the PSScriptAnalyzer module (Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser);
    without it lint is skipped with a warning locally and fails in CI. Prints 1 final PASS or FAIL line.
#>
$root = Split-Path -Parent $PSScriptRoot
$ps = Join-Path $PSHOME 'powershell.exe'
$fail = 0
& $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\run-tests.ps1')
if ($LASTEXITCODE -ne 0) { $fail++ }
if (Get-Module -ListAvailable PSScriptAnalyzer) {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\lint.ps1')
    if ($LASTEXITCODE -ne 0) { $fail++ }
} elseif ($env:CI) {
    Write-Host 'FAIL PSScriptAnalyzer is not installed'
    $fail++
} else {
    Write-Host 'WARN lint skipped: PSScriptAnalyzer is not installed (Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser)'
}
if ($fail -gt 0) { Write-Host 'FAIL verify'; exit 1 }
Write-Host 'PASS verify'
