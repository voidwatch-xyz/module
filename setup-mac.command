#!/bin/sh
# Voidwatch setup for macOS, also for clients in CrossOver or Wine: copies the upload script, starts it now and at
# every login. Double-click it. The first time, macOS may ask: right-click the file, pick Open, then Open again.
set -eu
DEST="$HOME/Library/Application Support/Voidwatch"
# macOS lists a login item under the name of the file it starts, so the script runs as "Voidwatch Upload"
APP="$DEST/Voidwatch Upload"
PLIST="$HOME/Library/LaunchAgents/xyz.voidwatch.upload.plist"
mkdir -p "$DEST" "$HOME/Library/LaunchAgents"
launchctl unload "$PLIST" 2>/dev/null || true
# an earlier setup started the script as "sh upload.sh"
pkill -f "Voidwatch/upload.sh" 2>/dev/null || true
rm -f "$DEST/upload.sh"
cp "$(dirname "$0")/upload/upload.sh" "$APP"
chmod 755 "$APP"
xattr -d com.apple.quarantine "$APP" 2>/dev/null || true
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
  <key>ProgramArguments</key><array><string>$APP</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
</dict></plist>
PL
launchctl load "$PLIST"
echo
echo "Voidwatch is set up. It runs in the background as \"Voidwatch Upload\" and starts with your Mac from now on."
echo "Start the game and log in: a game message shows a code and a link. You can close this window."
