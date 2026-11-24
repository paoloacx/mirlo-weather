// Ventana de bienvenida y selectores del modo «solo localidad».
// La localidad se busca con autocompletado (MapKit): sugiere mientras se escribe
// y no necesita permiso de ubicación ni usa el GPS.
import Cocoa
import CoreLocation
import MapKit

final class OnboardingWindow: NSObject, NSWindowDelegate, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, MKLocalSearchCompleterDelegate {
    // Al elegir «tengo mi estación» se abre el flujo OAuth de siempre.
    var onConectar: (() -> Void)?
    // La app busca estaciones y devuelve cuántas ha encontrado. Si no hay
    // ninguna, devuelve un error con un mensaje para la ventana.
    var onLocalidad: ((String, Double, Double, @escaping (Result<Int, Error>) -> Void) -> Void)?
    var onCerrar: (() -> Void)?

    private let ventana: NSWindow
    private let vistaInicio = NSView()
    private let vistaLocalidad = NSView()
    private let campo = NSTextField()
    private let estado = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let botonBuscar = NSButton()
    private let botonVolver = NSButton()
    private var busquedaActiva: MKLocalSearch?
    private let completer = MKLocalSearchCompleter()
    private var sugerencias: [MKLocalSearchCompletion] = []
    private var seleccion: MKLocalSearchCompletion?
    private let tabla = NSTableView()
    private let scrollSugerencias = NSScrollView()
    private var alturaSugerencias: NSLayoutConstraint!
    private var volverAlInicio = true
    private var buscando = false

    override init() {
        ventana = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        ventana.title = "Mirlo Weather"
        ventana.isReleasedWhenClosed = false
        ventana.isMovableByWindowBackground = true
        ventana.standardWindowButton(.miniaturizeButton)?.isHidden = true
        ventana.standardWindowButton(.zoomButton)?.isHidden = true
        super.init()
        ventana.delegate = self
        completer.delegate = self
        completer.resultTypes = .address
        construirInicio()
        construirLocalidad()
    }

