# Changelog

Each release is listed here, newest first. The version is `$script:Version` in `claude-usage-widget\claude-usage-widget.ps1`; tagging `v<version>` publishes it as a GitHub release with downloadable zips.

## 1.1.0 (2026-11-14)

**Easier install:** the downloads now include **Install Claude widget.cmd** and **Install Codex widget.cmd**. Unzip and double-click; no terminal needed. The terminal steps now also explain the Windows 10 way to open one.

**Fixed:** if Windows refused a notification (for example during Focus or Do not disturb), that alert was marked as shown and lost for the week. It now stays due and is retried after 15 minutes.

**Also:**
- A security policy with private vulnerability reporting.
- A bug report form that asks for the version shown in About.
- Dependabot for the workflow actions.
- `.editorconfig` that keeps scripts UTF-8 with BOM.
- Link checks for the website and README on every pull request.
- Search metadata and a faster first paint on the website.
- Badges in the README.

## 1.0.0 (2026-11-14)

The first public release of the Claude and Codex usage taskbar widgets.

**Download** `ai-usage-taskbar-widgets.zip` (both widgets), or `claude-usage-widget.zip` / `codex-usage-widget.zip` for just one. Unzip, open the folder in Terminal, and run:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-usage-widget\install.ps1
```

**What's in it**
- **Taskbar pill:** a ring with the share of the weekly allowance left and the time until the weekly reset, or today's budget. Its edge turns orange or red when little is left.
- **Hover card:** the share left; a *Pace this week* box (*On pace*, *Cutting close* or *Too fast*) with the time the allowance runs out at your current rate; a bar for every limit (weekly, 5-hour session, per-model) with its reset time; credits and extra usage.
- **Alerts:** at 25% and 10% left, at the limit, and when you are on track to run out before the reset. They can be snoozed for an hour, until morning or until the weekly reset.
- **Right-click menu:**
  - Refresh now, Open usage page, Sign in again (through the official CLI)
  - Alert thresholds and snooze
  - What the pill shows, refresh interval, compact pill, details (a burn-up chart and the full pace breakdown)
  - Every taskbar, Start with Windows, Uninstall, About
- **Fallback sources:** Claude Code's own `/usage` when the Claude usage service is rate limited or down. The Codex CLI when the Codex sign-in is rejected.
- **Windows integration:** light and dark themes, per-monitor DPI, and the pills hide while a full-screen app is in front.
- **Installer:** one command per widget, no admin rights. It starts with Windows and also works from sandboxed app terminals.
