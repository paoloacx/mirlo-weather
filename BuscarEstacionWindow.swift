import Cocoa

// Contenedor con el origen arriba a la izquierda: sin esto, el contenido de
// un NSScrollView se pega al borde inferior y la lista parece vacía.
private final class VistaVolteada: NSView {
    override var isFlipped: Bool { true }
}

// Ventana para buscar estaciones públicas de Netatmo cerca de casa y elegir
// una como favorita. Solo lectura: muestra lo que la estación comparte
// públicamente (lluvia y viento) y nunca modifica nada.
final class BuscarEstacionWindow: NSObject, NSWindowDelegate {
    var onBuscar: ((Int, @escaping (Result<[[String: Any]], Error>) -> Void) -> Void)?
    var onElegir: ((FavoritoPublico) -> Void)?
    var onQuitar: (() -> Void)?

    private let ventana: NSWindow
    private let popupRadio = NSPopUpButton()
    private let botonBuscar = NSButton()
    private let spinner = NSProgressIndicator()
    private let estado = NSTextField(wrappingLabelWithString: "")
    private let pila = NSStackView()
    private let scroll = NSScrollView()
    private let etiquetaFavorita = NSTextField(wrappingLabelWithString: "")
    private let botonQuitar = NSButton()

    private var favoritoActual: FavoritoPublico?
    private var resultados: [[String: Any]] = []
    private var buscando = false

    private let radios: [(String, Int)] = [
        ("2 km", 2), ("5 km", 5), ("10 km", 10), ("20 km", 20),
    ]

    override init() {
        ventana = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        ventana.title = L("Estación cercana")
        ventana.isReleasedWhenClosed = false
        ventana.minSize = NSSize(width: 540, height: 460)
        super.init()
        ventana.delegate = self
        construir()
    }

    func mostrar(favorito: FavoritoPublico?) {
        favoritoActual = favorito
        actualizarFavorita()
        NSApp.activate(ignoringOtherApps: true)
        ventana.center()
        ventana.makeKeyAndOrderFront(nil)
        buscar()
    }

    func cerrar() {
        ventana.close()
    }

    private func construir() {
        guard let content = ventana.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString:
            L("Si tu estación no tiene anemómetro o pluviómetro, puedes usar los datos públicos de una estación Netatmo cercana. Solo se leen sus medidas: nunca se modifica nada."))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.maximumNumberOfLines = 4

        let etiquetaRadio = NSTextField(labelWithString: L("Buscar en un radio de"))
        etiquetaRadio.font = .systemFont(ofSize: 12)

        for (titulo, _) in radios { popupRadio.addItem(withTitle: titulo) }
        popupRadio.selectItem(at: 2)
        popupRadio.controlSize = .small
        popupRadio.target = self
        popupRadio.action = #selector(radioCambiado(_:))

        botonBuscar.title = L("Buscar")
        botonBuscar.bezelStyle = .rounded
        botonBuscar.controlSize = .small
        botonBuscar.target = self
        botonBuscar.action = #selector(buscarPulsado(_:))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true

        let filaControles = NSStackView(views: [
            etiquetaRadio, popupRadio, botonBuscar, spinner,
        ])
        filaControles.orientation = .horizontal
        filaControles.spacing = 8
        filaControles.alignment = .centerY

        pila.orientation = .vertical
        pila.alignment = .leading
        pila.spacing = 1
        pila.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        pila.translatesAutoresizingMaskIntoConstraints = false

        let documento = VistaVolteada()
        documento.translatesAutoresizingMaskIntoConstraints = false
        documento.addSubview(pila)

        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = documento
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pila.leadingAnchor.constraint(equalTo: documento.leadingAnchor),
            pila.trailingAnchor.constraint(equalTo: documento.trailingAnchor),
            pila.topAnchor.constraint(equalTo: documento.topAnchor),
            pila.bottomAnchor.constraint(equalTo: documento.bottomAnchor),
            documento.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        estado.font = .systemFont(ofSize: 11)
        estado.textColor = .secondaryLabelColor
        estado.maximumNumberOfLines = 2
        estado.stringValue = ""

        etiquetaFavorita.font = .systemFont(ofSize: 12)
        etiquetaFavorita.maximumNumberOfLines = 2