    // ----------------------------- inicio -----------------------------
    private func construirInicio() {
        guard let content = ventana.contentView else { return }
        vistaInicio.frame = content.bounds
        vistaInicio.autoresizingMask = [.width, .height]

        let icono = NSImageView()
        icono.image = NSApp.applicationIconImage
        icono.imageScaling = .scaleProportionallyUpOrDown
        icono.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icono.widthAnchor.constraint(equalToConstant: 60),
            icono.heightAnchor.constraint(equalToConstant: 60),
        ])

        let titulo = NSTextField(labelWithString: L("Bienvenido a Mirlo Weather"))
        titulo.font = .systemFont(ofSize: 24, weight: .semibold)
        titulo.alignment = .center

        let cuerpo = NSTextField(wrappingLabelWithString:
            L("Elige cómo quieres usar la app. Podrás cambiar de modo cuando quieras."))
        cuerpo.font = .systemFont(ofSize: 13)
        cuerpo.textColor = .secondaryLabelColor
        cuerpo.alignment = .center
        cuerpo.maximumNumberOfLines = 2

        let tarjetaCuenta = TarjetaOnboarding(
            simbolo: "dot.radiowaves.left.and.right",
            titulo: L("Tengo mi estación de Netatmo"),
            subtitulo: L("Conecta tu cuenta y lee todos tus sensores."),
            onClick: { [weak self] in self?.conectarPulsado() }
        )

        let tarjetaLocalidad = TarjetaOnboarding(
            simbolo: "location",
            titulo: L("Ver el tiempo de mi localidad"),
            subtitulo: L("Sin cuenta, con estaciones públicas cercanas."),
            onClick: { [weak self] in self?.localidadPulsado() }
        )

        let nota = NSTextField(wrappingLabelWithString:
            L("Sin cuenta usaremos estaciones Netatmo públicas cercanas a la localidad que escribas. Solo se leen sus medidas; no se usa el GPS."))
        nota.font = .systemFont(ofSize: 11)
        nota.textColor = .tertiaryLabelColor
        nota.alignment = .center
        nota.maximumNumberOfLines = 3

        let cerrar = NSButton(title: L("Ahora no"), target: self, action: #selector(cerrarPulsado))
        cerrar.bezelStyle = .inline

        let hueco = NSView()
        hueco.setContentHuggingPriority(.defaultLow, for: .vertical)
        hueco.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let pila = NSStackView(views: [icono, titulo, cuerpo, tarjetaCuenta,
                                       tarjetaLocalidad, nota, hueco, cerrar])
        pila.orientation = .vertical
        pila.alignment = .centerX
        pila.spacing = 10
        pila.translatesAutoresizingMaskIntoConstraints = false
        pila.setCustomSpacing(14, after: icono)
        pila.setCustomSpacing(6, after: titulo)
        pila.setCustomSpacing(20, after: cuerpo)
        pila.setCustomSpacing(10, after: tarjetaCuenta)
        pila.setCustomSpacing(14, after: tarjetaLocalidad)
        pila.setCustomSpacing(8, after: nota)
        vistaInicio.addSubview(pila)

        NSLayoutConstraint.activate([
            pila.topAnchor.constraint(equalTo: vistaInicio.topAnchor, constant: 24),
            pila.leadingAnchor.constraint(equalTo: vistaInicio.leadingAnchor, constant: 40),
            pila.trailingAnchor.constraint(equalTo: vistaInicio.trailingAnchor, constant: -40),
            pila.bottomAnchor.constraint(equalTo: vistaInicio.bottomAnchor, constant: -20),
            tarjetaCuenta.widthAnchor.constraint(equalTo: pila.widthAnchor),
            tarjetaLocalidad.widthAnchor.constraint(equalTo: pila.widthAnchor),
            tarjetaCuenta.heightAnchor.constraint(equalToConstant: 84),
            tarjetaLocalidad.heightAnchor.constraint(equalToConstant: 84),
            nota.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            cuerpo.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])

        content.addSubview(vistaInicio)
    }

    // ----------------------------- localidad -----------------------------
    private func construirLocalidad() {
        guard let content = ventana.contentView else { return }
        vistaLocalidad.frame = content.bounds
        vistaLocalidad.autoresizingMask = [.width, .height]
        vistaLocalidad.isHidden = true

        let icono = NSImageView()
        icono.image = NSApp.applicationIconImage
        icono.imageScaling = .scaleProportionallyUpOrDown
        icono.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icono.widthAnchor.constraint(equalToConstant: 44),
            icono.heightAnchor.constraint(equalToConstant: 44),
        ])

        let titulo = NSTextField(labelWithString: L("¿Dónde quieres ver el tiempo?"))
        titulo.font = .systemFont(ofSize: 20, weight: .semibold)
        titulo.alignment = .center

        let cuerpo = NSTextField(wrappingLabelWithString:
            L("Escribe tu localidad y elige una de las sugerencias. Buscaremos estaciones Netatmo públicas cerca y elegiremos los datos más representativos."))
        cuerpo.font = .systemFont(ofSize: 12)
        cuerpo.textColor = .secondaryLabelColor
        cuerpo.alignment = .center
        cuerpo.maximumNumberOfLines = 3

        campo.font = .systemFont(ofSize: 14)
        campo.placeholderString = L("Tu localidad")
        campo.delegate = self
        campo.alignment = .center
        campo.target = self
        campo.action = #selector(buscarPulsado)
        campo.translatesAutoresizingMaskIntoConstraints = false
        campo.heightAnchor.constraint(equalToConstant: 28).isActive = true

        botonBuscar.title = L("Buscar estaciones")
        botonBuscar.bezelStyle = .rounded
        botonBuscar.controlSize = .large
        botonBuscar.keyEquivalent = "\r"
        botonBuscar.target = self
        botonBuscar.action = #selector(buscarPulsado)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        estado.font = .systemFont(ofSize: 12)
        estado.textColor = .secondaryLabelColor
        estado.alignment = .left
        estado.maximumNumberOfLines = 4

        let filaEstado = NSStackView(views: [spinner, estado])
        filaEstado.orientation = .horizontal
        filaEstado.alignment = .centerY
        filaEstado.spacing = 8

        botonVolver.title = L("Volver")
        botonVolver.bezelStyle = .inline
        botonVolver.target = self
        botonVolver.action = #selector(volverPulsado)

        let huecoArriba = NSView()
        huecoArriba.setContentHuggingPriority(.defaultLow, for: .vertical)
        huecoArriba.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let huecoAbajo = NSView()
        huecoAbajo.setContentHuggingPriority(.defaultLow, for: .vertical)
        huecoAbajo.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let pila = NSStackView(views: [huecoArriba, icono, titulo, cuerpo, campo,
                                       botonBuscar, filaEstado, huecoAbajo,
                                       botonVolver])
        pila.orientation = .vertical
        pila.alignment = .centerX
        pila.spacing = 10
        pila.translatesAutoresizingMaskIntoConstraints = false
        pila.setCustomSpacing(10, after: icono)
        pila.setCustomSpacing(6, after: titulo)
        pila.setCustomSpacing(18, after: cuerpo)
        pila.setCustomSpacing(10, after: campo)
        pila.setCustomSpacing(12, after: botonBuscar)
        pila.setCustomSpacing(8, after: filaEstado)
        vistaLocalidad.addSubview(pila)

        NSLayoutConstraint.activate([
            pila.topAnchor.constraint(equalTo: vistaLocalidad.topAnchor, constant: 26),
            pila.leadingAnchor.constraint(equalTo: vistaLocalidad.leadingAnchor, constant: 52),
            pila.trailingAnchor.constraint(equalTo: vistaLocalidad.trailingAnchor, constant: -52),
            pila.bottomAnchor.constraint(equalTo: vistaLocalidad.bottomAnchor, constant: -20),
            campo.widthAnchor.constraint(equalTo: pila.widthAnchor),
            botonBuscar.widthAnchor.constraint(equalTo: pila.widthAnchor),
            filaEstado.widthAnchor.constraint(equalTo: pila.widthAnchor),
            cuerpo.widthAnchor.constraint(equalTo: pila.widthAnchor),
        ])

        // Lista de sugerencias: flota justo debajo del campo, por encima del
        // resto de controles. Su altura se ajusta al número de resultados.
        let columna = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sug"))
        columna.width = 416
        columna.resizingMask = .autoresizingMask
        tabla.addTableColumn(columna)
        tabla.headerView = nil
        tabla.rowHeight = 36
        tabla.backgroundColor = .clear
        tabla.dataSource = self
        tabla.delegate = self
        tabla.target = self
        tabla.action = #selector(sugerenciaClic)
        scrollSugerencias.documentView = tabla
        scrollSugerencias.hasVerticalScroller = false
        scrollSugerencias.borderType = .noBorder
        scrollSugerencias.drawsBackground = true
        scrollSugerencias.backgroundColor = .controlBackgroundColor
        scrollSugerencias.wantsLayer = true
        scrollSugerencias.layer?.cornerRadius = 8
        scrollSugerencias.layer?.borderWidth = 0.5
        scrollSugerencias.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollSugerencias.isHidden = true
        scrollSugerencias.translatesAutoresizingMaskIntoConstraints = false
        vistaLocalidad.addSubview(scrollSugerencias)

        alturaSugerencias = scrollSugerencias.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollSugerencias.leadingAnchor.constraint(equalTo: campo.leadingAnchor),
            scrollSugerencias.trailingAnchor.constraint(equalTo: campo.trailingAnchor),
            scrollSugerencias.topAnchor.constraint(equalTo: campo.bottomAnchor, constant: 2),
            alturaSugerencias,
        ])

        content.addSubview(vistaLocalidad)
    }

    // ----------------------------- autocompletado -----------------------------
    func controlTextDidChange(_ obj: Notification) {
        seleccion = nil
        let texto = campo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if texto.count < 2 {
            completer.cancel()
            mostrarSugerencias([])
        } else {
            completer.queryFragment = texto
        }
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        // Solo localidades: se descartan calles y números.
        let utiles = completer.results.filter { r in
            !r.title.contains(where: { $0.isNumber }) && !r.subtitle.isEmpty
        }
        mostrarSugerencias(Array(utiles.prefix(5)))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        mostrarSugerencias([])
    }

    private func mostrarSugerencias(_ lista: [MKLocalSearchCompletion]) {
        guard ventana.isVisible, !vistaLocalidad.isHidden, !buscando,
              ventana.firstResponder === campo.currentEditor() else {
            sugerencias = []
            alturaSugerencias.constant = 0
            scrollSugerencias.isHidden = true
            return
        }
        sugerencias = lista
        tabla.reloadData()
        if lista.isEmpty {
            alturaSugerencias.constant = 0
            scrollSugerencias.isHidden = true
            return
        }
        let alto = CGFloat(lista.count) * tabla.rowHeight + 4
        alturaSugerencias.constant = alto
        scrollSugerencias.isHidden = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { sugerencias.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let s = sugerencias[row]
        let texto = NSMutableAttributedString(
            string: s.title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
        texto.append(NSAttributedString(
            string: "\n" + s.subtitle,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        let celda = NSTextField(labelWithAttributedString: texto)
        celda.lineBreakMode = .byTruncatingTail
        return celda
    }

    @objc private func sugerenciaClic(_ sender: Any?) {
        let fila = tabla.clickedRow
        guard fila >= 0, fila < sugerencias.count else { return }
        elegir(sugerencias[fila])
    }

    private func elegir(_ s: MKLocalSearchCompletion) {
        seleccion = s
        campo.stringValue = s.title + ", " + s.subtitle
        alturaSugerencias.constant = 0
        scrollSugerencias.isHidden = true
        sugerencias = []
        ventana.makeFirstResponder(campo)
        campo.currentEditor()?.moveToEndOfDocument(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !scrollSugerencias.isHidden else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            tabla.selectRowIndexes(IndexSet(integer: min(tabla.selectedRow + 1, sugerencias.count - 1)), byExtendingSelection: false)
            return true
        case #selector(NSResponder.moveUp(_:)):
            tabla.selectRowIndexes(IndexSet(integer: max(tabla.selectedRow - 1, 0)), byExtendingSelection: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if tabla.selectedRow >= 0, tabla.selectedRow < sugerencias.count {
                elegir(sugerencias[tabla.selectedRow])
                return true
            }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            alturaSugerencias.constant = 0
            scrollSugerencias.isHidden = true
            return true
        default:
            return false
        }
    }

    // ----------------------------- API -----------------------------
    func mostrarInicio() {
        volverAlInicio = true
        vistaInicio.isHidden = false
        vistaLocalidad.isHidden = true
        estado.stringValue = ""
        buscando = false
        actualizarControles()
        presentar()
    }

    func mostrarLocalidad(nombreActual: String?, volverAlInicio: Bool) {
        self.volverAlInicio = volverAlInicio
        vistaInicio.isHidden = true
        vistaLocalidad.isHidden = false
        campo.stringValue = nombreActual ?? ""
        seleccion = nil
        sugerencias = []
        alturaSugerencias.constant = 0
        scrollSugerencias.isHidden = true
        estado.stringValue = ""
        estado.textColor = .secondaryLabelColor
        buscando = false
        actualizarControles()
        presentar()
        ventana.makeFirstResponder(campo)
    }

    private func presentar() {
        NSApp.activate(ignoringOtherApps: true)
        ventana.center()
        ventana.makeKeyAndOrderFront(nil)
    }

    private func actualizarControles() {
        botonBuscar.isEnabled = !buscando
        campo.isEnabled = !buscando
        botonVolver.isEnabled = !buscando
        botonBuscar.title = buscando ? L("Buscando…") : L("Buscar estaciones")
        spinner.isHidden = !buscando
        if buscando { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func ponerEstado(_ texto: String, error: Bool = false) {
        estado.stringValue = texto
        estado.textColor = error ? .systemRed : .secondaryLabelColor
    }

    // ----------------------------- acciones -----------------------------
    @objc private func conectarPulsado() {
        ventana.close()
        onConectar?()
    }

    @objc private func localidadPulsado() {
        mostrarLocalidad(nombreActual: nil, volverAlInicio: true)
    }

    @objc private func volverPulsado() {
        if volverAlInicio {
            mostrarInicio()
        } else {
            ventana.close()
        }
    }

    @objc private func cerrarPulsado() {
        ventana.close()
        onCerrar?()
    }

    @objc private func buscarPulsado() {
        let texto = campo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !texto.isEmpty else {
            ponerEstado(L("Escribe una localidad."), error: true)
            return
        }
        guard !buscando else { return }
        buscando = true
        actualizarControles()
        ponerEstado(L("Buscando «%@»…", texto))
        alturaSugerencias.constant = 0
        scrollSugerencias.isHidden = true
        busquedaActiva?.cancel()
        let peticion: MKLocalSearch.Request
        if let elegida = seleccion {
            peticion = MKLocalSearch.Request(completion: elegida)
        } else {
            peticion = MKLocalSearch.Request()
            peticion.naturalLanguageQuery = texto
        }
        peticion.resultTypes = .address
        let busqueda = MKLocalSearch(request: peticion)
        busquedaActiva = busqueda
        busqueda.start { [weak self] respuesta, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.buscando = false
                    self.actualizarControles()
                    self.ponerEstado(self.describeGeocode(error), error: true)
                    return
                }
                guard let marca = respuesta?.mapItems.first?.placemark, let coordenada = marca.location?.coordinate else {
                    self.buscando = false
                    self.actualizarControles()
                    self.ponerEstado(
                        L("No se encontró esa localidad. Elige una de las sugerencias."),
                        error: true
                    )
                    return
                }
                let nombre = self.nombreLocalidad(marca, respaldo: texto)
                guard self.ventana.isVisible else { return }
                self.ponerEstado(L("Buscando estaciones cerca de %@…", nombre))
                self.onLocalidad?(nombre, coordenada.latitude, coordenada.longitude) { resultado in
                    DispatchQueue.main.async {
                        self.buscando = false
                        self.actualizarControles()
                        switch resultado {
                        case .success(let total):
                            self.ponerEstado(
                                L("%d estaciones encontradas. Datos listos.", total)
                            )
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                self.ventana.close()
                            }
                        case .failure(let fallo):
                            self.ponerEstado(fallo.localizedDescription, error: true)
                        }
                    }
                }
            }
        }
    }

    private func nombreLocalidad(_ marca: CLPlacemark, respaldo: String) -> String {
        var partes: [String] = []
        if let localidad = marca.locality, !localidad.isEmpty {
            partes.append(localidad)
        }
        if let provincia = marca.administrativeArea, !provincia.isEmpty,
           !partes.contains(provincia) {
            partes.append(provincia)
        }
        if partes.isEmpty, let nombre = marca.name, !nombre.isEmpty {
            return nombre
        }
        return partes.isEmpty ? respaldo : partes.joined(separator: ", ")
    }

    private func describeGeocode(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == CLError.errorDomain,
           let codigo = CLError.Code(rawValue: ns.code) {
            switch codigo {
            case .network:
                return L("No hay conexión para buscar la localidad.")
            case .geocodeFoundNoResult:
                return L("No se encontró esa localidad. Elige una de las sugerencias.")
            case .geocodeCanceled:
                return L("Búsqueda cancelada.")
            default:
                break
            }
        }
        if ns.domain == MKError.errorDomain, let codigo = MKError.Code(rawValue: UInt(ns.code)) {
            switch codigo {
            case .placemarkNotFound:
                return L("No se encontró esa localidad. Elige una de las sugerencias.")
            case .serverFailure, .loadingThrottled:
                return L("No hay conexión para buscar la localidad.")
            case .directionsNotFound:
                break
            default:
                break
            }
        }
        return L("No se pudo buscar la localidad: %@", error.localizedDescription)
    }
}

// ----------------------------- piezas del onboarding -----------------------------
// Tarjeta pulsable. Es una vista con rol de botón: conserva el foco, el teclado
// y la accesibilidad, pero dibuja solo el fondo y el borde que queremos.
final class TarjetaOnboarding: NSView {
    var onClick: (() -> Void)?
    private let icono = NSImageView()
    private let titulo = NSTextField(labelWithString: "")
    private let subtitulo = NSTextField(wrappingLabelWithString: "")
    private let flecha = NSImageView()
    private var areaSeguimiento: NSTrackingArea?
    private var encima = false {
        didSet { actualizarFondo() }
    }
    private var enfocada = false {
        didSet { actualizarFondo() }
    }

    init(
        simbolo: String,
        titulo texto: String,
        subtitulo detalle: String,
        onClick: @escaping () -> Void
    ) {
        super.init(frame: .zero)
        self.onClick = onClick
        toolTip = detalle
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true

        icono.image = NSImage(systemSymbolName: simbolo, accessibilityDescription: nil)
        icono.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 26, weight: .regular
        )
        icono.contentTintColor = .controlAccentColor
        icono.imageScaling = .scaleProportionallyDown
        icono.translatesAutoresizingMaskIntoConstraints = false

        titulo.stringValue = texto
        titulo.font = .systemFont(ofSize: 14, weight: .semibold)
        titulo.lineBreakMode = .byTruncatingTail
        titulo.translatesAutoresizingMaskIntoConstraints = false

        subtitulo.stringValue = detalle
        subtitulo.font = .systemFont(ofSize: 11)
        subtitulo.textColor = .secondaryLabelColor
        subtitulo.lineBreakMode = .byTruncatingTail
        subtitulo.translatesAutoresizingMaskIntoConstraints = false

        flecha.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: nil
        )
        flecha.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 12, weight: .semibold
        )
        flecha.contentTintColor = .tertiaryLabelColor
        flecha.translatesAutoresizingMaskIntoConstraints = false

        for vista in [icono, titulo, subtitulo, flecha] {
            addSubview(vista)
        }
        NSLayoutConstraint.activate([
            icono.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icono.centerYAnchor.constraint(equalTo: centerYAnchor),
            icono.widthAnchor.constraint(equalToConstant: 30),
            icono.heightAnchor.constraint(equalToConstant: 30),
            titulo.leadingAnchor.constraint(equalTo: icono.trailingAnchor, constant: 14),
            titulo.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            titulo.trailingAnchor.constraint(
                lessThanOrEqualTo: flecha.leadingAnchor, constant: -12
            ),
            subtitulo.leadingAnchor.constraint(equalTo: titulo.leadingAnchor),
            subtitulo.topAnchor.constraint(equalTo: titulo.bottomAnchor, constant: 3),
            subtitulo.trailingAnchor.constraint(
                lessThanOrEqualTo: flecha.leadingAnchor, constant: -12
            ),
            subtitulo.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -18
            ),
            flecha.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            flecha.centerYAnchor.constraint(equalTo: centerYAnchor),
            flecha.widthAnchor.constraint(equalToConstant: 10),
            flecha.heightAnchor.constraint(equalToConstant: 14),
        ])

        setAccessibilityRole(.button)
        setAccessibilityLabel(texto)
        setAccessibilityHelp(detalle)
        actualizarFondo()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no está disponible")
    }

    // Toda la tarjeta responde al clic, incluidas las etiquetas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        enfocada = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        enfocada = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            activar()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        activar()
        return true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let areaSeguimiento { removeTrackingArea(areaSeguimiento) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        areaSeguimiento = area
    }

    override func mouseEntered(with event: NSEvent) { encima = true }
    override func mouseExited(with event: NSEvent) { encima = false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        if bounds.contains(local) { activar() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        actualizarFondo()
    }

    private func activar() {
        onClick?()
    }

    private func actualizarFondo() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let fondo = encima
                ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.7)
            layer?.backgroundColor = fondo.cgColor
            let resaltada = encima || enfocada
            let borde = resaltada
                ? NSColor.controlAccentColor
                : NSColor.separatorColor
            layer?.borderColor = borde.withAlphaComponent(resaltada ? 0.9 : 0.6).cgColor
            layer?.borderWidth = enfocada ? 1.5 : 1.0
        }
    }
}

