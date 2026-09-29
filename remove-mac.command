#!/bin/sh
# Removes the Voidwatch upload script from macOS: stops it, removes the login item, deletes its files.
# the upload script ran as "Emberwatch" before the rename; stop that one too
launchctl unload "$HOME/Library/LaunchAgents/online.funyo.emberwatch.plist" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/online.funyo.emberwatch.plist"
pkill -f "Emberwatch/upload.sh" 2>/dev/null
rm -rf "$HOME/Library/Application Support/Emberwatch"
PLIST="$HOME/Library/LaunchAgents/xyz.voidwatch.upload.plist"
launchctl unload "$PLIST" 2>/dev/null
rm -f "$PLIST"
pkill -f "Voidwatch/upload.sh" 2>/dev/null
rm -rf "$HOME/Library/Application Support/Voidwatch"
echo "Voidwatch upload script removed. The module in your game client stays until you delete its folder."
