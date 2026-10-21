# BitlockerMac

**Open BitLocker-encrypted external drives on your Mac from a menu bar icon.**

[Español](README.es.md)

BitlockerMac is a small macOS menu bar app (a single Swift file) that detects external drives encrypted with BitLocker on Windows, asks for the key in a small window and opens them in Finder. Under the hood it uses [dislocker](https://github.com/Aorimn/dislocker), [macFUSE](https://macfuse.github.io/) and, for writing, [ntfs-3g](https://github.com/tuxera/ntfs-3g).

**No need to lower your Mac's security.** macFUSE runs in its FSKit mode, which works without a kernel extension: no Recovery Mode, no Reduced Security.

## Features

- **Menu bar icon** (a drive with a closed or open padlock) listing the connected BitLocker drives and the ones you have open.
- **Key window**: takes the BitLocker password or the 48-digit recovery key.
- **Read-only by default**, using macOS's own NTFS/exFAT support.
- **Optional writing (experimental)** with a checkbox: NTFS through ntfs-3g; exFAT/FAT through macOS.
- **Eject** from the same menu: closes the volume and ejects the physical drive so you can unplug it.
- Notices drives being plugged in and out by itself.
- English or Spanish interface.

## Requirements

- macOS 15.4 or later (macFUSE's FSKit mode needs it). Developed and tested on macOS 26 (Tahoe) on Apple Silicon; Intel Macs should work but are untested.
- [Homebrew](https://brew.sh).
- Apple's Command Line Tools, to build it: `xcode-select --install`.
- For writing: macFUSE 5.5 or later (5.4 has a data corruption bug in FSKit). With 5.4, drives open read-only.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/rubo88/BitlockerMac/main/install.sh | bash
```

Or from a clone:

```bash
git clone https://github.com/rubo88/BitlockerMac.git
cd BitlockerMac
./install.sh
```

The installer:

1. checks the requirements;
2. installs whatever is missing with Homebrew: macFUSE (it will ask for your Mac password), dislocker and ntfs-3g;
3. builds the app and installs it to `~/.local/bin/BitlockerMac`;
4. registers a LaunchAgent so it starts at login.

Run it again at any time to update.

### One manual step (only once)

Turn on the macFUSE extension in **System Settings → General → Login Items & Extensions → File System Extensions (ⓘ) → macFUSE**. The installer opens that pane the first time. Without it, the app shows a message when you try to unlock.

## Usage

1. Plug in the drive. The icon's menu shows "Unlock *drive name* · *size*…".
2. Type the BitLocker password or the recovery key and click **Unlock**.
3. The first time after plugging in the drive, the app also asks for your **Mac password** (see [Security](#security)).
4. The drive opens in Finder and the icon switches to an open padlock.
5. When you are done, **Eject** from the menu. Then you can unplug it.

### Writing (experimental)

Tick **Allow writing** in the unlock window. Keep in mind:

- **Always eject from the menu before unplugging.** Writes go through two FUSE layers; pulling the cable can lose data.
- If the drive comes from a Windows PC that was not fully shut down (Fast Startup or hibernation), it will not open for writing so as not to damage it. Shut Windows down with Shift + "Shut down", or open it read-only.
- Back up anything important before you start using it.

### Language

The interface follows the Mac's first language. To force one:

```bash
defaults write io.github.rubo88.BitlockerMac language en   # or es, or auto
```

and restart the app (Quit from the menu, then `launchctl kickstart gui/$(id -u)/io.github.rubo88.BitlockerMac`, or log out and back in).

## How it works

1. **Access to the drive.** macFUSE's FSKit mode only mounts as a normal user, not as root, so dislocker cannot run as administrator. With your Mac password, the app (through `sudo`) makes your user the owner of the encrypted partition (`/dev/diskXsY`) with read-only access (or read-write if you ask for it). macOS undoes this when the drive is unplugged.
2. **Decrypt.** `dislocker-fuse` decrypts the partition and exposes the decrypted volume as a virtual file in `~/Library/Caches/BitlockerMac/<diskXsY>/dislocker-file`.
3. **Mount.** Read-only, `hdiutil` attaches that file and macOS mounts it with its own NTFS/exFAT support. For writing, `ntfs-3g` mounts it in `/Volumes` (or `hdiutil` read-write for exFAT/FAT).

## Security

- **The BitLocker key never goes on the command line** (any user on the Mac can see it with `ps`) **nor into any log**. The password reaches dislocker through the `DISLOCKER_PASSWORD` environment variable (a process's environment is only visible to your user and root). The recovery key is typed into a pseudo-terminal with echo off, because dislocker only reads it from a terminal.
- **The Mac password** is only used to change the partition's permissions, through `sudo` and the app's own password window.
- While the drive is plugged in, the encrypted partition is readable by your user. It is encrypted, so nothing can be read without the key.
- The log (`~/Library/Logs/BitlockerMac.log`) only records what was done and errors, never keys.

## Limitations

- The **recovery key** path has not been tested with a real key yet; the password path has.
- Writing is experimental: tested with NTFS test images, and only briefly with real drives.
- macFUSE 5.5 does not mount in `/Volumes` with non-ASCII names: when writing, the app strips accents from the mount folder's name.
- External drives only.

## Uninstall

```bash
./uninstall.sh
```

From a clone, or remove `~/.local/bin/BitlockerMac` and `~/Library/LaunchAgents/io.github.rubo88.BitlockerMac.plist` by hand (after `launchctl bootout gui/$(id -u)/io.github.rubo88.BitlockerMac`). macFUSE, dislocker and ntfs-3g stay installed; the script says how to remove them.

## License

MIT. BitLocker is a trademark of Microsoft; this project is not affiliated with Microsoft.