// ----------------------------- selector manual -----------------------------
// Se usa cuando no hay estaciones en el radio inicial o cuando el usuario
// quiere decidir a mano qué estación aporta cada dato.
final class SelectorEstacionesWindow: NSObject, NSWindowDelegate {
    var onGuardar: ((String?, String?, String?) -> Void)?
    var onCancelar: (() -> Void)?

    private let ventana: NSWindow
    private let intro = NSTextField(wrappingLabelWithString: "")
    private let popupPrincipal = NSPopUpButton()
    private let popupViento = NSPopUpButton()
    private let popupLluvia = NSPopUpButton()
    private var estaciones: [[String: Any]] = []
    private var cierrePorAccion = false

    override init() {
        ventana = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        ventana.title = L("Elegir estaciones")
        ventana.isReleasedWhenClosed = false
        ventana.isMovableByWindowBackground = true
        ventana.standardWindowButton(.miniaturizeButton)?.isHidden = true
        ventana.standardWindowButton(.zoomButton)?.isHidden = true
        super.init()
        ventana.delegate = self
        construir()
    }

    private func construir() {
        guard let content = ventana.contentView else { return }

        let titulo = NSTextField(labelWithString: L("Estaciones de tu localidad"))
        titulo.font = .systemFont(ofSize: 17, weight: .semibold)
        titulo.frame = NSRect(x: 24, y: 312, width: 492, height: 24)
        content.addSubview(titulo)

        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 3
        intro.frame = NSRect(x: 24, y: 252, width: 492, height: 52)
        content.addSubview(intro)

        let filas: [(String, NSPopUpButton)] = [
            (L("Datos principales (temperatura, humedad y presión)"), popupPrincipal),
            (L("Viento y rachas"), popupViento),
            (L("Lluvia"), popupLluvia),
        ]
        var y: CGFloat = 210
        for (texto, popup) in filas {
            let etiqueta = NSTextField(labelWithString: texto)
            etiqueta.font = .systemFont(ofSize: 12)
            etiqueta.frame = NSRect(x: 24, y: y + 6, width: 492, height: 17)
            content.addSubview(etiqueta)

            popup.font = .systemFont(ofSize: 12)
            popup.frame = NSRect(x: 24, y: y - 26, width: 492, height: 26)
            content.addSubview(popup)
            y -= 56
        }

        let nota = NSTextField(wrappingLabelWithString:
            L("«Automático» elige la estación cuya lectura esté más cerca de la mediana de la zona. Los datos son públicos y de solo lectura."))
        nota.font = .systemFont(ofSize: 10)
        nota.textColor = .tertiaryLabelColor
        nota.maximumNumberOfLines = 3
        nota.frame = NSRect(x: 24, y: 52, width: 492, height: 40)
        content.addSubview(nota)

        let guardar = NSButton(
            title: L("Usar estas estaciones"),
            target: self,
            action: #selector(guardarPulsado)
        )
        guardar.bezelStyle = .rounded
        guardar.keyEquivalent = "\r"
        guardar.frame = NSRect(x: 330, y: 14, width: 186, height: 30)
        content.addSubview(guardar)

        let cancelar = NSButton(
            title: L("Cancelar"),
            target: self,
            action: #selector(cancelarPulsado)
        )
        cancelar.bezelStyle = .rounded
        cancelar.frame = NSRect(x: 232, y: 14, width: 92, height: 30)
        content.addSubview(cancelar)
    }

