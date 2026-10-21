// BitlockerMac: a menu bar app to open BitLocker-encrypted external drives on macOS.
//
// Uses dislocker with macFUSE's FSKit backend (no kernel extension, no lowered Mac security).
//
//   1. With the Mac password, the encrypted partition becomes readable (or readable and
//      writable) by the user. macOS undoes it by itself when the drive is unplugged.
//   2. dislocker-fuse runs as the user (FSKit only works that way) and leaves the decrypted
//      volume in ~/Library/Caches/BitlockerMac/<diskXsY>/dislocker-file.
//   3. Read-only: hdiutil attaches that file and macOS mounts it with its own NTFS/exFAT support.
//      Writing (experimental): ntfs-3g mounts it in /Volumes, also through FSKit; if it is not
//      NTFS (exFAT/FAT from BitLocker To Go), hdiutil attaches it writable with macOS's support.
//
// The key never goes in command-line arguments (anyone can read them with `ps`) nor in any log:
// the password goes through the DISLOCKER_PASSWORD variable and the recovery key is typed into a
// pseudo-terminal with echo off.

import AppKit
import DiskArbitration

let version = "1.2.0"

// Spanish or English. Follows the Mac's first language unless overridden with
//   defaults write io.github.rubo88.BitlockerMac language es   (or en / auto)
let defaultsDomain = "io.github.rubo88.BitlockerMac"
let uiSpanish: Bool = {
    switch UserDefaults(suiteName: defaultsDomain)?.string(forKey: "language")?.lowercased() {
    case "es": return true
    case "en": return false
    default: return (Locale.preferredLanguages.first ?? "en").hasPrefix("es")
    }
}()
func L(_ en: String, _ es: String) -> String { uiSpanish ? es : en }

/// Homebrew lives in /opt/homebrew on Apple Silicon and in /usr/local on Intel.
func brewTool(_ subpath: String) -> String {
    let candidates = ["/opt/homebrew/" + subpath, "/usr/local/" + subpath]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
}
let dislockerPath = brewTool("bin/dislocker-fuse")
let ntfs3gPath = brewTool("bin/ntfs-3g")
let ntfslabelPath = brewTool("sbin/ntfslabel")
let macfuseBundle = "/Library/Filesystems/macfuse.fs"
let home = NSHomeDirectory()
// macFUSE 5.4 (FSKit) could not mount on paths with spaces: hence Caches and not Application Support
let baseDir = home + "/Library/Caches/BitlockerMac"
let logPath = home + "/Library/Logs/BitlockerMac.log"
let windowsContents: Set<String> = ["Microsoft Basic Data", "Windows_NTFS", "Windows_FAT_32", "DOS_FAT_32"]

let stampFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ s: String) {
    print("\(stampFormatter.string(from: Date())) \(s)")
    fflush(stdout)
}

func macfuseVersion() -> String? {
    Bundle(path: macfuseBundle)?.infoDictionary?["CFBundleShortVersionString"] as? String
}

/// Writing needs ntfs-3g and macFUSE 5.5 or later: 5.4 has a data corruption bug in FSKit.
func writeUnavailableReason() -> String? {
    guard let v = macfuseVersion(), v.compare("5.5", options: .numeric) != .orderedAscending else {
        return L("Writing needs macFUSE 5.5 or later.", "Para escribir hace falta macFUSE 5.5 o posterior.")
    }
    if !FileManager.default.isExecutableFile(atPath: ntfs3gPath) || !FileManager.default.isExecutableFile(atPath: ntfslabelPath) {
        return L("Writing needs ntfs-3g: brew install gromgit/fuse/ntfs-3g-mac",
                 "Para escribir hace falta ntfs-3g: brew install gromgit/fuse/ntfs-3g-mac")
    }
    return nil
}

// MARK: - Processes

final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

struct Output { var status: Int32; var out: String; var err: String }

