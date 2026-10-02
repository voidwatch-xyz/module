#!/bin/sh
# Removes the Voidwatch upload script from Linux: stops the user service and deletes its files.
systemctl --user disable --now voidwatch.service 2>/dev/null
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/voidwatch.service"
rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/voidwatch"
echo "Voidwatch upload script removed. The module in your game client stays until you delete its folder."
