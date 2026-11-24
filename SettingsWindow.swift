// Ventana única de Ajustes: barra lateral nativa y secciones.
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
            try? FileManager.default.removeItem(at: agentURL)
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

// ------------------------- secciones y datos -------------------------
enum SeccionAjustes: String, CaseIterable {
    case general
    case barra
    case estaciones
    case avisos
    case avanzado

    var titulo: String {
        switch self {
        case .general: return L("General")
        case .barra: return L("Barra y menú")
        case .estaciones: return L("Estaciones")
        case .avisos: return L("Avisos")
        case .avanzado: return L("Avanzado")
        }
    }

    var simbolo: String {
        switch self {
        case .general: return "gearshape"
        case .barra: return "menubar.rectangle"
        case .estaciones: return "house"
        case .avisos: return "bell.badge"
        case .avanzado: return "wrench.and.screwdriver"
        }
    }
}

struct ModuloAjustes {
    let nombre: String
    let tipo: String
}

struct EstacionAjustes {
    let nombre: String
    let modulos: [ModuloAjustes]
}

struct ResumenEstacionesAjustes {
    let modo: String
    let detalle: String
    let estaciones: [EstacionAjustes]
    let publica: String?
    // Nombre de la estación elegida ("" o nil = la de Netatmo).
    let principalActual: String?
    let principales: [String]
}

