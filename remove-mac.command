#!/bin/sh
# Removes the Voidwatch upload script from macOS: stops it, removes the login item, deletes its files.
PLIST="$HOME/Library/LaunchAgents/xyz.voidwatch.upload.plist"
launchctl unload "$PLIST" 2>/dev/null
rm -f "$PLIST"
pkill -f "Voidwatch/Voidwatch Upload" 2>/dev/null
pkill -f "Voidwatch/upload.sh" 2>/dev/null
rm -rf "$HOME/Library/Application Support/Voidwatch"
echo "Voidwatch upload script removed. The module in your game client stays until you delete its folder."
