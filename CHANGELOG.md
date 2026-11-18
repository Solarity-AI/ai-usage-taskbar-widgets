# Changelog

Each release is listed here, newest first. The version is `$script:Version` in `claude-usage-widget\claude-usage-widget.ps1` and `appVersion` in `macos/Sources/Core.swift`; tagging `v<version>` publishes it as a GitHub release with downloadable zips.

## 1.5.0 (2026-11-18)

**New:** the hover card has a second pace box, *Pace this 5-hour session*, under *Pace this week*. Like the weekly box, it says *On pace*, *Cutting close*, *Too fast* or *Limit reached* and when the 5-hour session runs out at your current pace. The Mac menu shows the same row ([#67](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/67)).

## 1.4.3 (2026-11-18)

**Fixed (macOS):** `./macos/install.sh` stopped with "version…: unbound variable" in a normal Terminal window, so the Mac app could not be installed from one ([#65](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/65)).

**Fixed (macOS):** a usage reply with an out-of-range number, such as a reset date thousands of years away or a share of 1e30, stopped the menu-bar app. Such dates are now skipped, and such numbers show a dash and send no alert ([#61](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/61)).

**Fixed (macOS):** the app called itself version 1.0.0. It now has the same version as the Windows widgets, and the tests check that they stay the same ([#62](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/62)).

**Changed:** pull requests that change the Mac app now build and test it on a macOS runner ([#57](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/57)), and its weekly alert rule has its own tests ([#64](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/64)). The Mac guide has full install and update steps ([#60](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/60)). The website and the README point Mac users to it ([#58](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/58)), say "used" like the widgets ([#59](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/59)) and list the Mac develop commands ([#63](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/63)).

The Windows widgets are unchanged apart from the version number.

## 1.4.2 (2026-11-18)

**Fixed:** the pace lines on the card and the installer's check still said "% left"; they now say "% used" like the rest of the widget ([#54](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/54)).

## 1.4.1 (2026-11-18)

**Fixed:** on a PC with only the Claude desktop app, the Claude widget showed *sign in needed* every night and *Sign in again* said the command-line tool was not found. It now uses the Claude Code that the desktop app ships with, both to renew the sign-in and for *Sign in again* ([#52](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/52)).

## 1.4.0 (2026-11-17)

**Changed:** the pill, the card's big number and the alerts show the share **used**, not the share left: `31%` used instead of `69%` left. Alert thresholds are the same points, now named 50%, 75%, 90% and 95% used ([#48](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/48)).

**Changed:** the pill now names the limit it shows: `weekly 4d 11h` or `5-hour 1h 23m` instead of `4d 11h` or `session 1h 23m` ([#42](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/42)).

## 1.3.1 (2026-11-16)

Fixes from a QA bug hunt.

**Fixed:** a damaged `alerts.json` stopped the widget from starting. Bad entries are now skipped ([#29](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/29)).

**Fixed:** a reinstall turned *Start with Windows* back on after you had turned it off in the widget. A reinstall now keeps your choice; a first install still turns it on ([#30](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/30)).

**Fixed:** on battery power, the uninstaller's run outside an app sandbox never started and gave up after 90 seconds ([#31](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/31)).

**Fixed:** a pill could sit partly or fully off screen after a monitor or resolution change. It is now kept inside its monitor ([#32](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/32)).

**Fixed:** a `CLAUDE_CONFIG_DIR` with characters Windows does not allow in a path made the collector fail without a readable error. It now reports the folder as missing ([#33](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/33)).

**Fixed:** with no network, every refresh waited for the official CLI, which cannot reach the service either. Offline is now detected at once and the last reading is shown ([#34](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/34)).

**Fixed:** when a refresh failed or the CLI timed out, its child processes could keep running. The collectors, the widget and the watchdog now stop the whole process tree ([#35](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/35)).

**Fixed:** the same alert could show twice when the reported reset time moved across the half hour. Readings up to 30 minutes apart now count as the same window; your saved alerts stay valid ([#36](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/36)).

**Fixed:** if Windows took the mouse away during a drag (for example with Alt+Tab or a lock), the pill kept following the pointer. The drag now ends there and the position is saved ([#37](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/37)).

**Fixed:** when Windows could not list processes, the watchdog started a second widget. It now skips that check ([#38](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/38)).

**Fixed:** the collector reported `limit_reached` only for the weekly limit, not for a used-up 5-hour session ([#39](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/39)).

**Docs:** the installer and uninstaller help and the README now list everything they create and remove, including the watchdog, with correct example paths ([#40](https://github.com/Solarity-AI/ai-usage-taskbar-widgets/issues/40)).

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
