#!/bin/bash
# Removes everything install.sh put in place. Restores normal sleep first.
set -u
USER_ID="$(id -u)"
BIN=/usr/local/bin/insomnia

[ -x "$BIN" ] && "$BIN" off 2>/dev/null || true
for name in backstop menubar; do
  launchctl bootout "gui/$USER_ID/com.usman.insomnia.$name" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.usman.insomnia.$name.plist"
done
pkill -x Insomnia 2>/dev/null || true
rm -rf "$HOME/Applications/Insomnia.app" "$HOME/Library/Application Support/Insomnia"
rm -f "$BIN"
echo "Removed the app, command, agents and state. Logs are left in ~/Library/Logs/Insomnia."
if [ -f /etc/sudoers.d/insomnia ]; then
  echo "One file needs your password to remove:"
  echo "  sudo rm /etc/sudoers.d/insomnia"
fi