/// Runs a program and waits for it. `input` is written to its stdin one second after launch (time
/// for `stty -echo` inside the pseudo-terminal) and stdin stays open until the end: if `script`
/// saw end-of-file it would hang up the terminal too early.
@discardableResult
func run(_ exe: String, _ args: [String], env: [String: String] = [:],
         input: String? = nil, timeout: TimeInterval = 120) -> Output {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    p.standardOutput = outPipe
    p.standardError = errPipe
    let out = Buffer(), err = Buffer()
    for (pipe, buf) in [(outPipe, out), (errPipe, err)] {
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { buf.append(d) }
        }
    }
    let done = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in done.signal() }
    do { try p.run() } catch { return Output(status: -1, out: "", err: "\(error)") }
    if let input {
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        }
    }
    var timedOut = false
    if done.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        p.terminate()
        done.wait()
    }
    if input != nil { try? inPipe.fileHandleForWriting.close() }
    Thread.sleep(forTimeInterval: 0.1)
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    return Output(status: timedOut ? -2 : p.terminationStatus, out: out.string, err: err.string)
}

func plist(_ s: String) -> Any? {
    try? PropertyListSerialization.propertyList(from: Data(s.utf8), format: nil)
}

// MARK: - Disks

/// Unmounted Windows partition on an external drive: a BitLocker candidate.
struct Locked { let id: String; let size: Int64; let media: String }
/// Volume decrypted and mounted by this app. `dev` is the hdiutil disk; nil when ntfs-3g mounts it.
struct Opened { let id: String; let dev: String?; let mount: String?; let writable: Bool }

