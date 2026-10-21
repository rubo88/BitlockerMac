#!/bin/bash
# Instalador de bitlocker-menu: compila, instala en ~/.local/bin y registra un LaunchAgent para
# que arranque al iniciar sesión. Volver a ejecutarlo actualiza la instalación.
set -euo pipefail

LABEL="io.github.rubo88.bitlocker-menu"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/bitlocker-menu"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/bitlocker-menu.log"
DOMAIN="gui/$(id -u)"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

xcrun --find swiftc >/dev/null 2>&1 || die "Falta el compilador de Swift: xcode-select --install"
[ -d /Library/Filesystems/macfuse.fs ] || warn "Falta macFUSE: brew install --cask macfuse"
[ -x /opt/homebrew/bin/dislocker-fuse ] || warn "Falta dislocker: brew install gromgit/fuse/dislocker-mac"

say "Compilando…"
BUILD_DIR="$(mktemp -d)"
xcrun swiftc -O "$SRC_DIR/bitlocker-menu.swift" -o "$BUILD_DIR/bitlocker-menu"
"$BUILD_DIR/bitlocker-menu" version >/dev/null || die "El binario compilado no arranca."

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    say "Parando la instancia en marcha…"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    sleep 1
fi

# rm antes de cp: sobrescribir en el mismo inodo conserva la firma en caché y macOS mata el binario nuevo
mkdir -p "$BIN_DIR"
rm -f "$BIN"
cp "$BUILD_DIR/bitlocker-menu" "$BIN"
rm -rf "$BUILD_DIR"
say "Instalado $BIN"

# KeepAlive solo ante salidas con error: «Salir» en el menú la cierra de verdad hasta el próximo inicio de sesión
mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"

sleep 2
if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then
    say "bitlocker-menu está en marcha (arrancará solo al iniciar sesión)."
else
    warn "bitlocker-menu no ha arrancado. Mira $LOG"
    exit 1
fi
