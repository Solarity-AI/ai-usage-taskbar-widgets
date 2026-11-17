# Claude usage widget for macOS

A native menu-bar version of the Claude widget for macOS 13 or later. It shows a ring and the share left of the limit that runs out first (`61% wk · 1d 14h`, or `40% 5h · 2h` when the 5-hour session is tighter). Its menu shows:

- the share of the week left and your plan
- a *Pace this week* row: *On pace*, *Cutting close*, *Too fast* or *Limit reached*, with the time the allowance runs out at your current rate
- a bar for each limit (weekly, 5-hour session, per-model limits) with its reset time, plus extra usage when it is on
- *Refresh now*, *Open usage page*, *Sign in again…* (only when needed), *Refresh every*, *Alerts at 25% and 10% left*, *Start at login*, *Open data folder* and *Quit*

Notifications fire at 25% and 10% of the week left, when the limit is reached, and when you are on track to run out before the reset.

Codex is Windows-only for now.

## Requirements

- macOS 13 or later, with the Command Line Tools: `xcode-select --install`. Xcode is not needed.
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) signed in on this Mac with a Claude subscription. The Claude desktop app's own sign-in is not enough: install the CLI and run `claude` once in Terminal to sign in.

## Install

Run this in Terminal, from the repository folder:

```bash
./macos/install.sh
```

The installer:

1. Builds `Claude Usage.app` with `swiftc` and signs it ad hoc.
2. Copies the app to `~/Applications`.
3. Adds a LaunchAgent (`~/Library/LaunchAgents/ai.solarity.claude-usage-widget.plist`). It starts the widget at login and restarts it after a crash, but never after *Quit*.
4. Starts the widget and checks that it runs and can read usage.

Running the installer again updates the app in place and keeps your settings.

The first reading may make macOS ask whether `security` may read `Claude Code-credentials`. Choose **Always Allow**.

## Uninstall

```bash
./macos/uninstall.sh
```

This removes the app, its LaunchAgent and its data. Add `--keep-data` to keep settings and history. Your Claude Code sign-in is never touched.

## How it works

The widget works the same way as the Windows one:

- **Usage:** `GET https://api.anthropic.com/api/oauth/usage`, with the same headers as `claude-usage.ps1`.
- **Sign-in:** read from the Keychain item Claude Code keeps on macOS (`Claude Code-credentials`), through `/usr/bin/security`. If that item is missing, it reads `~/.claude/.credentials.json` instead, or `$CLAUDE_CONFIG_DIR/.credentials.json`.
- **Token handling:** the token is sent only to that endpoint. It is never logged, cached or put on a command line.
- **Expired sign-in:** the widget never signs in or refreshes tokens itself. Claude Code renews its own sign-in when the widget runs `claude -p "/usage"`, at most every 10 minutes.
- **Errors:** rate limits and server errors back off from 2 minutes up to 30, and the last reading stays visible, marked as not up to date.
- **Pace forecast:** the same model as the Windows widget. It uses your speed over the last 2–6 hours, or the week's average, and is an estimate, not an official forecast.

Local files live in `~/Library/Application Support/ClaudeUsageWidget/`:

- `settings.json`
- `history.json`: 15 days of readings
- `alerts.json`
- `reading.json`: the last reading
- `widget.log`

## Develop

| Command | What it does |
|---|---|
| `./macos/build.sh` | Builds `macos/build/Claude Usage.app` |
| `./macos/test.sh` | Builds, runs `--self-test` (parsing and pace), then one-shot readings against a local mock of the usage endpoint: a 200, 401, 429, HTML, a redirect, and the headers sent. Fake sign-in, no network |

The app binary also takes `--once` (one live reading as JSON), `--render-preview <png> --from <response.json>` (draws the menu rows offscreen, a layout check) and `--version`.

If the Command Line Tools have a stale `usr/include/swift/module.modulemap` ("redefinition of module 'SwiftBridging'"), `build.sh` hides it through a VFS overlay. Nothing on disk changes.

Not in this first version: the burn-up chart, adjustable alert thresholds, snoozing, a compact mode and Claude Code's `/usage` text as a backup source.
