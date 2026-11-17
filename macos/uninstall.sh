#!/bin/bash
# Stops the Claude usage menu-bar widget and removes the app, its LaunchAgent and (unless --keep-data) its
# settings and history. The Claude Code sign-in is never touched.
set -uo pipefail
green=$'\e[32m'; off=$'\e[0m'
label="ai.solarity.claude-usage-widget"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/Claude Usage.app"
[ "${1:-}" = "--keep-data" ] || rm -rf "$HOME/Library/Application Support/ClaudeUsageWidget"
echo "${green}✅ Claude usage widget removed${off}"
