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
        say "$(t "Installing ${f}…" "Instalando ${f}…")"
        "$BREW" install "gromgit/fuse/$f"
    fi
done

# --- writing needs macFUSE 5.5+ (5.4 has a data corruption bug in FSKit): offer it ---
# true if version $1 is older than 5.5
older_than_55() { local a b; IFS=. read -r a b _ <<<"$1.0.0"; [ "$a" -lt 5 ] || { [ "$a" -eq 5 ] && [ "$b" -lt 5 ]; }; }
macfuse_version() { defaults read "$MACFUSE/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo 0; }
# answers from the keyboard even under `curl … | bash`, where stdin is the script itself
ask_yes() {
    local answer
    printf '%s ' "$1" >/dev/tty
    read -r answer </dev/tty || return 1
    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in y|yes|s|si|sí) return 0 ;; *) return 1 ;; esac
}

# macFUSE 5.5.0 prerelease, pinned: the checksum is checked against this value, not one downloaded next to it
BETA_VERSION="5.5.0"
BETA_URL="https://github.com/macfuse/macfuse/releases/download/macfuse-$BETA_VERSION/macfuse-$BETA_VERSION.dmg"
BETA_SHA256="92c21ef2db4199bcf5bddc8e6efb57b23ecb9715f74ab38cba2c77ab226d3830"
BETA_SIGNER="Developer ID Installer: Benjamin Fleischer (3T5GSNBU6W)"

install_macfuse_beta() {
    local dir; dir="$(mktemp -d)"
    say "$(t "Downloading macFUSE ${BETA_VERSION}…" "Descargando macFUSE ${BETA_VERSION}…")"
    if ! curl -fsSL -o "$dir/macfuse.dmg" "$BETA_URL"; then
        warn "$(t "Download failed." "La descarga ha fallado.")"; rm -rf "$dir"; return 1
    fi
    if [ "$(shasum -a 256 "$dir/macfuse.dmg" | cut -d' ' -f1)" != "$BETA_SHA256" ]; then
        warn "$(t "The download's checksum does not match: not installing it." \
                  "La suma de comprobación de la descarga no coincide: no se instala.")"
        rm -rf "$dir"; return 1
    fi
    if ! hdiutil attach -nobrowse -readonly -mountpoint "$dir/dmg" "$dir/macfuse.dmg" >/dev/null; then
        warn "$(t "Could not open the download." "No se ha podido abrir la descarga.")"; rm -rf "$dir"; return 1
    fi
    local pkg="$dir/dmg/Install macFUSE.pkg" sig ok=1
    sig="$(pkgutil --check-signature "$pkg" 2>&1 || true)"
    if printf '%s' "$sig" | grep -qF "$BETA_SIGNER" && printf '%s' "$sig" | grep -q "trusted by the Apple notary service"; then
        say "$(t "Signature and notarization OK. Installing (it will ask for your Mac password)…" \
                 "Firma y notarización correctas. Instalando (te pedirá la contraseña del Mac)…")"
        sudo /usr/sbin/installer -pkg "$pkg" -target / && ok=0
    else
        warn "$(t "The installer is not signed by macFUSE's developer: not installing it." \
                  "El instalador no está firmado por el desarrollador de macFUSE: no se instala.")"
    fi
    hdiutil detach "$dir/dmg" >/dev/null 2>&1 || true
    rm -rf "$dir"
    return $ok
}

if older_than_55 "$(macfuse_version)"; then
    BREW_MF="$("$BREW" info --cask macfuse 2>/dev/null | sed -n '1s/.*: \([0-9][0-9.]*\).*/\1/p')"
    if mount | grep -q macfuse; then
        warn "$(t "A macFUSE volume is mounted: eject it and run the installer again to update macFUSE." \
                  "Hay un volumen de macFUSE montado: expúlsalo y vuelve a ejecutar el instalador para actualizar macFUSE.")"
    elif [ ! -r /dev/tty ] || ! : </dev/tty 2>/dev/null; then
        :   # no keyboard to ask: the warning at the end explains how to update
    elif [ -n "$BREW_MF" ] && ! older_than_55 "$BREW_MF"; then
        if ask_yes "$(t "Update macFUSE to $BREW_MF with Homebrew so drives can be opened for writing? [y/N]" \
                        "¿Actualizar macFUSE a la $BREW_MF con Homebrew para poder abrir los discos en escritura? [s/N]")"; then
            "$BREW" upgrade --cask --greedy macfuse
        fi
    else
        echo
        say "$(t "You have macFUSE $(macfuse_version): drives will open read-only. Writing needs macFUSE 5.5,
   which is still a prerelease (test version) on GitHub. It fixes a data corruption bug in the mode
   BitlockerMac uses. It will be checked (checksum, developer signature, Apple notarization) before installing." \
                 "Tienes macFUSE $(macfuse_version): los discos se abrirán en solo lectura. Para escribir hace falta
   macFUSE 5.5, que de momento es una versión de prueba en GitHub. Corrige un fallo de corrupción de datos en el
   modo que usa BitlockerMac. Se comprobará (suma, firma del desarrollador y notarización de Apple) antes de instalarla.")"
        if ask_yes "$(t "Install macFUSE $BETA_VERSION (prerelease)? [y/N]" "¿Instalar macFUSE $BETA_VERSION (versión de prueba)? [s/N]")"; then
            install_macfuse_beta || warn "$(t "macFUSE was not updated; drives will open read-only." \
                                              "macFUSE no se ha actualizado; los discos se abrirán en solo lectura.")"
        fi
    fi
fi

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
MFV="$(macfuse_version)"
if older_than_55 "$MFV"; then
    warn "$(t "You have macFUSE $MFV: drives open read-only. Writing needs macFUSE 5.5 or later: run this
   installer again and accept the update, or brew upgrade --cask macfuse once Homebrew has it." \
              "Tienes macFUSE $MFV: los discos se abren en solo lectura. Para escribir hace falta macFUSE 5.5 o
   posterior: vuelve a ejecutar este instalador y acepta la actualización, o brew upgrade --cask macfuse
   cuando Homebrew la tenga.")"
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