    func mostrar(
        estaciones: [[String: Any]],
        principalId: String?,
        vientoId: String?,
        lluviaId: String?,
        aviso: String?
    ) {
        self.estaciones = estaciones.sorted {
            (distanciaEstacion($0) ?? 9999) < (distanciaEstacion($1) ?? 9999)
        }
        intro.stringValue = aviso ?? L("Elige qué estación aporta cada dato. También puedes dejar que la app lo haga sola.")
        llenar(popupPrincipal, clave: "principal", seleccion: principalId)
        llenar(popupViento, clave: "viento", seleccion: vientoId)
        llenar(popupLluvia, clave: "lluvia", seleccion: lluviaId)
        NSApp.activate(ignoringOtherApps: true)
        ventana.center()
        ventana.makeKeyAndOrderFront(nil)
    }

    private func llenar(_ popup: NSPopUpButton, clave: String, seleccion: String?) {
        popup.removeAllItems()
        popup.addItem(withTitle: L("Automático"))
        popup.lastItem?.representedObject = nil

        let candidatas = estaciones.filter { cumple($0, clave: clave) }
        if candidatas.isEmpty {
            popup.addItem(withTitle: L("Sin datos disponibles"))
            popup.lastItem?.isEnabled = false
            popup.selectItem(at: 0)
            return
        }
        for estacion in candidatas {
            popup.addItem(withTitle: etiquetaEstacion(estacion))
            popup.lastItem?.representedObject = estacion["id"] as? String
        }
        if let seleccion = seleccion,
           let indice = popup.itemArray.firstIndex(where: {
               ($0.representedObject as? String) == seleccion
           }) {
            popup.selectItem(at: indice)
        } else {
            popup.selectItem(at: 0)
        }
    }

    private func cumple(_ estacion: [String: Any], clave: String) -> Bool {
        switch clave {
        case "viento":
            return (estacion["viento"] as? [String: Any]) != nil
        case "lluvia":
            return (estacion["lluvia"] as? [String: Any]) != nil
        default:
            return medidaEstacion(estacion, "temperatura") != nil
                || medidaEstacion(estacion, "humedad") != nil
                || medidaEstacion(estacion, "presion") != nil
        }
    }

    @objc private func guardarPulsado() {
        cierrePorAccion = true
        ventana.close()
        onGuardar?(
            popupPrincipal.selectedItem?.representedObject as? String,
            popupViento.selectedItem?.representedObject as? String,
            popupLluvia.selectedItem?.representedObject as? String
        )
    }

    @objc private func cancelarPulsado() {
        cierrePorAccion = true
        ventana.close()
        onCancelar?()
    }

    func windowWillClose(_ notification: Notification) {
        guard !cierrePorAccion else { return }
        onCancelar?()
    }
}
