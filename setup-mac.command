#!/bin/sh
# Voidwatch setup for macOS, also for clients in CrossOver or Wine: copies the upload script, starts it now and at
# every login. Double-click it. The first time, macOS may ask: right-click the file, pick Open, then Open again.
set -eu
DEST="$HOME/Library/Application Support/Voidwatch"
PLIST="$HOME/Library/LaunchAgents/xyz.voidwatch.upload.plist"
# the upload script ran as "Emberwatch" before the rename; stop that one too
launchctl unload "$HOME/Library/LaunchAgents/online.funyo.emberwatch.plist" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/online.funyo.emberwatch.plist"
pkill -f "Emberwatch/upload.sh" 2>/dev/null || true
rm -rf "$HOME/Library/Application Support/Emberwatch"
mkdir -p "$DEST" "$HOME/Library/LaunchAgents"
cp "$(dirname "$0")/upload/upload.sh" "$DEST/upload.sh"
echo "Drag the folder the game message showed into this window and press Enter,"
printf "or just press Enter to look in the usual places: "
read -r folder || folder=""
folder=$(printf '%s' "$folder" | sed "s/^'//; s/'$//; s/\\\\ / /g")
[ -n "$folder" ] && printf '%s\n' "$folder" >> "$DEST/folders.txt"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>xyz.voidwatch.upload</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>$DEST/upload.sh</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
</dict></plist>
PL
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
echo
echo "Voidwatch is set up. It runs in the background now and starts with your Mac from now on."
echo "Start the game and log in: a game message shows a code and a link. You can close this window."
