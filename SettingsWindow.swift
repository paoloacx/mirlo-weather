// Ventana de Ajustes: abrir al iniciar sesión y actualizaciones.
import AppKit
import ServiceManagement

// ------------------------- iniciar al arrancar -------------------------
enum LoginItem {
    static let label = "com.paoloac.mirloweather"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            let status = SMAppService.mainApp.status
            return status == .enabled || status == .requiresApproval
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static var needsApproval: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .requiresApproval
        }
        return false
    }

    static func setEnabled(_ enabled: Bool) throws {
        if #available(macOS 13.0, *) {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return
        }

        #if APPSTORE
        throw NSError(domain: "MirloWeather.LoginItem", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Requiere macOS 13 o posterior.")])
        #else
        if enabled {
            try installAgent()
        } else {
            try removeAgent()
        }
        #endif
    }

    static func openSystemSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.users") {
            NSWorkspace.shared.open(url)
        }
    }

    #if !APPSTORE
    // ------------------------- macOS 12 -------------------------
    private static func installAgent() throws {
        let executable = Bundle.main.executablePath ?? ""
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        let folder = agentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: agentURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: agentURL.path
        )
        try runLaunchctl(["load", "-w", agentURL.path])
    }

    private static func removeAgent() throws {
        if FileManager.default.fileExists(atPath: agentURL.path) {
            try? runLaunchctl(["unload", "-w", agentURL.path])
            try FileManager.default.removeItem(at: agentURL)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(
                domain: "MirloWeather.LoginItem",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: text.isEmpty
                    ? L("launchctl devolvió un error.")
                    : text]
            )
        }
    }
    #endif
}

// ------------------------- ventana -------------------------
final class SettingsWindow: NSObject, NSWindowDelegate {
    #if !APPSTORE
    var onAutoUpdateChanged: ((Bool) -> Void)?
    var onCheckNow: (() -> Void)?
    #endif
    var onHighlightChanged: ((Bool, NSColor, String, Set<String>) -> Void)?
    var onLanguageChanged: ((String) -> Void)?

    private let window: NSWindow
    private let loginCheck = NSButton(
        checkboxWithTitle: L("Abrir Mirlo Weather al iniciar sesión"),
        target: nil,
        action: nil
    )
    private let languageLabel = NSTextField(labelWithString: L("Idioma"))
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var languageOptions: [(clave: String, titulo: String)] {
        [
            ("auto", L("Automático (sistema)")),
            ("es", "Español"),
            ("en", "English"),
        ]
    }
    #if !APPSTORE
    private let autoCheck = NSButton(
        checkboxWithTitle: L("Buscar actualizaciones automáticamente"),
        target: nil,
        action: nil
    )
    #endif
    private let highlightCheck = NSButton(
        checkboxWithTitle: L("Destacar los datos con color"),
        target: nil,
        action: nil
    )
    private let colorWell = NSColorWell(frame: .zero)
    private let colorPreview = NSTextField(labelWithString: fmtTemp(21.5))
    private let textLabel = NSTextField(labelWithString: L("Texto del resaltado"))
    private let textPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var textOptions: [(clave: String, titulo: String)] {
        [
            ("auto", L("Automático")),
            ("blanco", L("Blanco")),
            ("negro", L("Negro")),
        ]
    }
    private var itemChecks: [String: NSButton] = [:]
    private var highlightKeys: [(clave: String, titulo: String)] {
        [
            ("exterior", L("Exterior")),
            ("interior", L("Interior")),
            ("termostato", L("Termostato")),
            ("caldera", L("Caldera")),
            ("viento", L("Viento")),
            ("lluvia", L("Lluvia")),
            ("estacion", L("Estación cercana")),
            ("otras", L("Otras estaciones")),
        ]
    }
    #if !APPSTORE
    private let statusLabel = NSTextField(labelWithString: "")
    private let checkButton = NSButton(title: L("Buscar ahora"), target: nil, action: nil)
    #endif
    private let approvalLabel = NSTextField(labelWithString: "")

