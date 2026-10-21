#!/bin/bash
# Installs Insomnia for the current user. Nothing here needs a password; the
# one step that does (the sudoers rule) is printed at the end for you to run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/Insomnia"
LOG_DIR="$HOME/Library/Logs/Insomnia"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Insomnia.app"
AGENTS="$HOME/Library/LaunchAgents"
BIN=/usr/local/bin/insomnia
USER_ID="$(id -u)"
ARCH="$(uname -m)"

echo "1/4  Command line tool -> $BIN"
if [ -w /usr/local/bin ] || [ -w "$BIN" ]; then
  install -m 0755 "$HERE/insomnia" "$BIN"
else
  echo "  /usr/local/bin is not writable; run: sudo install -m 0755 \"$HERE/insomnia\" $BIN" >&2
  exit 1
fi

echo "2/4  Building the menu bar app -> $APP"
BUILD="$(mktemp -d)"
mkdir -p "$BUILD/Insomnia.app/Contents/MacOS" "$BUILD/Insomnia.app/Contents/Resources"
cp "$HERE/MenuBar/Info.plist" "$BUILD/Insomnia.app/Contents/Info.plist"
xcrun swiftc -O \
  -target "${ARCH}-apple-macos12.0" \
  -sdk "$(xcrun --show-sdk-path)" \
  -o "$BUILD/Insomnia.app/Contents/MacOS/Insomnia" \
  "$HERE/MenuBar/main.swift"
codesign --force --sign - "$BUILD/Insomnia.app" >/dev/null 2>&1
mkdir -p "$APP_DIR" "$APP_SUPPORT" "$LOG_DIR"
pkill -x Insomnia 2>/dev/null || true
rm -rf "$APP"
mv "$BUILD/Insomnia.app" "$APP"
rm -rf "$BUILD"

echo "3/4  Launch agents (backstop every minute, network guard, menu bar app at login)"
mkdir -p "$AGENTS"
for name in backstop netguard menubar; do
  plist="$AGENTS/com.usman.insomnia.$name.plist"
  sed "s|__HOME__|$HOME|g" "$HERE/launchd/com.usman.insomnia.$name.plist" > "$plist"
  launchctl bootout "gui/$USER_ID/com.usman.insomnia.$name" 2>/dev/null || true
  launchctl bootstrap "gui/$USER_ID" "$plist"
done

echo "4/4  Password-free pmset rule"
"$BIN" setup
