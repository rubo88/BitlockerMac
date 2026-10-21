// bitlocker-menu: icono en la barra de menús para abrir discos externos cifrados con BitLocker.
//
// Usa dislocker con macFUSE en modo FSKit (sin extensión del kernel ni bajar la seguridad del Mac).
//
//   1. Con la contraseña del Mac, la partición cifrada pasa a ser legible (o legible y escribible)
//      por el usuario. macOS lo deshace solo al desconectar el disco.
//   2. dislocker-fuse se ejecuta como el usuario (FSKit solo funciona así) y deja en
//      ~/Library/Caches/bitlocker-menu/<diskXsY>/dislocker-file el volumen descifrado.
//   3. Solo lectura: hdiutil adjunta ese fichero y macOS lo monta con su NTFS/exFAT nativo.
//      Escritura (experimental): ntfs-3g lo monta en /Volumes, también con FSKit; si no es NTFS
//      (exFAT/FAT de BitLocker To Go), hdiutil lo adjunta en escritura con el soporte de macOS.
//
// La clave nunca va en los argumentos (los ve cualquiera con `ps`) ni en ningún registro:
// la contraseña va por la variable DISLOCKER_PASSWORD y la clave de recuperación se teclea
// en un pseudoterminal sin eco.

import AppKit
import DiskArbitration

let version = "1.1.0"
let dislockerPath = "/opt/homebrew/bin/dislocker-fuse"
let ntfs3gPath = "/opt/homebrew/bin/ntfs-3g"
let ntfslabelPath = "/opt/homebrew/sbin/ntfslabel"
let home = NSHomeDirectory()
// macFUSE 5.4 (FSKit) no montaba en rutas con espacios: por eso Caches y no Application Support
let baseDir = home + "/Library/Caches/bitlocker-menu"
let logPath = home + "/Library/Logs/bitlocker-menu.log"
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

// MARK: - Procesos

final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

struct Output { var status: Int32; var out: String; var err: String }

/// Ejecuta un programa y espera a que acabe. `input` se escribe en su entrada un segundo después
/// de arrancar (deja tiempo a `stty -echo` dentro del pseudoterminal) y la entrada sigue abierta
/// hasta el final: si `script` viera fin de fichero, colgaría el terminal antes de tiempo.
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

// MARK: - Discos

/// Partición de Windows sin montar en un disco externo: candidata a ser BitLocker.
struct Locked { let id: String; let size: Int64; let media: String }
/// Volumen descifrado y montado por esta app. `dev` es el disco de hdiutil; nil si lo monta ntfs-3g.
struct Opened { let id: String; let dev: String?; let mount: String?; let writable: Bool }

func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
func mountDir(_ id: String) -> String { baseDir + "/" + id }
/// Guarda dónde montó ntfs-3g cada volumen: con FSKit, `mount` no dice qué fichero hay detrás.
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
            try? FileManager.default.removeItem(atPath: ntfsStateFile(id))   // expulsado desde Finder
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

// MARK: - Desbloquear y expulsar

/// Hace la partición legible (y escribible si `write`) por el usuario. Pide la contraseña del Mac.
/// Va fuera del hilo principal. Devuelve nil si todo va bien o el mensaje de error.
///
/// Usa `sudo -A` con esta misma app como ventana de contraseña (modo `askpass`). No sirve
/// `do shell script … with administrator privileges`: macOS le deniega el chown de /dev
/// ("Operation not permitted") aunque la contraseña sea correcta.
func grantAccess(_ id: String, write: Bool) -> String? {
    let fm = FileManager.default
    if fm.isReadableFile(atPath: "/dev/r" + id) && (!write || fm.isWritableFile(atPath: "/dev/" + id)) { return nil }
    let user = NSUserName()
    guard id.range(of: #"^disk\d+s\d+$"#, options: .regularExpression) != nil,
          user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
        return "Identificador de disco o usuario inesperado."
    }
    let mode = write ? "600" : "400"
    let cmd = "/usr/sbin/chown \(user) /dev/\(id) /dev/r\(id) && /bin/chmod \(mode) /dev/\(id) /dev/r\(id)"
    let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let r = run("/usr/bin/sudo", ["-A", "/bin/sh", "-c", cmd],
                env: ["SUDO_ASKPASS": me, "BITLOCKER_MENU_ASKPASS": "1"], timeout: 300)
    if r.status == 0 {
        log("Permiso de \(write ? "lectura y escritura" : "lectura") concedido en \(id)")
        return nil
    }
    let msg = r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    log("Permiso en \(id) fallido (\(r.status)): \(msg)")
    if msg.contains("no password was provided") || msg.contains("no askpass") { return "Cancelado." }
    if msg.contains("incorrect password") { return "Contraseña del Mac incorrecta." }
    return "No se ha podido dar permiso sobre el disco: \(msg)"
}

