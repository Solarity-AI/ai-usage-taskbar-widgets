# Changelog

Each release is listed here, newest first. The version is `$script:Version` in `claude-usage-widget\claude-usage-widget.ps1`; tagging `v<version>` publishes it as a GitHub release with downloadable zips.

## 1.3.0 (2026-11-16)

**Tighter limit first:** the pill and the card's headline now show whichever limit runs out first, the weekly one or the 5-hour session ([#22](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/22)).

**Narrower pill:** the product name now sits beside the percentage, and the second line shows only the reset time or status. The Claude pill is 132 instead of 155 pixels wide, the Codex pill 126 instead of 135 ([#25](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/25)).

**Fixed:** both pills sometimes vanished and came back ([#24](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/24)). Start, Search, Task View and Alt+Tab no longer count as a full-screen app; the pills hide only after a full-screen app stays in front for 2 checks in a row, and they come back on top as soon as another window takes focus.

## 1.2.0 (2026-11-16)

**Fixed:** a widget that Windows closed (for example as "not responding" after the PC woke from sleep) stayed gone until the next sign-in ([#23](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/23)). The installer now adds a per-user watchdog task that, every 5 minutes, starts the widget if it is not running and replaces one whose window stopped updating. It never restarts a widget you closed with *Exit*, with *Start with Windows* off, or after uninstalling. Run the installer again to get it.

**Also fixed:** when the collector timed out, only the collector was stopped; the official CLI it started kept running. Now its whole process tree is stopped, and a child that holds the collector's output open no longer blocks every later refresh.

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
