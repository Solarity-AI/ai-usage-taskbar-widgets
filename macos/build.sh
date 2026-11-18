#!/bin/bash
# Builds "Claude Usage.app" into macos/build/ with swiftc (Xcode not needed, Command Line Tools are enough),
# then signs it ad hoc so macOS notifications and the Keychain prompt name a stable app.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$here/build/Claude Usage.app"
version="$(sed -n 's/^let appVersion = "\(.*\)"$/\1/p' "$here/Sources/Core.swift")"

green=$'\e[32m'; red=$'\e[31m'; dim=$'\e[2m'; off=$'\e[0m'
command -v swiftc >/dev/null || { echo "${red}❌ swiftc not found. Run: xcode-select --install${off}"; exit 1; }

rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
# Braces matter: under a UTF-8 locale, bash 3.2 reads the first byte of "…" as part of a bare $version.
echo "${dim}Compiling ${version}…${off}"
flags=()
# Some Command Line Tools installs keep a stale usr/include/swift/module.modulemap next to bridging.modulemap;
# both define SwiftBridging and every build fails. Hide the stale one through a VFS overlay (nothing on disk changes).
inc="$(dirname "$(dirname "$(xcrun --find swiftc)")")/include/swift"
if [ -f "$inc/module.modulemap" ] && [ -f "$inc/bridging.modulemap" ]; then
  mkdir -p "$here/build"
  : > "$here/build/empty.modulemap"
  cat > "$here/build/overlay.yaml" <<YAML
{ "version": 0, "case-sensitive": "false", "roots": [ { "type": "file", "name": "$inc/module.modulemap", "external-contents": "$here/build/empty.modulemap" } ] }
YAML
  flags+=(-vfsoverlay "$here/build/overlay.yaml")
fi
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" ${flags[@]+"${flags[@]}"} \
  -o "$out/Contents/MacOS/ClaudeUsage" "$here"/Sources/*.swift

cat > "$out/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ai.solarity.claude-usage-widget</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$out" >/dev/null 2>&1
codesign --verify "$out" && echo "${green}✅ Built $out${off}"
