#!/bin/bash
# Desinstala bitlocker-menu (no toca macFUSE ni dislocker).
set -uo pipefail
LABEL="io.github.rubo88.bitlocker-menu"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/bitlocker-menu"
CACHE="$HOME/Library/Caches/bitlocker-menu"
if mount | grep -q " on $CACHE/"; then
    echo "Hay un disco BitLocker abierto: expúlsalo antes. No borro $CACHE"
else
    rm -rf "$CACHE"
fi
echo "bitlocker-menu desinstalado. El registro sigue en ~/Library/Logs/bitlocker-menu.log"