        botonQuitar.title = L("Quitar favorita")
        botonQuitar.bezelStyle = .rounded
        botonQuitar.controlSize = .small
        botonQuitar.target = self
        botonQuitar.action = #selector(quitarPulsado(_:))
        botonQuitar.isHidden = true

        let filaFavorita = NSStackView(views: [etiquetaFavorita, botonQuitar])
        filaFavorita.orientation = .horizontal
        filaFavorita.spacing = 10
        filaFavorita.alignment = .centerY

        let nota = NSTextField(wrappingLabelWithString:
            L("Datos públicos de Netatmo. Solo aparecen estaciones que comparten sus medidas públicamente; la disponibilidad depende de cada zona."))
        nota.font = .systemFont(ofSize: 10)
        nota.textColor = .tertiaryLabelColor
        nota.maximumNumberOfLines = 3

        let columna = NSStackView(views: [
            intro, filaControles, scroll, estado, filaFavorita, nota,
        ])
        columna.orientation = .vertical
        columna.alignment = .leading
        columna.spacing = 10
        columna.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(columna)
        NSLayoutConstraint.activate([
            columna.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            columna.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            columna.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            columna.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(equalTo: columna.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            intro.widthAnchor.constraint(equalTo: columna.widthAnchor),
            estado.widthAnchor.constraint(equalTo: columna.widthAnchor),
            filaFavorita.widthAnchor.constraint(equalTo: columna.widthAnchor),
            nota.widthAnchor.constraint(equalTo: columna.widthAnchor),
        ])
    }

    private func radioSeleccionado() -> Int {
        let indice = max(0, min(radios.count - 1, popupRadio.indexOfSelectedItem))
        return radios[indice].1
    }

    @objc private func radioCambiado(_ sender: Any?) {
        buscar()
    }

    @objc private func buscarPulsado(_ sender: Any?) {
        buscar()
    }

    private func buscar() {
        guard !buscando else { return }
        buscando = true
        botonBuscar.isEnabled = false
        spinner.isHidden = false
        spinner.startAnimation(nil)
        estado.textColor = .secondaryLabelColor
        estado.stringValue = L("Buscando estaciones públicas en %d km…", radioSeleccionado())

        onBuscar?(radioSeleccionado()) { [weak self] resultado in
            guard let self = self else { return }
            self.buscando = false
            self.botonBuscar.isEnabled = true
            self.spinner.stopAnimation(nil)
            self.spinner.isHidden = true
            switch resultado {
            case .failure(let error):
                self.resultados = []
                self.reconstruirLista()
                self.estado.textColor = .systemRed
                self.estado.stringValue = error.localizedDescription
            case .success(let estaciones):
                self.resultados = estaciones
                self.reconstruirLista()
                self.estado.textColor = .secondaryLabelColor
                if estaciones.isEmpty {
                    self.estado.stringValue = L("No hay estaciones públicas con lluvia o viento en %d km. Prueba un radio mayor.", self.radioSeleccionado())
                } else {
                    self.estado.stringValue = estaciones.count == 1
                        ? L("1 estación encontrada con lluvia o viento.")
                        : L("%d estaciones encontradas con lluvia o viento.", estaciones.count)
                }
            }
        }
    }

    private func reconstruirLista() {
        for vista in pila.arrangedSubviews {
            pila.removeArrangedSubview(vista)
            vista.removeFromSuperview()
        }
        if resultados.isEmpty {
            let vacio = NSTextField(labelWithString: L("Sin resultados."))
            vacio.textColor = .tertiaryLabelColor
            vacio.font = .systemFont(ofSize: 12)
            pila.addArrangedSubview(vacio)
            return
        }
        for (indice, estacion) in resultados.enumerated() {
            pila.addArrangedSubview(fila(estacion, indice: indice))
        }
    }

