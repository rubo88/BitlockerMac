#!/bin/bash
# BitlockerMac installer
#
#   From a clone:   ./install.sh
#   One-liner:      curl -fsSL https://raw.githubusercontent.com/rubo88/BitlockerMac/main/install.sh | bash
#
# Installs the dependencies with Homebrew (macFUSE, dislocker, ntfs-3g), builds BitlockerMac from
# source, installs it to ~/.local/bin and registers a LaunchAgent so it starts at login.
# Re-running it updates an existing install.
set -euo pipefail

REPO="rubo88/BitlockerMac"
BRANCH="${BITLOCKERMAC_BRANCH:-main}"
LABEL="io.github.rubo88.BitlockerMac"
BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/BitlockerMac"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/BitlockerMac.log"
DOMAIN="gui/$(id -u)"
MACFUSE="/Library/Filesystems/macfuse.fs"

# messages in Spanish when the Mac's first language is Spanish or the app is set to Spanish
ES=0
defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -Eq '^[[:space:]]*"?es' && ES=1
case "$(defaults read "$LABEL" language 2>/dev/null || true)" in es) ES=1 ;; en) ES=0 ;; esac
t() { if [ "$ES" = 1 ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m%s\033[0m %s\n' "$(t "Error:" "Error:")" "$*" >&2; exit 1; }

# --- requirements ---
[ "$(uname -s)" = "Darwin" ] || die "$(t "BitlockerMac only runs on macOS." "BitlockerMac solo funciona en macOS.")"

# macFUSE's FSKit backend (no kernel extension) needs macOS 15.4 or later
IFS=. read -r MAJOR MINOR _ <<<"$(sw_vers -productVersion).0"
if [ "$MAJOR" -lt 15 ] || { [ "$MAJOR" -eq 15 ] && [ "$MINOR" -lt 4 ]; }; then
    die "$(t "BitlockerMac needs macOS 15.4 or later (you have $(sw_vers -productVersion))." \
             "BitlockerMac necesita macOS 15.4 o posterior (tienes $(sw_vers -productVersion)).")"
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
    die "$(t "The Swift compiler was not found. Install Apple's Command Line Tools with
       xcode-select --install
and run this installer again." "No se encuentra el compilador de Swift. Instala las Command Line Tools de Apple con
       xcode-select --install
y vuelve a ejecutar este instalador.")"
fi

BREW="$(command -v brew || true)"
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -z "$BREW" ] && [ -x "$b" ] && BREW="$b"; done
[ -n "$BREW" ] || die "$(t "Homebrew is needed to install the dependencies: see https://brew.sh" \
                           "Hace falta Homebrew para instalar las dependencias: mira https://brew.sh")"

# --- dependencies ---
if [ ! -d "$MACFUSE" ]; then
    say "$(t "Installing macFUSE (it will ask for your Mac password)…" "Instalando macFUSE (te pedirá la contraseña del Mac)…")"
    "$BREW" install --cask macfuse
fi
"$BREW" tap gromgit/fuse >/dev/null 2>&1 || "$BREW" tap gromgit/fuse
for f in dislocker-mac ntfs-3g-mac; do
    if ! "$BREW" list --formula "$f" >/dev/null 2>&1; then
        say "$(t "Installing $f…" "Instalando $f…")"
        "$BREW" install "gromgit/fuse/$f"
    fi
done

# --- source: the clone this script lives in, or a fresh download ---
SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/BitlockerMac.swift" ]; then
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    say "$(t "Downloading source ($REPO@$BRANCH)…" "Descargando el código ($REPO@$BRANCH)…")"
    curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar -xz -C "$TMP"
    SRC_DIR="$(find "$TMP" -maxdepth 1 -mindepth 1 -type d | head -1)"
    [ -f "$SRC_DIR/BitlockerMac.swift" ] || die "$(t "Download failed: BitlockerMac.swift not found." \
                                                   "La descarga ha fallado: no está BitlockerMac.swift.")"
fi

# --- build ---
say "$(t "Building…" "Compilando…")"
BUILD_DIR="$(mktemp -d)"
xcrun swiftc -O "$SRC_DIR/BitlockerMac.swift" -o "$BUILD_DIR/BitlockerMac"
"$BUILD_DIR/BitlockerMac" version >/dev/null || die "$(t "The build does not run." "El binario compilado no arranca.")"

# --- stop a running instance before replacing the binary ---
FIRST_INSTALL=1
[ -f "$PLIST" ] && FIRST_INSTALL=0
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    say "$(t "Stopping the running instance…" "Parando la instancia en marcha…")"
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    sleep 1
fi

# --- install binary (rm first: overwriting in place keeps macOS's cached code signature
#     for that inode and the new binary gets killed at launch) ---
mkdir -p "$BIN_DIR"
rm -f "$BIN"
cp "$BUILD_DIR/BitlockerMac" "$BIN"
rm -rf "$BUILD_DIR"
say "$(t "Installed" "Instalado") $BIN"

# --- LaunchAgent (KeepAlive only on crashes: "Quit" in the menu really quits until next login) ---
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
    say "$(t "BitlockerMac is running: look for the drive-with-padlock icon in the menu bar." \
             "BitlockerMac está en marcha: busca el icono del disco con candado en la barra de menús.")"
else
    warn "$(t "BitlockerMac did not start. Check $LOG" "BitlockerMac no ha arrancado. Mira $LOG")"
    exit 1
fi

# --- macFUSE checks ---
MFV="$(defaults read "$MACFUSE/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0)"
IFS=. read -r MFMAJ MFMIN _ <<<"$MFV.0.0"
if [ "$MFMAJ" -lt 5 ] || { [ "$MFMAJ" -eq 5 ] && [ "$MFMIN" -lt 5 ]; }; then
    warn "$(t "You have macFUSE $MFV: drives open read-only. Writing needs macFUSE 5.5 or later
   (brew upgrade --cask macfuse once Homebrew has it, or https://github.com/macfuse/macfuse/releases)." \
              "Tienes macFUSE $MFV: los discos se abren en solo lectura. Para escribir hace falta macFUSE 5.5
   o posterior (brew upgrade --cask macfuse cuando Homebrew la tenga, o https://github.com/macfuse/macfuse/releases).")"
fi

# registers the FSKit extension so it shows up in System Settings
open -g "$MACFUSE/Contents/Resources/macfuse.app" 2>/dev/null || true
echo
say "$(t "One manual step (only once): turn on the macFUSE extension in
   System Settings → General → Login Items & Extensions → File System Extensions (ⓘ) → macFUSE" \
         "Un paso a mano (solo una vez): activa la extensión de macFUSE en
   Ajustes del Sistema → General → Ítems de inicio y extensiones → Extensiones del sistema de archivos (ⓘ) → macFUSE")"
if [ "$FIRST_INSTALL" = 1 ]; then
    open "x-apple.systempreferences:com.apple.LoginItems-Settings.extension" 2>/dev/null || true
fi