func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func mountDir(_ id: String) -> String { baseDir + "/" + id }
/// Where ntfs-3g mounted each volume: with FSKit, `mount` does not say which file is behind it.
func ntfsStateFile(_ id: String) -> String { baseDir + "/" + id + ".ntfs3g" }
func physicalDisk(_ id: String) -> String {
    id.replacingOccurrences(of: #"s\d+$"#, with: "", options: .regularExpression)
}

func openedVolumes() -> [Opened] {
    var res: [Opened] = []
    let r = run("/usr/bin/hdiutil", ["info", "-plist"])
    if let d = plist(r.out) as? [String: Any], let images = d["images"] as? [[String: Any]] {
        for img in images {
            guard let path = img["image-path"] as? String, path.hasPrefix(baseDir + "/") else { continue }
            let id = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            let ents = img["system-entities"] as? [[String: Any]] ?? []
            guard let dev = ents.compactMap({ $0["dev-entry"] as? String }).sorted().first else { continue }
            res.append(Opened(id: id, dev: dev, mount: ents.compactMap { $0["mount-point"] as? String }.first,
                              writable: img["writeable"] as? Bool ?? false))
        }
    }
    let files = (try? FileManager.default.contentsOfDirectory(atPath: baseDir)) ?? []
    for f in files where f.hasSuffix(".ntfs3g") {
        let id = String(f.dropLast(".ntfs3g".count))
        guard let mp = try? String(contentsOfFile: ntfsStateFile(id), encoding: .utf8) else { continue }
        if isMounted(mp) {
            res.append(Opened(id: id, dev: nil, mount: mp, writable: true))
        } else {
            try? FileManager.default.removeItem(atPath: ntfsStateFile(id))   // ejected from Finder
        }
    }
    return res
}

func lockedPartitions(excluding opened: [Opened]) -> [Locked] {
    let r = run("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
    guard let d = plist(r.out) as? [String: Any],
          let disks = d["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
    let open = Set(opened.map(\.id))
    var res: [Locked] = []
    for disk in disks {
        let parts = (disk["Partitions"] as? [[String: Any]] ?? []).filter { p in
            guard let id = p["DeviceIdentifier"] as? String, !open.contains(id) else { return false }
            let mounted = !((p["MountPoint"] as? String) ?? "").isEmpty
            return !mounted && windowsContents.contains(p["Content"] as? String ?? "")
        }
        if parts.isEmpty { continue }
        let info = plist(run("/usr/sbin/diskutil", ["info", "-plist", disk["DeviceIdentifier"] as? String ?? ""]).out)
        let media = ((info as? [String: Any])?["MediaName"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        for p in parts {
            res.append(Locked(id: p["DeviceIdentifier"] as! String,
                              size: (p["Size"] as? NSNumber)?.int64Value ?? 0, media: media))
        }
    }
    return res
}

func isMounted(_ dir: String) -> Bool {
    run("/sbin/mount", []).out.contains(" on \(dir) (")
}

// MARK: - Unlock and eject

/// Makes the partition readable (and writable if `write`) by the user. Asks for the Mac password.
/// Runs off the main thread. Returns nil on success or the error message.
///
/// Uses `sudo -A` with this same app as the password window (`askpass` mode). `do shell script …
/// with administrator privileges` does not work: macOS denies it the chown of /dev
/// ("Operation not permitted") even with the right password.
func grantAccess(_ id: String, write: Bool) -> String? {
    let fm = FileManager.default
    if fm.isReadableFile(atPath: "/dev/r" + id) && (!write || fm.isWritableFile(atPath: "/dev/" + id)) { return nil }
    let user = NSUserName()
    guard id.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil,
          user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
        return L("Unexpected disk identifier or user name.", "Identificador de disco o usuario inesperado.")
    }
    let mode = write ? "600" : "400"
    let cmd = "/usr/sbin/chown \(user) /dev/\(id) /dev/r\(id) && /bin/chmod \(mode) /dev/\(id) /dev/r\(id)"
    let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let r = run("/usr/bin/sudo", ["-A", "/bin/sh", "-c", cmd],
                env: ["SUDO_ASKPASS": me, "BITLOCKERMAC_ASKPASS": "1"], timeout: 300)
    if r.status == 0 {
        log("\(write ? "Read-write" : "Read") access granted on \(id)")
        return nil
    }
    let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    log("Access on \(id) failed (\(r.status)): \(msg)")
    if msg.contains("no password was provided") || msg.contains("no askpass") { return L("Cancelled.", "Cancelado.") }
    if msg.contains("incorrect password") { return L("Wrong Mac password.", "Contraseña del Mac incorrecta.") }
    return L("Could not get access to the drive: ", "No se ha podido dar permiso sobre el disco: ") + msg
}

/// `askpass` mode for `sudo -A`: asks for the Mac password and writes it to stdout.
func askpass() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installEditMenu()
    let alert = NSAlert()
    alert.messageText = L("Mac password", "Contraseña del Mac")
    alert.informativeText = L("BitlockerMac needs it to open the encrypted drive (until you unplug it).",
                              "BitlockerMac la necesita para poder abrir el disco cifrado (hasta que lo desconectes).")
    alert.addButton(withTitle: L("OK", "Aceptar"))
    alert.addButton(withTitle: L("Cancel", "Cancelar"))
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
    print(field.stringValue)
    exit(0)
}

func isRecoveryKey(_ key: String) -> Bool {
    let digits = key.filter { $0.isASCII && $0.isNumber }
    let rest = key.filter { !($0.isASCII && $0.isNumber) && $0 != "-" && $0 != " " }
    return digits.count == 48 && rest.isEmpty
}

/// Decrypts and mounts. Returns the mount point or the error. Runs off the main thread.
func unlock(_ part: Locked, key: String, write: Bool) -> Result<String, UnlockError> {
    let dir = mountDir(part.id), dlog = dir + ".log"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if isMounted(dir) { run("/sbin/umount", [dir]) }   // leftovers from a previous attempt
    try? FileManager.default.removeItem(atPath: dlog)

    let head = (write ? [] : ["-r"]) + ["-V", "/dev/" + part.id]
    let tail = ["-l", dlog, "--", dir, "-o", "backend=fskit"]
    let r: Output
    if isRecoveryKey(key) {
        // dislocker only reads the recovery key from a terminal: it gets one with echo off.
        // Its output repeats the digits, so it is never stored anywhere.
        log("Unlocking \(part.id) with recovery key")
        let digits = String(key.filter { $0.isASCII && $0.isNumber })
        r = run("/usr/bin/script", ["-q", "/dev/null", "/bin/sh", "-c", "stty -echo; exec \"$0\" \"$@\"",
                                    dislockerPath] + head + ["-p"] + tail, input: digits + "\n")
    } else {
        log("Unlocking \(part.id) with password")
        r = run(dislockerPath, head + ["-u"] + tail, env: ["DISLOCKER_PASSWORD": key])
    }
    let dl = (try? String(contentsOfFile: dlog, encoding: .utf8)) ?? ""
    if !dl.isEmpty { log("dislocker: " + dl.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if r.status != 0 {
        log("dislocker exited with code \(r.status)")
        if isMounted(dir) { run("/sbin/umount", [dir]) }
        if (r.out + r.err).contains("extension not enabled") { return .failure(.extensionDisabled) }
        if dl.contains("VMK") { return .failure(.wrongKey) }
        if r.status == -2 { return .failure(.other(L("dislocker did not answer in time.", "dislocker no ha respondido a tiempo."))) }
        return .failure(.other(L("dislocker failed (code \(r.status)). Details in the log.",
                                 "dislocker ha fallado (código \(r.status)). Detalles en el registro.")))
    }

    let file = dir + "/dislocker-file"
    var tries = 0
    while !FileManager.default.fileExists(atPath: file) && tries < 50 {
        Thread.sleep(forTimeInterval: 0.2)
        tries += 1
    }
    guard FileManager.default.fileExists(atPath: file) else {
        run("/sbin/umount", [dir])
        return .failure(.other(L("dislocker did not create the decrypted volume.", "dislocker no ha creado el volumen descifrado.")))
    }
    // macOS only reads NTFS: writing to it needs ntfs-3g. macOS writes exFAT/FAT by itself.
    if write {
        let label = run(ntfslabelPath, [file])
        if label.status == 0 {
            return mountNTFS(part.id, file: file, label: label.out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    let a = run("/usr/bin/hdiutil", ["attach"] + (write ? [] : ["-readonly"]) +
                ["-imagekey", "diskimage-class=CRawDiskImage", "-plist", file])
    let ents = ((plist(a.out) as? [String: Any])?["system-entities"] as? [[String: Any]]) ?? []
    guard a.status == 0, let mount = ents.compactMap({ $0["mount-point"] as? String }).first else {
        log("hdiutil attach: code \(a.status) \(a.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        for dev in ents.compactMap({ $0["dev-entry"] as? String }).sorted().prefix(1) {
            run("/usr/bin/hdiutil", ["detach", dev])
        }
        run("/sbin/umount", [dir])
        return .failure(.other(L("Decrypted, but macOS does not recognise the drive's file system.",
                                 "Descifrado, pero macOS no reconoce el sistema de archivos del disco.")))
    }
    log("\(part.id) mounted on \(mount)\(write ? " (read-write)" : "")")
    return .success(mount)
}

/// Mounts read-write with ntfs-3g the NTFS that dislocker left in `file`.
func mountNTFS(_ id: String, file: String, label: String) -> Result<String, UnlockError> {
    // commas separate -o options, and / and : are not valid in a volume name. Also macFUSE 5.5 does
    // not mount in /Volumes when the name has non-ASCII characters (it fails silently): strip accents.
    var name = (label.applyingTransform(.stripDiacritics, reverse: false) ?? label)
        .replacingOccurrences(of: #"[/:,]"#, with: "-", options: .regularExpression)
        .replacingOccurrences(of: #"[^\x20-\x7E]"#, with: "_", options: .regularExpression)
    if name.isEmpty { name = "BitLocker" }
    var mp = "/Volumes/" + name, n = 2
    while FileManager.default.fileExists(atPath: mp) {
        mp = "/Volumes/\(name) \(n)"
        n += 1
    }
    // user_xattr: without it macOS cannot store extended attributes and `cp`/Finder fail to copy
    let r = run(ntfs3gPath, [file, mp, "-o", "backend=fskit,user_xattr,volname=\(name)"])
    // ntfs-3g returns before the volume shows up as mounted
    var tries = 0
    while r.status == 0 && !isMounted(mp) && tries < 20 {
        Thread.sleep(forTimeInterval: 0.5)
        tries += 1
    }
    guard r.status == 0, isMounted(mp) else {
        let msg = (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)
        log("ntfs-3g: code \(r.status) \(msg.isEmpty ? "(not mounted on \(mp))" : msg)")
        run("/usr/bin/pkill", ["-f", "\(ntfs3gPath) \(file)"])
        Thread.sleep(forTimeInterval: 1)
        run("/sbin/umount", [mountDir(id)])
        if msg.localizedCaseInsensitiveContains("hibernat") || msg.localizedCaseInsensitiveContains("unclean")
            || msg.localizedCaseInsensitiveContains("Windows cache") {
            return .failure(.other(L("Windows was not fully shut down (Fast Startup or hibernation) and writing could damage the drive. Open it read-only, or shut Windows down with Shift + “Shut down” before bringing it over.",
                                     "Windows no se apagó del todo (inicio rápido o hibernación) y escribir podría dañar el disco. Ábrelo en solo lectura, o apaga Windows con Mayúsculas + «Apagar» antes de traerlo.")))
        }
        return .failure(.other(L("ntfs-3g could not mount the drive read-write. Details in the log.",
                                 "ntfs-3g no ha podido montar el disco en escritura. Detalles en el registro.")))
    }
    try? mp.write(toFile: ntfsStateFile(id), atomically: true, encoding: .utf8)
    log("\(id) mounted on \(mp) (read-write, ntfs-3g)")
    return .success(mp)
}

enum UnlockError: Error {
    case wrongKey, extensionDisabled, other(String)
    var message: String {
        switch self {
        case .wrongKey: return L("Wrong key (or the partition is not BitLocker).", "La clave no es correcta (o la partición no es BitLocker).")
        case .extensionDisabled:
            return L("The macFUSE extension is turned off. Turn it on in System Settings → General → Login Items & Extensions → File System Extensions.",
                     "La extensión de macFUSE está desactivada. Actívala en Ajustes del Sistema → General → Ítems de inicio y extensiones → Extensiones del sistema de archivos.")
        case .other(let s): return s
        }
    }
}

/// Unmounts the volume, stops dislocker and ejects the physical drive. Returns nil or the error.
func eject(_ o: Opened) -> String? {
    let d = o.dev.map { run("/usr/bin/hdiutil", ["detach", $0]) } ?? run("/sbin/umount", [o.mount ?? ""])
    if d.status != 0 {
        log("Eject \(o.dev ?? o.mount ?? o.id): \(d.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        return L("Could not eject: a file on the drive may still be open.",
                 "No se ha podido expulsar: puede que haya algún archivo del disco abierto.")
    }
    if o.dev == nil { try? FileManager.default.removeItem(atPath: ntfsStateFile(o.id)) }
    // ntfs-3g takes a moment to let go of dislocker-file after unmounting
    var tries = 0
    while run("/sbin/umount", [mountDir(o.id)]).status != 0 && isMounted(mountDir(o.id)) && tries < 20 {
        Thread.sleep(forTimeInterval: 0.5)
        tries += 1
    }
    let e = run("/usr/sbin/diskutil", ["eject", physicalDisk(o.id)])
    log("\(o.id) ejected (physical drive: \(e.status == 0 ? "ok" : e.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
    return e.status == 0 ? nil : L("The volume was closed, but the physical drive could not be ejected.",
                                   "El volumen se ha cerrado, pero el disco físico no se ha podido expulsar.")
}

// MARK: - Unlock window

final class UnlockPanel: NSObject, NSWindowDelegate {
    let part: Locked
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let field = NSSecureTextField()
    let sub = NSTextField(labelWithString: "")
    let writeBox = NSButton(checkboxWithTitle: L("Allow writing (experimental)", "Permitir escritura (experimental)"),
                            target: nil, action: nil)
    let note = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let unlockButton = NSButton(title: L("Unlock", "Desbloquear"), target: nil, action: nil)
    let cancelButton = NSButton(title: L("Cancel", "Cancelar"), target: nil, action: nil)
    let writeBlocker = writeUnavailableReason()
    var onClose: (() -> Void)?

    init(part: Locked) {
        self.part = part
        super.init()
        window.title = L("Unlock BitLocker drive", "Desbloquear disco BitLocker")
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self

        let title = NSTextField(labelWithString: part.media.isEmpty ? L("External drive", "Disco externo") : part.media)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        sub.textColor = .secondaryLabelColor
        field.placeholderString = L("Password or recovery key (48 digits)", "Contraseña o clave de recuperación (48 dígitos)")
        writeBox.target = self; writeBox.action = #selector(writeToggled)
        writeBox.isEnabled = writeBlocker == nil
        writeBox.toolTip = writeBlocker ?? L("When writing, always eject the drive from this menu before unplugging it.",
                                             "Con escritura, expulsa siempre el disco desde este menú antes de desconectarlo.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .systemRed
        status.isHidden = true
        for l in [note, status] { l.preferredMaxLayoutWidth = 380 }
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        unlockButton.target = self; unlockButton.action = #selector(doUnlock)
        unlockButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [spinner, NSView(), cancelButton, unlockButton])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [title, sub, field, writeBox, note, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 380),
            buttons.widthAnchor.constraint(equalTo: field.widthAnchor),
        ])
        window.contentView = stack
        writeToggled()
    }

    @objc func writeToggled() {
        let write = writeBox.state == .on
        sub.stringValue = "\(part.id) · \(sizeText(part.size)) · "
            + (write ? L("will open read-write", "se abrirá en lectura y escritura")
                     : L("will open read-only", "se abrirá en solo lectura"))
        var text = write
            ? L("Always eject the drive from this menu before unplugging it. If it comes from a Windows PC that was not fully shut down, it cannot be opened for writing.",
                "Expulsa siempre el disco desde este menú antes de desconectarlo. Si el disco viene de un Windows que no se apagó del todo, no se podrá abrir en escritura.")
            : L("The first time after plugging in the drive, macOS will also ask for your Mac password.",
                "La primera vez tras conectar el disco, macOS te pedirá también tu contraseña del Mac.")
        if let writeBlocker { text += " " + writeBlocker }
        note.stringValue = text
        window.setContentSize(window.contentView!.fittingSize)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(field)
    }

    func setBusy(_ busy: Bool, _ text: String? = nil) {
        field.isEnabled = !busy
        writeBox.isEnabled = !busy && writeBlocker == nil
        unlockButton.isEnabled = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        showStatus(text, error: false)
    }

    func showStatus(_ text: String?, error: Bool) {
        status.stringValue = text ?? ""
        status.textColor = error ? .systemRed : .secondaryLabelColor
        status.isHidden = text == nil
        window.setContentSize(window.contentView!.fittingSize)
    }

    @objc func doUnlock() {
        let key = field.stringValue
        if key.isEmpty { return }
        setBusy(true, L("Waiting for permission…", "Esperando permiso…"))
        let part = self.part, write = writeBox.state == .on
        DispatchQueue.global(qos: .userInitiated).async {
            if let e = grantAccess(part.id, write: write) {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.showStatus(e, error: true)
                }
                return
            }
            DispatchQueue.main.async {
                self.setBusy(true, L("Decrypting… this may take a few seconds.", "Descifrando… puede tardar unos segundos."))
            }
            let res = unlock(part, key: key, write: write)
            DispatchQueue.main.async {
                self.setBusy(false)
                switch res {
                case .success(let mount):
                    self.field.stringValue = ""
                    self.window.close()
                    NSWorkspace.shared.open(URL(fileURLWithPath: mount))
                case .failure(let e):
                    self.showStatus(e.message, error: true)
                    self.window.makeFirstResponder(self.field)
                    self.field.selectText(nil)
                }
                controller?.scheduleRefresh()
            }
        }
    }

    @objc func cancel() { window.close() }

    func windowWillClose(_ notification: Notification) {
        field.stringValue = ""
        onClose?()
    }
}

// MARK: - Menu bar

final class MenuController: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var locked: [Locked] = []
    var opened: [Opened] = []
    var panels: [String: UnlockPanel] = [:]
    var pending: DispatchWorkItem?

    override init() {
        super.init()
        item.button?.toolTip = "BitLocker"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        setIcon()
        scheduleRefresh()
    }

    func setIcon() {
        item.button?.image = driveIcon(open: !opened.isEmpty)
    }

    /// Large external drive with a (closed or open) padlock on top: macOS has no such symbol.
    func driveIcon(open: Bool) -> NSImage? {
        guard let drive = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "BitLocker")?
                .withSymbolConfiguration(.init(pointSize: 24, weight: .regular)),
              let lock = NSImage(systemSymbolName: open ? "lock.open.fill" : "lock.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) else { return nil }
        // the drive is scaled to 21 pt high to fit the menu bar (22 pt); the padlock keeps its size
        let h: CGFloat = 21
        let size = NSSize(width: (drive.size.width * h / drive.size.height).rounded(), height: h)
        let l = lock.size
        let img = NSImage(size: size, flipped: false) { _ in
            drive.draw(in: NSRect(origin: .zero, size: size))
            let lr = NSRect(x: (size.width - l.width) / 2, y: (size.height - l.height) / 2 - 0.5,
                            width: l.width, height: l.height)
            // thin gap around the padlock so it does not merge with the drive's outline
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: lr.insetBy(dx: -0.6, dy: -0.6), xRadius: 2.5, yRadius: 2.5).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            lock.draw(in: lr)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = open ? L("BitLocker: drive open", "BitLocker: disco abierto") : "BitLocker"
        return img
    }

    /// Re-reads the disks in the background. Called when disks come and go and after every action.
    func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem {
            DispatchQueue.global(qos: .utility).async {
                let o = openedVolumes()
                let l = lockedPartitions(excluding: o)
                DispatchQueue.main.async {
                    self.opened = o
                    self.locked = l
                    self.setIcon()
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        var missing: [String] = []
        if macfuseVersion() == nil { missing.append(L("Missing macFUSE: brew install --cask macfuse", "Falta macFUSE: brew install --cask macfuse")) }
        if !FileManager.default.isExecutableFile(atPath: dislockerPath) {
            missing.append(L("Missing dislocker: brew install gromgit/fuse/dislocker-mac", "Falta dislocker: brew install gromgit/fuse/dislocker-mac"))
        }
        for m in missing { add(m, nil, nil).isEnabled = false }
        if !missing.isEmpty { menu.addItem(.separator()) }
        if !opened.isEmpty {
            menu.addItem(.sectionHeader(title: L("Open drives", "Discos abiertos")))
            for o in opened {
                let name = (o.mount.map { URL(fileURLWithPath: $0).lastPathComponent } ?? o.id)
                    + (o.writable ? L(" (read-write)", " (escritura)") : "")
                add(L("Open “\(name)”", "Abrir «\(name)»"), #selector(openInFinder(_:)), o.mount, symbol: "folder")
                    .isEnabled = o.mount != nil
                add(L("Eject “\(name)”", "Expulsar «\(name)»"), #selector(ejectItem(_:)), o.id, symbol: "eject")
            }
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: L("Locked BitLocker drives", "Discos BitLocker cerrados")))
        if locked.isEmpty {
            add(L("No encrypted drive connected", "No hay ningún disco cifrado conectado"), nil, nil).isEnabled = false
        }
        for p in locked {
            let name = p.media.isEmpty ? p.id : p.media
            add(L("Unlock \(name) · \(sizeText(p.size))…", "Desbloquear \(name) · \(sizeText(p.size))…"),
                #selector(unlockItem(_:)), p.id, symbol: "key")
        }
        menu.addItem(.separator())
        add(L("Show log", "Ver registro"), #selector(showLog), nil)
        add(L("Quit", "Salir"), #selector(quit), nil)
        scheduleRefresh()
    }

    @discardableResult
    func add(_ title: String, _ action: Selector?, _ obj: Any?, symbol: String? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        mi.representedObject = obj
        if let symbol { mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(mi)
        return mi
    }

    @objc func unlockItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let part = locked.first(where: { $0.id == id }) else { return }
        if let p = panels[id] { p.show(); return }
        let p = UnlockPanel(part: part)
        p.onClose = { [weak self] in self?.panels[id] = nil }
        panels[id] = p
        p.show()
    }

    @objc func openInFinder(_ sender: NSMenuItem) {
        if let m = sender.representedObject as? String { NSWorkspace.shared.open(URL(fileURLWithPath: m)) }
    }

    @objc func ejectItem(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let o = opened.first(where: { $0.id == id }) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let err = eject(o)
            DispatchQueue.main.async {
                self.scheduleRefresh()
                guard let err else { return }
                let alert = NSAlert()
                alert.messageText = L("Could not eject the drive", "No se ha podido expulsar el disco")
                alert.informativeText = err
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc func quit() { NSApp.terminate(nil) }
}

// Without a main menu, an app with no Dock icon does not get ⌘V in the key field.
func installEditMenu() {
    let main = NSMenu(), editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    editItem.submenu = edit
    main.addItem(editItem)
    NSApp.mainMenu = main
}

func watchDisks() {
    guard let session = DASessionCreate(kCFAllocatorDefault) else { return }
    DARegisterDiskAppearedCallback(session, nil, { _, _ in controller?.scheduleRefresh() }, nil)
    DARegisterDiskDisappearedCallback(session, nil, { _, _ in controller?.scheduleRefresh() }, nil)
    DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, _ in controller?.scheduleRefresh() }, nil)
    DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    daSession = session
}

var controller: MenuController?
var daSession: DASession?

// sudo calls the askpass program with its own prompt ("Password:") as argument: it is recognised by the environment
if ProcessInfo.processInfo.environment["BITLOCKERMAC_ASKPASS"] == "1" { askpass() }
if CommandLine.arguments.dropFirst().first == "version" {
    print("BitlockerMac \(version)")
    exit(0)
}
signal(SIGPIPE, SIG_IGN)   // writing the key to a process that already exited must not kill the app
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // no Dock icon
installEditMenu()
log("BitlockerMac \(version) starting")
controller = MenuController()
watchDisks()
app.run()