// ------------------------- ventana -------------------------
final class SettingsWindow: NSObject, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    #if !APPSTORE
    var onAutoUpdateChanged: ((Bool) -> Void)?
    var onCheckNow: (() -> Void)?
    #endif
    var onHighlightChanged: ((Bool, NSColor, String, Set<String>) -> Void)?
    var onLanguageChanged: ((String) -> Void)?
    var onBarValueChanged: ((String) -> Void)?
    var onSectionChanged: ((String) -> Void)?
    var onResetConnection: (() -> Void)?
    var onCambiarServicio: (() -> Void)?
    var onClearHistory: (() -> Void)?
    var onDiagnostics: (() -> Void)?
    var onBuscarEstacion: (() -> Void)?
    var onEstacionPrincipalChanged: ((String) -> Void)?
    var onTestNotification: (() -> Void)?

    private let window: NSWindow
    private let split = NSSplitViewController()
    private let sidebar = NSOutlineView()
    private let detalle = NSView()
    private let vistaAvisos: VistaAvisos
    private var paneles: [SeccionAjustes: NSView] = [:]
    private var seccionActual: SeccionAjustes = .general
    private var opcionPulsada = false
    private var monitorOpcion: Any?

    // General
    private let versionLabel = NSTextField(labelWithString: "")
    private let loginSwitch = NSSwitch()
    private let approvalLabel = NSTextField(labelWithString: "")
    private let approvalButton = NSButton(title: L("Abrir Ajustes del Sistema"),
                                          target: nil, action: nil)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var languageOptions: [(clave: String, titulo: String)] {
        [
            ("auto", L("Automático (sistema)")),
            ("es", "Español"),
            ("en", "English"),
        ]
    }
    #if !APPSTORE
    private let autoSwitch = NSSwitch()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let checkButton = NSButton(title: L("Buscar ahora"), target: nil, action: nil)
    private let repoLabel = NSTextField(labelWithString: "")
    #endif

    // Barra y menú
    private let barraPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var barraClaves: [(clave: String, titulo: String)] = []
    private let highlightSwitch = NSSwitch()
    private let colorWell = NSColorWell(frame: .zero)
    private let colorPreview = NSTextField(labelWithString: fmtTemp(21.5))
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

    // Estaciones
    private let estacionesModoLabel = NSTextField(labelWithString: "")
    private let estacionesDetalleLabel = NSTextField(wrappingLabelWithString: "")
    private let estacionesPila = NSStackView()
    private let estacionPrincipalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var filaEstacionPrincipal: NSView?
    private var principalesPopup: [String] = []
    private let publicaLabel = NSTextField(wrappingLabelWithString: "")
    private let buscarEstacionButton = NSButton(title: L("Buscar estación cercana…"),
                                                target: nil, action: nil)

    // Avanzado
    private let servicioLabel = NSTextField(wrappingLabelWithString: "")

    init(currentVersion: String, motor: MotorAvisos, pollSeconds: Int) {
        vistaAvisos = VistaAvisos(motor: motor, pollSeconds: pollSeconds)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = L("Ajustes")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 520)
        window.setFrameAutosaveName("MirloAjustes")
        if !window.setFrameUsingName("MirloAjustes") {
            window.setContentSize(NSSize(width: 760, height: 560))
            window.center()
        }

        vistaAvisos.hostWindow = { [weak self] in self?.window }
        vistaAvisos.onTestNotification = { [weak self] in
            self?.onTestNotification?()
        }
        construirVentana()
        construirPaneles(currentVersion: currentVersion)
        instalarMonitorOpcion()
        seccionActual = .general
        seleccionar(.general, notificar: false)
    }

    // ------------------------- estructura -------------------------
    private func construirVentana() {
        let sidebarVC = NSViewController()
        let fondo = NSVisualEffectView()
        fondo.material = .sidebar
        fondo.blendingMode = .behindWindow
        fondo.state = .active
        sidebarVC.view = fondo

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        fondo.addSubview(scroll)

        let columna = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("seccion"))
        columna.title = ""
        columna.width = 210
        columna.resizingMask = .autoresizingMask
        sidebar.addTableColumn(columna)
        sidebar.outlineTableColumn = columna
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowSizeStyle = .default
        sidebar.indentationPerLevel = 0
        sidebar.floatsGroupRows = false
        sidebar.backgroundColor = .clear
        sidebar.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.frame = NSRect(x: 0, y: 0, width: 210, height: 560)
        sidebar.autoresizingMask = [.width]
        scroll.documentView = sidebar

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: fondo.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: fondo.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: fondo.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: fondo.bottomAnchor),
        ])

        let itemSidebar = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        itemSidebar.minimumThickness = 210
        itemSidebar.maximumThickness = 210
        itemSidebar.canCollapse = false
        split.addSplitViewItem(itemSidebar)

        let detalleVC = NSViewController()
        detalleVC.view = detalle
        let itemDetalle = NSSplitViewItem(viewController: detalleVC)
        itemDetalle.minimumThickness = 480
        split.addSplitViewItem(itemDetalle)
        split.preferredContentSize = NSSize(width: 760, height: 560)

        window.contentViewController = split
        window.setContentSize(NSSize(width: 760, height: 560))
    }

    private func instalarMonitorOpcion() {
        monitorOpcion = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            guard let self = self, self.window.isVisible else { return event }
            let nueva = event.modifierFlags.contains(.option)
            if nueva != self.opcionPulsada {
                self.opcionPulsada = nueva
                self.refrescarAvanzado()
            }
            return event
        }
    }

    private var seccionesVisibles: [SeccionAjustes] {
        SeccionAjustes.allCases.filter { $0 != .avanzado || opcionPulsada }
    }

    private func refrescarAvanzado() {
        if !opcionPulsada && seccionActual == .avanzado {
            seleccionar(.general, notificar: true)
        }
        sidebar.reloadData()
        seleccionarFilaActual()
    }

    private func seleccionarFilaActual() {
        let visibles = seccionesVisibles
        guard let indice = visibles.firstIndex(of: seccionActual) else { return }
        sidebar.selectRowIndexes(IndexSet(integer: indice), byExtendingSelection: false)
        sidebar.scrollRowToVisible(indice)
    }

    private func seleccionar(_ seccion: SeccionAjustes, notificar: Bool) {
        if seccion == .avanzado && !opcionPulsada { return }
        seccionActual = seccion
        sidebar.reloadData()
        seleccionarFilaActual()
        mostrarPanel(seccion)
        if notificar { onSectionChanged?(seccion.rawValue) }
    }

    private func mostrarPanel(_ seccion: SeccionAjustes) {
        for vista in detalle.subviews { vista.removeFromSuperview() }
        guard let panel = paneles[seccion] else { return }
        panel.translatesAutoresizingMaskIntoConstraints = false
        detalle.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: detalle.topAnchor),
            panel.leadingAnchor.constraint(equalTo: detalle.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: detalle.trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: detalle.bottomAnchor),
        ])
        if seccion == .avisos { vistaAvisos.refresh() }
    }

    // ------------------------- paneles -------------------------
    private func construirPaneles(currentVersion: String) {
        paneles[.general] = panelGeneral(currentVersion: currentVersion)
        paneles[.barra] = panelBarra()
        paneles[.estaciones] = panelEstaciones()
        paneles[.avisos] = panelAvisos()
        paneles[.avanzado] = panelAvanzado()
    }

    private func panelGeneral(currentVersion: String) -> NSView {
        versionLabel.stringValue = L("Versión %@", currentVersion)
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        let icono = NSImageView()
        icono.image = NSApp.applicationIconImage
        icono.imageScaling = .scaleProportionallyUpOrDown
        icono.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icono.widthAnchor.constraint(equalToConstant: 52),
            icono.heightAnchor.constraint(equalToConstant: 52),
        ])

        let nombre = NSTextField(labelWithString: "Mirlo Weather")
        nombre.font = .systemFont(ofSize: 17, weight: .semibold)
        let textos = NSStackView(views: [nombre, versionLabel])
        textos.orientation = .vertical
        textos.alignment = .leading
        textos.spacing = 2

        let cabecera = NSStackView(views: [icono, textos, espaciador()])
        cabecera.orientation = .horizontal
        cabecera.alignment = .centerY
        cabecera.spacing = 14

        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin(_:))

        approvalLabel.font = .systemFont(ofSize: 11)
        approvalLabel.textColor = .secondaryLabelColor
        approvalLabel.isHidden = true

        approvalButton.target = self
        approvalButton.action = #selector(abrirAprobacion(_:))
        approvalButton.bezelStyle = .inline
        approvalButton.isHidden = true

        languagePopup.font = .systemFont(ofSize: 12)
        languagePopup.addItems(withTitles: languageOptions.map { $0.titulo })
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))

        let inicio: [NSView] = [
            fila(L("Abrir Mirlo Weather al iniciar sesión"), loginSwitch),
            approvalLabel,
            approvalButton,
        ]

        let tarjetaInicio = tarjeta(titulo: L("Inicio"), contenido: inicio)

        var general: [NSView] = [
            cabecera,
            tarjetaInicio,
            tarjeta(titulo: L("Idioma"), contenido: [
                fila(L("Idioma de la app"), languagePopup),
                textoAyuda(L("El cambio se aplica al menú y a las ventanas abiertas.")),
            ]),
        ]

        #if !APPSTORE
        autoSwitch.target = self
        autoSwitch.action = #selector(toggleAutoCheck(_:))
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        checkButton.target = self
        checkButton.action = #selector(checkNow(_:))
        checkButton.bezelStyle = .rounded
        repoLabel.font = .systemFont(ofSize: 10)
        repoLabel.textColor = .tertiaryLabelColor
        repoLabel.stringValue = Updater.shared.repository.isEmpty
            ? L("Repositorio sin configurar")
            : "GitHub: \(Updater.shared.repository)"
        let actualizaciones: [NSView] = [
            fila(L("Buscar actualizaciones automáticamente"), autoSwitch),
            statusLabel,
            fila(L("Actualizaciones"), checkButton),
            repoLabel,
        ]
        general.append(tarjeta(titulo: L("Actualizaciones"), contenido: actualizaciones))
        #endif

        return panelConScroll(general)
    }

    private func panelBarra() -> NSView {
        barraPopup.font = .systemFont(ofSize: 12)
        barraPopup.target = self
        barraPopup.action = #selector(barraCambiada(_:))

        highlightSwitch.target = self
        highlightSwitch.action = #selector(toggleHighlight(_:))
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))
        colorPreview.font = .systemFont(ofSize: 13, weight: .semibold)
        textPopup.font = .systemFont(ofSize: 12)
        textPopup.addItems(withTitles: textOptions.map { $0.titulo })
        textPopup.target = self
        textPopup.action = #selector(textChanged(_:))

        let color = NSStackView(views: [colorWell, colorPreview, espaciador()])
        color.orientation = .horizontal
        color.alignment = .centerY
        color.spacing = 8
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            colorWell.widthAnchor.constraint(equalToConstant: 34),
            colorWell.heightAnchor.constraint(equalToConstant: 26),
        ])

        var filas: [[NSView]] = []
        let checks = highlightKeys.map { par -> NSButton in
            let check = NSButton(
                checkboxWithTitle: par.titulo,
                target: self,
                action: #selector(toggleItem(_:))
            )
            check.tag = highlightKeys.firstIndex(where: { $0.clave == par.clave }) ?? 0
            itemChecks[par.clave] = check
            return check
        }
        for indice in stride(from: 0, to: checks.count, by: 2) {
            let segundo = indice + 1 < checks.count ? checks[indice + 1] : NSView()
            filas.append([checks[indice], segundo])
        }
        let grid = NSGridView(views: filas)
        grid.rowSpacing = 6
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading

        let tarjetaBarra = tarjeta(titulo: L("Barra de menús"), contenido: [
            fila(L("Mostrar en la barra"), barraPopup),
            textoAyuda(L("El valor elegido aparece junto al icono de Mirlo. «Solo el icono» deja la barra limpia.")),
        ])

        let tarjetaResaltado = tarjeta(titulo: L("Resaltado"), contenido: [
            fila(L("Destacar los datos con color"), highlightSwitch),
            fila(L("Color"), color),
            fila(L("Texto del resaltado"), textPopup),
            textoAyuda(L("Bloques a resaltar")),
            grid,
            textoAyuda(L("El resaltado se aplica a los bloques marcados del menú. El color de texto automático elige blanco o negro según el contraste.")),
        ])

        return panelConScroll([tarjetaBarra, tarjetaResaltado])
    }

    private func panelEstaciones() -> NSView {
        estacionesModoLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        estacionesModoLabel.alignment = .left
        estacionesDetalleLabel.font = .systemFont(ofSize: 11)
        estacionesDetalleLabel.textColor = .secondaryLabelColor
        estacionesDetalleLabel.alignment = .left

        estacionesPila.orientation = .vertical
        estacionesPila.alignment = .leading
        estacionesPila.spacing = 8

        publicaLabel.font = .systemFont(ofSize: 11)
        publicaLabel.textColor = .secondaryLabelColor
        publicaLabel.alignment = .left

        buscarEstacionButton.target = self
        buscarEstacionButton.action = #selector(buscarEstacion(_:))
        buscarEstacionButton.bezelStyle = .rounded

        estacionPrincipalPopup.target = self
        estacionPrincipalPopup.action = #selector(cambiarEstacionPrincipal(_:))
        estacionPrincipalPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let filaPrincipal = fila(L("Estación principal"), estacionPrincipalPopup)
        filaPrincipal.isHidden = true
        filaEstacionPrincipal = filaPrincipal

        let tarjetaConexion = tarjeta(titulo: L("Conexión"), contenido: [
            estacionesModoLabel,
            estacionesDetalleLabel,
        ])
        let tarjetaEstaciones = tarjeta(titulo: L("Estaciones y módulos"), contenido: [
            filaPrincipal,
            estacionesPila,
        ])
        let tarjetaPublica = tarjeta(titulo: L("Estación pública"), contenido: [
            publicaLabel,
            fila(L("Añadir o cambiar la estación pública"), buscarEstacionButton),
            textoAyuda(L("La estación pública aporta viento o lluvia cuando tu cuenta no tiene esos sensores. Netatmo solo permite leer sus datos; nunca se escribe en ella.")),
        ])

        return panelConScroll([tarjetaConexion, tarjetaEstaciones, tarjetaPublica])
    }

    private func panelAvisos() -> NSView {
        let contenedor = NSView()
        vistaAvisos.translatesAutoresizingMaskIntoConstraints = false
        contenedor.addSubview(vistaAvisos)
        NSLayoutConstraint.activate([
            vistaAvisos.topAnchor.constraint(equalTo: contenedor.topAnchor),
            vistaAvisos.leadingAnchor.constraint(equalTo: contenedor.leadingAnchor),
            vistaAvisos.trailingAnchor.constraint(equalTo: contenedor.trailingAnchor),
            vistaAvisos.bottomAnchor.constraint(equalTo: contenedor.bottomAnchor),
        ])
        return contenedor
    }

    private func panelAvanzado() -> NSView {
        servicioLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        servicioLabel.textColor = .secondaryLabelColor
        servicioLabel.isSelectable = true

        let restablecer = NSButton(title: L("Restablecer conexión…"),
                                   target: self, action: #selector(restablecerConexion(_:)))
        restablecer.bezelStyle = .rounded
        let cambiar = NSButton(title: L("Cambiar servicio…"),
                               target: self, action: #selector(cambiarServicio(_:)))
        cambiar.bezelStyle = .rounded
        let borrar = NSButton(title: L("Borrar historial local…"),
                              target: self, action: #selector(borrarHistorial(_:)))
        borrar.bezelStyle = .rounded
        let diagnostico = NSButton(title: L("Copiar diagnóstico"),
                                   target: self, action: #selector(copiarDiagnostico(_:)))
        diagnostico.bezelStyle = .rounded

        let tarjetaServicio = tarjeta(titulo: L("Servicio"), contenido: [
            servicioLabel,
            fila(L("Conexión con Netatmo"), restablecer),
            fila(L("Dirección del servicio"), cambiar),
            textoAyuda(L("El servicio es el Cloudflare Worker que habla con Netatmo. Restablecer borra la credencial local y pide volver a autorizar la cuenta.")),
        ])
        let tarjetaDatos = tarjeta(titulo: L("Datos locales"), contenido: [
            fila(L("Historial de este Mac"), borrar),
            textoAyuda(L("Borra las muestras guardadas para la gráfica y las tendencias. Los avisos y sus reglas no se tocan.")),
        ])
        let tarjetaDiagnostico = tarjeta(titulo: L("Diagnóstico"), contenido: [
            fila(L("Informe para soporte"), diagnostico),
            textoAyuda(L("Copia versión, modo, servicio, estado de la última lectura y número de módulos y avisos. No incluye tu credencial.")),
        ])

        return panelConScroll([tarjetaServicio, tarjetaDatos, tarjetaDiagnostico])
    }

    // ------------------------- piezas visuales -------------------------
    private func panelConScroll(_ contenido: [NSView]) -> NSView {
        let contenedor = NSView()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let doc = VistaAjustesVolcado()
        doc.translatesAutoresizingMaskIntoConstraints = false
        let pila = NSStackView(views: contenido)
        pila.orientation = .vertical
        pila.alignment = .leading
        pila.spacing = 14
        pila.translatesAutoresizingMaskIntoConstraints = false
        for vista in contenido {
            vista.widthAnchor.constraint(equalTo: pila.widthAnchor).isActive = true
        }
        doc.addSubview(pila)

        scroll.documentView = doc
        contenedor.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contenedor.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: contenedor.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contenedor.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contenedor.bottomAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            pila.topAnchor.constraint(equalTo: doc.topAnchor, constant: 24),
            pila.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            pila.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            pila.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -24),
        ])
        return contenedor
    }

    private func tarjeta(titulo: String, contenido: [NSView]) -> NSView {
        let fondo = TarjetaAjustes()

        let pila = NSStackView()
        pila.orientation = .vertical
        pila.alignment = .leading
        pila.spacing = 9
        pila.translatesAutoresizingMaskIntoConstraints = false

        let cabecera = NSTextField(labelWithString: titulo)
        cabecera.font = .systemFont(ofSize: 12, weight: .semibold)
        cabecera.textColor = .secondaryLabelColor
        cabecera.alignment = .left
        pila.addArrangedSubview(cabecera)
        cabecera.widthAnchor.constraint(equalTo: pila.widthAnchor).isActive = true
        for vista in contenido {
            pila.addArrangedSubview(vista)
            vista.widthAnchor.constraint(equalTo: pila.widthAnchor).isActive = true
        }

        fondo.addSubview(pila)
        NSLayoutConstraint.activate([
            pila.topAnchor.constraint(equalTo: fondo.topAnchor, constant: 14),
            pila.leadingAnchor.constraint(equalTo: fondo.leadingAnchor, constant: 16),
            pila.trailingAnchor.constraint(equalTo: fondo.trailingAnchor, constant: -16),
            pila.bottomAnchor.constraint(equalTo: fondo.bottomAnchor, constant: -14),
        ])
        return fondo
    }

    private func fila(_ titulo: String, _ control: NSView) -> NSView {
        let etiqueta = NSTextField(labelWithString: titulo)
        etiqueta.font = .systemFont(ofSize: 12)
        etiqueta.alignment = .left
        etiqueta.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let pila = NSStackView(views: [etiqueta, espaciador(), control])
        pila.orientation = .horizontal
        pila.alignment = .centerY
        pila.spacing = 10
        return pila
    }

    private func textoAyuda(_ texto: String) -> NSTextField {
        let etiqueta = NSTextField(wrappingLabelWithString: texto)
        etiqueta.font = .systemFont(ofSize: 11)
        etiqueta.textColor = .secondaryLabelColor
        etiqueta.alignment = .left
        return etiqueta
    }

    private func espaciador() -> NSView {
        let vista = NSView()
        vista.setContentHuggingPriority(.defaultLow, for: .horizontal)
        vista.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return vista
    }

    // ------------------------- API -------------------------
    var frameOrigin: NSPoint { window.frame.origin }
    var isVisible: Bool { window.isVisible }

    func setFrameOrigin(_ point: NSPoint) {
        window.setFrameOrigin(point)
    }

    func close() {
        window.close()
    }

    func refrescarAvisos() {
        vistaAvisos.refresh()
    }

    func actualizarEstaciones(_ resumen: ResumenEstacionesAjustes) {
        estacionesModoLabel.stringValue = resumen.modo
        estacionesDetalleLabel.stringValue = resumen.detalle
        publicaLabel.stringValue = resumen.publica
            ?? L("No hay ninguna estación pública guardada.")

        let actual = resumen.principalActual ?? ""
        filaEstacionPrincipal?.isHidden = resumen.principales.count < 2
        // Reconstruir el desplegable en cada lectura cerraría el menú si el
        // usuario lo tiene abierto. Solo se rehace si cambia la lista.
        if resumen.principales != principalesPopup {
            principalesPopup = resumen.principales
            estacionPrincipalPopup.removeAllItems()
            estacionPrincipalPopup.addItem(withTitle: L("Automática (Netatmo)"))
            estacionPrincipalPopup.lastItem?.representedObject = ""
            for nombre in resumen.principales {
                estacionPrincipalPopup.addItem(withTitle: nombre)
                estacionPrincipalPopup.lastItem?.representedObject = nombre
            }
        }
        if let item = estacionPrincipalPopup.itemArray.first(where: {
            ($0.representedObject as? String) == actual
        }), estacionPrincipalPopup.selectedItem !== item {
            estacionPrincipalPopup.select(item)
        }

        for vista in estacionesPila.arrangedSubviews {
            estacionesPila.removeArrangedSubview(vista)
            vista.removeFromSuperview()
        }

        func anadir(_ vista: NSView) {
            estacionesPila.addArrangedSubview(vista)
            vista.widthAnchor.constraint(equalTo: estacionesPila.widthAnchor).isActive = true
        }

        if resumen.estaciones.isEmpty {
            anadir(textoAyuda(L("Todavía no hay módulos. Conecta la cuenta o espera a la primera lectura.")))
        } else {
            for (indice, estacion) in resumen.estaciones.enumerated() {
                if indice > 0 { anadir(separador()) }
                let nombre = NSTextField(labelWithString: estacion.nombre)
                nombre.font = .systemFont(ofSize: 12, weight: .medium)
                nombre.alignment = .left
                anadir(nombre)
                if estacion.modulos.isEmpty {
                    anadir(textoAyuda(L("Sin módulos visibles.")))
                } else {
                    for modulo in estacion.modulos {
                        let titulo = NSTextField(labelWithString: modulo.nombre)
                        titulo.font = .systemFont(ofSize: 12)
                        titulo.alignment = .left
                        titulo.setContentHuggingPriority(.defaultLow, for: .horizontal)
                        let tipo = NSTextField(labelWithString: modulo.tipo)
                        tipo.font = .systemFont(ofSize: 11)
                        tipo.textColor = .secondaryLabelColor
                        tipo.alignment = .right
                        let filaModulo = NSStackView(views: [titulo, espaciador(), tipo])
                        filaModulo.orientation = .horizontal
                        filaModulo.alignment = .centerY
                        filaModulo.spacing = 8
                        anadir(filaModulo)
                    }
                }
            }
        }
    }

    private func separador() -> NSView {
        let caja = NSBox()
        caja.boxType = .separator
        caja.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return caja
    }

    #if APPSTORE
    func show(
        language: String,
        barValue: String,
        barra: [(clave: String, titulo: String)],
        highlight: Bool,
        color: NSColor,
        textColor: String,
        highlightItems: Set<String>,
        seccion: String,
        resumen: ResumenEstacionesAjustes,
        serviceUrl: String
    ) {
        mostrar(
            language: language,
            barValue: barValue,
            barra: barra,
            highlight: highlight,
            color: color,
            textColor: textColor,
            highlightItems: highlightItems,
            seccion: seccion,
            resumen: resumen,
            serviceUrl: serviceUrl,
            autoUpdate: nil,
            status: nil
        )
    }
    #else
    func show(
        language: String,
        barValue: String,
        barra: [(clave: String, titulo: String)],
        autoUpdate: Bool,
        status: String,
        highlight: Bool,
        color: NSColor,
        textColor: String,
        highlightItems: Set<String>,
        seccion: String,
        resumen: ResumenEstacionesAjustes,
        serviceUrl: String
    ) {
        autoSwitch.state = autoUpdate ? .on : .off
        statusLabel.stringValue = status
        mostrar(
            language: language,
            barValue: barValue,
            barra: barra,
            highlight: highlight,
            color: color,
            textColor: textColor,
            highlightItems: highlightItems,
            seccion: seccion,
            resumen: resumen,
            serviceUrl: serviceUrl,
            autoUpdate: autoUpdate,
            status: status
        )
    }
    #endif

    private func mostrar(
        language: String,
        barValue: String,
        barra: [(clave: String, titulo: String)],
        highlight: Bool,
        color: NSColor,
        textColor: String,
        highlightItems: Set<String>,
        seccion: String,
        resumen: ResumenEstacionesAjustes,
        serviceUrl: String,
        autoUpdate: Bool?,
        status: String?
    ) {
        opcionPulsada = NSEvent.modifierFlags.contains(.option)

        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        approvalLabel.isHidden = !LoginItem.needsApproval
        approvalLabel.stringValue = LoginItem.needsApproval
            ? L("macOS debe aprobar la app en Ajustes del Sistema.")
            : ""
        approvalButton.isHidden = !LoginItem.needsApproval

        if let indice = languageOptions.firstIndex(where: { $0.clave == language }) {
            languagePopup.selectItem(at: indice)
        } else {
            languagePopup.selectItem(at: 0)
        }

        actualizarBarra(barra, valor: barValue)
        highlightSwitch.state = highlight ? .on : .off
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
        actualizarEstaciones(resumen)
        servicioLabel.stringValue = serviceUrl

        #if !APPSTORE
        if let autoUpdate = autoUpdate {
            autoSwitch.state = autoUpdate ? .on : .off
        }
        if let status = status {
            statusLabel.stringValue = status
        }
        #endif

        let deseada = SeccionAjustes(rawValue: seccion) ?? .general
        let permitida = deseada == .avanzado && !opcionPulsada ? .general : deseada
        seleccionar(permitida, notificar: true)

        NSApp.activate(ignoringOtherApps: true)
        NSColorPanel.shared.showsAlpha = false
        window.makeKeyAndOrderFront(nil)
    }

    private func actualizarBarra(
        _ barra: [(clave: String, titulo: String)],
        valor: String
    ) {
        if barra.map({ $0.clave }) != barraClaves.map({ $0.clave }) {
            barraClaves = barra
            barraPopup.removeAllItems()
            for filaBarra in barra {
                let item = NSMenuItem(title: filaBarra.titulo, action: nil, keyEquivalent: "")
                item.representedObject = filaBarra.clave
                barraPopup.menu?.addItem(item)
            }
        }
        if let indice = barra.firstIndex(where: { $0.clave == valor }) {
            barraPopup.selectItem(at: indice)
        } else if barraPopup.numberOfItems > 0 {
            barraPopup.selectItem(at: 0)
        }
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
    @objc private func toggleLogin(_ sender: NSSwitch) {
        let enable = sender.state == .on
        do {
            try LoginItem.setEnabled(enable)
            approvalLabel.isHidden = !LoginItem.needsApproval
            approvalLabel.stringValue = LoginItem.needsApproval
                ? L("macOS debe aprobar la app en Ajustes del Sistema.")
                : ""
            approvalButton.isHidden = !LoginItem.needsApproval

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

    @objc private func abrirAprobacion(_ sender: Any?) {
        LoginItem.openSystemSettings()
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let indice = max(0, sender.indexOfSelectedItem)
        let codigo = indice < languageOptions.count ? languageOptions[indice].clave : "auto"
        onLanguageChanged?(codigo)
    }

    @objc private func barraCambiada(_ sender: NSPopUpButton) {
        guard let clave = sender.selectedItem?.representedObject as? String else { return }
        onBarValueChanged?(clave)
    }

    @objc private func toggleHighlight(_ sender: NSSwitch) {
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

    @objc private func colorChanged(_ sender: NSColorWell) {
        let solido = sender.color.withAlphaComponent(1)
        sender.color = solido
        actualizarPreview(solido)
        notificarDestacado()
    }

    private func notificarDestacado() {
        let activo = highlightSwitch.state == .on
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

    @objc private func buscarEstacion(_ sender: Any?) {
        onBuscarEstacion?()
    }

    @objc private func cambiarEstacionPrincipal(_ sender: NSPopUpButton) {
        let nombre = sender.selectedItem?.representedObject as? String ?? ""
        onEstacionPrincipalChanged?(nombre)
    }

    @objc private func restablecerConexion(_ sender: Any?) {
        onResetConnection?()
    }

    @objc private func cambiarServicio(_ sender: Any?) {
        onCambiarServicio?()
    }

    @objc private func borrarHistorial(_ sender: Any?) {
        onClearHistory?()
    }

    @objc private func copiarDiagnostico(_ sender: Any?) {
        onDiagnostics?()
    }

    #if !APPSTORE
    @objc private func toggleAutoCheck(_ sender: NSSwitch) {
        onAutoUpdateChanged?(sender.state == .on)
    }

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

    // ------------------------- barra lateral -------------------------
    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        item == nil ? seccionesVisibles.count : 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        seccionesVisibles[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let seccion = item as? SeccionAjustes else { return nil }
        let identificador = NSUserInterfaceItemIdentifier("CeldaSeccion")
        let celda: NSTableCellView
        if let existente = outlineView.makeView(
            withIdentifier: identificador,
            owner: self
        ) as? NSTableCellView {
            celda = existente
        } else {
            celda = NSTableCellView()
            celda.identifier = identificador

            let imagen = NSImageView()
            imagen.translatesAutoresizingMaskIntoConstraints = false
            imagen.imageScaling = .scaleProportionallyDown
            let texto = NSTextField(labelWithString: "")
            texto.translatesAutoresizingMaskIntoConstraints = false
            texto.font = .systemFont(ofSize: 13)
            texto.lineBreakMode = .byTruncatingTail
            celda.addSubview(imagen)
            celda.addSubview(texto)
            celda.imageView = imagen
            celda.textField = texto

            NSLayoutConstraint.activate([
                imagen.leadingAnchor.constraint(equalTo: celda.leadingAnchor, constant: 2),
                imagen.centerYAnchor.constraint(equalTo: celda.centerYAnchor),
                imagen.widthAnchor.constraint(equalToConstant: 18),
                imagen.heightAnchor.constraint(equalToConstant: 18),
                texto.leadingAnchor.constraint(equalTo: imagen.trailingAnchor, constant: 7),
                texto.trailingAnchor.constraint(equalTo: celda.trailingAnchor, constant: -4),
                texto.centerYAnchor.constraint(equalTo: celda.centerYAnchor),
            ])
        }
        celda.textField?.stringValue = seccion.titulo
        celda.imageView?.image = NSImage(
            systemSymbolName: seccion.simbolo,
            accessibilityDescription: seccion.titulo
        )
        return celda
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let fila = sidebar.selectedRow
        guard fila >= 0, fila < sidebar.numberOfRows,
              let seccion = sidebar.item(atRow: fila) as? SeccionAjustes else { return }
        guard seccion != seccionActual else { return }
        seccionActual = seccion
        mostrarPanel(seccion)
        onSectionChanged?(seccion.rawValue)
    }
}

// Vista con el origen arriba para que la pila crezca hacia abajo.
final class VistaAjustesVolcado: NSView {
    override var isFlipped: Bool { true }
}

// Tarjeta con fondo y borde propios. Los colores son dinámicos para que se
// adapten al modo claro y oscuro al cambiar la apariencia.
final class TarjetaAjustes: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true
        actualizarColores()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no está disponible")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        actualizarColores()
    }

    private func actualizarColores() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor
                .withAlphaComponent(0.65).cgColor
            layer?.borderColor = NSColor.separatorColor
                .withAlphaComponent(0.55).cgColor
        }
    }
}
