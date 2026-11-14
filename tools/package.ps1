<#
.SYNOPSIS
    Builds the release downloads in dist\ and checks that the version is the same everywhere.
.DESCRIPTION
    dist\ai-usage-taskbar-widgets.zip   both widgets, their double-click installers and the README
    dist\claude-usage-widget.zip        the Claude widget and "Install Claude widget.cmd"
    dist\codex-usage-widget.zip         the Codex widget and "Install Codex widget.cmd"
    dist\SHA256SUMS.txt                 checksums of the three zips
    dist\release-notes.md               this version's section of CHANGELOG.md

    The version comes from $script:Version in the widget. It must match the newest CHANGELOG.md heading and,
    when -Version is given (the release workflow passes the tag without its "v"), that value too.
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\package.ps1
#>
param([string]$Version)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $root 'dist'

$widgetSrc = [IO.File]::ReadAllText((Join-Path $root 'claude-usage-widget\claude-usage-widget.ps1'))
$m = [regex]::Match($widgetSrc, "(?m)^\`$script:Version\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'")
if (-not $m.Success) { throw 'No $script:Version found in claude-usage-widget.ps1' }
$ver = $m.Groups[1].Value
$changelog = [IO.File]::ReadAllText((Join-Path $root 'CHANGELOG.md'))
$h = [regex]::Match($changelog, '(?m)^## \[?([0-9]+\.[0-9]+\.[0-9]+)\]?')
if (-not $h.Success -or $h.Groups[1].Value -ne $ver) { throw "CHANGELOG.md's newest entry ($($h.Groups[1].Value)) is not the widget version ($ver)" }
if ($Version -and $Version -ne $ver) { throw "Tag version $Version does not match the widget version $ver" }
$codexSrc = [IO.File]::ReadAllText((Join-Path $root 'codex-usage-widget\codex-usage-widget.ps1'))
if ($codexSrc -notmatch [regex]::Escape("`$script:Version       = '$ver'")) { throw 'The Codex widget has another version: run tools\sync.ps1' }

# This version's notes: from its heading to the next "## " heading.
$start = $h.Index + $h.Length
$next = [regex]::Match($changelog.Substring($start), '(?m)^## ')
$notes = $(if ($next.Success) { $changelog.Substring($start, $next.Index) } else { $changelog.Substring($start) })
$notes = ($notes -replace '^[^\n]*\n', '').Trim()

if (Test-Path -LiteralPath $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
[void](New-Item -ItemType Directory -Path $dist)
$widgets = @{ 'claude-usage-widget' = @('claude-usage-widget.ps1', 'claude-usage.ps1', 'install.ps1', 'uninstall.ps1')
              'codex-usage-widget'  = @('codex-usage-widget.ps1', 'codex-usage.ps1', 'install.ps1', 'uninstall.ps1') }
$launchers = @{ 'claude-usage-widget' = 'Install Claude widget.cmd'; 'codex-usage-widget' = 'Install Codex widget.cmd' }
foreach ($l in $launchers.Values) { if (-not (Test-Path -LiteralPath (Join-Path $root $l))) { throw "Missing $l" } }

function New-Zip([string]$Path, [string[]]$Folders, [bool]$WithReadme) {
    # Each widget folder comes with its double-click installer ("Install <Name> widget.cmd") at the zip root.
    # Entries use forward slashes and sit at the zip's root, so "Extract All" gives a folder holding the widget folders.
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($folder in $Folders) {
            foreach ($file in $widgets[$folder]) {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root "$folder\$file"), "$folder/$file", 'Optimal')
            }
        }
        foreach ($folder in $Folders) {
            $launcher = $launchers[$folder]
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root $launcher), $launcher, 'Optimal')
        }
        if ($WithReadme) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $root 'README.md'), 'README.md', 'Optimal') }
    } finally { $zip.Dispose() }
}
New-Zip (Join-Path $dist 'ai-usage-taskbar-widgets.zip') @('claude-usage-widget', 'codex-usage-widget') $true
New-Zip (Join-Path $dist 'claude-usage-widget.zip') @('claude-usage-widget') $false
New-Zip (Join-Path $dist 'codex-usage-widget.zip') @('codex-usage-widget') $false

$sums = Get-ChildItem -LiteralPath $dist -Filter *.zip | Sort-Object Name | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
$verify = "Verify a download in PowerShell: ``Get-FileHash .\ai-usage-taskbar-widgets.zip`` and compare with ``SHA256SUMS.txt``."
[IO.File]::WriteAllText((Join-Path $dist 'release-notes.md'), ($notes + "`n`n" + $verify + "`n"), (New-Object Text.UTF8Encoding($false)))

"Packaged version $ver into dist\:"
Get-ChildItem -LiteralPath $dist | ForEach-Object { '  {0,-32} {1,8:N0} bytes' -f $_.Name, $_.Length }
