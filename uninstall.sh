#!/bin/bash
# Uninstalls BitlockerMac. Leaves macFUSE, dislocker and ntfs-3g installed (remove them with brew).
set -uo pipefail
LABEL="io.github.rubo88.BitlockerMac"
CACHE="$HOME/Library/Caches/BitlockerMac"

if mount | grep -q " on $CACHE/"; then
    echo "A BitLocker drive is still open: eject it from the menu first. / Hay un disco BitLocker abierto: expúlsalo antes desde el menú."
    exit 1
fi
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/.local/bin/BitlockerMac"
rm -rf "$CACHE"
echo "BitlockerMac uninstalled / desinstalado. Log / registro: ~/Library/Logs/BitlockerMac.log"
echo "Dependencies / dependencias: brew uninstall gromgit/fuse/dislocker-mac gromgit/fuse/ntfs-3g-mac && brew uninstall --cask macfuse"
