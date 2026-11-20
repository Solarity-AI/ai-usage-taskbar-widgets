#!/bin/bash
# Builds and installs the Claude usage menu-bar widget for this macOS user: ~/Applications/Claude Usage.app,
# a LaunchAgent that starts it at login (and restarts it after a crash, never after Quit), then starts it and
# checks that it runs and can read usage. Running it again updates the app in place and keeps settings.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
green=$'\e[32m'; red=$'\e[31m'; yellow=$'\e[33m'; off=$'\e[0m'
app="$HOME/Applications/Claude Usage.app"
label="ai.solarity.claude-usage-widget"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

"$here/build.sh" || { echo "${red}❌ build failed${off}"; exit 1; }
echo

# An update keeps the owner's choice: an installed app without a LaunchAgent means Start at login was turned off (QA-23).
keep_off=0; [ -d "$app" ] && [ ! -f "$plist" ] && keep_off=1
# Pass CLAUDE_CONFIG_DIR on, so the login item reads the same Claude account as this shell (QA-12).
env_xml=""
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  esc="$(printf '%s' "$CLAUDE_CONFIG_DIR" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
  env_xml="  <key>EnvironmentVariables</key><dict><key>CLAUDE_CONFIG_DIR</key><string>$esc</string></dict>"
fi

launchctl bootout "$domain/$label" 2>/dev/null
pkill -f "Claude Usage.app/Contents/MacOS/ClaudeUsage" 2>/dev/null
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$app"
cp -R "$here/build/Claude Usage.app" "$app"
echo "${green}✅ Installed $app${off}"

if [ "$keep_off" = 1 ]; then
  nohup "$app/Contents/MacOS/ClaudeUsage" >/dev/null 2>&1 &
  echo "${green}✅ Start at login stays off (turn it on in the menu)${off}"
else
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/ClaudeUsage</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
$env_xml
</dict>
</plist>
PLIST
launchctl bootstrap "$domain" "$plist" && echo "${green}✅ Starts at login ($plist)${off}" || echo "${red}❌ launchctl bootstrap failed${off}"
fi

sleep 2
if pgrep -f "$app/Contents/MacOS/ClaudeUsage" >/dev/null; then
  echo "${green}✅ Running (pid $(pgrep -f "$app/Contents/MacOS/ClaudeUsage" | head -1)) — look for the ring in the menu bar${off}"
else
  echo "${red}❌ Not running; see ~/Library/Application Support/ClaudeUsageWidget/widget.log${off}"; exit 1
fi

echo
result="$("$app/Contents/MacOS/ClaudeUsage" --once 2>&1)"
if echo "$result" | grep -q '"weekly"'; then
  echo "${green}✅ Live usage read: $(echo "$result" | python3 -I -c 'import json,sys; w=json.load(sys.stdin)["weekly"]; print("%g%% of the week used" % w["used"])')${off}"
else
  echo "${yellow}⚠ No live data yet: $(echo "$result" | sed -n 's/.*"error":"\(.*\)"}/\1/p' | sed 's/\\"/"/g')${off}"
  echo "${yellow}  If macOS asks whether \"security\" may read \"Claude Code-credentials\", choose Always Allow.${off}"
fi
