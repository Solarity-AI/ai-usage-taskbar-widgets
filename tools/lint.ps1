<#
.SYNOPSIS
    PSScriptAnalyzer gate: every script in the widgets, tools and tests, with the repo's PSScriptAnalyzerSettings.psd1.
.DESCRIPTION
    Needs the PSScriptAnalyzer module (CI installs 1.25.0):
        Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Scope CurrentUser
        powershell -NoProfile -ExecutionPolicy Bypass -File tools\lint.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module PSScriptAnalyzer
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$files = Get-ChildItem -Path (Join-Path $root 'claude-usage-widget'), (Join-Path $root 'codex-usage-widget'), (Join-Path $root 'antigravity-usage-widget'), (Join-Path $root 'tools'), (Join-Path $root 'tests') -Filter '*.ps1' -Recurse
$found = @($files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings $settings })
foreach ($f in $found) { Write-Host ('FAIL {0}:{1} {2}: {3}' -f $f.ScriptName, $f.Line, $f.RuleName, $f.Message) }
if ($found.Count -gt 0) { Write-Host "$($found.Count) PSScriptAnalyzer finding(s)."; exit 1 }
Write-Host "Lint OK ($($files.Count) scripts, PSScriptAnalyzer $((Get-Module PSScriptAnalyzer).Version))"