/// Modo `askpass` para `sudo -A`: pide la contraseña del Mac y la escribe por la salida estándar.
func askpass() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installEditMenu()
    let alert = NSAlert()
    alert.messageText = "Contraseña del Mac"
    alert.informativeText = "bitlocker-menu la necesita para poder abrir el disco cifrado (hasta que lo desconectes)."
    alert.addButton(withTitle: "Aceptar")
    alert.addButton(withTitle: "Cancelar")
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

/// Descifra y monta. Devuelve el punto de montaje o el mensaje de error. Va fuera del hilo principal.
func unlock(_ part: Locked, key: String, write: Bool) -> Result<String, UnlockError> {
    let dir = mountDir(part.id), dlog = dir + ".log"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    if isMounted(dir) { run("/sbin/umount", [dir]) }   // restos de un intento anterior
    try? FileManager.default.removeItem(atPath: dlog)

    let head = (write ? [] : ["-r"]) + ["-V", "/dev/" + part.id]
    let tail = ["-l", dlog, "--", dir, "-o", "backend=fskit"]
    let r: Output
    if isRecoveryKey(key) {
        // dislocker solo lee la clave de recuperación desde un terminal: se le da uno sin eco.
        // Su salida repite los dígitos, así que no se guarda en ningún sitio.
        log("Desbloqueando \(part.id) con clave de recuperación")
        let digits = String(key.filter { $0.isASCII && $0.isNumber })
        r = run("/usr/bin/script", ["-q", "/dev/null", "/bin/sh", "-c", "stty -echo; exec \"$0\" \"$@\"",
                                    dislockerPath] + head + ["-p"] + tail, input: digits + "\n")
    } else {
        log("Desbloqueando \(part.id) con contraseña")
        r = run(dislockerPath, head + ["-u"] + tail, env: ["DISLOCKER_PASSWORD": key])
    }
    let dl = (try? String(contentsOfFile: dlog, encoding: .utf8)) ?? ""
    if !dl.isEmpty { log("dislocker: " + dl.trimmingCharacters(in: .whitespacesAndNewlines)) }
    if r.status != 0 {
        log("dislocker terminó con código \(r.status)")
        if isMounted(dir) { run("/sbin/umount", [dir]) }
        if (r.out + r.err).contains("extension not enabled") { return .failure(.extensionDisabled) }
        if dl.contains("VMK") { return .failure(.wrongKey) }
        if r.status == -2 { return .failure(.other("dislocker no ha respondido a tiempo.")) }
        return .failure(.other("dislocker ha fallado (código \(r.status)). Detalles en el registro."))
    }

    let file = dir + "/dislocker-file"
    var tries = 0
    while !FileManager.default.fileExists(atPath: file) && tries < 50 {
        Thread.sleep(forTimeInterval: 0.2)
        tries += 1
    }
    guard FileManager.default.fileExists(atPath: file) else {
        run("/sbin/umount", [dir])
        return .failure(.other("dislocker no ha creado el volumen descifrado."))
    }
    // macOS solo lee NTFS: para escribir en él hace falta ntfs-3g. exFAT/FAT los escribe macOS.
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
        log("hdiutil attach: código \(a.status) \(a.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        for dev in ents.compactMap({ $0["dev-entry"] as? String }).sorted().prefix(1) {
            run("/usr/bin/hdiutil", ["detach", dev])
        }
        run("/sbin/umount", [dir])
        return .failure(.other("Descifrado, pero macOS no reconoce el sistema de archivos del disco."))
    }
    log("\(part.id) montado en \(mount)\(write ? " (escritura)" : "")")
    return .success(mount)
}