    private func fila(_ estacion: [String: Any], indice: Int) -> NSView {
        let id = estacion["id"] as? String ?? ""
        let nombre = (estacion["nombre"] as? String)?.trimmingCharacters(in: .whitespaces)
            ?? (estacion["ciudad"] as? String) ?? L("Estación")
        let distancia = num(estacion["distancia_km"]).map { fmtNum($0, 1) } ?? "--"
        let pais = estacion["pais"] as? String ?? ""

        var medidas: [String] = []
        if let lluvia = estacion["lluvia"] as? [String: Any] {
            let actual = num(lluvia["actual"])
            let unaHora = num(lluvia["hace_1h"])
            var texto = L("Lluvia")
            if let unaHora = unaHora {
                texto += " " + fmtNum(unaHora, 1) + " mm/h"
            } else if let actual = actual {
                texto += " " + fmtNum(actual, 1) + " mm"
            }
            medidas.append(texto)
        }
        if let viento = estacion["viento"] as? [String: Any] {
            var texto = L("Viento")
            if let velocidad = num(viento["velocidad"]) {
                texto += " " + fmtNum(velocidad, 0) + " km/h"
            }
            let direccion = rumbo(num(viento["direccion"]))
            if !direccion.isEmpty { texto += " " + direccion }
            medidas.append(texto)
        }

        let titulo = NSTextField(labelWithString: nombre)
        titulo.font = .systemFont(ofSize: 13, weight: .semibold)
        let detalle = NSTextField(labelWithString:
            L("a %@ km", distancia) + (pais.isEmpty ? "" : " · \(pais)")
            + (medidas.isEmpty ? "" : " · " + medidas.joined(separator: " · ")))
        detalle.font = .systemFont(ofSize: 11)
        detalle.textColor = .secondaryLabelColor
        detalle.lineBreakMode = .byTruncatingTail

        let textos = NSStackView(views: [titulo, detalle])
        textos.orientation = .vertical
        textos.alignment = .leading
        textos.spacing = 2

        let accion: NSView
        if id == favoritoActual?.id {
            let marca = NSTextField(labelWithString: L("Favorita"))
            marca.font = .systemFont(ofSize: 11, weight: .semibold)
            marca.textColor = .controlAccentColor
            accion = marca
        } else {
            let boton = NSButton(title: L("Usar"), target: self, action: #selector(usarPulsado(_:)))
            boton.bezelStyle = .rounded
            boton.controlSize = .small
            boton.tag = indice
            accion = boton
        }

        let fila = NSStackView(views: [textos, accion])
        fila.orientation = .horizontal
        fila.spacing = 12
        fila.alignment = .centerY
        fila.distribution = .fill
        textos.setContentHuggingPriority(.defaultLow, for: .horizontal)
        accion.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let contenedor = NSView()
        contenedor.translatesAutoresizingMaskIntoConstraints = false
        fila.translatesAutoresizingMaskIntoConstraints = false
        contenedor.addSubview(fila)
        NSLayoutConstraint.activate([
            fila.topAnchor.constraint(equalTo: contenedor.topAnchor, constant: 7),
            fila.bottomAnchor.constraint(equalTo: contenedor.bottomAnchor, constant: -7),
            fila.leadingAnchor.constraint(equalTo: contenedor.leadingAnchor, constant: 10),
            fila.trailingAnchor.constraint(equalTo: contenedor.trailingAnchor, constant: -10),
            contenedor.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return contenedor
    }

    @objc private func usarPulsado(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < resultados.count,
              let favorito = FavoritoPublico.desde(resultados[sender.tag]) else { return }
        favoritoActual = favorito
        actualizarFavorita()
        onElegir?(favorito)
    }

    @objc private func quitarPulsado(_ sender: Any?) {
        favoritoActual = nil
        actualizarFavorita()
        onQuitar?()
    }

    private func actualizarFavorita() {
        if let favorito = favoritoActual {
            var partes = [L("Favorita actual: %@", favorito.etiqueta)]
            var tipos: [String] = []
            if favorito.tieneLluvia { tipos.append(L("lluvia")) }
            if favorito.tieneViento { tipos.append(L("viento")) }
            if !tipos.isEmpty { partes.append(tipos.joined(separator: L(" y "))) }
            etiquetaFavorita.stringValue = partes.joined(separator: " · ")
            etiquetaFavorita.textColor = .labelColor
            botonQuitar.isHidden = false
        } else {
            etiquetaFavorita.stringValue = L("Sin estación favorita.")
            etiquetaFavorita.textColor = .secondaryLabelColor
            botonQuitar.isHidden = true
        }
    }
}
