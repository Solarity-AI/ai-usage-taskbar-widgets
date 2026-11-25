# Rules for AI agents

Verify: `powershell -NoProfile -ExecutionPolicy Bypass -File tools\verify.ps1` (what CI runs: `tests\run-tests.ps1`,
then the PSScriptAnalyzer gate `tools\lint.ps1`; prints 1 final PASS or FAIL line).

AI usage taskbar widgets: Windows taskbar pills that show Claude and Codex plan usage (PowerShell 5.1 + WPF), plus a
macOS menu-bar app in `macos/` (Swift).

## Commands

- `tools\verify.ps1`: the verify command above. Lint needs `Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0
  -Scope CurrentUser` once; without it lint is skipped with a warning locally (never in CI).
- `tests\run-tests.ps1 [-Suite Claude|Codex]`: `tools\sync.ps1 -Check`, link checks, the version and packaging check,
  then the simulated test suites (fake sign-ins and CLIs, no network). Exit an installed widget before running it.
- `tools\sync.ps1`: regenerates the Codex copy from the Claude files and checks every script parses and has a BOM.
- `tools\package.ps1`: builds the release zips and checksums in `dist\`.
- macOS (on a Mac): `./macos/build.sh`, `./macos/test.sh` (CI: the **macOS app** workflow).

## Layout and rules

- `claude-usage-widget\` is the source. In `codex-usage-widget\` everything except `codex-usage.ps1` and the product
  block at the top of the widget is generated: never hand-edit it; edit the Claude file and run `tools\sync.ps1`.
- Scripts stay compatible with Windows PowerShell 5.1 and are saved as UTF-8 with BOM (`.editorconfig`,
  `.gitattributes`); `sync.ps1 -Check` fails otherwise.
- `shared\WidgetStrip.cs` is the same file as in hw-widget and machines-widget; change all copies together.
- A version bump changes `$script:Version` in `claude-usage-widget\claude-usage-widget.ps1`, `appVersion` in
  `macos/Sources/Core.swift` and a new top section in `CHANGELOG.md` together.
- Do not run the installers or uninstallers (`Install * widget.cmd`, `*\install.ps1`, `*\uninstall.ps1`,
  `macos/install.sh`): they install into the user's session. Never paste tokens, `.credentials.json` or `auth.json`.

## Shipping

- 1 issue per piece of work, then a branch `feat/<issue>-<slug>` or `fix/<issue>-<slug>`.
- Commit subjects `feat: … (#<issue>)` or `fix: … (#<issue>)`; the pull request body says `Fixes #<issue>`.
- Squash merge once CI is green. Releases: push a `v<version>` tag on the merge commit; the **Release** workflow publishes.