/// Monta en lectura y escritura con ntfs-3g el NTFS que dislocker ha dejado en `file`.
func mountNTFS(_ id: String, file: String, label: String) -> Result<String, UnlockError> {
    // las comas separan opciones de -o, y / y : no valen en un nombre de volumen
    var name = label.replacingOccurrences(of: #"[/:,]"#, with: "-", options: .regularExpression)
    if name.isEmpty { name = "BitLocker" }
    var mp = "/Volumes/" + name, n = 2
    while FileManager.default.fileExists(atPath: mp) {
        mp = "/Volumes/\(name) \(n)"
        n += 1
    }
    // user_xattr: sin él macOS no puede guardar atributos extendidos y `cp`/Finder fallan al copiar
    let r = run(ntfs3gPath, [file, mp, "-o", "backend=fskit,user_xattr,volname=\(name)"])
    guard r.status == 0, isMounted(mp) else {
        let msg = (r.err + r.out).trimmingCharacters(in: .whitespacesAndNewlines)
        log("ntfs-3g: código \(r.status) \(msg)")
        run("/sbin/umount", [mountDir(id)])
        if msg.localizedCaseInsensitiveContains("hibernat") || msg.localizedCaseInsensitiveContains("unclean")
            || msg.localizedCaseInsensitiveContains("Windows cache") {
            return .failure(.other("Windows no se apagó del todo (inicio rápido o hibernación) y escribir podría dañar el disco. Ábrelo en solo lectura, o apaga Windows con Mayúsculas + «Apagar» antes de traerlo."))
        }
        return .failure(.other("ntfs-3g no ha podido montar el disco en escritura. Detalles en el registro."))
    }
    try? mp.write(toFile: ntfsStateFile(id), atomically: true, encoding: .utf8)
    log("\(id) montado en \(mp) (escritura, ntfs-3g)")
    return .success(mp)
}

enum UnlockError: Error {
    case wrongKey, extensionDisabled, other(String)
    var message: String {
        switch self {
        case .wrongKey: return "La clave no es correcta (o la partición no es BitLocker)."
        case .extensionDisabled:
            return "La extensión de macFUSE está desactivada. Actívala en Ajustes del Sistema → General → Ítems de inicio y extensiones → Extensiones del sistema de archivos."
        case .other(let s): return s
        }
    }
}

/// Desmonta el volumen, cierra dislocker y expulsa el disco físico. Devuelve nil o el error.
func eject(_ o: Opened) -> String? {
    let d = o.dev.map { run("/usr/bin/hdiutil", ["detach", $0]) } ?? run("/sbin/umount", [o.mount ?? ""])
    if d.status != 0 {
        log("Expulsar \(o.dev ?? o.mount ?? o.id): \(d.err.trimmingCharacters(in: .whitespacesAndNewlines))")
        return "No se ha podido expulsar: puede que haya algún archivo del disco abierto."
    }
    if o.dev == nil { try? FileManager.default.removeItem(atPath: ntfsStateFile(o.id)) }
    // ntfs-3g tarda un momento en soltar dislocker-file después de desmontar
    var tries = 0
    while run("/sbin/umount", [mountDir(o.id)]).status != 0 && isMounted(mountDir(o.id)) && tries < 20 {
        Thread.sleep(forTimeInterval: 0.5)
        tries += 1
    }
    let e = run("/usr/sbin/diskutil", ["eject", physicalDisk(o.id)])
    log("\(o.id) expulsado (disco físico: \(e.status == 0 ? "ok" : e.err.trimmingCharacters(in: .whitespacesAndNewlines)))")
    return e.status == 0 ? nil : "El volumen se ha cerrado, pero el disco físico no se ha podido expulsar."
}

// MARK: - Ventana de desbloqueo

final class UnlockPanel: NSObject, NSWindowDelegate {
    let part: Locked
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let field = NSSecureTextField()
    let sub = NSTextField(labelWithString: "")
    let writeBox = NSButton(checkboxWithTitle: "Permitir escritura (experimental)", target: nil, action: nil)
    let note = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    let spinner = NSProgressIndicator()
    let unlockButton = NSButton(title: "Desbloquear", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancelar", target: nil, action: nil)
    var onClose: (() -> Void)?

    init(part: Locked) {
        self.part = part
        super.init()
        window.title = "Desbloquear disco BitLocker"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self

        let title = NSTextField(labelWithString: part.media.isEmpty ? "Disco externo" : part.media)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        sub.textColor = .secondaryLabelColor
        field.placeholderString = "Contraseña o clave de recuperación (48 dígitos)"
        writeBox.target = self; writeBox.action = #selector(writeToggled)
        writeBox.toolTip = "Con escritura, expulsa siempre el disco desde este menú antes de desconectarlo."
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
        sub.stringValue = "\(part.id) · \(sizeText(part.size)) · se abrirá en "
            + (write ? "lectura y escritura" : "solo lectura")
        note.stringValue = write
            ? "Expulsa siempre el disco desde este menú antes de desconectarlo. Si el disco viene de un Windows que no se apagó del todo, no se podrá abrir en escritura."
            : "La primera vez tras conectar el disco, macOS te pedirá también tu contraseña del Mac."
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
        writeBox.isEnabled = !busy
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
        setBusy(true, "Esperando permiso…")
        let part = self.part, write = writeBox.state == .on
        DispatchQueue.global(qos: .userInitiated).async {
            if let e = grantAccess(part.id, write: write) {
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.showStatus(e, error: true)
                }
                return
            }
            DispatchQueue.main.async { self.setBusy(true, "Descifrando… puede tardar unos segundos.") }
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

// MARK: - Barra de menús

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

    /// Disco externo grande con un candado (cerrado o abierto) encima: macOS no trae ese símbolo.
    func driveIcon(open: Bool) -> NSImage? {
        guard let drive = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "BitLocker")?
                .withSymbolConfiguration(.init(pointSize: 24, weight: .regular)),
              let lock = NSImage(systemSymbolName: open ? "lock.open.fill" : "lock.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold)) else { return nil }
        // el disco se escala a 21 pt de alto para caber en la barra (22 pt); el candado mantiene su tamaño
        let h: CGFloat = 21
        let size = NSSize(width: (drive.size.width * h / drive.size.height).rounded(), height: h)
        let l = lock.size
        let img = NSImage(size: size, flipped: false) { _ in
            drive.draw(in: NSRect(origin: .zero, size: size))
            let lr = NSRect(x: (size.width - l.width) / 2, y: (size.height - l.height) / 2 - 0.5,
                            width: l.width, height: l.height)
            // hueco fino alrededor del candado para que no se funda con el contorno del disco
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(roundedRect: lr.insetBy(dx: -0.6, dy: -0.6), xRadius: 2.5, yRadius: 2.5).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            lock.draw(in: lr)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = open ? "BitLocker: disco abierto" : "BitLocker"
        return img
    }

    /// Relee los discos en segundo plano. Se llama al conectar o desconectar discos y tras cada acción.
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
        if !FileManager.default.isExecutableFile(atPath: dislockerPath) {
            add("Falta dislocker: brew install gromgit/fuse/dislocker-mac", nil, nil).isEnabled = false
            menu.addItem(.separator())
        }
        if !opened.isEmpty {
            menu.addItem(.sectionHeader(title: "Discos abiertos"))
            for o in opened {
                let name = (o.mount.map { URL(fileURLWithPath: $0).lastPathComponent } ?? o.id)
                    + (o.writable ? " (escritura)" : "")
                add("Abrir «\(name)»", #selector(openInFinder(_:)), o.mount, symbol: "folder").isEnabled = o.mount != nil
                add("Expulsar «\(name)»", #selector(ejectItem(_:)), o.id, symbol: "eject")
            }
            menu.addItem(.separator())
        }
        menu.addItem(.sectionHeader(title: "Discos BitLocker cerrados"))
        if locked.isEmpty {
            add("No hay ningún disco cifrado conectado", nil, nil).isEnabled = false
        }
        for p in locked {
            let name = p.media.isEmpty ? p.id : p.media
            add("Desbloquear \(name) · \(sizeText(p.size))…", #selector(unlockItem(_:)), p.id, symbol: "key")
        }
        menu.addItem(.separator())
        add("Ver registro", #selector(showLog), nil)
        add("Salir", #selector(quit), nil)
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
                alert.messageText = "No se ha podido expulsar el disco"
                alert.informativeText = err
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func showLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc func quit() { NSApp.terminate(nil) }
}

// Sin menú principal, una app sin icono en el Dock no recibe ⌘V en el campo de la clave.
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

// sudo llama al askpass con su propio texto («Password:») como argumento: se reconoce por el entorno
if ProcessInfo.processInfo.environment["BITLOCKER_MENU_ASKPASS"] == "1" { askpass() }
if CommandLine.arguments.dropFirst().first == "version" {
    print("bitlocker-menu \(version)")
    exit(0)
}
signal(SIGPIPE, SIG_IGN)   // escribir la clave a un proceso que ya ha terminado no debe tumbar la app
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // sin icono en el Dock
installEditMenu()
log("bitlocker-menu \(version) arrancando")
controller = MenuController()
watchDisks()
app.run()
