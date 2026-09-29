#!/bin/sh
# Voidwatch setup for Linux, also for clients in Wine: copies the upload script and runs it as a user service, now and
# at every login. Run: sh setup-linux.sh [the folder the game message showed]
set -eu
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/voidwatch"
UNIT="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/voidwatch.service"
# the upload script ran as "emberwatch" before the rename; stop that one too
systemctl --user disable --now emberwatch.service 2>/dev/null || true
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/emberwatch.service"
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/emberwatch"
mkdir -p "$DEST" "$(dirname "$UNIT")"
cp "$(dirname "$0")/upload/upload.sh" "$DEST/upload.sh"
[ $# -gt 0 ] && printf '%s\n' "$1" >> "$DEST/folders.txt"
cat > "$UNIT" <<U
[Unit]
Description=Voidwatch upload script
[Service]
ExecStart=/bin/sh $DEST/upload.sh
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
U
systemctl --user daemon-reload
systemctl --user enable --now voidwatch.service
echo "Voidwatch is set up and starts at every login. Start the game and log in: a game message shows a code and a link."
