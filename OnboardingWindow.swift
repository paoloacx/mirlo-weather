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
    private var volverAlInicio = true
    private var buscando = false

    override init() {
        ventana = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 430),
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

        let icono = NSImageView(frame: NSRect(x: 207, y: 342, width: 56, height: 56))
        icono.image = NSApp.applicationIconImage
        icono.imageScaling = .scaleProportionallyUpOrDown
        vistaInicio.addSubview(icono)

        let titulo = NSTextField(labelWithString: L("Bienvenido a Mirlo Weather"))
        titulo.font = .systemFont(ofSize: 21, weight: .semibold)
        titulo.alignment = .center
        titulo.frame = NSRect(x: 30, y: 300, width: 410, height: 28)
        vistaInicio.addSubview(titulo)

        let cuerpo = NSTextField(wrappingLabelWithString:
            L("Elige cómo quieres usar la app. Podrás cambiar de modo cuando quieras."))
        cuerpo.font = .systemFont(ofSize: 13)
        cuerpo.textColor = .secondaryLabelColor
        cuerpo.alignment = .center
        cuerpo.maximumNumberOfLines = 2
        cuerpo.frame = NSRect(x: 46, y: 252, width: 378, height: 40)
        vistaInicio.addSubview(cuerpo)

        let botonCuenta = NSButton(
            title: L("Tengo mi estación de Netatmo"),
            target: self,
            action: #selector(conectarPulsado)
        )
        botonCuenta.bezelStyle = .rounded
        botonCuenta.controlSize = .large
        botonCuenta.font = .systemFont(ofSize: 13, weight: .medium)
        botonCuenta.frame = NSRect(x: 65, y: 198, width: 340, height: 38)
        vistaInicio.addSubview(botonCuenta)

        let botonLocalidad = NSButton(
            title: L("Ver el tiempo de mi localidad"),
            target: self,
            action: #selector(localidadPulsado)
        )
        botonLocalidad.bezelStyle = .rounded
        botonLocalidad.controlSize = .large
        botonLocalidad.font = .systemFont(ofSize: 13, weight: .medium)
        botonLocalidad.keyEquivalent = "\r"
        botonLocalidad.frame = NSRect(x: 65, y: 152, width: 340, height: 38)
        vistaInicio.addSubview(botonLocalidad)

        let nota = NSTextField(wrappingLabelWithString:
            L("Sin cuenta usaremos estaciones Netatmo públicas cercanas a la localidad que escribas. Solo se leen sus medidas; no se usa el GPS."))
        nota.font = .systemFont(ofSize: 11)
        nota.textColor = .tertiaryLabelColor
        nota.alignment = .center
        nota.maximumNumberOfLines = 3
        nota.frame = NSRect(x: 46, y: 92, width: 378, height: 46)
        vistaInicio.addSubview(nota)

        let cerrar = NSButton(title: L("Ahora no"), target: self, action: #selector(cerrarPulsado))
        cerrar.bezelStyle = .inline
        cerrar.frame = NSRect(x: 190, y: 52, width: 90, height: 26)
        vistaInicio.addSubview(cerrar)

        content.addSubview(vistaInicio)
    }

    // ----------------------------- localidad -----------------------------
    private func construirLocalidad() {
        guard let content = ventana.contentView else { return }
        vistaLocalidad.frame = content.bounds
        vistaLocalidad.autoresizingMask = [.width, .height]
        vistaLocalidad.isHidden = true

        let icono = NSImageView(frame: NSRect(x: 207, y: 344, width: 56, height: 56))
        icono.image = NSApp.applicationIconImage
        icono.imageScaling = .scaleProportionallyUpOrDown
        vistaLocalidad.addSubview(icono)

        let titulo = NSTextField(labelWithString: L("¿Dónde quieres ver el tiempo?"))
        titulo.font = .systemFont(ofSize: 19, weight: .semibold)
        titulo.alignment = .center
        titulo.frame = NSRect(x: 30, y: 304, width: 410, height: 26)
        vistaLocalidad.addSubview(titulo)

        let cuerpo = NSTextField(wrappingLabelWithString:
            L("Escribe tu localidad y elige una de las sugerencias. Buscaremos estaciones Netatmo públicas cerca y elegiremos los datos más representativos."))
        cuerpo.font = .systemFont(ofSize: 12)
        cuerpo.textColor = .secondaryLabelColor
        cuerpo.alignment = .center
        cuerpo.maximumNumberOfLines = 3
        cuerpo.frame = NSRect(x: 42, y: 252, width: 386, height: 44)
        vistaLocalidad.addSubview(cuerpo)

        campo.font = .systemFont(ofSize: 14)
        campo.placeholderString = L("Tu localidad")
        campo.delegate = self
        campo.alignment = .center
        campo.frame = NSRect(x: 65, y: 214, width: 340, height: 30)
        campo.target = self
        campo.action = #selector(buscarPulsado)
        vistaLocalidad.addSubview(campo)

        botonBuscar.title = L("Buscar estaciones")
        botonBuscar.bezelStyle = .rounded
        botonBuscar.controlSize = .large
        botonBuscar.keyEquivalent = "\r"
        botonBuscar.target = self
        botonBuscar.action = #selector(buscarPulsado)
        botonBuscar.frame = NSRect(x: 65, y: 170, width: 340, height: 34)
        vistaLocalidad.addSubview(botonBuscar)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 227, y: 140, width: 16, height: 16)
        spinner.isHidden = true
        vistaLocalidad.addSubview(spinner)

        estado.font = .systemFont(ofSize: 12)
        estado.textColor = .secondaryLabelColor
        estado.alignment = .center
        estado.maximumNumberOfLines = 4
        estado.frame = NSRect(x: 46, y: 82, width: 378, height: 54)
        vistaLocalidad.addSubview(estado)

        botonVolver.title = L("Volver")
        botonVolver.bezelStyle = .inline
        botonVolver.target = self
        botonVolver.action = #selector(volverPulsado)
        botonVolver.frame = NSRect(x: 190, y: 46, width: 90, height: 26)
        vistaLocalidad.addSubview(botonVolver)

        // Lista de sugerencias, encima del resto de controles.
        let columna = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sug"))
        columna.width = 336
        tabla.addTableColumn(columna)
        tabla.headerView = nil
        tabla.rowHeight = 34
        tabla.dataSource = self
        tabla.delegate = self
        tabla.target = self
        tabla.action = #selector(sugerenciaClic)
        scrollSugerencias.documentView = tabla
        scrollSugerencias.hasVerticalScroller = false
        scrollSugerencias.borderType = .lineBorder
        scrollSugerencias.isHidden = true
        scrollSugerencias.frame = NSRect(x: 65, y: 214, width: 340, height: 0)
        vistaLocalidad.addSubview(scrollSugerencias)

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
            scrollSugerencias.isHidden = true
            return
        }
        sugerencias = lista
        tabla.reloadData()
        if lista.isEmpty {
            scrollSugerencias.isHidden = true
            return
        }
        let alto = CGFloat(lista.count) * tabla.rowHeight + 4
        scrollSugerencias.frame = NSRect(x: 65, y: 214 - alto, width: 340, height: alto)
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