    init(currentVersion: String) {
        let content = NSRect(x: 0, y: 0, width: 440, height: 590)
        window = NSWindow(
            contentRect: content,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = L("Ajustes")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        buildContent(currentVersion: currentVersion)
    }

    private func buildContent(currentVersion: String) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 590))
        root.wantsLayer = true
        #if APPSTORE
        // Sin sección de actualizaciones: ventana más baja, contenido anclado arriba.
        let recorte: CGFloat = 130
        let contenedor = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 590 - recorte))
        root.frame.origin.y = -recorte
        contenedor.addSubview(root)
        window.contentView = contenedor
        window.setContentSize(NSSize(width: 440, height: 590 - recorte))
        #else
        window.contentView = root
        #endif

        let icon = NSImageView(frame: NSRect(x: 24, y: 504, width: 52, height: 52))
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(icon)

        let title = NSTextField(labelWithString: "Mirlo Weather")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: 90, y: 538, width: 326, height: 22)
        root.addSubview(title)

        let version = NSTextField(labelWithString: L("Versión %@", currentVersion))
        version.font = NSFont.systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.frame = NSRect(x: 90, y: 517, width: 326, height: 17)
        root.addSubview(version)

        addSeparator(root, y: 494)

        let general = sectionLabel(L("General"))
        general.frame = NSRect(x: 24, y: 464, width: 392, height: 16)
        root.addSubview(general)

        loginCheck.target = self
        loginCheck.action = #selector(toggleLogin(_:))
        loginCheck.frame = NSRect(x: 24, y: 436, width: 392, height: 20)
        root.addSubview(loginCheck)

        approvalLabel.font = NSFont.systemFont(ofSize: 11)
        approvalLabel.textColor = .secondaryLabelColor
        approvalLabel.frame = NSRect(x: 44, y: 416, width: 372, height: 16)
        approvalLabel.isHidden = true
        root.addSubview(approvalLabel)

        languageLabel.font = NSFont.systemFont(ofSize: 12)
        languageLabel.frame = NSRect(x: 24, y: 386, width: 120, height: 18)
        root.addSubview(languageLabel)

        languagePopup.font = NSFont.systemFont(ofSize: 12)
        languagePopup.addItems(withTitles: languageOptions.map { $0.titulo })
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.frame = NSRect(x: 150, y: 382, width: 190, height: 24)
        root.addSubview(languagePopup)

        addSeparator(root, y: 368)

        let appearance = sectionLabel(L("Menú"))
        appearance.frame = NSRect(x: 24, y: 342, width: 392, height: 16)
        root.addSubview(appearance)

        highlightCheck.target = self
        highlightCheck.action = #selector(toggleHighlight(_:))
        highlightCheck.frame = NSRect(x: 24, y: 314, width: 248, height: 20)
        root.addSubview(highlightCheck)

        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorWell.frame = NSRect(x: 276, y: 308, width: 30, height: 30)
        root.addSubview(colorWell)

        colorPreview.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        colorPreview.frame = NSRect(x: 314, y: 315, width: 92, height: 18)
        root.addSubview(colorPreview)

        textLabel.font = NSFont.systemFont(ofSize: 11)
        textLabel.textColor = .secondaryLabelColor
        textLabel.frame = NSRect(x: 24, y: 286, width: 150, height: 16)
        root.addSubview(textLabel)

        textPopup.font = NSFont.systemFont(ofSize: 11)
        textPopup.addItems(withTitles: textOptions.map { $0.titulo })
        textPopup.target = self
        textPopup.action = #selector(textChanged(_:))
        textPopup.frame = NSRect(x: 176, y: 280, width: 130, height: 24)
        root.addSubview(textPopup)

        let bloques = NSTextField(labelWithString: L("Bloques a resaltar"))
        bloques.font = NSFont.systemFont(ofSize: 11)
        bloques.textColor = .secondaryLabelColor
        bloques.frame = NSRect(x: 24, y: 258, width: 392, height: 16)
        root.addSubview(bloques)

        for (indice, par) in highlightKeys.enumerated() {
            let columna = indice % 2
            let fila = indice / 2
            let check = NSButton(
                checkboxWithTitle: par.titulo,
                target: self,
                action: #selector(toggleItem(_:))
            )
            check.tag = indice
            check.frame = NSRect(
                x: 24 + CGFloat(columna) * 210,
                y: 232 - CGFloat(fila) * 26,
                width: 200,
                height: 20
            )
            itemChecks[par.clave] = check
            root.addSubview(check)
        }

        #if !APPSTORE
        addSeparator(root, y: 138)

        let updates = sectionLabel(L("Actualizaciones"))
        updates.frame = NSRect(x: 24, y: 112, width: 392, height: 16)
        root.addSubview(updates)

        autoCheck.target = self
        autoCheck.action = #selector(toggleAutoCheck(_:))
        autoCheck.frame = NSRect(x: 24, y: 84, width: 392, height: 20)
        root.addSubview(autoCheck)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2
        statusLabel.frame = NSRect(x: 24, y: 42, width: 392, height: 34)
        root.addSubview(statusLabel)

        checkButton.target = self
        checkButton.action = #selector(checkNow(_:))
        checkButton.bezelStyle = .rounded
        checkButton.frame = NSRect(x: 24, y: 8, width: 128, height: 30)
        root.addSubview(checkButton)

        let repo = Updater.shared.repository
        let repoLabel = NSTextField(labelWithString: repo.isEmpty
            ? L("Repositorio sin configurar")
            : "GitHub: \(repo)")
        repoLabel.font = NSFont.systemFont(ofSize: 10)
        repoLabel.textColor = .tertiaryLabelColor
        repoLabel.alignment = .right
        repoLabel.frame = NSRect(x: 164, y: 15, width: 252, height: 16)
        root.addSubview(repoLabel)
        #endif
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return label
    }

    private func addSeparator(_ root: NSView, y: CGFloat) {
        let line = NSBox(frame: NSRect(x: 24, y: y, width: 392, height: 1))
        line.boxType = .separator
        root.addSubview(line)
    }

    // ------------------------- API -------------------------
    var frameOrigin: NSPoint { window.frame.origin }

    func setFrameOrigin(_ point: NSPoint) {
        window.setFrameOrigin(point)
    }

    func close() {
        window.close()
    }
    #if APPSTORE
    func show(
        language: String,
        highlight: Bool,
        color: NSColor,
        textColor: String,
        highlightItems: Set<String>
    ) {
        mostrar(language: language, highlight: highlight, color: color, textColor: textColor, highlightItems: highlightItems)
    }
    #else
    func show(
        language: String,
        autoUpdate: Bool,
        status: String,
        highlight: Bool,
        color: NSColor,
        textColor: String,
        highlightItems: Set<String>
    ) {
        autoCheck.state = autoUpdate ? .on : .off
        statusLabel.stringValue = status
        mostrar(language: language, highlight: highlight, color: color, textColor: textColor, highlightItems: highlightItems)
    }
    #endif

    private func mostrar(
        language: String,
        highlight: Bool,
        color: NSColor,
        textColor: String,
        highlightItems: Set<String>
    ) {
        loginCheck.state = LoginItem.isEnabled ? .on : .off
        if let indice = languageOptions.firstIndex(where: { $0.clave == language }) {
            languagePopup.selectItem(at: indice)
        } else {
            languagePopup.selectItem(at: 0)
        }
        highlightCheck.state = highlight ? .on : .off
        colorWell.color = color
        colorWell.isEnabled = highlight
        if let indice = textOptions.firstIndex(where: { $0.clave == textColor }) {
            textPopup.selectItem(at: indice)
        }
        textPopup.isEnabled = highlight
        for (clave, check) in itemChecks {
            check.state = highlightItems.contains(clave) ? .on : .off
            check.isEnabled = highlight
        }
        actualizarPreview(color)
        approvalLabel.isHidden = !LoginItem.needsApproval
        approvalLabel.stringValue = LoginItem.needsApproval
            ? L("macOS debe aprobar la app en Ajustes del Sistema.")
            : ""

        NSApp.activate(ignoringOtherApps: true)
        NSColorPanel.shared.showsAlpha = false
        window.makeKeyAndOrderFront(nil)
    }

    #if !APPSTORE
    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    func setChecking(_ checking: Bool) {
        checkButton.isEnabled = !checking
        checkButton.title = checking ? L("Buscando…") : L("Buscar ahora")
    }
    #endif

    // ------------------------- acciones -------------------------
    @objc private func toggleLogin(_ sender: NSButton) {
        let enable = sender.state == .on
        do {
            try LoginItem.setEnabled(enable)
            approvalLabel.isHidden = !LoginItem.needsApproval
            approvalLabel.stringValue = LoginItem.needsApproval
                ? L("macOS debe aprobar la app en Ajustes del Sistema.")
                : ""

            if enable && LoginItem.needsApproval {
                let alert = NSAlert()
                alert.messageText = L("Confirma el inicio automático")
                alert.informativeText = L("macOS ha registrado Mirlo Weather, pero necesita tu aprobación en Ajustes del Sistema → General → Inicio de sesión.")
                alert.addButton(withTitle: L("Abrir Ajustes del Sistema"))
                alert.addButton(withTitle: L("Ahora no"))
                if alert.runModal() == .alertFirstButtonReturn {
                    LoginItem.openSystemSettings()
                }
            }
        } catch {
            sender.state = enable ? .off : .on
            showAlert(
                L("No se pudo cambiar el inicio automático"),
                error.localizedDescription + "\n\n" + L("Si la app está fuera de la carpeta Aplicaciones, muévela allí y vuelve a intentarlo.")
            )
        }
    }

    #if !APPSTORE
    @objc private func toggleAutoCheck(_ sender: NSButton) {
        onAutoUpdateChanged?(sender.state == .on)
    }
    #endif

    @objc private func toggleHighlight(_ sender: NSButton) {
        let activo = sender.state == .on
        colorWell.isEnabled = activo
        textPopup.isEnabled = activo
        for check in itemChecks.values { check.isEnabled = activo }
        actualizarPreview(colorWell.color)
        notificarDestacado()
    }

    @objc private func toggleItem(_ sender: NSButton) {
        notificarDestacado()
    }

    @objc private func textChanged(_ sender: NSPopUpButton) {
        notificarDestacado()
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let indice = max(0, sender.indexOfSelectedItem)
        let codigo = indice < languageOptions.count ? languageOptions[indice].clave : "auto"
        onLanguageChanged?(codigo)
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        // Un color solido: se descarta cualquier transparencia.
        let solido = sender.color.withAlphaComponent(1)
        sender.color = solido
        actualizarPreview(solido)
        notificarDestacado()
    }

    private func notificarDestacado() {
        let activo = highlightCheck.state == .on
        let items = Set(itemChecks.compactMap { clave, check in
            check.state == .on ? clave : nil
        })
        let indice = max(0, textPopup.indexOfSelectedItem)
        let texto = indice < textOptions.count ? textOptions[indice].clave : "auto"
        onHighlightChanged?(activo, colorWell.color, texto, items)
    }

    private func actualizarPreview(_ color: NSColor) {
        colorPreview.textColor = color
        colorPreview.stringValue = fmtTemp(21.5)
    }

    #if !APPSTORE
    @objc private func checkNow(_ sender: Any?) {
        onCheckNow?()
    }
    #endif

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("Aceptar"))
        alert.runModal()
    }
}
