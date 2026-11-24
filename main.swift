// Mirlo Weather - app nativa de barra de menus para macOS (solo lectura).
//
// Cada persona conecta su propia cuenta de Netatmo con OAuth + PKCE contra un
// servicio propio en Cloudflare Workers. La app no guarda claves de Netatmo:
// solo recibe una credencial de instalación y la guarda en el Llavero.
//
// Configuracion: ~/.netatmo-free/config.json
// Credencial: Llavero, servicio "netatmo-free", cuenta "credential".
// Callback: netatmofree://oauth/callback
import Cocoa
import CryptoKit
import Security
import UniformTypeIdentifiers
import UserNotifications

// ----------------------------- constantes -----------------------------
#if APPSTORE
let CONFIG_DIR = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".mirlo-weather")
#else
let CONFIG_DIR = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".netatmo-free")
#endif
let CONFIG_PATH = CONFIG_DIR.appendingPathComponent("config.json")
#if APPSTORE
let KEYCHAIN_SERVICE = "com.paoloac.mirloweather"
#else
let KEYCHAIN_SERVICE = "netatmo-free"
#endif
let KEYCHAIN_ACCOUNT = "credential"
let APP_CALLBACK = "netatmofree://oauth/callback"
let POLL_DEFAULT = 300
let STALE_SECONDS: TimeInterval = 1200
let NETATMO_WEB = "https://my.netatmo.com/app/station"

// Servicio gratuito ya desplegado. La primera conexion lo usa por defecto;
// el menu permite cambiarlo.
let DEFAULT_SERVICE_URL = "https://netatmo-free-worker.paolocorreyero.workers.dev"

// ----------------------------- errores -----------------------------
struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// ----------------------------- formato -----------------------------
func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
    return nil
}

func entero(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    return num(v).map { Int($0) }
}

func fmtNum(_ v: Double?, _ dec: Int = 1) -> String {
    guard let v = v else { return "--" }
    let texto = String(format: "%.\(dec)f", v)
    let sep = IdiomaApp.locale.decimalSeparator ?? ","
    return sep == "." ? texto : texto.replacingOccurrences(of: ".", with: sep)
}

func fmtTemp(_ v: Any?) -> String { fmtNum(num(v)) + "°" }

func rumbo(_ grados: Double?) -> String {
    guard let valor = grados else { return "" }
    let puntos = ["N", "NE", "E", "SE", "S", L("SO"), L("O"), L("NO")]
    let normalizado = ((valor.truncatingRemainder(dividingBy: 360)) + 360)
        .truncatingRemainder(dividingBy: 360)
    let indice = Int((normalizado / 45).rounded()) % 8
    return puntos[indice]
}

// Flecha hacia donde sopla el viento. Netatmo informa del ángulo de
// procedencia (convención meteorológica: 225° = del SO), así que se gira 180°
// para que la punta indique el destino.
func flechaViento(_ grados: Double?) -> String {
    guard let valor = grados else { return "" }
    let normalizado = ((valor + 180).truncatingRemainder(dividingBy: 360) + 360)
        .truncatingRemainder(dividingBy: 360)
    let flechas = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
    let indice = Int((normalizado / 45).rounded()) % 8
    return flechas[indice]
}
func fmtPct(_ v: Any?) -> String { fmtNum(num(v), 0) + " %" }

// ----------------------------- gráfica 24 h -----------------------------
// Sparkline dibujada a mano con el historial local que ya escribe el motor de
// avisos (~/.netatmo-free/historial.jsonl). Nunca sale del Mac.
func leerHistorialGrafica(campo: String, horas: Double = 24) -> [(ts: Double, valor: Double)] {
    guard let txt = try? String(contentsOf: AVISOS_HIST_PATH, encoding: .utf8) else { return [] }
    let corte = Date().timeIntervalSince1970 - horas * 3600
    var out: [(ts: Double, valor: Double)] = []
    for linea in txt.split(separator: "\n") {
        guard let data = linea.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = num(d["ts"]), ts >= corte,
              let valor = num(d[campo]) else { continue }
        // Cada refresco evalúa varias veces y escribe muestras casi iguales:
        // basta una por minuto para que la línea no salga engrosada.
        if let ultima = out.last, ts - ultima.ts < 60 { continue }
        out.append((ts: ts, valor: valor))
    }
    return out
}

struct CampoGrafica {
    let clave: String
    let nombre: String
    // Nombre sin el grupo de estación, para el título de la ventana.
    let nombreCorto: String
    let unidad: String
    let decimales: Int
    // `id` del módulo en Netatmo. Vacío en los campos heredados y en la
    // caldera, que no tienen serie propia en getmeasure.
    let idModulo: String?
    // Clave de la serie en la respuesta del Worker. En los campos heredados
    // coincide con `clave` (`exterior.temperatura`); por módulo es el nombre
    // corto (`temperatura`).
    let serieRemota: String?
    // Consulta antigua `modulo=` para los campos heredados.
    let modulo: String?
    let tipo: String
    // «Mi casa · Exterior». Vacío en los campos heredados.
    let grupo: String
    let campoBase: String
}

// Campos heredados: los que no dependen de un módulo concreto (caldera,
// tendencias y el modo localidad). En modo cuenta se sustituyen por el
// catálogo real de `modulos`, pero siguen siendo el respaldo si aún no hay
// lecturas.
var CAMPOS_GRAFICA: [CampoGrafica] {
    let legacy: [(clave: String, nombre: String, modulo: String?)] = [
        ("exterior.temperatura", L("Temperatura exterior"), "exterior"),
        ("interior.temperatura", L("Temperatura interior"), "interior"),
        ("exterior.humedad", L("Humedad exterior"), "exterior"),
        ("interior.humedad", L("Humedad interior"), "interior"),
        ("interior.co2", L("CO₂ interior"), "interior"),
        ("interior.presion", L("Presión interior"), "interior"),
        ("interior.ruido", L("Ruido interior"), "interior"),
        ("termostato.temperatura", L("Temperatura del termostato"), "termostato"),
        ("caldera.encendida", L("Caldera encendida"), nil),
        ("lluvia.24h", L("Lluvia en 24 h"), "lluvia"),
        ("lluvia.actual", L("Lluvia actual"), nil),
        ("viento.velocidad", L("Viento"), "viento"),
        ("viento.racha", L("Racha de viento"), "viento"),
    ]
    return legacy.map { item in
        let info = campoAviso(item.clave)
        let partes = item.clave.split(separator: ".").map(String.init)
        return CampoGrafica(
            clave: item.clave,
            nombre: item.nombre,
            nombreCorto: item.nombre,
            unidad: info.unidad,
            decimales: info.decimales,
            idModulo: nil,
            serieRemota: item.clave,
            modulo: item.modulo,
            tipo: partes.first ?? "otro",
            grupo: "",
            campoBase: partes.last ?? item.clave
        )
    }
}

final class VistaGrafica: NSView {
    var puntos: [(ts: Double, valor: Double)] = []
    var campo: String = "exterior.temperatura"
    // Nombre, unidad y decimales del campo elegido. En la gráfica por módulo
    // no coinciden con las claves heredadas de `campoAviso`.
    var nombreCampo: String = ""
    var unidadCampo: String = ""
    var decimalesCampo: Int = 1
    var origen: String = "local"
    // Aclaración opcional del pie (por ejemplo, cuando Netatmo no publica
    // histórico del campo y solo hay muestras de este Mac).
    var nota: String = ""

    private var definicion: CampoAviso {
        let heredado = campoAviso(campo)
        guard !nombreCampo.isEmpty else { return heredado }
        return CampoAviso(
            clave: campo,
            nombre: nombreCampo,
            unidad: unidadCampo,
            decimales: decimalesCampo
        )
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 336, height: 164) }

    // La gráfica es un dibujo, no una jerarquía de controles. Para VoiceOver se
    // expone como una imagen con un resumen hablado del campo y del último
    // valor, y con la aclaración del pie como ayuda.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .image }

    override func accessibilityLabel() -> String? {
        let info = definicion
        guard let ultimo = puntos.last else {
            return L("Gráfica de %@ sin datos", info.nombre)
        }
        let valor = fmtNum(ultimo.valor, info.decimales) + " " + info.unidad
        return L("Gráfica de %@, último valor %@", info.nombre, valor)
    }

    override func accessibilityHelp() -> String? {
        nota.isEmpty ? origenAccesible : nota
    }

    private var origenAccesible: String {
        origen == "Netatmo"
            ? L("Datos del histórico oficial de Netatmo de las últimas 24 horas.")
            : L("Datos de las lecturas guardadas en este Mac durante las últimas 24 horas.")
    }

    override func draw(_ r: NSRect) {
        // Márgenes: izquierda para los valores del eje Y, abajo para las horas
        // y el pie con el origen de los datos.
        let margenIzq: CGFloat = 42
        let margenDer: CGFloat = 10
        let margenSup: CGFloat = 12
        let altoHoras: CGFloat = 14
        let altoPie: CGFloat = 12
        let area = NSRect(
            x: margenIzq,
            y: altoPie + altoHoras,
            width: max(20, bounds.width - margenIzq - margenDer),
            height: max(20, bounds.height - margenSup - altoPie - altoHoras)
        )
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: bounds.width >= 640 ? 10 : 9),
        ]

        func dibujar(_ texto: String, x: CGFloat, centroY: CGFloat, derecha: Bool) {
            let tam = (texto as NSString).size(withAttributes: attrs)
            let px = derecha ? x - tam.width : x
            (texto as NSString).draw(
                at: NSPoint(x: px, y: centroY - tam.height / 2),
                withAttributes: attrs
            )
        }

        let info = definicion

        guard puntos.count >= 2 else {
            let titulo = origen == "Netatmo"
                ? L("Netatmo no devolvió muestras para «%@».", info.nombre)
                : L("Sin historial todavía para «%@».", info.nombre)
            (titulo as NSString)
                .draw(at: NSPoint(x: margenIzq + 2, y: area.midY + 4), withAttributes: attrs)
            let pie = origen == "Netatmo"
                ? L("Prueba otro campo o espera a la próxima consulta.")
                : L("Se genera con las lecturas de la app.")
            (pie as NSString)
                .draw(at: NSPoint(x: margenIzq, y: altoPie - 4), withAttributes: attrs)
            return
        }

        let vals = puntos.map { $0.valor }
        var mn = vals.min()!, mx = vals.max()!
        // Si todos los valores coinciden, se abre un margen mínimo para que la
        // línea no quede pegada al borde y las etiquetas tengan sentido.
        let minimo = info.decimales == 0 ? 1.0 : 0.4
        if mx - mn < minimo {
            let centro = (mx + mn) / 2
            mn = centro - minimo / 2
            mx = centro + minimo / 2
        }
        let rango = mx - mn

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        let filas = area.height >= 220 ? 4 : 2
        let guia = NSBezierPath()
        guia.lineWidth = 1
        for i in 0...filas {
            let y = area.minY + area.height * CGFloat(i) / CGFloat(filas)
            guia.move(to: NSPoint(x: area.minX, y: y))
            guia.line(to: NSPoint(x: area.maxX, y: y))
        }
        guia.stroke()

        // La ventana representa siempre las últimas 24 h, no solo el tramo que
        // ocupan los puntos: así se ve de un vistazo si faltan datos a la
        // izquierda (por ejemplo, si la app lleva poco tiempo abierta).
        let t1 = Date().timeIntervalSince1970
        let t0 = t1 - 24 * 3600
        let span = 24 * 3600.0
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        var anterior: Double?
        for p in puntos where p.ts >= t0 {
            let x = area.minX + CGFloat((p.ts - t0) / span) * area.width
            let y = area.minY + CGFloat((p.valor - mn) / rango) * area.height
            // Un hueco de más de 45 min (los datos de Netatmo van cada 30)
            // se deja en blanco en vez de unir los extremos con una recta
            // que no ocurrió.
            if let previo = anterior, p.ts - previo > 45 * 60 {
                path.move(to: NSPoint(x: x, y: y))
            } else if anterior == nil {
                path.move(to: NSPoint(x: x, y: y))
            } else {
                path.line(to: NSPoint(x: x, y: y))
            }
            anterior = p.ts
        }
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        // Etiquetas del eje Y: una por línea de guía.
        for i in 0...filas {
            let valor = mx - rango * Double(i) / Double(filas)
            let y = area.maxY - area.height * CGFloat(i) / CGFloat(filas)
            dibujar(fmtNum(valor, info.decimales),
                    x: area.minX - 5, centroY: y, derecha: true)
        }
        // Etiquetas del eje X: cada 12 h en ventanas pequeñas, cada 6 o 3 h
        // cuando hay ancho suficiente para que no se pisen.
        let pasoHoras = area.width >= 860 ? 3 : (area.width >= 560 ? 6 : 12)
        var hora = -24
        while hora <= 0 {
            let x = area.minX + CGFloat(Double(hora + 24) / 24) * area.width
            let texto = hora == 0 ? L("ahora") : "−\(-hora) h"
            let tam = (texto as NSString).size(withAttributes: attrs)
            let px: CGFloat
            if hora == -24 {
                px = x
            } else if hora == 0 {
                px = x - tam.width
            } else {
                px = x - tam.width / 2
            }
            (texto as NSString).draw(
                at: NSPoint(x: px, y: area.minY - altoHoras / 2 - tam.height / 2),
                withAttributes: attrs
            )
            hora += pasoHoras
        }

        let pie = (origen == "Netatmo" ? "Netatmo" : L("local"))
            + " · " + L("%d muestras", puntos.count)
            + (info.unidad.isEmpty ? "" : " · " + info.unidad)
            + (nota.isEmpty ? "" : " · " + nota)
        (pie as NSString).draw(
            at: NSPoint(x: margenIzq, y: altoPie - 10),
            withAttributes: attrs
        )
    }
}

func edad(_ fecha: Date?) -> String {
    guard let fecha = fecha else { return "" }
    let segundos = max(0, Int(Date().timeIntervalSince(fecha)))
    if segundos < 60 { return L("hace %d s", segundos) }
    if segundos < 3600 { return L("hace %d min", segundos / 60) }
    return L("hace %d h", segundos / 3600)
}

// La hora que declara el servicio ("yyyy-MM-dd HH:mm:ss" en la zona que
// enviamos en X-Time-Zone). Se usa para detectar que Netatmo dejo de
// actualizar aunque el Worker siga respondiendo.
func fechaDelServicio(_ texto: String?) -> Date? {
    guard let texto = texto, !texto.isEmpty else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    f.timeZone = .current
    return f.date(from: texto)
}

// Icono monocromo de barra: SF Symbols en modo plantilla. Si un simbolo no
// existe en esa version de macOS se prueba el de reserva.
func simbolo(_ nombre: String, _ reserva: String) -> NSImage? {
    if let img = NSImage(systemSymbolName: nombre, accessibilityDescription: nil) {
        img.isTemplate = true
        return img
    }
    if let img = NSImage(systemSymbolName: reserva, accessibilityDescription: nil) {
        img.isTemplate = true
        return img
    }
    return nil
}

// ----------------------------- caldera -----------------------------
// Histórico oficial de Netatmo (getmeasure). No se estima por muestreo:
// Netatmo devuelve `sum_boiler_on` por día, en segundos.
struct CalderaRemota {
    var hoyMin: Int
    var ayerMin: Int
    var mesMin: Int
    var actualizado: String?
}

func fmtMinutos(_ minutos: Int) -> String {
    let total = max(0, minutos)
    if total < 1 { return "0 min" }
    let h = total / 60, m = total % 60
    if h == 0 { return "\(m) min" }
    if m == 0 { return "\(h) h" }
    return "\(h) h \(m) min"
}

// ----------------------------- configuracion -----------------------------
// Estación pública de Netatmo elegida para cubrir sensores que no tenemos
// (lluvia y/o viento). Se guarda solo en el Mac: id público, nombre y
// coordenadas de la estación, nada de la cuenta.
struct FavoritoPublico {
    var id: String
    var nombre: String
    var lat: Double
    var lon: Double
    var distanciaKm: Double
    var tieneLluvia: Bool
    var tieneViento: Bool

    var etiqueta: String {
        let distancia = fmtNum(distanciaKm, 1)
        return "\(nombre) (\(distancia) km)"
    }

    var diccionario: [String: Any] {
        [
            "id": id,
            "nombre": nombre,
            "lat": lat,
            "lon": lon,
            "distancia_km": distanciaKm,
            "tiene_lluvia": tieneLluvia,
            "tiene_viento": tieneViento,
        ]
    }

    static func desde(_ raw: Any?) -> FavoritoPublico? {
        guard let d = raw as? [String: Any],
              let id = d["id"] as? String, !id.isEmpty,
              let lat = num(d["lat"]), let lon = num(d["lon"]) else { return nil }
        let nombre = (d["nombre"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FavoritoPublico(
            id: id,
            nombre: nombre.isEmpty ? L("Estación cercana") : nombre,
            lat: lat,
            lon: lon,
            distanciaKm: num(d["distancia_km"]) ?? 0,
            tieneLluvia: (d["tiene_lluvia"] as? Bool) ?? false,
            tieneViento: (d["tiene_viento"] as? Bool) ?? false
        )
    }
}

struct Config {
    var serviceUrl: String = ""
    var endpoint: String = ""
    var installationId: String = ""
    var pollSeconds: Int = POLL_DEFAULT
    var barValue: String = "exterior"
    var polling: Bool = true
    var favorito: FavoritoPublico?
    // "cuenta" (OAuth de Netatmo) o "localidad" (estaciones públicas sin
    // cuenta). Vacío solo en el primer arranque, cuando se muestra la
    // ventana de bienvenida con las dos vías.
    var modo: String = ""
    var localidad: LocalidadConfig?
    // Localidades guardadas (hasta 5). `localidad` es la activa; esta lista
    // permite cambiar sin repetir la búsqueda de bienvenida.
    var localidades: [LocalidadConfig] = []
    // Estación principal en cuentas con varias. Vacío = la que elija Netatmo.
    var estacionPrincipal: String = ""
    // Verdadero si `load` ha tenido que completar la lista de localidades.
    // No se guarda: solo sirve para persistir la migración al arrancar.
    var migrada = false
    #if !APPSTORE
    var autoUpdate: Bool = true
    var notifiedUpdate: String = ""
    #endif
    var highlight: Bool = false
    var highlightColor: String = "#FF9F0A"
    // "auto", "blanco" o "negro". El usuario puede forzar el color del texto
    // del resaltado si el automático no le convence con su color elegido.
    var highlightTextColor: String = "auto"
    var highlightItems: [String] = ["exterior", "interior", "caldera"]
    var graphField: String = "exterior.temperatura"
    // Sección elegida en la ventana única de Ajustes (general, barra,
    // estaciones, avisos o avanzado). Se restaura al volver a abrirla.
    var ajustesSection: String = "general"
    // La ventana de la gráfica se mantiene por encima del resto solo si el
    // usuario lo pide con el botón de la barra de herramientas.
    var graficaFlotante: Bool = false
    // "auto", "es" o "en".
    var idioma: String = "auto"
    var loginItemInit: Bool = false
    var avisos = ConfigAvisos()

    static func load() -> Config {
        var c = Config()
        if let data = try? Data(contentsOf: CONFIG_PATH),
           let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let lang = d["idioma"] as? String ?? "auto"
            c.idioma = ["auto", "es", "en"].contains(lang) ? lang : "auto"
            IdiomaApp.aplicar(c.idioma)
            c.loginItemInit = (d["login_item_init"] as? Bool) ?? false
            c.serviceUrl = d["service_url"] as? String ?? ""
            c.endpoint = d["endpoint"] as? String ?? ""
            c.installationId = d["installation_id"] as? String ?? ""
            c.pollSeconds = max(60, entero(d["poll_seconds"]) ?? POLL_DEFAULT)
            c.barValue = d["valor_barra"] as? String ?? "exterior"
            // La pausa de consultas se ha retirado: una configuración antigua
            // con consultas pausadas no debe dejar la app sin datos.
            c.polling = true
            c.favorito = FavoritoPublico.desde(d["favorito_publico"])
            c.modo = d["modo"] as? String ?? ""
            c.localidad = LocalidadConfig.desde(d["localidad"])
            if let lista = d["localidades"] as? [[String: Any]] {
                c.localidades = lista.compactMap { LocalidadConfig.desde($0) }
            }
            c.estacionPrincipal = (d["estacion_principal"] as? String) ?? ""
            if c.modo != "cuenta" && c.modo != "localidad" {
                // Configuraciones anteriores no tienen «modo»: si ya había
                // una cuenta conectada, se mantiene el modo de siempre.
                if !c.endpoint.isEmpty {
                    c.modo = "cuenta"
                } else if c.localidad != nil {
                    c.modo = "localidad"
                } else {
                    c.modo = ""
                }
            }
            if c.modo == "localidad" {
                if c.localidad == nil {
                    c.modo = ""
                } else if c.serviceUrl.isEmpty {
                    c.serviceUrl = DEFAULT_SERVICE_URL
                }
            }
            #if !APPSTORE
            c.autoUpdate = (d["auto_update"] as? Bool) ?? true
            c.notifiedUpdate = d["notified_update"] as? String ?? ""
            #endif
            c.highlight = (d["destacar_datos"] as? Bool) ?? false
            c.highlightColor = d["color_destacado"] as? String ?? "#FF9F0A"
            let texto = d["texto_destacado"] as? String ?? "auto"
            c.highlightTextColor = ["auto", "blanco", "negro"].contains(texto)
                ? texto
                : "auto"
            if let items = d["destacar_items"] as? [String] {
                c.highlightItems = items
            } else if c.highlight {
                // Configuraciones anteriores resaltaban todo: empezamos con
                // los bloques principales para que el usuario elija el resto.
                c.highlightItems = ["exterior", "interior", "caldera"]
            } else {
                c.highlightItems = []
            }
            c.graphField = d["grafica_campo"] as? String ?? "exterior.temperatura"
            c.ajustesSection = d["ajustes_seccion"] as? String ?? "general"
            c.graficaFlotante = (d["grafica_flotante"] as? Bool) ?? false
            if let a = d["avisos"] as? [String: Any] {
                c.avisos = ConfigAvisos.desde(a)
            }
        } else {
            IdiomaApp.aplicar("auto")
            c.avisos = ConfigAvisos()
        }
        if c.installationId.isEmpty {
            c.installationId = UUID().uuidString.lowercased()
        }
        // Migración: la localidad activa siempre forma parte de la lista.
        if migrarLocalidades(activa: c.localidad, lista: &c.localidades) {
            c.migrada = true
        }
        if !c.loginItemInit {
            c.loginItemInit = true
            if !LoginItem.isEnabled {
                try? LoginItem.setEnabled(true)
            }
        }
        c.save()
        return c
    }

    // Guarda (o reemplaza por nombre) una localidad y la deja como activa.
    mutating func guardarLocalidad(_ nueva: LocalidadConfig) {
        if let indice = localidades.firstIndex(where: { $0.nombre == nueva.nombre }) {
            localidades[indice] = nueva
        } else {
            localidades.insert(nueva, at: 0)
        }
        if localidades.count > 5 {
            localidades = Array(localidades.prefix(5))
        }
        localidad = nueva
    }

    func save() {
        var d: [String: Any] = [
            "service_url": serviceUrl,
            "endpoint": endpoint,
            "installation_id": installationId,
            "poll_seconds": pollSeconds,
            "valor_barra": barValue,
            "consultas_iniciadas": polling,
            "destacar_datos": highlight,
            "color_destacado": highlightColor,
            "texto_destacado": highlightTextColor,
            "destacar_items": highlightItems,
            "grafica_campo": graphField,
            "grafica_flotante": graficaFlotante,
            "ajustes_seccion": ajustesSection,
            "idioma": idioma,
            "login_item_init": loginItemInit,
            "avisos": avisos.diccionario,
            "modo": modo,
        ]
        #if !APPSTORE
        d["auto_update"] = autoUpdate
        d["notified_update"] = notifiedUpdate
        #endif
        if let localidad = localidad {
            d["localidad"] = localidad.diccionario
        }
        d["localidades"] = localidades.map { $0.diccionario }
        d["estacion_principal"] = estacionPrincipal
        if let favorito = favorito {
            d["favorito_publico"] = favorito.diccionario
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: d,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(
            at: CONFIG_DIR,
            withIntermediateDirectories: true
        )
        try? data.write(to: CONFIG_PATH, options: .atomic)
    }
}

// ----------------------------- fila resaltada -----------------------------
// Vista propia para las filas destacadas del menú. Un NSMenuItem normal solo
// permite pintar el fondo del texto (attributedTitle), que deja márgenes
// arriba, abajo y a la derecha. Con item.view el color ocupa toda la fila,
// igual que el resaltado azul del ratón, y el texto se dibuja encima.
final class FilaResaltada: NSView {
    var texto: String = ""
    var colorFondo: NSColor = .white
    var colorTexto: NSColor = .black

    // El texto del menú empieza a unos 10 pt del borde de la fila.
    private let margenTexto: CGFloat = 10

    override func draw(_ dirty: NSRect) {
        colorFondo.setFill()
        NSBezierPath(rect: bounds).fill()

        guard !texto.isEmpty else { return }
        let fuente = NSFont.menuFont(ofSize: 0)
        let parrafo = NSMutableParagraphStyle()
        parrafo.lineBreakMode = .byTruncatingTail
        let atributos: [NSAttributedString.Key: Any] = [
            .font: fuente,
            .foregroundColor: colorTexto,
            .paragraphStyle: parrafo,
        ]
        let alto = (texto as NSString).size(withAttributes: [.font: fuente]).height
        let rect = NSRect(
            x: margenTexto,
            y: (bounds.height - alto) / 2,
            width: max(0, bounds.width - margenTexto - 6),
            height: alto + 1
        )
        (texto as NSString).draw(in: rect, withAttributes: atributos)
    }
}

// ----------------------------- color -----------------------------
// El color de destacado se guarda como #RRGGBB para que config.json sea
// legible y no dependa del espacio de color del Mac.
extension NSColor {
    static func desdeHex(_ texto: String) -> NSColor? {
        var limpio = texto.trimmingCharacters(in: .whitespacesAndNewlines)
        if limpio.hasPrefix("#") { limpio.removeFirst() }
        guard limpio.count == 6, let valor = UInt32(limpio, radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((valor >> 16) & 0xFF) / 255,
            green: CGFloat((valor >> 8) & 0xFF) / 255,
            blue: CGFloat(valor & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexRGB: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FF9F0A" }
        return String(
            format: "#%02X%02X%02X",
            Int((c.redComponent * 255).rounded()),
            Int((c.greenComponent * 255).rounded()),
            Int((c.blueComponent * 255).rounded())
        )
    }

    // Texto legible sobre el color de resalte. Se comparan las relaciones de
    // contraste WCAG con blanco y con el tono oscuro, y se elige la mejor.
    // macOS adapta los grises (incluido el negro puro) al color de texto del
    // menú y en modo oscuro los pinta casi blancos: sobre un fondo claro
    // desaparecerían. Un azul muy oscuro conserva el contraste y se lee
    // prácticamente como negro.
    static let textoOscuroResaltado = NSColor(
        srgbRed: 0.03, green: 0.12, blue: 0.21, alpha: 1
    )

    var textoContraste: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return NSColor.textoOscuroResaltado }
        func lineal(_ valor: CGFloat) -> CGFloat {
            let v = max(0, min(1, valor))
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let luminancia = 0.2126 * lineal(c.redComponent)
            + 0.7152 * lineal(c.greenComponent)
            + 0.0722 * lineal(c.blueComponent)
        let contrasteBlanco = 1.05 / (luminancia + 0.05)
        let contrasteOscuro = (luminancia + 0.05) / 0.05
        return contrasteOscuro >= contrasteBlanco
            ? NSColor.textoOscuroResaltado
            : .white
    }
}

// ----------------------------- llavero -----------------------------
// En la versión de App Store se usa el llavero de datos protegidos, propio de la
// app: no pide permiso al usuario y no toca elementos de otras apps.
func keychainBase() -> [String: Any] {
    var q: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: KEYCHAIN_SERVICE,
        kSecAttrAccount as String: KEYCHAIN_ACCOUNT,
    ]
    #if APPSTORE
    q[kSecUseDataProtectionKeychain as String] = true
    #endif
    return q
}

func keychainRead() -> String? {
    var q = keychainBase()
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

func keychainSave(_ value: String) -> Bool {
    let base = keychainBase()
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecValueData as String] = Data(value.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
}

func keychainDelete() {
    SecItemDelete(keychainBase() as CFDictionary)
}

// ----------------------------- criptografia -----------------------------
func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func sha256Base64url(_ value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return Data(digest).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// ----------------------------- red -----------------------------
struct HTTPResult {
    let status: Int
    let json: [String: Any]?
    let text: String
}

func httpJSON(
    _ urlString: String,
    method: String = "GET",
    body: [String: Any]? = nil,
    bearer: String? = nil,
    timeZone: String? = nil,
    timeout: TimeInterval = 20
) throws -> HTTPResult {
    guard let url = URL(string: urlString) else { throw AppError(L("URL no válida")) }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeout
    request.setValue("NetatmoFree/0.1", forHTTPHeaderField: "User-Agent")
    if let timeZone = timeZone, !timeZone.isEmpty {
        request.setValue(timeZone, forHTTPHeaderField: "X-Time-Zone")
    }
    if let body = body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    if let bearer = bearer, !bearer.isEmpty {
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    }

    let sem = DispatchSemaphore(value: 0)
    var outData: Data?
    var outResponse: URLResponse?
    var outError: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
        outData = data
        outResponse = response
        outError = error
        sem.signal()
    }.resume()

    if sem.wait(timeout: .now() + timeout + 5) == .timedOut {
        throw AppError(L("El servicio no respondió a tiempo"))
    }
    if let error = outError {
        throw AppError(L("Error de red: %@", error.localizedDescription))
    }
    guard let http = outResponse as? HTTPURLResponse, let data = outData else {
        throw AppError(L("Sin respuesta del servicio"))
    }
    let text = String(data: data, encoding: .utf8) ?? ""
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return HTTPResult(status: http.statusCode, json: json, text: text)
}

func normalizarServicio(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while value.hasSuffix("/") { value.removeLast() }
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          let host = url.host, !host.isEmpty,
          url.path.isEmpty || url.path == "/",
          url.query == nil, url.fragment == nil else { return nil }
    if scheme == "https" { return value }
    if scheme == "http" && (host == "127.0.0.1" || host == "localhost") { return value }
    return nil
}

func codigoError(_ resultado: HTTPResult) -> String {
    resultado.json?["error"] as? String ?? ""
}

// ------------------------- notificaciones -------------------------
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    static let categoriaAviso = "MIRLO_AVISO"
    static let accionSilenciar = "MIRLO_SILENCIAR_1H"
    static let accionAbrir = "MIRLO_ABRIR"
    var onOpenSettings: (() -> Void)?
    // Silenciar una regla concreta desde la propia notificación.
    var onSilenciar: ((String) -> Void)?
    // Abrir el menú de la barra desde la notificación.
    var onAbrir: (() -> Void)?
    private(set) var permiso: UNAuthorizationStatus = .notDetermined
    private var prepared = false

    func prepare() {
        guard !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let silenciar = UNNotificationAction(
            identifier: Self.accionSilenciar,
            title: L("Silenciar 1 h")
        )
        let abrir = UNNotificationAction(
            identifier: Self.accionAbrir,
            title: L("Abrir Mirlo")
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoriaAviso,
                actions: [silenciar, abrir],
                intentIdentifiers: [],
                options: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            self.refrescarPermiso(nil)
        }
    }

    // Permiso de notificaciones para los avisos configurables.
    func refrescarPermiso(_ completion: ((UNAuthorizationStatus) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { ajustes in
            self.permiso = ajustes.authorizationStatus
            guard let cb = completion else { return }
            DispatchQueue.main.async { cb(ajustes.authorizationStatus) }
        }
    }

    func pedirPermiso(_ completion: ((Bool) -> Void)? = nil) {
        prepare()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            self.refrescarPermiso { _ in completion?(ok) }
        }
    }

    // Devuelve false si el sistema no permite notificaciones: el motor de
    // avisos usa entonces sonido + aviso visible en el menú.
    @discardableResult
    func enviar(titulo: String, cuerpo: String, reglaId: String? = nil) -> Bool {
        guard permiso == .authorized || permiso == .provisional else { return false }
        let content = UNMutableNotificationContent()
        content.title = titulo
        content.body = cuerpo
        content.sound = .default
        if let reglaId = reglaId {
            content.categoryIdentifier = Self.categoriaAviso
            content.userInfo = ["regla": reglaId]
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        return true
    }

    func reconnectNeeded() {
        prepare()
        let content = UNMutableNotificationContent()
        content.title = "Mirlo Weather"
        content.body = L("Vuelve a conectar tu cuenta de Netatmo para seguir viendo las lecturas.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "mirlo-reconnect",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    #if !APPSTORE
    func updateAvailable(version: String) {
        prepare()
        let content = UNMutableNotificationContent()
        content.title = "Mirlo Weather \(version)"
        content.body = L("Hay una versión nueva disponible. Abre Ajustes para instalarla.")
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "mirlo-update-\(version)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
    #endif

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if response.notification.request.identifier.hasPrefix("mirlo-update") {
            DispatchQueue.main.async { self.onOpenSettings?() }
        } else if response.actionIdentifier == Self.accionSilenciar,
                  let id = info["regla"] as? String {
            DispatchQueue.main.async { self.onSilenciar?(id) }
        } else if response.actionIdentifier == Self.accionAbrir
                    || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onAbrir?() }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

// ----------------------------- app -----------------------------
var VALORES_BARRA: [(String, String)] {
    [
        ("exterior", L("Temperatura exterior")),
        ("interior", L("Temperatura interior")),
        ("interior_tendencia", L("Temperatura interior con tendencia")),
        ("minmax", L("Min/Max de hoy (exterior)")),
        ("humedad_ext", L("Humedad exterior")),
        ("humedad_int", L("Humedad interior")),
        ("co2", L("CO₂ interior")),
        ("ruido", L("Ruido interior")),
        ("termostato", L("Termostato y consigna")),
        ("viento", L("Viento")),
        ("lluvia", L("Lluvia")),
        ("ninguno", L("Solo el icono")),
    ]
}

final class ConnectWindow {
    let window: NSWindow
    var onConnect: (() -> Void)?

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let connectButton = NSButton()
    private let closeButton = NSButton()
    private var idleTitle = L("Conectar con Netatmo")
    private var statusHeight: NSLayoutConstraint!
    private var spinnerHeight: NSLayoutConstraint!

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mirlo Weather"
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.center()
        build()
    }

    var isVisible: Bool { window.isVisible }

    private func build() {
        guard let content = window.contentView else { return }

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        let symbol = NSImage.SymbolConfiguration(pointSize: 46, weight: .regular)
        icon.image = NSImage(
            systemSymbolName: "thermometer.sun.fill",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(symbol)
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 3
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.stringValue = ""

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true

        connectButton.title = idleTitle
        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectPressed)
        connectButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.title = L("Ahora no")
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(icon)
        content.addSubview(titleLabel)
        content.addSubview(bodyLabel)
        content.addSubview(spinner)
        content.addSubview(statusLabel)
        content.addSubview(connectButton)
        content.addSubview(closeButton)

        statusHeight = statusLabel.heightAnchor.constraint(equalToConstant: 0)
        spinnerHeight = spinner.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            bodyLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 36),
            bodyLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -36),
            bodyLabel.heightAnchor.constraint(equalToConstant: 38),

            spinner.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 10),
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinnerHeight,

            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
            statusHeight,

            connectButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            connectButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            connectButton.widthAnchor.constraint(equalToConstant: 230),
            connectButton.heightAnchor.constraint(equalToConstant: 34),

            closeButton.topAnchor.constraint(equalTo: connectButton.bottomAnchor, constant: 8),
            closeButton.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ])
    }

    func configure(reconnect: Bool) {
        idleTitle = reconnect ? L("Reconectar con Netatmo") : L("Conectar con Netatmo")
        titleLabel.stringValue = reconnect
            ? L("Vuelve a conectar tu cuenta")
            : L("Conecta tu cuenta de Netatmo")
        bodyLabel.stringValue = reconnect
            ? L("Autoriza de nuevo el acceso de solo lectura. No se cambiará nada de tu casa ni de tu cuenta.")
            : L("Mirlo Weather leerá tu estación y tu termostato. Solo lectura: nunca cambia la calefacción ni la caldera.")
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        statusHeight.constant = 0
        spinnerHeight.constant = 0
        window.setContentSize(NSSize(width: 440, height: 300))
        connectButton.title = idleTitle
        connectButton.isEnabled = true
        closeButton.isEnabled = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func setWaiting(_ message: String) {
        connectButton.isEnabled = false
        closeButton.isEnabled = false
        connectButton.title = L("Conectando…")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = message
        statusHeight.constant = 30
        spinnerHeight.constant = 16
        window.setContentSize(NSSize(width: 440, height: 340))
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func setError(_ message: String) {
        connectButton.isEnabled = true
        closeButton.isEnabled = true
        connectButton.title = L("Reintentar")
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = message
        statusHeight.constant = 30
        spinnerHeight.constant = 0
        window.setContentSize(NSSize(width: 440, height: 340))
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        show()
    }

    func setSuccess() {
        connectButton.isEnabled = false
        closeButton.isEnabled = false
        connectButton.title = L("Conectado")
        statusLabel.textColor = .systemGreen
        statusLabel.stringValue = L("Cuenta conectada. Cargando lecturas…")
        statusHeight.constant = 30
        spinnerHeight.constant = 0
        window.setContentSize(NSSize(width: 440, height: 340))
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.window.close()
        }
    }

    @objc private func connectPressed() {
        onConnect?()
    }

    @objc private func closePressed() {
        window.close()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var cfg = Config.load()
    private var credential: String?
    private var datos: [String: Any]?
    // Respuesta tal cual del servicio. Se guarda para poder cambiar de
    // estación principal sin esperar a otra consulta.
    private var datosBrutos: [String: Any]?
    // Cambia al cambiar de localidad para descartar respuestas antiguas.
    private var generacionLocalidad = 0
    private var lastSuccess: Date?
    private var lastAttempt: Date?
    private var lastError: String?
    private var caldera: CalderaRemota?
    private var calderaCargada: Date?
    private var calderaError: String?
    private var sinCaldera = false
    private var cargandoCaldera = false
    private var needsReconnect = false
    private var refreshing = false
    private var connecting = false
    private var pending: PendingOAuth?
    private var pollTimer: Timer?
    private var arranqueTimer: Timer?
    private var arranqueIntentos = 0
    private var pauseGeneration = 0
    private var connectWindow: ConnectWindow?
    private var statusCaldera: NSStatusItem?
    private var alertTimer: Timer?
    private var avisoPendiente: String?
    private var avisoPendienteTimer: Timer?
    private var avisoBarraHasta: Date?
    private var avisoBarraTimer: Timer?

    private lazy var motorAvisos: MotorAvisos = {
        let motor = MotorAvisos(config: cfg.avisos)
        motor.onConfigChanged = { [weak self] in
            guard let self = self else { return }
            self.cfg.avisos = motor.snapshot()
            self.cfg.save()
            self.reconstruirSubmenuAvisos()
        }
        motor.onAvisoVisible = { [weak self] texto in
            self?.mostrarAvisoPendiente(texto)
        }
        return motor
    }()

    private var statusItem: NSStatusItem!
    private var itCuenta: NSMenuItem!
    private var itConectar: NSMenuItem!
    private var itCambiarLocalidad: NSMenuItem!
    private var itElegirEstaciones: NSMenuItem!
    private var itUsarLocalidad: NSMenuItem!
    private var itConectarCuenta: NSMenuItem!
    private var itAvisoPendiente: NSMenuItem!
    private var itExterior: NSMenuItem!
    private var itExtMinMax: NSMenuItem!
    private var itInterior: NSMenuItem!
    private var itIntExtra: NSMenuItem!
    private var itTermo: NSMenuItem!
    private var itCaldera: NSMenuItem!
    private var itCalderaHoy: NSMenuItem!
    private var itEstacionCercana: NSMenuItem!
    private var itFuenteLocalidad: NSMenuItem!
    private var itFavViento: NSMenuItem!
    private var itFavLluvia: NSMenuItem!
    private var itActualizar: NSMenuItem!
    private var itAvisos: NSMenuItem!
    private var itGrafica: NSMenuItem!
    private var vistaGrafica = VistaGrafica(frame: NSRect(x: 0, y: 0, width: 336, height: 164))
    private var ventanaGrafica: NSWindow?
    private var popupGrafica: NSPopUpButton?
    // true si el sistema recordó tamaño y posición de la gráfica; entonces no
    // se recoloca debajo del icono de la barra al abrirla.
    private var graficaRestaurada = false
    private var camposGraficaClaves: [String] = []
    // Histórico oficial de Netatmo (getmeasure) por campo. Si aún no hay
    // respuesta para un campo, la gráfica usa el historial local.
    private var historialNetatmo: [String: (puntos: [(ts: Double, valor: Double)], cargado: Date)] = [:]
    private var cargandoHistorial: Set<String> = []
    private var intentoHistorial: [String: Date] = [:]
    private var moduloSinHistorial: Set<String> = []
    #if !APPSTORE
    private var itNuevaVersion: NSMenuItem!
    #endif
    private var itAjustes: NSMenuItem!
    private var itAvanzado: NSMenuItem!
    private var itCambiarServicio: NSMenuItem!
    private var itRestablecer: NSMenuItem!
    private var itemsBarra: [NSMenuItem] = []
    private var itemsModulosExt: [NSMenuItem] = []
    private var itemsModulosInt: [NSMenuItem] = []
    private var itemsModulosOtras: [NSMenuItem] = []
    private var sepExteriorInterior: NSMenuItem!
    private var sepInteriorCaldera: NSMenuItem!
    private var sepEstaciones: NSMenuItem!
    private var settingsWindow: SettingsWindow?
    private var ventanaEstacion: BuscarEstacionWindow?
    private var favoritoDatos: [String: Any]?
    private var favoritoActualizado: Date?
    private var favoritoError: String?
    private var cargandoFavorito = false
    // Modo «solo localidad»: estaciones públicas alrededor del punto elegido.
    private var onboardingWindow: OnboardingWindow?
    private var selectorEstaciones: SelectorEstacionesWindow?
    private var estacionesLocalidad: [[String: Any]] = []
    private var composicionLocalidad: ComposicionLocalidad?
    private var avisoLocalidad: String?
    #if !APPSTORE
    private var availableRelease: AppRelease?
    private var updateTimer: Timer?
    private var checkingUpdate = false
    private var updateStatus = L("Comprobación automática activada.")
    #endif

    private struct PendingOAuth {
        let appState: String
        let verifier: String
        let serviceUrl: String
        let credential: String?
    }

    // ------------------------- ciclo de vida -------------------------
    func applicationDidFinishLaunching(_ notification: Notification) {
        credential = keychainRead()
        _ = motorAvisos
        buildStatusItem()
        buildMenu()
        instalarAtajosLocales()
        updateMenu()
        if cfg.migrada { cfg.save() }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(despertar(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NotificationPresenter.shared.prepare()
        }
        NotificationPresenter.shared.onOpenSettings = { [weak self] in
            self?.mostrarAjustes(nil)
        }
        NotificationPresenter.shared.onSilenciar = { [weak self] id in
            guard let self = self else { return }
            self.motorAvisos.silenciarRegla(
                id, hasta: Date().timeIntervalSince1970 + 3600)
            self.settingsWindow?.refrescarAvisos()
        }
        NotificationPresenter.shared.onAbrir = { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
        #if !APPSTORE
        scheduleUpdateChecks()
        #endif
        alertTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            self?.comprobarAvisosPeriodicos()
        }

        if modoLocalidad {
            refresh()
            reintentarArranque()
        } else if isConnected {
            refresh()
            reintentarArranque()
        } else if tieneConfiguracion {
            // Tras un reinicio el Llavero puede tardar en estar disponible o
            // la red aún no está lista: reintentamos sin esperar al polling.
            reintentarArranque()
        } else if cfg.modo == "localidad" && cfg.localidad == nil {
            // Configuración de localidad incompleta: volvemos a preguntar.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.mostrarOnboarding(localidad: true)
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.mostrarOnboarding(localidad: false)
            }
        }
        startPolling()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if credential == nil {
            credential = keychainRead()
        }
        guard activo else { return }
        if datos == nil || lastError != nil {
            refresh()
        } else if let ultimo = lastSuccess,
                  Date().timeIntervalSince(ultimo) > 120 {
            refresh()
        }
    }

    // La app arranca con el Mac. El primer intento puede fallar porque el
    // Llavero esté bloqueado o la red todavía no exista; se reintenta durante
    // un par de minutos y se para en cuanto llega el primer dato.
    private var tieneConfiguracion: Bool {
        !cfg.serviceUrl.isEmpty && !cfg.endpoint.isEmpty
    }

    private func reintentarArranque() {
        arranqueTimer?.invalidate()
        arranqueIntentos = 0
        arranqueTimer = Timer.scheduledTimer(
            withTimeInterval: 10,
            repeats: true
        ) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            self.arranqueIntentos += 1
            if self.credential == nil {
                self.credential = keychainRead()
            }
            if self.modoLocalidad || self.isConnected {
                self.refresh()
            }
            if self.datos != nil || self.arranqueIntentos >= 12 {
                timer.invalidate()
                self.arranqueTimer = nil
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "netatmofree" {
            handleCallback(url)
        }
    }

    // ------------------------- barra y menu -------------------------
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.title = "--"
        updateStatusIcon()
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(noop(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    private func buildMenu() {
        itemsBarra.removeAll()
        itemsModulosExt.removeAll()
        itemsModulosInt.removeAll()
        itemsModulosOtras.removeAll()

        let menu = NSMenu()
        menu.delegate = self

        itCuenta = NSMenuItem(
            title: L("Cuenta: no conectada"),
            action: #selector(noop(_:)),
            keyEquivalent: ""
        )
        itCuenta.target = self
        itConectar = NSMenuItem(
            title: L("Conectar cuenta Netatmo…"),
            action: #selector(conectar(_:)),
            keyEquivalent: ""
        )
        itConectar.target = self
        itCambiarLocalidad = NSMenuItem(
            title: L("Cambiar localidad…"),
            action: #selector(cambiarLocalidad(_:)),
            keyEquivalent: ""
        )
        itCambiarLocalidad.target = self
        itCambiarLocalidad.isHidden = true
        itElegirEstaciones = NSMenuItem(
            title: L("Elegir estaciones…"),
            action: #selector(elegirEstaciones(_:)),
            keyEquivalent: ""
        )
        itElegirEstaciones.target = self
        itElegirEstaciones.isHidden = true
        itUsarLocalidad = NSMenuItem(
            title: L("Usar el tiempo de mi localidad…"),
            action: #selector(usarLocalidad(_:)),
            keyEquivalent: ""
        )
        itUsarLocalidad.target = self
        itConectarCuenta = NSMenuItem(
            title: L("Conectar mi estación de Netatmo…"),
            action: #selector(conectarCuenta(_:)),
            keyEquivalent: ""
        )
        itConectarCuenta.target = self
        itAvisoPendiente = infoItem("")
        itAvisoPendiente.isHidden = true

        itExterior = infoItem(L("Exterior: --"))
        itExtMinMax = infoItem(L("Min/Max hoy: --"))
        itInterior = infoItem(L("Interior: --"))
        itIntExtra = infoItem(L("CO₂: --"))
        itTermo = infoItem(L("Termostato: --"))
        itCaldera = infoItem(L("Caldera: --"))
        itCalderaHoy = infoItem(L("Caldera hoy: --"))

        itActualizar = NSMenuItem(
            title: L("Actualizar ahora"),
            action: #selector(actualizarAhora(_:)),
            keyEquivalent: "r"
        )
        itActualizar.target = self
        itAvisos = NSMenuItem(title: L("Avisos"), action: nil, keyEquivalent: "")

        itGrafica = NSMenuItem(
            title: L("Gráfica 24 h…"),
            action: #selector(abrirGrafica(_:)),
            keyEquivalent: ""
        )
        itGrafica.target = self
        #if !APPSTORE
        itNuevaVersion = NSMenuItem(
            title: L("Actualizar…"),
            action: #selector(instalarDisponible(_:)),
            keyEquivalent: ""
        )
        itNuevaVersion.target = self
        itNuevaVersion.isHidden = true
        #endif
        itCambiarServicio = NSMenuItem(
            title: L("Cambiar servicio…"),
            action: #selector(cambiarServicio(_:)),
            keyEquivalent: ""
        )
        itCambiarServicio.target = self
        itRestablecer = NSMenuItem(
            title: L("Restablecer conexión…"),
            action: #selector(restablecer(_:)),
            keyEquivalent: ""
        )
        itRestablecer.target = self

        let menuBarra = NSMenuItem(title: L("Ver en barra"), action: nil, keyEquivalent: "")
        let subBarra = NSMenu()
        for (clave, nombre) in VALORES_BARRA {
            let item = NSMenuItem(
                title: nombre,
                action: #selector(elegirBarra(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = clave
            itemsBarra.append(item)
            subBarra.addItem(item)
        }
        menuBarra.submenu = subBarra

        let itWeb = NSMenuItem(
            title: L("Abrir Netatmo web"),
            action: #selector(abrirWeb(_:)),
            keyEquivalent: ""
        )
        itWeb.target = self
        let itSalir = NSMenuItem(
            title: L("Salir"),
            action: #selector(salir(_:)),
            keyEquivalent: "q"
        )
        itSalir.target = self

        menu.addItem(itCuenta)
        menu.addItem(itConectar)
        menu.addItem(itCambiarLocalidad)
        menu.addItem(itElegirEstaciones)
        menu.addItem(itAvisoPendiente)
        menu.addItem(.separator())
        // Exterior: lecturas propias de exterior, viento y lluvia.
        menu.addItem(itExterior)
        menu.addItem(itExtMinMax)
        for _ in 0..<4 {
            let item = infoItem("")
            item.isHidden = true
            itemsModulosExt.append(item)
            menu.addItem(item)
        }
        sepExteriorInterior = .separator()
        menu.addItem(sepExteriorInterior)
        // Interior: estación principal y módulos interiores adicionales.
        menu.addItem(itInterior)
        menu.addItem(itIntExtra)
        for _ in 0..<4 {
            let item = infoItem("")
            item.isHidden = true
            itemsModulosInt.append(item)
            menu.addItem(item)
        }
        sepInteriorCaldera = .separator()
        menu.addItem(sepInteriorCaldera)
        // Termostato y caldera.
        menu.addItem(itTermo)
        menu.addItem(itCaldera)
        menu.addItem(itCalderaHoy)
        sepEstaciones = .separator()
        menu.addItem(sepEstaciones)
        // Estaciones que no son la principal: pública favorita u otras
        // estaciones de la misma cuenta. Siempre marcadas como externas.
        itEstacionCercana = NSMenuItem(
            title: L("Buscar estación cercana…"),
            action: #selector(mostrarEstacionCercana(_:)),
            keyEquivalent: ""
        )
        itEstacionCercana.target = self
        itEstacionCercana.isHidden = true
        menu.addItem(itEstacionCercana)
        itFuenteLocalidad = infoItem(L("Estación: --"))
        itFuenteLocalidad.isHidden = true
        menu.addItem(itFuenteLocalidad)
        itFavViento = infoItem(L("Viento (estación cercana): --"))
        itFavViento.isHidden = true
        itFavLluvia = infoItem(L("Lluvia (estación cercana): --"))
        itFavLluvia.isHidden = true
        menu.addItem(itFavViento)
        menu.addItem(itFavLluvia)
        for _ in 0..<4 {
            let item = infoItem("")
            item.isHidden = true
            itemsModulosOtras.append(item)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(itAvisos)
        menu.addItem(itGrafica)
        menu.addItem(itActualizar)
        #if !APPSTORE
        menu.addItem(itNuevaVersion)
        #endif
        menu.addItem(menuBarra)

        itAvanzado = NSMenuItem(title: L("Avanzado"), action: nil, keyEquivalent: "")
        let subAvanzado = NSMenu()
        subAvanzado.addItem(itUsarLocalidad)
        subAvanzado.addItem(itConectarCuenta)
        subAvanzado.addItem(itCambiarServicio)
        subAvanzado.addItem(itRestablecer)
        let itDiagnostico = NSMenuItem(
            title: L("Copiar diagnóstico…"),
            action: #selector(copiarDiagnosticoObjc(_:)),
            keyEquivalent: ""
        )
        itDiagnostico.target = self
        subAvanzado.addItem(.separator())
        subAvanzado.addItem(itDiagnostico)
        itAvanzado.submenu = subAvanzado
        itAvanzado.isHidden = true
        menu.addItem(itAvanzado)

        itAjustes = NSMenuItem(
            title: L("Ajustes…"),
            action: #selector(mostrarAjustes(_:)),
            keyEquivalent: ","
        )
        itAjustes.target = self

        menu.addItem(.separator())
        menu.addItem(itWeb)
        menu.addItem(itAjustes)
        menu.addItem(itSalir)

        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        itAvanzado.isHidden = !NSEvent.modifierFlags.contains(.option)
        reconstruirSubmenuAvisos()
        updateMenu()
    }

    private var isConnected: Bool {
        !cfg.serviceUrl.isEmpty && !cfg.endpoint.isEmpty && credential != nil
    }

    // Modo sin cuenta: hay una localidad elegida y no se usa OAuth.
    private var modoLocalidad: Bool {
        cfg.modo == "localidad" && cfg.localidad != nil
    }

    private var activo: Bool { modoLocalidad || isConnected }

    private var servicioBase: String {
        cfg.serviceUrl.isEmpty ? DEFAULT_SERVICE_URL : cfg.serviceUrl
    }

    private func updateMenu() {
        // El sistema puede entregar un callback antes de que exista el menú.
        guard statusItem != nil else { return }
        if modoLocalidad {
            actualizarMenuLocalidad()
        } else {
            actualizarMenuCuenta()
        }
        finalizarMenu()
    }

    // ------------------------- menú: cuenta Netatmo -------------------------
    private func actualizarMenuCuenta() {
        itCambiarLocalidad.isHidden = true
        if itCambiarLocalidad.submenu != nil {
            itCambiarLocalidad.submenu = nil
            itCambiarLocalidad.action = #selector(cambiarLocalidad(_:))
            itCambiarLocalidad.title = L("Cambiar localidad…")
        }
        itElegirEstaciones.isHidden = true
        itUsarLocalidad.isHidden = false
        itConectarCuenta.isHidden = true
        itFuenteLocalidad.isHidden = true
        sepExteriorInterior.isHidden = false
        sepInteriorCaldera.isHidden = false
        sepEstaciones.isHidden = false
        itEstacionCercana.isHidden = false

        let connected = isConnected
        let edad = ultimoDatoTexto()
        if pending != nil {
            itCuenta.title = connecting
                ? L("Conectando con el servicio…")
                : L("Esperando autorización en el navegador…")
            itCuenta.action = #selector(noop(_:))
            itCuenta.toolTip = nil
        } else if connected && needsReconnect {
            var titulo = L("⚠︎ Cuenta: reconectar…")
            if let edad = edad { titulo += L(" · Último dato %@", edad.texto) }
            itCuenta.title = titulo
            itCuenta.action = #selector(reconectar(_:))
            itCuenta.toolTip = tooltipUltimoDato()
        } else if connected {
            var titulo = L("Cuenta: conectada")
            if let edad = edad {
                if edad.viejo { titulo = "⚠︎ " + titulo }
                titulo += L(" · Último dato %@", edad.texto)
            } else {
                titulo += L(" · sin datos todavía")
            }
            itCuenta.title = titulo
            itCuenta.action = #selector(noop(_:))
            itCuenta.toolTip = tooltipUltimoDato()
        } else {
            if cfg.modo.isEmpty && !tieneConfiguracion {
                itCuenta.title = L("Configurar Mirlo Weather…")
                itCuenta.action = #selector(configurar(_:))
            } else {
                itCuenta.title = L("Cuenta: no conectada")
                itCuenta.action = #selector(noop(_:))
            }
            itCuenta.toolTip = nil
        }

        itConectar.isHidden = connected
        itRestablecer.isHidden = cfg.serviceUrl.isEmpty && credential == nil
        itActualizar.isEnabled = connected && !refreshing
        itActualizar.title = refreshing ? L("Actualizando…") : L("Actualizar ahora")
        #if !APPSTORE
        itNuevaVersion.isHidden = availableRelease == nil
        if let release = availableRelease {
            itNuevaVersion.title = L("Actualizar a la versión %@…", release.version)
        }
        #endif

        if let datos = datos {
            let ext = datos["exterior"] as? [String: Any]
            let inte = datos["interior"] as? [String: Any]
            let termo = datos["termostato"] as? [String: Any]

            let extTemp = fmtTemp(ext?["temperatura"])
            let extHum = fmtPct(ext?["humedad"])
            itExterior.title = L("Exterior: %@ · %@", extTemp, extHum)
                + tendenciaMenu("exterior.temperatura", actual: num(ext?["temperatura"]))
            if let min = num(ext?["min"]), let max = num(ext?["max"]) {
                let horas = [ext?["min_hora"], ext?["max_hora"]]
                    .compactMap { $0 as? String }
                    .joined(separator: " / ")
                let sufijo = horas.isEmpty ? "" : " (\(horas))"
                itExtMinMax.title = L("Min/Max hoy: %@ / %@%@", fmtTemp(min), fmtTemp(max), sufijo)
            } else {
                itExtMinMax.title = L("Min/Max hoy: --")
            }

            itInterior.title = L("Interior: %@ · %@", fmtTemp(inte?["temperatura"]), fmtPct(inte?["humedad"]))
                + tendenciaMenu("interior.temperatura", actual: num(inte?["temperatura"]))
            var extras: [String] = []
            if let co2 = num(inte?["co2"]) { extras.append("CO₂ \(fmtNum(co2, 0)) ppm") }
            if let ruido = num(inte?["ruido"]) { extras.append(L("Ruido %@ dB", fmtNum(ruido, 0))) }
            if let presion = num(inte?["presion"]) { extras.append(L("Presión %@ mbar", fmtNum(presion, 0))) }
            itIntExtra.title = extras.isEmpty ? L("CO₂: --") : extras.joined(separator: " · ")

            renderModulos(
                datos["modulos"] as? [[String: Any]] ?? [],
                tieneExteriorHeredado: datos["exterior"] != nil
            )
            actualizarEstacionCercana(datos)

            if let temp = termo?["temperatura"], let consigna = termo?["consigna"] {
                let modo = termo?["modo"] as? String ?? "--"
                itTermo.title = L("Termostato: %@ · consigna %@ · %@", fmtTemp(temp), fmtTemp(consigna), modo)
            } else {
                itTermo.title = L("Termostato: --")
            }
            if let calderaOn = termo?["caldera"] as? Bool {
                itCaldera.title = calderaOn ? L("Caldera: encendida") : L("Caldera: apagada")
            } else {
                itCaldera.title = L("Caldera: --")
            }
            itCaldera.isHidden = sinCaldera
            itCalderaHoy.isHidden = sinCaldera
            if let remota = caldera {
                itCalderaHoy.title = L("Caldera hoy: %@ · ayer: %@ · este mes: %@", fmtMinutos(remota.hoyMin), fmtMinutos(remota.ayerMin), fmtMinutos(remota.mesMin))
                itCalderaHoy.toolTip = remota.actualizado.map {
                    L("Histórico oficial de Netatmo · actualizado %@", $0)
                }
            } else {
                itCalderaHoy.title = L("Caldera hoy: --")
                itCalderaHoy.toolTip = calderaError
            }
        } else {
            itExterior.title = L("Exterior: --")
            itExtMinMax.title = L("Min/Max hoy: --")
            itInterior.title = L("Interior: --")
            itIntExtra.title = L("CO₂: --")
            renderModulos([], tieneExteriorHeredado: false)
            actualizarEstacionCercana(nil)
            itTermo.title = L("Termostato: --")
            itCaldera.title = L("Caldera: --")
            itCalderaHoy.title = L("Caldera hoy: --")
        }
    }

    // ------------------------- menú: solo localidad -------------------------
    private func actualizarMenuLocalidad() {
        let localidad = cfg.localidad
        let edad = ultimoDatoTexto()
        var titulo = L("Localidad: %@", localidad?.nombre ?? L("sin elegir"))
        if let edad = edad {
            if edad.viejo { titulo = "⚠︎ " + titulo }
            titulo += L(" · Último dato %@", edad.texto)
        } else if refreshing {
            titulo += L(" · actualizando…")
        } else {
            titulo += L(" · sin datos todavía")
        }
        itCuenta.title = titulo
        itCuenta.action = #selector(cambiarLocalidad(_:))
        itCuenta.toolTip = localidad.map {
            L("Estaciones públicas de Netatmo en %d km a la redonda", $0.radioKm)
        }

        itConectar.isHidden = true
        itCambiarLocalidad.isHidden = false
        itElegirEstaciones.isHidden = localidad == nil
        itUsarLocalidad.isHidden = true
        itConectarCuenta.isHidden = false
        itRestablecer.isHidden = true
        itActualizar.isEnabled = !refreshing
        itActualizar.title = refreshing ? L("Actualizando…") : L("Actualizar ahora")
        #if !APPSTORE
        itNuevaVersion.isHidden = availableRelease == nil
        if let release = availableRelease {
            itNuevaVersion.title = L("Actualizar a la versión %@…", release.version)
        }
        #endif

        // El modo localidad no tiene interior, termostato ni caldera.
        itInterior.isHidden = true
        itIntExtra.isHidden = true
        itTermo.isHidden = true
        itCaldera.isHidden = true
        itCalderaHoy.isHidden = true
        sepExteriorInterior.isHidden = true
        sepInteriorCaldera.isHidden = true
        sepEstaciones.isHidden = false
        itEstacionCercana.isHidden = true
        for item in itemsModulosExt { item.isHidden = true }
        for item in itemsModulosInt { item.isHidden = true }
        for item in itemsModulosOtras { item.isHidden = true }

        let comp = composicionLocalidad
        if let datos = datos {
            let ext = datos["exterior"] as? [String: Any]
            itExterior.title = L("Exterior: %@ · %@", fmtTemp(ext?["temperatura"]), fmtPct(ext?["humedad"]))
                + tendenciaMenu("exterior.temperatura", actual: num(ext?["temperatura"]))
            if let presion = num(ext?["presion"]) {
                itExtMinMax.title = L("Presión: %@ mbar", fmtNum(presion, 0))
            } else {
                itExtMinMax.title = L("Presión: --")
            }
        } else {
            itExterior.title = L("Exterior: --")
            itExtMinMax.title = L("Presión: --")
        }

        if let viento = comp?.viento, let datosViento = viento["viento"] as? [String: Any] {
            let direccion = flechaViento(num(datosViento["direccion"]))
            var texto = fmtNum(num(datosViento["velocidad"]), 0)
                + (direccion.isEmpty ? "" : " \(direccion)")
            if let racha = num(datosViento["racha"]) {
                texto += L(" · racha %@", fmtNum(racha, 0))
            }
            itFavViento.title = L("Viento: %@", texto)
            let origen = rumbo(num(datosViento["direccion"]))
            let nota = origen.isEmpty
                ? ""
                : L(" · viento del %@; la flecha indica hacia donde sopla", origen)
            itFavViento.toolTip = L("Estación %@", nombreEstacion(viento)) + nota
            itFavViento.isHidden = false
        } else {
            itFavViento.title = L("Viento: --")
            itFavViento.toolTip = L("Ninguna estación cercana publica viento.")
            itFavViento.isHidden = false
        }

        if let lluvia = comp?.lluvia, let datosLluvia = lluvia["lluvia"] as? [String: Any] {
            let actual = num(datosLluvia["actual"]) ?? num(datosLluvia["hace_1h"])
            let decimales = num(datosLluvia["actual"]) != nil ? 2 : 1
            var texto = fmtNum(actual, decimales) + " mm"
            if let dia = num(datosLluvia["hace_24h"]) {
                texto += " · " + fmtNum(dia, 1) + " mm 24 h"
            }
            itFavLluvia.title = L("Lluvia: %@", texto)
            itFavLluvia.toolTip = L("Estación %@", nombreEstacion(lluvia))
            itFavLluvia.isHidden = false
        } else {
            itFavLluvia.title = L("Lluvia: --")
            itFavLluvia.toolTip = L("Ninguna estación cercana publica lluvia.")
            itFavLluvia.isHidden = false
        }

        if let principal = comp?.principal {
            let distancia = distanciaEstacion(principal).map {
                fmtNum($0, 1) + " km"
            }
            itFuenteLocalidad.title = L("Estación: %@", nombreEstacion(principal))
                + (distancia.map { " · \($0)" } ?? "")
            itFuenteLocalidad.toolTip = L(
                "Datos públicos de Netatmo. Esta estación aporta temperatura, humedad y presión; el viento y la lluvia pueden venir de otras cercanas."
            )
            itFuenteLocalidad.isHidden = false
        } else {
            itFuenteLocalidad.title = avisoLocalidad ?? L("Estación: sin datos")
            itFuenteLocalidad.toolTip = avisoLocalidad
            itFuenteLocalidad.isHidden = false
        }

        reconstruirSubmenuLocalidades()
    }

    private func finalizarMenu() {
        // En modo localidad no existen interior, termostato ni min/max diario.
        let clavesLocalidad: Set<String> = [
            "exterior", "humedad_ext", "viento", "lluvia", "ninguno",
        ]
        var barraCambiada = false
        for item in itemsBarra {
            let clave = item.representedObject as? String ?? ""
            if modoLocalidad && !clavesLocalidad.contains(clave) {
                item.isHidden = true
            } else {
                item.isHidden = false
            }
            item.state = clave == cfg.barValue ? .on : .off
        }
        if modoLocalidad && !clavesLocalidad.contains(cfg.barValue) {
            cfg.barValue = "exterior"
            cfg.save()
            barraCambiada = true
        }
        if barraCambiada {
            for item in itemsBarra {
                let clave = item.representedObject as? String ?? ""
                item.state = clave == cfg.barValue ? .on : .off
            }
        }

        aplicarColorDestacado()
        // La ventana de la gráfica se actualiza sola mientras está abierta.
        if ventanaGrafica?.isVisible == true { actualizarGrafica() }
        // La sección Estaciones se mantiene al día si Ajustes está abierto.
        if settingsWindow?.isVisible == true {
            settingsWindow?.actualizarEstaciones(resumenEstacionesAjustes())
        }
        updateBarTitle()
    }


    // Edad del último dato según la hora que declara el servicio.
    private func ultimoDatoTexto() -> (texto: String, viejo: Bool)? {
        var referencia = datos.flatMap {
            fechaDelServicio($0["actualizado"] as? String)
        }
        if referencia == nil { referencia = lastSuccess }
        guard let referencia = referencia else { return nil }
        let segundos = max(
            0,
            Int(Date().timeIntervalSince1970 - referencia.timeIntervalSince1970)
        )
        let minutos = segundos / 60
        let texto: String
        if minutos < 1 {
            texto = L("hace menos de 1 min")
        } else if minutos == 1 {
            texto = L("hace 1 min")
        } else {
            texto = L("hace %d min", minutos)
        }
        return (texto, Double(segundos) > STALE_SECONDS)
    }

    private func tooltipUltimoDato() -> String? {
        guard let actualizado = datos?["actualizado"] as? String else {
            return nil
        }
        let origen = modoLocalidad ? L("la estación pública") : L("el servicio")
        return L("Último dato según %@: %@", origen, actualizado)
    }

    // Resalta con un bloque de color solo los grupos marcados en Ajustes.
    // El texto cambia a blanco o negro según el brillo del fondo.
    private func aplicarColorDestacado() {
        var pares: [(NSMenuItem, String)] = []
        pares.append((itExterior, "exterior"))
        pares.append((itExtMinMax, "exterior"))
        pares.append((itInterior, "interior"))
        pares.append((itIntExtra, "interior"))
        pares.append((itTermo, "termostato"))
        pares.append((itCaldera, "caldera"))
        pares.append((itCalderaHoy, "caldera"))
        pares.append((itFavViento, "estacion"))
        pares.append((itFavLluvia, "estacion"))
        pares.append((itFuenteLocalidad, "estacion"))
        for item in itemsModulosExt {
            pares.append((item, item.representedObject as? String ?? "exterior"))
        }
        for item in itemsModulosInt {
            pares.append((item, "interior"))
        }
        for item in itemsModulosOtras {
            pares.append((item, "otras"))
        }

        // Quitar el resaltado anterior: las filas vuelven a ser ítems
        // normales del menú y se descarta el estilo del texto.
        for item in (statusItem.menu?.items ?? []) {
            if item.view is FilaResaltada { item.view = nil }
            item.attributedTitle = nil
        }

        guard cfg.highlight,
              let color = NSColor.desdeHex(cfg.highlightColor) else { return }

        let seleccion = Set(cfg.highlightItems)
        // Color del texto: automático (el que más contraste tenga) o el que
        // haya elegido el usuario en Ajustes.
        let textoColor: NSColor
        switch cfg.highlightTextColor {
        case "blanco": textoColor = .white
        case "negro": textoColor = NSColor.textoOscuroResaltado
        default: textoColor = color.textoContraste
        }

        // Ancho real del menú según AppKit con los títulos ya actualizados.
        // La vista ocupa la fila entera, de borde a borde. El alto coincide con
        // la fila estándar del menú (24 pt), el mismo del resaltado del ratón.
        let altoFila: CGFloat = 24
        let ancho = max(120, statusItem.menu?.size.width ?? 240)

        for (item, clave) in pares {
            guard seleccion.contains(clave),
                  !item.isHidden, !item.title.isEmpty else { continue }
            let fila = FilaResaltada(
                frame: NSRect(x: 0, y: 0, width: ancho, height: altoFila)
            )
            fila.texto = item.title
            fila.colorFondo = color
            fila.colorTexto = textoColor
            item.view = fila
        }
    }

    private func updateStatusIcon() {
        statusItem.button?.imagePosition = .imageLeading
        if avisoBarraHasta != nil {
            statusItem.button?.image = simbolo("bell.badge", "bell")
            return
        }
        if needsReconnect {
            statusItem.button?.image = simbolo("exclamationmark.triangle", "thermometer.medium")
        } else if !cfg.polling && datos == nil {
            statusItem.button?.image = simbolo("pause.circle", "thermometer.medium")
        } else {
            statusItem.button?.image = iconoBarra()
        }
        statusItem.button?.toolTip = cfg.polling ? nil : L("Consultas pausadas")
    }

    // Icono segun lo que se muestra en la barra (SF Symbols, modo plantilla).
    private func iconoBarra() -> NSImage? {
        switch cfg.barValue {
        case "exterior", "minmax":
            let ext = datos?["exterior"] as? [String: Any]
            switch ext?["es_de_dia"] as? Bool {
            case true: return simbolo("sun.max", "thermometer.medium")
            case false: return simbolo("moon.stars", "moon")
            case nil: return simbolo("thermometer.medium", "thermometer")
            }
        case "interior":
            return simbolo("house", "thermometer.medium")
        case "humedad_ext", "humedad_int":
            return simbolo("humidity", "drop")
        case "co2":
            return simbolo("aqi.medium", "wind")
        case "ruido":
            return simbolo("waveform", "speaker.wave.2")
        case "termostato":
            return simbolo("thermometer.medium", "thermometer")
        case "viento":
            return simbolo("wind", "thermometer")
        case "lluvia":
            return simbolo("cloud.rain", "cloud")
        default:
            return simbolo("thermometer.medium", "thermometer")
        }
    }

    // Tendencia de temperatura de los últimos 30 min. Sin historial suficiente
    // (o con un cambio menor de 0,1°) devuelve una cadena vacía: nunca se
    // inventa una flecha.
    private func tendenciaMenu(_ campo: String, actual: Double?) -> String {
        guard let actual = actual,
              let cambio = motorAvisos.tendencia(campo, actual: actual, ventanaMin: 30),
              abs(cambio) >= 0.1 else { return "" }
        let flecha = cambio > 0 ? "↑" : "↓"
        return " \(flecha)\(fmtNum(abs(cambio), 1))° \(L("en 30 min"))"
    }

    private func tendenciaBarra(_ campo: String, actual: Double?) -> String {
        guard let actual = actual,
              let cambio = motorAvisos.tendencia(campo, actual: actual, ventanaMin: 30),
              abs(cambio) >= 0.1 else { return "" }
        let flecha = cambio > 0 ? "↑" : "↓"
        return " \(flecha)\(fmtNum(abs(cambio), 1))°"
    }

    private func updateBarTitle() {
        updateStatusIcon()
        if avisoBarraHasta != nil {
            statusItem.button?.title = L("Aviso")
            statusItem.button?.toolTip = avisoPendiente
            return
        }
        actualizarIconoCaldera()
        statusItem.button?.toolTip = nil
        guard activo, let datos = datos else {
            statusItem.button?.title = "--"
            return
        }
        let ext = datos["exterior"] as? [String: Any]
        let inte = datos["interior"] as? [String: Any]
        let termo = datos["termostato"] as? [String: Any]
        switch cfg.barValue {
        case "interior":
            statusItem.button?.title = fmtTemp(inte?["temperatura"])
        case "interior_tendencia":
            statusItem.button?.title = fmtTemp(inte?["temperatura"])
                + tendenciaBarra("interior.temperatura",
                                 actual: num(inte?["temperatura"]))
            statusItem.button?.toolTip = L("Tendencia de los últimos 30 minutos.")
        case "minmax":
            if let min = num(ext?["min"]), let max = num(ext?["max"]) {
                statusItem.button?.title = "\(fmtTemp(min))/\(fmtTemp(max))"
            } else {
                statusItem.button?.title = "--"
            }
        case "humedad_ext":
            statusItem.button?.title = num(ext?["humedad"]) != nil
                ? fmtPct(ext?["humedad"]) : "--"
        case "humedad_int":
            statusItem.button?.title = num(inte?["humedad"]) != nil
                ? fmtPct(inte?["humedad"]) : "--"
        case "co2":
            if let co2 = num(inte?["co2"]) {
                statusItem.button?.title = fmtNum(co2, 0) + " ppm"
            } else {
                statusItem.button?.title = "--"
            }
        case "ruido":
            if let ruido = num(inte?["ruido"]) {
                statusItem.button?.title = fmtNum(ruido, 0) + " dB"
            } else {
                statusItem.button?.title = "--"
            }
        case "termostato":
            if let temp = num(termo?["temperatura"]), let consigna = num(termo?["consigna"]) {
                statusItem.button?.title = "\(fmtTemp(temp)) → \(fmtTemp(consigna))"
            } else {
                statusItem.button?.title = "--"
            }
        case "viento":
            if let modulo = primerModulo("viento", en: datos) {
                let datosMod = modulo["datos"] as? [String: Any]
                let dir = flechaViento(num(datosMod?["direccion"]))
                var texto = fmtNum(num(datosMod?["viento"]), 0)
                    + (dir.isEmpty ? "" : " \(dir)")
                if let racha = num(datosMod?["racha"]) {
                    texto += L(" · racha %@", fmtNum(racha, 0))
                }
                statusItem.button?.title = texto
                let origen = rumbo(num(datosMod?["direccion"]))
                if !origen.isEmpty {
                    statusItem.button?.toolTip =
                        L("Viento del %@; la flecha indica hacia donde sopla.", origen)
                }
            } else if let viento = vientoPublico() {
                statusItem.button?.title = viento.valor
                if cfg.polling {
                    statusItem.button?.toolTip = viento.origen
                }
            } else {
                statusItem.button?.title = "--"
            }
        case "lluvia":
            if let modulo = primerModulo("lluvia", en: datos) {
                let datosMod = modulo["datos"] as? [String: Any]
                let actual = num(datosMod?["lluvia"]) ?? num(datosMod?["lluvia_1h"])
                let dec = num(datosMod?["lluvia"]) != nil ? 2 : 1
                var texto = fmtNum(actual, dec) + " mm"
                if let dia = num(datosMod?["lluvia_24h"]) {
                    texto += " · " + fmtNum(dia, 1) + " mm 24 h"
                }
                statusItem.button?.title = texto
            } else if let lluvia = lluviaPublica() {
                statusItem.button?.title = lluvia.valor
                if cfg.polling {
                    statusItem.button?.toolTip = lluvia.origen
                }
            } else {
                statusItem.button?.title = "--"
            }
        case "ninguno":
            statusItem.button?.title = ""
        default:
            statusItem.button?.title = fmtTemp(ext?["temperatura"])
        }
    }

    // Icono extra en la barra mientras la caldera esta encendida. Solo si el
    // dato es fresco y las consultas estan activas: si esta pausado o viejo,
    // mejor ocultar que afirmar algo que ya no sabemos.
    private func actualizarIconoCaldera() {
        let fresco = cfg.polling && lastError == nil && datos != nil
            && (lastSuccess.map { Date().timeIntervalSince($0) <= STALE_SECONDS } ?? false)
        let termo = datos?["termostato"] as? [String: Any]
        let visible = fresco && (termo?["caldera"] as? Bool) == true
        guard visible else {
            if let item = statusCaldera {
                NSStatusBar.system.removeStatusItem(item)
                statusCaldera = nil
            }
            return
        }
        if statusCaldera == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageLeading
            // El mismo menu que la barra principal: un solo sitio que mantener.
            item.menu = statusItem.menu
            statusCaldera = item
        }
        statusCaldera?.button?.image = simbolo("flame.fill", "flame")
        statusCaldera?.button?.title = ""
        statusCaldera?.button?.toolTip = L("Caldera encendida según Netatmo")
    }

    private func primerModulo(_ tipo: String, en datos: [String: Any]) -> [String: Any]? {
        let modulos = datos["modulos"] as? [[String: Any]] ?? []
        return modulos.first { ($0["tipo"] as? String) == tipo }
    }

    // Valores de la estación pública para la barra. Solo se usan cuando la
    // cuenta no tiene ese sensor; el tooltip deja claro de dónde vienen.
    private func vientoPublico() -> (valor: String, origen: String)? {
        guard let favorito = cfg.favorito, favorito.tieneViento,
              let viento = favoritoDatos?["viento"] as? [String: Any],
              let velocidad = num(viento["velocidad"]) else { return nil }
        let direccion = flechaViento(num(viento["direccion"]))
        var texto = fmtNum(velocidad, 0) + (direccion.isEmpty ? "" : " \(direccion)")
        if let racha = num(viento["racha"]) {
            texto += L(" · racha %@", fmtNum(racha, 0))
        }
        let origen = rumbo(num(viento["direccion"]))
        let nota = origen.isEmpty
            ? ""
            : L(" (viento del %@; la flecha indica hacia donde sopla)", origen)
        return (texto, L("Datos públicos de %@", favorito.etiqueta) + nota)
    }

    private func lluviaPublica() -> (valor: String, origen: String)? {
        guard let favorito = cfg.favorito, favorito.tieneLluvia,
              let lluvia = favoritoDatos?["lluvia"] as? [String: Any] else { return nil }
        let actual = num(lluvia["actual"]) ?? num(lluvia["hace_1h"])
        guard actual != nil || num(lluvia["hace_24h"]) != nil else { return nil }
        var texto = fmtNum(actual, 2) + " mm"
        if let dia = num(lluvia["hace_24h"]) {
            texto += " · " + fmtNum(dia, 1) + " mm 24 h"
        }
        return (texto, L("Datos públicos de %@", favorito.etiqueta))
    }

    // Sustituye las lecturas principales (interior y exterior) por las de la
    // estación elegida en Ajustes. El termostato y la caldera no dependen de
    // esta selección.
    private func datosConEstacionPrincipal(_ json: [String: Any]) -> [String: Any] {
        guard cfg.modo == "cuenta" else { return json }
        return aplicarEstacionPrincipal(json, estacion: cfg.estacionPrincipal)
    }

    private func renderModulos(
        _ modulos: [[String: Any]],
        tieneExteriorHeredado: Bool
    ) {
        var exterior: [[String: Any]] = []
        var interior: [[String: Any]] = []
        var otras: [[String: Any]] = []

        var interiorSaltado = false
        var exteriorSaltado = false
        // La estación elegida manda; si ya no existe, se usa la de Netatmo.
        let nombres = Set(modulos.compactMap { $0["estacion"] as? String })
        let elegida = nombres.contains(cfg.estacionPrincipal)
            ? cfg.estacionPrincipal
            : ""
        let estacionPrincipal = elegida.isEmpty
            ? (modulos.first { ($0["principal"] as? Bool) == true }
                .flatMap { $0["estacion"] as? String } ?? "")
            : elegida
        let hayNombre = !estacionPrincipal.isEmpty

        for modulo in modulos {
            let esPrincipal = (modulo["principal"] as? Bool) == true
            let estacion = modulo["estacion"] as? String ?? ""
            let esDePrincipal = hayNombre ? estacion == estacionPrincipal : esPrincipal
            let esOtra = hayNombre ? !esDePrincipal : esPrincipal
            let tipo = modulo["tipo"] as? String ?? "otro"

            if esDePrincipal && tipo == "interior" && !interiorSaltado {
                // La estación principal ya se muestra como "Interior".
                interiorSaltado = true
                continue
            }
            if esDePrincipal && tipo == "exterior" && tieneExteriorHeredado
                && !exteriorSaltado {
                exteriorSaltado = true
                continue
            }
            if esOtra {
                otras.append(modulo)
            } else if tipo == "exterior" || tipo == "viento" || tipo == "lluvia" {
                exterior.append(modulo)
            } else {
                interior.append(modulo)
            }
        }

        renderGrupo(exterior, en: itemsModulosExt, prefijo: nil, clave: "exterior")
        renderGrupo(interior, en: itemsModulosInt, prefijo: nil, clave: "interior")
        renderGrupo(otras, en: itemsModulosOtras, prefijo: L("Estación "), clave: "otras")
    }

    private func renderGrupo(
        _ modulos: [[String: Any]],
        en items: [NSMenuItem],
        prefijo: String?,
        clave: String
    ) {
        var usados = 0
        for modulo in modulos {
            if usados >= items.count { break }
            let tipo = modulo["tipo"] as? String ?? "otro"
            let datosMod = modulo["datos"] as? [String: Any] ?? [:]
            let nombre = (modulo["nombre"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var etiqueta = nombre
            var partes: [String] = []
            switch tipo {
            case "viento":
                let direccion = flechaViento(num(datosMod["direccion"]))
                var velocidad = fmtNum(num(datosMod["viento"]), 0) + " km/h"
                if !direccion.isEmpty { velocidad += " " + direccion }
                partes.append(velocidad)
                if let racha = num(datosMod["racha"]) {
                    partes.append(L("racha %@ km/h", fmtNum(racha, 0)))
                }
                if etiqueta.isEmpty { etiqueta = L("Viento") }
            case "lluvia":
                if let actual = num(datosMod["lluvia"]) {
                    partes.append(L("%@ mm ahora", fmtNum(actual, 2)))
                }
                if let unaHora = num(datosMod["lluvia_1h"]) {
                    partes.append(fmtNum(unaHora, 1) + " mm 1 h")
                }
                if let dia = num(datosMod["lluvia_24h"]) {
                    partes.append(fmtNum(dia, 1) + " mm 24 h")
                }
                if partes.isEmpty { partes.append("--") }
                if etiqueta.isEmpty { etiqueta = L("Lluvia") }
            case "exterior":
                partes.append(fmtTemp(datosMod["temperatura"]))
                partes.append(fmtPct(datosMod["humedad"]))
                if etiqueta.isEmpty { etiqueta = L("Exterior") }
            default:
                partes.append(fmtTemp(datosMod["temperatura"]))
                partes.append(fmtPct(datosMod["humedad"]))
                if let co2 = num(datosMod["co2"]) {
                    partes.append("CO₂ " + fmtNum(co2, 0) + " ppm")
                }
                if etiqueta.isEmpty { etiqueta = L("Interior") }
            }
            if let bateria = num(modulo["bateria"]), bateria <= 20 {
                partes.append(L("batería %@ %%", fmtNum(bateria, 0)))
            }

            let item = items[usados]
            item.title = (prefijo ?? "") + etiqueta + ": "
                + partes.joined(separator: " · ")
            item.toolTip = prefijo == nil
                ? nil
                : L("Datos de otra estación de tu cuenta, no de la principal.")
            // La flecha de viento apunta hacia donde sopla; el rumbo de
            // procedencia queda en el tooltip para que no haya dudas.
            if tipo == "viento" {
                let origen = rumbo(num(datosMod["direccion"]))
                if !origen.isEmpty {
                    let base = item.toolTip.map { $0 + " " } ?? ""
                    item.toolTip = base
                        + L("Viento del %@; la flecha indica hacia donde sopla.", origen)
                }
            }
            // El bloque de resaltado depende del grupo; dentro de Exterior,
            // viento y lluvia se pueden marcar por separado.
            if clave == "exterior", tipo == "viento" || tipo == "lluvia" {
                item.representedObject = tipo
            } else {
                item.representedObject = clave
            }
            item.isHidden = false
            usados += 1
        }
        for indice in usados..<items.count {
            items[indice].title = ""
            items[indice].toolTip = nil
            items[indice].representedObject = nil
            items[indice].isHidden = true
        }
    }

    // ------------------------- estación cercana -------------------------
    // Si la cuenta no tiene anemómetro o pluviómetro, se ofrece una estación
    // pública de Netatmo cercana. El dato se etiqueta con su nombre: nunca se
    // hace pasar por una lectura propia.
    private func actualizarEstacionCercana(_ datos: [String: Any]?) {
        guard let datos = datos else {
            itEstacionCercana.isHidden = true
            itFavViento.isHidden = true
            itFavLluvia.isHidden = true
            actualizarSeparadorEstaciones()
            return
        }
        let modulos = datos["modulos"] as? [[String: Any]] ?? []
        func tieneModulo(_ tipo: String) -> Bool {
            modulos.contains { ($0["tipo"] as? String) == tipo }
        }
        let propioViento = tieneModulo("viento")
        let propioLluvia = tieneModulo("lluvia")
        let fav = cfg.favorito

        var faltan: [String] = []
        if !propioViento && !(fav?.tieneViento ?? false) { faltan.append("viento") }
        if !propioLluvia && !(fav?.tieneLluvia ?? false) { faltan.append("lluvia") }

        if let fav = fav {
            itEstacionCercana.isHidden = false
            itEstacionCercana.title = (faltan.isEmpty ? "" : "⚠︎ ")
                + L("Estación %@", fav.nombre)
            itEstacionCercana.toolTip =
                L("Cambiar o quitar %@. Datos públicos de Netatmo.", fav.etiqueta)
        } else if !propioViento || !propioLluvia {
            itEstacionCercana.isHidden = false
            let que: String
            if !propioViento && !propioLluvia {
                que = L("Sin viento ni lluvia")
            } else if !propioViento {
                que = L("Sin viento")
            } else {
                que = L("Sin lluvia")
            }
            itEstacionCercana.title = L("⚠︎ %@ · Buscar estación cercana…", que)
            itEstacionCercana.toolTip =
                L("Usa los datos públicos de una estación Netatmo cercana.")
        } else {
            itEstacionCercana.isHidden = true
        }

        let mostrarViento = !propioViento && (fav?.tieneViento ?? false)
        let mostrarLluvia = !propioLluvia && (fav?.tieneLluvia ?? false)
        itFavViento.isHidden = !mostrarViento
        itFavLluvia.isHidden = !mostrarLluvia
        let sufijo = sufijoDatoPublico()

        if mostrarViento {
            if let viento = favoritoDatos?["viento"] as? [String: Any],
               let velocidad = num(viento["velocidad"]) {
                var texto = L("Viento: %@ km/h", fmtNum(velocidad, 0))
                let direccion = flechaViento(num(viento["direccion"]))
                if !direccion.isEmpty { texto += " " + direccion }
                if let racha = num(viento["racha"]) {
                    texto += L(" · racha %@ km/h", fmtNum(racha, 0))
                }
                itFavViento.title = texto + sufijo
            } else {
                itFavViento.title = L("Viento: --")
            }
            itFavViento.toolTip = favoritoError
                ?? fav.map { L("Datos públicos de %@", $0.etiqueta) }
        }
        if mostrarLluvia {
            if let lluvia = favoritoDatos?["lluvia"] as? [String: Any] {
                var partes: [String] = []
                if let actual = num(lluvia["actual"]) {
                    partes.append(L("%@ mm ahora", fmtNum(actual, 2)))
                }
                if let unaHora = num(lluvia["hace_1h"]) {
                    partes.append(fmtNum(unaHora, 1) + " mm 1 h")
                }
                if let unDia = num(lluvia["hace_24h"]) {
                    partes.append(fmtNum(unDia, 1) + " mm 24 h")
                }
                itFavLluvia.title = L("Lluvia: %@", partes.isEmpty ? "--" : partes.joined(separator: " · "))
                    + sufijo
            } else {
                itFavLluvia.title = L("Lluvia: --")
            }
            itFavLluvia.toolTip = favoritoError
                ?? fav.map { L("Datos públicos de %@", $0.etiqueta) }
        }
        actualizarSeparadorEstaciones()
    }

    private func actualizarSeparadorEstaciones() {
        let hayOtras = itemsModulosOtras.contains { !$0.isHidden }
        let hayPublica = !itEstacionCercana.isHidden
            || !itFavViento.isHidden || !itFavLluvia.isHidden
        sepEstaciones.isHidden = !(hayOtras || hayPublica)
    }

    // " · hace 25 min" solo si el dato público lleva un rato sin renovarse.
    private func sufijoDatoPublico() -> String {
        guard let ts = num(favoritoDatos?["actualizado_ts"]) else { return "" }
        let minutos = Int(max(0, Date().timeIntervalSince1970 - ts) / 60)
        return minutos > 20 ? L(" · hace %d min", minutos) : ""
    }

    @objc private func mostrarEstacionCercana(_ sender: Any?) {
        if ventanaEstacion == nil {
            let ventana = BuscarEstacionWindow()
            ventana.onBuscar = { [weak self] radio, completion in
                self?.buscarEstaciones(radio: radio, completion: completion)
            }
            ventana.onElegir = { [weak self] favorito in
                self?.guardarFavorito(favorito)
            }
            ventana.onQuitar = { [weak self] in
                self?.quitarFavorito()
            }
            ventanaEstacion = ventana
        }
        ventanaEstacion?.mostrar(favorito: cfg.favorito)
    }

    private func buscarEstaciones(
        radio: Int,
        completion: @escaping (Result<[[String: Any]], Error>) -> Void
    ) {
        guard isConnected, let credential = credential else {
            completion(.failure(AppError(L("Conecta la cuenta de Netatmo primero."))))
            return
        }
        let url = cfg.serviceUrl + "/v1/nearby?radio_km=\(radio)"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try httpJSON(url, bearer: credential)
                guard (200..<300).contains(result.status),
                      let estaciones = result.json?["estaciones"] as? [[String: Any]] else {
                    throw AppError(self.describePublicFailure(result))
                }
                DispatchQueue.main.async { completion(.success(estaciones)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func guardarFavorito(_ favorito: FavoritoPublico) {
        cfg.favorito = favorito
        cfg.save()
        favoritoDatos = nil
        favoritoActualizado = nil
        favoritoError = nil
        ventanaEstacion?.cerrar()
        updateMenu()
        refrescarFavorito(forzar: true)
    }

    private func quitarFavorito() {
        cfg.favorito = nil
        cfg.save()
        favoritoDatos = nil
        favoritoActualizado = nil
        favoritoError = nil
        ventanaEstacion?.cerrar()
        updateMenu()
    }

    private func refrescarFavorito(forzar: Bool = false) {
        guard let favorito = cfg.favorito, isConnected,
              let credential = credential, !cargandoFavorito else { return }
        if !forzar, let ultimo = favoritoActualizado,
           Date().timeIntervalSince(ultimo) < 600 { return }

        cargandoFavorito = true
        var componentes = URLComponents(
            string: cfg.serviceUrl + "/v1/public/favorite"
        )
        componentes?.queryItems = [
            URLQueryItem(name: "id", value: favorito.id),
            URLQueryItem(name: "lat", value: String(favorito.lat)),
            URLQueryItem(name: "lon", value: String(favorito.lon)),
        ]
        guard let url = componentes?.url?.absoluteString else {
            cargandoFavorito = false
            return
        }

        DispatchQueue.global(qos: .utility).async {
            do {
                let result = try httpJSON(url, bearer: credential)
                DispatchQueue.main.async {
                    self.cargandoFavorito = false
                    if (200..<300).contains(result.status),
                       let estacion = result.json?["estacion"] as? [String: Any] {
                        self.favoritoDatos = estacion
                        self.favoritoActualizado = Date()
                        self.favoritoError = nil
                        self.evaluarAvisos()
                    } else {
                        self.favoritoError = self.describePublicFailure(result)
                    }
                    self.updateMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self.cargandoFavorito = false
                    self.favoritoError = error.localizedDescription
                    self.updateMenu()
                }
            }
        }
    }

    private func describePublicFailure(_ result: HTTPResult) -> String {
        switch result.json?["error"] as? String {
        case "public_station_not_found":
            return L("La estación ya no comparte sus datos.")
        case "public_station_without_data":
            return L("La estación no publica lluvia ni viento.")
        case "home_location_unavailable":
            return L("Tu estación no tiene ubicación; no se puede buscar cerca.")
        case "invalid_radius", "invalid_coordinates", "invalid_station_id":
            return L("La búsqueda no es válida.")
        case "authorization_expired":
            return L("Vuelve a conectar la cuenta de Netatmo.")
        case "home_stations_unavailable":
            return L("No se pudo leer la ubicación de tu estación.")
        default:
            return L("No se pudieron leer los datos públicos de Netatmo.")
        }
    }

    // ------------------------- modo solo localidad -------------------------
    private func buscarAlrededor(
        lat: Double,
        lon: Double,
        radio: Int,
        completion: @escaping (Result<[[String: Any]], Error>) -> Void
    ) {
        var componentes = URLComponents(string: servicioBase + "/v1/public/around")
        componentes?.queryItems = [
            URLQueryItem(name: "lat", value: String(lat)),
            URLQueryItem(name: "lon", value: String(lon)),
            URLQueryItem(name: "radio_km", value: String(radio)),
        ]
        guard let url = componentes?.url?.absoluteString else {
            completion(.failure(AppError(L("La dirección del servicio no es válida."))))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try httpJSON(url)
                guard (200..<300).contains(result.status),
                      let estaciones = result.json?["estaciones"] as? [[String: Any]] else {
                    throw AppError(self.describeAroundFailure(result))
                }
                DispatchQueue.main.async { completion(.success(estaciones)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func describeAroundFailure(_ result: HTTPResult) -> String {
        switch result.json?["error"] as? String {
        case "invalid_coordinates", "invalid_radius":
            return L("La localidad no es válida para buscar estaciones.")
        case "too_many_attempts":
            return L("Demasiadas búsquedas. Espera unos minutos y vuelve a probar.")
        case "public_service_unavailable":
            return L("El servicio de estaciones públicas no está disponible ahora.")
        case "authorization_expired":
            return L("El servicio necesita volver a autorizarse. Prueba más tarde.")
        case "temporarily_unavailable":
            return L("El servicio está ocupado. Se reintentará.")
        default:
            return (200..<300).contains(result.status)
                ? L("El servicio no devolvió estaciones.")
                : L("No se pudieron leer las estaciones públicas (HTTP %d).", result.status)
        }
    }

    private func refrescarLocalidad(manual: Bool = false) {
        guard let localidad = cfg.localidad, !refreshing else {
            updateMenu()
            return
        }
        refreshing = true
        lastAttempt = Date()
        if manual { updateMenu() }
        // Si el usuario cambia de localidad mientras hay una consulta en
        // marcha, la respuesta antigua se descarta en vez de pisar los datos.
        let generacion = generacionLocalidad

        buscarAlrededor(
            lat: localidad.lat,
            lon: localidad.lon,
            radio: localidad.radioKm
        ) { [weak self] resultado in
            guard let self = self, generacion == self.generacionLocalidad else { return }
            self.refreshing = false
            switch resultado {
            case .success(let estaciones):
                self.estacionesLocalidad = estaciones
                let composicion = ComposicionLocalidad.componer(
                    estaciones: estaciones,
                    localidad: localidad
                )
                self.composicionLocalidad = composicion
                self.datos = composicion.datos
                self.avisoLocalidad = composicion.aviso
                self.lastSuccess = Date()
                self.lastError = nil
                self.needsReconnect = false
                self.arranqueTimer?.invalidate()
                self.arranqueTimer = nil
                self.evaluarAvisos(muestra: true)
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
            self.updateMenu()
        }
    }

    private func recomponerLocalidad() {
        guard let localidad = cfg.localidad else { return }
        let composicion = ComposicionLocalidad.componer(
            estaciones: estacionesLocalidad,
            localidad: localidad
        )
        composicionLocalidad = composicion
        datos = composicion.datos
        avisoLocalidad = composicion.aviso
        lastSuccess = Date()
        evaluarAvisos(muestra: true)
        updateMenu()
    }

    private func activarLocalidad(
        nombre: String,
        lat: Double,
        lon: Double,
        radio: Int,
        estaciones: [[String: Any]],
        seleccion: (principal: String?, viento: String?, lluvia: String?)? = nil,
        completion: ((Result<Int, Error>) -> Void)? = nil
    ) {
        var localidad = LocalidadConfig(
            nombre: nombre,
            lat: lat,
            lon: lon,
            radioKm: radio
        )
        if let seleccion = seleccion {
            localidad.automatico = seleccion.principal == nil
                && seleccion.viento == nil
                && seleccion.lluvia == nil
            localidad.principalId = seleccion.principal
            localidad.vientoId = seleccion.viento
            localidad.lluviaId = seleccion.lluvia
        }
        cfg.modo = "localidad"
        cfg.guardarLocalidad(localidad)
        if cfg.serviceUrl.isEmpty { cfg.serviceUrl = DEFAULT_SERVICE_URL }
        if !["exterior", "humedad_ext", "viento", "lluvia", "ninguno"]
            .contains(cfg.barValue) {
            cfg.barValue = "exterior"
        }
        cfg.save()

        estacionesLocalidad = estaciones
        composicionLocalidad = ComposicionLocalidad.componer(
            estaciones: estaciones,
            localidad: localidad
        )
        datos = composicionLocalidad?.datos
        avisoLocalidad = composicionLocalidad?.aviso
        // La gráfica del modo localidad usa solo muestras de estaciones
        // públicas, no el histórico de la cuenta que hubiera antes.
        historialNetatmo.removeAll()
        moduloSinHistorial.removeAll()
        lastSuccess = Date()
        lastError = nil
        needsReconnect = false
        refreshing = false
        generacionLocalidad += 1
        updateMenu()
        startPolling()
        completion?(.success(estaciones.count))
    }

    private func buscarYActivarLocalidad(
        nombre: String,
        lat: Double,
        lon: Double,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        buscarAlrededor(lat: lat, lon: lon, radio: 10) { [weak self] resultado in
            guard let self = self else { return }
            switch resultado {
            case .failure(let error):
                completion(.failure(error))
            case .success(let cercanas) where !cercanas.isEmpty:
                self.activarLocalidad(
                    nombre: nombre,
                    lat: lat,
                    lon: lon,
                    radio: 10,
                    estaciones: cercanas,
                    completion: completion
                )
            case .success:
                // Sin estaciones en 10 km: se amplía a 20 km y, si hay,
                // se avisa y se deja elegir a mano cuáles usar.
                self.buscarAlrededor(lat: lat, lon: lon, radio: 20) { [weak self] amplio in
                    guard let self = self else { return }
                    switch amplio {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let lejanas) where lejanas.isEmpty:
                        completion(.failure(AppError(L(
                            "No hay estaciones públicas de Netatmo en 20 km. Prueba otra localidad o conecta tu estación."
                        ))))
                    case .success(let lejanas):
                        self.mostrarSelectorLocalidad(
                            estaciones: lejanas,
                            aviso: L(
                                "No hay estaciones a menos de 10 km. Estas están más lejos: elige a mano cuáles usar."
                            ),
                            alGuardar: { [weak self] principal, viento, lluvia in
                                self?.activarLocalidad(
                                    nombre: nombre,
                                    lat: lat,
                                    lon: lon,
                                    radio: 20,
                                    estaciones: lejanas,
                                    seleccion: (principal, viento, lluvia),
                                    completion: completion
                                )
                            },
                            alCancelar: {
                                completion(.failure(AppError(L(
                                    "Selección cancelada. Prueba otra localidad."
                                ))))
                            }
                        )
                    }
                }
            }
        }
    }

    private func mostrarSelectorLocalidad(
        estaciones: [[String: Any]],
        aviso: String?,
        alGuardar: @escaping (String?, String?, String?) -> Void,
        alCancelar: (() -> Void)? = nil
    ) {
        if selectorEstaciones == nil {
            selectorEstaciones = SelectorEstacionesWindow()
        }
        guard let ventana = selectorEstaciones else { return }
        ventana.onGuardar = { [weak self] principal, viento, lluvia in
            self?.selectorEstaciones = nil
            alGuardar(principal, viento, lluvia)
        }
        ventana.onCancelar = { [weak self] in
            self?.selectorEstaciones = nil
            alCancelar?()
        }
        let localidad = cfg.localidad
        ventana.mostrar(
            estaciones: estaciones,
            principalId: localidad?.principalId,
            vientoId: localidad?.vientoId,
            lluviaId: localidad?.lluviaId,
            aviso: aviso
        )
    }

    private func mostrarOnboarding(localidad: Bool) {
        if onboardingWindow == nil {
            let ventana = OnboardingWindow()
            ventana.onConectar = { [weak self] in
                self?.showConnectWindow(reconnect: false)
            }
            ventana.onLocalidad = { [weak self] nombre, lat, lon, completion in
                self?.buscarYActivarLocalidad(
                    nombre: nombre,
                    lat: lat,
                    lon: lon,
                    completion: completion
                )
            }
            onboardingWindow = ventana
        }
        if localidad {
            onboardingWindow?.mostrarLocalidad(
                nombreActual: cfg.localidad?.nombre,
                volverAlInicio: false
            )
        } else {
            onboardingWindow?.mostrarInicio()
        }
    }

    @objc private func cambiarLocalidad(_ sender: Any?) {
        mostrarOnboarding(localidad: true)
    }

    @objc private func configurar(_ sender: Any?) {
        mostrarOnboarding(localidad: false)
    }

    @objc private func usarLocalidad(_ sender: Any?) {
        mostrarOnboarding(localidad: true)
    }

    @objc private func conectarCuenta(_ sender: Any?) {
        showConnectWindow(reconnect: false)
    }

    @objc private func elegirEstaciones(_ sender: Any?) {
        guard cfg.localidad != nil else { return }
        guard !estacionesLocalidad.isEmpty else {
            refresh()
            showError(
                L("Todavía no hay estaciones cargadas"),
                L("Espera a que termine la consulta y vuelve a abrir «Elegir estaciones».")
            )
            return
        }
        mostrarSelectorLocalidad(
            estaciones: estacionesLocalidad,
            aviso: L(
                "Elige qué estación aporta cada dato. «Automático» usa la estación más cercana a la mediana de la zona."
            ),
            alGuardar: { [weak self] principal, viento, lluvia in
                guard let self = self, var localidad = self.cfg.localidad else { return }
                localidad.automatico = principal == nil
                    && viento == nil
                    && lluvia == nil
                localidad.principalId = principal
                localidad.vientoId = viento
                localidad.lluviaId = lluvia
                self.cfg.localidad = localidad
                self.cfg.save()
                self.recomponerLocalidad()
            }
        )
    }

    // ------------------------- consultas -------------------------
    // Histórico oficial de la caldera (getmeasure de Netatmo). Se cachea un
    // cuarto de hora para no gastar llamadas de más; una consulta manual
    // fuerza la actualización.
    private func refrescarCaldera(forzar: Bool = false) {
        guard isConnected, let credential = credential, !cargandoCaldera else { return }
        if !forzar, let cargada = calderaCargada,
           Date().timeIntervalSince(cargada) < 900 { return }

        cargandoCaldera = true
        let url = cfg.serviceUrl + "/v1/boiler"
        DispatchQueue.global(qos: .utility).async {
            do {
                let result = try httpJSON(
                    url,
                    bearer: credential,
                    timeZone: TimeZone.current.identifier
                )
                DispatchQueue.main.async {
                    self.cargandoCaldera = false
                    if (200..<300).contains(result.status),
                       let json = result.json,
                       let hoy = num(json["hoy_min"]),
                       let ayer = num(json["ayer_min"]),
                       let mes = num(json["mes_min"]) {
                        self.caldera = CalderaRemota(
                            hoyMin: Int(hoy),
                            ayerMin: Int(ayer),
                            mesMin: Int(mes),
                            actualizado: json["actualizado"] as? String
                        )
                        self.calderaCargada = Date()
                        self.calderaError = nil
                        self.sinCaldera = false
                        self.evaluarAvisos()
                    } else if result.status == 404 {
                        // La cuenta no tiene caldera: no es un fallo temporal.
                        self.caldera = nil
                        self.calderaError = self.describeCalderaFailure(result)
                        self.sinCaldera = true
                    } else {
                        // Un fallo pasajero no borra el último dato bueno.
                        self.calderaError = self.describeCalderaFailure(result)
                    }
                    self.updateMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self.cargandoCaldera = false
                    self.calderaError = error.localizedDescription
                    self.updateMenu()
                }
            }
        }
    }

    private func describeCalderaFailure(_ result: HTTPResult) -> String {
        switch result.json?["error"] as? String {
        case "boiler_not_found":
            return L("La cuenta no tiene termostato con caldera.")
        case "invalid_time_zone":
            return L("La zona horaria no es válida.")
        case "authorization_expired":
            return L("Vuelve a conectar la cuenta de Netatmo.")
        case "temporarily_unavailable":
            return L("El servicio está ocupado. Se reintentará.")
        case "boiler_data_unavailable":
            return L("Netatmo no devolvió el histórico de la caldera.")
        default:
            return L("No se pudo leer el histórico de la caldera.")
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let interval = TimeInterval(max(60, cfg.pollSeconds))
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh(manual: Bool = false) {
        guard !refreshing else { return }
        if modoLocalidad {
            refrescarLocalidad(manual: manual)
            return
        }
        if credential == nil {
            credential = keychainRead()
        }
        guard isConnected, let credential = credential else {
            updateMenu()
            return
        }
        if needsReconnect && !manual {
            return
        }
        guard cfg.polling || manual else {
            updateMenu()
            return
        }
        refreshing = true
        lastAttempt = Date()
        let generation = pauseGeneration
        if manual { updateMenu() }

        let endpoint = cfg.endpoint
        DispatchQueue.global(qos: .utility).async {
            do {
                let result = try httpJSON(
                    endpoint,
                    bearer: credential,
                    timeZone: TimeZone.current.identifier
                )
                DispatchQueue.main.async {
                    self.refreshing = false
                    if (200..<300).contains(result.status), let json = result.json {
                        self.datosBrutos = json
                        self.datos = self.datosConEstacionPrincipal(json)
                        self.lastSuccess = Date()
                        self.lastError = nil
                        self.needsReconnect = false
                        self.arranqueTimer?.invalidate()
                        self.arranqueTimer = nil
                        // Una consulta manual con exito reanuda las consultas.
                        if manual && !self.cfg.polling
                            && generation == self.pauseGeneration {
                            self.cfg.polling = true
                            self.cfg.save()
                        }
                        self.refrescarFavorito()
                        self.refrescarCaldera(forzar: manual)
                        self.evaluarAvisos(muestra: true)
                    } else {
                        self.applyFailure(status: result.status, json: result.json)
                    }
                    self.updateMenu()
                }
            } catch {
                DispatchQueue.main.async {
                    self.refreshing = false
                    self.lastError = error.localizedDescription
                    self.updateMenu()
                }
            }
        }
    }

    private func applyFailure(status: Int, json: [String: Any]?) {
        let code = json?["error"] as? String ?? ""
        switch (status, code) {
        case (401, _):
            requireReconnect(L("La credencial no es válida. Reconecta la cuenta."))
        case (429, _):
            lastError = L("Demasiados intentos. Espera unos minutos.")
        case (503, "authorization_expired"):
            requireReconnect(L("Netatmo exige volver a autorizar la cuenta."))
        case (503, "temporarily_unavailable"):
            lastError = L("El servicio está ocupado. Se reintentará.")
        case (502, _):
            lastError = L("No se pudieron leer los datos de Netatmo.")
        default:
            lastError = L("Error del servicio (HTTP %d).", status)
        }
    }

    private func requireReconnect(_ message: String) {
        let yaAvisado = needsReconnect
        needsReconnect = true
        lastError = message
        if !yaAvisado {
            NotificationPresenter.shared.reconnectNeeded()
        }
    }

    // ------------------------- conexion OAuth -------------------------
    @objc private func conectar(_ sender: Any?) {
        showConnectWindow(reconnect: credential != nil)
    }

    @objc private func reconectar(_ sender: Any?) {
        showConnectWindow(reconnect: true)
    }

    private func showConnectWindow(reconnect: Bool) {
        if connectWindow == nil {
            let window = ConnectWindow()
            window.onConnect = { [weak self] in self?.connectFromWindow() }
            connectWindow = window
        }
        connectWindow?.configure(reconnect: reconnect)
        connectWindow?.show()
    }

    private func connectFromWindow() {
        let url = cfg.serviceUrl.isEmpty ? DEFAULT_SERVICE_URL : cfg.serviceUrl
        guard !url.isEmpty else {
            connectWindow?.setError(L("Falta la dirección del servicio."))
            return
        }
        beginConnect(serviceUrl: url)
    }

    @objc private func cambiarServicio(_ sender: Any?) {
        askService(prefill: cfg.serviceUrl) { url in
            if url != self.cfg.serviceUrl {
                keychainDelete()
                self.credential = nil
                self.cfg.serviceUrl = url
                self.cfg.endpoint = ""
                self.cfg.installationId = UUID().uuidString.lowercased()
                self.cfg.save()
                self.datos = nil
                self.datosBrutos = nil
                self.lastSuccess = nil
                self.lastError = nil
                self.needsReconnect = false
            }
            self.showConnectWindow(reconnect: false)
            self.beginConnect(serviceUrl: url)
        }
    }

    @objc private func restablecer(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("¿Restablecer la conexión?")
        alert.informativeText = L(
            "Se borrarán la credencial local y el identificador de instalación. Después tendrás que volver a autorizar la cuenta de Netatmo."
        )
        alert.addButton(withTitle: L("Restablecer"))
        alert.addButton(withTitle: L("Cancelar"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        keychainDelete()
        credential = nil
        cfg.endpoint = ""
        cfg.installationId = UUID().uuidString.lowercased()
        cfg.save()
        datos = nil
        datosBrutos = nil
        lastSuccess = nil
        lastError = nil
        needsReconnect = false
        pending = nil
        connecting = false
        updateMenu()
        showConnectWindow(reconnect: false)
    }

    private func askService(prefill: String, completion: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = L("Servicio de Mirlo Weather")
        alert.informativeText = L(
            "Escribe la dirección del servicio (Cloudflare Worker). Debe empezar por https://"
        )
        alert.addButton(withTitle: L("Continuar"))
        alert.addButton(withTitle: L("Cancelar"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = prefill
        field.placeholderString = "https://mi-servicio.workers.dev"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let url = normalizarServicio(field.stringValue) else {
            showError(
                L("Dirección no válida"),
                L("Usa una URL https (o http solo para localhost), sin rutas ni parámetros.")
            )
            return
        }
        completion(url)
    }

    private func beginConnect(serviceUrl: String) {
        guard !connecting else { return }
        let usarCredencial = serviceUrl == cfg.serviceUrl ? credential : nil
        let appState = randomToken()
        let verifier = randomToken()
        let challenge = sha256Base64url(verifier)
        let installationId = cfg.installationId

        pending = PendingOAuth(
            appState: appState,
            verifier: verifier,
            serviceUrl: serviceUrl,
            credential: usarCredencial
        )
        connecting = true
        connectWindow?.setWaiting(L("Abriendo el navegador…"))
        updateMenu()

        let body: [String: Any] = [
            "state": appState,
            "redirect_uri": APP_CALLBACK,
            "installation_id": installationId,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
        ]

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try httpJSON(
                    serviceUrl + "/v1/oauth/start",
                    method: "POST",
                    body: body,
                    bearer: usarCredencial
                )
                guard (200..<300).contains(result.status),
                      let authorization = result.json?["authorization_url"] as? String,
                      let url = URL(string: authorization) else {
                    throw AppError(self.describeStartFailure(result))
                }
                DispatchQueue.main.async {
                    self.connecting = false
                    self.connectWindow?.setWaiting(L("Esperando autorización en el navegador…"))
                    self.updateMenu()
                    NSWorkspace.shared.open(url)
                }
            } catch {
                DispatchQueue.main.async {
                    self.connecting = false
                    self.pending = nil
                    self.updateMenu()
                    self.reportConnectError(error.localizedDescription)
                }
            }
        }
    }

    private func reportConnectError(_ message: String) {
        if let window = connectWindow, window.isVisible {
            window.setError(message)
        } else {
            showError(L("No se pudo conectar"), message)
        }
    }

    private func handleCallback(_ url: URL) {
        guard let pending = pending else {
            // Un callback repetido o antiguo no es un error. Puede llegar
            // incluso antes de terminar de arrancar la app, así que no se
            // toca la interfaz: solo se trae al frente si ya está lista.
            if credential != nil {
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        guard value("state") == pending.appState else {
            // Respuesta de otra solicitud: se ignora sin interrumpir.
            return
        }
        if let error = value("error") {
            self.pending = nil
            updateMenu()
            let motivo = error == "access_denied"
                ? L("Has cancelado la autorización en Netatmo.")
                : L("Netatmo no autorizó la conexión (%@).", error)
            reportConnectError(motivo)
            return
        }
        guard let code = value("code"), !code.isEmpty else {
            self.pending = nil
            updateMenu()
            reportConnectError(L("Netatmo no devolvió un código de autorización."))
            return
        }

        connecting = true
        connectWindow?.setWaiting(L("Terminando la conexión…"))
        updateMenu()
        let body: [String: Any] = [
            "code": code,
            "state": pending.appState,
            "installation_id": cfg.installationId,
            "code_verifier": pending.verifier,
        ]

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try httpJSON(
                    pending.serviceUrl + "/v1/oauth/redeem",
                    method: "POST",
                    body: body,
                    bearer: pending.credential
                )
                guard (200..<300).contains(result.status),
                      let credential = result.json?["credential"] as? String,
                      let endpoint = result.json?["endpoint"] as? String,
                      !credential.isEmpty, !endpoint.isEmpty else {
                    throw AppError(self.describeRedeemFailure(result))
                }
                guard keychainSave(credential) else {
                    throw AppError(L("No se pudo guardar la credencial en el Llavero."))
                }
                DispatchQueue.main.async {
                    self.credential = credential
                    self.cfg.serviceUrl = pending.serviceUrl
                    self.cfg.endpoint = endpoint
                    self.cfg.modo = "cuenta"
                    self.cfg.save()
                    self.pending = nil
                    self.connecting = false
                    self.datos = nil
                    self.datosBrutos = nil
                    self.lastSuccess = nil
                    self.lastError = nil
                    self.needsReconnect = false
                    NSApp.activate(ignoringOtherApps: true)
                    self.connectWindow?.setSuccess()
                    self.updateMenu()
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.connecting = false
                    self.pending = nil
                    self.updateMenu()
                    self.reportConnectError(error.localizedDescription)
                }
            }
        }
    }

    private func describeStartFailure(_ result: HTTPResult) -> String {
        switch codigoError(result) {
        case "not_configured":
            return L("El servicio no tiene configurada la app de Netatmo.")
        case "installation_not_verified":
            return L("La instalación ya existe en el servicio, pero la credencial local no está disponible. Usa «Restablecer conexión».")
        case "too_many_attempts":
            return L("Demasiados intentos. Espera unos minutos y vuelve a probar.")
        case "invalid_connection_request":
            return L("El servicio rechazó la solicitud de conexión. Comprueba la dirección.")
        default:
            return L("El servicio respondió HTTP %d.", result.status)
        }
    }

    private func describeRedeemFailure(_ result: HTTPResult) -> String {
        switch codigoError(result) {
        case "invalid_or_expired_code":
            return L("El código de conexión caducó. Vuelve a conectar la cuenta.")
        case "installation_not_verified":
            return L("La instalación no se pudo verificar. Usa «Restablecer conexión» y vuelve a empezar.")
        case "installation_already_registered":
            return L("La instalación ya estaba registrada. Usa «Restablecer conexión».")
        case "too_many_attempts":
            return L("Demasiados intentos. Espera unos minutos y vuelve a probar.")
        default:
            return L("El servicio respondió HTTP %d.", result.status)
        }
    }

    // ------------------------- acciones -------------------------
    // El menú de la barra ya declara ⌘, y ⌘R, pero esos atajos solo llegan a la
    // app mientras el menú está abierto. Este monitor los atiende también
    // cuando hay una ventana de Mirlo en primer plano (Ajustes, gráfica…) y
    // permite cerrar la gráfica con Esc.
    private func instalarAtajosLocales() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] evento in
            guard let self = self else { return evento }
            let cmd = evento.modifierFlags.contains(.command)
            if cmd, let tecla = evento.charactersIgnoringModifiers?.lowercased() {
                if tecla == "," {
                    self.mostrarAjustes(nil)
                    return nil
                }
                if tecla == "r" {
                    self.actualizarAhora(nil)
                    return nil
                }
            }
            if evento.keyCode == 53,
               let ventana = self.ventanaGrafica,
               ventana.isVisible,
               ventana.attachedSheet == nil,
               NSApp.keyWindow === ventana {
                ventana.orderOut(nil)
                return nil
            }
            return evento
        }
    }

    @objc private func actualizarAhora(_ sender: Any?) {
        if activo {
            refresh(manual: true)
        } else {
            conectar(sender)
        }
    }

    @objc private func elegirBarra(_ sender: NSMenuItem) {
        guard let clave = sender.representedObject as? String else { return }
        cfg.barValue = clave
        cfg.save()
        updateMenu()
    }

    // ------------------------- gráfica 24 h -------------------------
    // La gráfica vive en su propia ventana flotante para poder cambiar de
    // campo (viento, temperatura, lluvia…) sin que se cierre el cuadro. Se
    // redimensiona como cualquier ventana y recuerda tamaño y posición.
    private func construirVentanaGrafica() {
        let ventana = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        ventana.title = L("Gráfica 24 h")
        ventana.isReleasedWhenClosed = false
        ventana.minSize = NSSize(width: 380, height: 260)
        ventana.level = cfg.graficaFlotante ? .floating : .normal
        ventana.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        ventana.setFrameAutosaveName("MirloGrafica")
        graficaRestaurada = ventana.setFrameUsingName("MirloGrafica")

        let contenido = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 380))
        ventana.contentView = contenido

        vistaGrafica.translatesAutoresizingMaskIntoConstraints = false
        vistaGrafica.setContentHuggingPriority(.defaultLow, for: .vertical)
        vistaGrafica.setContentHuggingPriority(.defaultLow, for: .horizontal)
        vistaGrafica.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        vistaGrafica.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let etiqueta = NSTextField(labelWithString: L("Campo"))
        etiqueta.font = NSFont.systemFont(ofSize: 11)
        etiqueta.textColor = .secondaryLabelColor
        etiqueta.setContentHuggingPriority(.required, for: .horizontal)

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.font = NSFont.systemFont(ofSize: 12)
        popup.target = self
        popup.action = #selector(cambiarCampoGrafica(_:))
        popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popupGrafica = popup

        let pin = NSButton()
        pin.bezelStyle = .texturedRounded
        pin.setButtonType(.toggle)
        pin.image = NSImage(
            systemSymbolName: "pin",
            accessibilityDescription: L("Mantener encima")
        )
        pin.state = cfg.graficaFlotante ? .on : .off
        pin.target = self
        pin.action = #selector(alternarPinGrafica(_:))
        pin.toolTip = L("Mantener encima")
        pin.imagePosition = .imageOnly
        pin.setAccessibilityLabel(L("Mantener encima"))
        pin.setContentHuggingPriority(.required, for: .horizontal)

        let exportar = NSButton()
        exportar.bezelStyle = .texturedRounded
        exportar.image = NSImage(
            systemSymbolName: "square.and.arrow.up",
            accessibilityDescription: L("Exportar PNG")
        )
        exportar.target = self
        exportar.action = #selector(exportarGrafica(_:))
        exportar.toolTip = L("Exportar PNG")
        exportar.imagePosition = .imageOnly
        exportar.setAccessibilityLabel(L("Exportar PNG"))
        exportar.setContentHuggingPriority(.required, for: .horizontal)

        let barra = NSStackView(views: [etiqueta, popup, pin, exportar])
        barra.orientation = .horizontal
        barra.spacing = 8
        barra.alignment = .centerY
        barra.distribution = .fill
        barra.translatesAutoresizingMaskIntoConstraints = false

        let borrar = NSButton(
            title: L("Borrar historial local…"),
            target: self,
            action: #selector(borrarHistorial(_:))
        )
        borrar.bezelStyle = .inline
        borrar.font = NSFont.systemFont(ofSize: 11)
        borrar.setContentHuggingPriority(.required, for: .horizontal)

        let pie = NSStackView(views: [borrar])
        pie.orientation = .horizontal
        pie.spacing = 8
        pie.alignment = .centerY
        pie.translatesAutoresizingMaskIntoConstraints = false

        let pila = NSStackView(views: [barra, vistaGrafica, pie])
        pila.orientation = .vertical
        pila.spacing = 10
        pila.alignment = .leading
        pila.distribution = .fill
        pila.translatesAutoresizingMaskIntoConstraints = false
        contenido.addSubview(pila)

        NSLayoutConstraint.activate([
            pila.topAnchor.constraint(equalTo: contenido.topAnchor, constant: 12),
            pila.leadingAnchor.constraint(equalTo: contenido.leadingAnchor, constant: 14),
            pila.trailingAnchor.constraint(equalTo: contenido.trailingAnchor, constant: -14),
            pila.bottomAnchor.constraint(equalTo: contenido.bottomAnchor, constant: -12),

            barra.widthAnchor.constraint(equalTo: pila.widthAnchor),
            vistaGrafica.widthAnchor.constraint(equalTo: pila.widthAnchor),
            vistaGrafica.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            pie.widthAnchor.constraint(equalTo: pila.widthAnchor),
        ])

        ventanaGrafica = ventana
    }

    @objc private func alternarPinGrafica(_ sender: NSButton) {
        cfg.graficaFlotante = sender.state == .on
        cfg.save()
        ventanaGrafica?.level = cfg.graficaFlotante ? .floating : .normal
        if cfg.graficaFlotante {
            ventanaGrafica?.orderFrontRegardless()
        }
    }

    @objc private func exportarGrafica(_ sender: Any?) {
        guard let ventana = ventanaGrafica,
              let rep = vistaGrafica.bitmapImageRepForCachingDisplay(
                  in: vistaGrafica.bounds
              ) else { return }
        vistaGrafica.cacheDisplay(in: vistaGrafica.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Mirlo gráfica 24 h.png"
        panel.beginSheetModal(for: ventana) { respuesta in
            guard respuesta == .OK, let url = panel.url else { return }
            try? png.write(to: url, options: .atomic)
        }
    }

    @objc private func abrirGrafica(_ sender: Any?) {
        if ventanaGrafica == nil { construirVentanaGrafica() }
        actualizarCamposGrafica()
        actualizarGrafica()
        // El menú aún se está cerrando cuando llega la acción; se muestra en
        // el siguiente ciclo para que la ventana reciba el foco.
        DispatchQueue.main.async {
            if !self.graficaRestaurada || !self.ventanaGraficaEnPantalla() {
                self.posicionarVentanaGrafica()
            }
            NSApp.activate(ignoringOtherApps: true)
            self.ventanaGrafica?.makeKeyAndOrderFront(nil)
        }
    }

    private func ventanaGraficaEnPantalla() -> Bool {
        guard let ventana = ventanaGrafica else { return false }
        return NSScreen.screens.contains { $0.visibleFrame.intersects(ventana.frame) }
    }

    private func posicionarVentanaGrafica() {
        guard let ventana = ventanaGrafica else { return }
        let tam = ventana.frame.size
        var origen = NSPoint(x: 0, y: 0)
        if let boton = statusItem.button, let barra = boton.window {
            let rect = barra.convertToScreen(boton.convert(boton.bounds, to: nil))
            origen = NSPoint(
                x: rect.midX - tam.width / 2,
                y: rect.minY - tam.height - 6
            )
        }
        if let pantalla = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            origen.x = min(max(origen.x, pantalla.minX + 8),
                           pantalla.maxX - tam.width - 8)
            if origen.y < pantalla.minY + 8 { origen.y = pantalla.minY + 8 }
        }
        ventana.setFrameOrigin(origen)
    }

    // Catálogo de la gráfica. En modo cuenta sale de `modulos` para que cada
    // sensor tenga su propia serie; si todavía no hay lecturas, se usan los
    // campos heredados.
    private var catalogoGraficaListo: Bool {
        if modoLocalidad { return true }
        let modulos = datos?["modulos"] as? [[String: Any]] ?? []
        return !modulos.isEmpty
    }

    private func camposGraficaDisponibles() -> [CampoGrafica] {
        if modoLocalidad {
            let permitidos: Set<String> = [
                "exterior.temperatura", "exterior.humedad",
                "viento.velocidad", "viento.racha",
                "lluvia.actual", "lluvia.24h",
            ]
            return CAMPOS_GRAFICA.filter { permitidos.contains($0.clave) }
        }

        let modulos = datos?["modulos"] as? [[String: Any]] ?? []
        guard !modulos.isEmpty else { return CAMPOS_GRAFICA }

        var salida: [CampoGrafica] = []
        for modulo in modulos {
            guard let id = modulo["id"] as? String, !id.isEmpty,
                  let tipo = modulo["tipo"] as? String else { continue }
            let datosMod = modulo["datos"] as? [String: Any] ?? [:]
            let estacion = (modulo["estacion"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let nombreModulo = (modulo["nombre"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let etiquetaModulo = nombreModulo.isEmpty
                ? nombreTipoModulo(tipo)
                : nombreModulo
            let grupo = estacion.isEmpty
                ? etiquetaModulo
                : "\(estacion) · \(etiquetaModulo)"

            for campo in camposDeModulo(tipo: tipo, datos: datosMod) {
                salida.append(CampoGrafica(
                    clave: "mod:\(id):\(campo.clave)",
                    nombre: grupo + " — " + campo.nombre,
                    nombreCorto: campo.nombre,
                    unidad: campo.unidad,
                    decimales: campo.decimales,
                    idModulo: id,
                    serieRemota: campo.clave,
                    modulo: nil,
                    tipo: tipo,
                    grupo: grupo,
                    campoBase: campo.clave
                ))
            }
        }

        // Además de los módulos, se mantienen los campos que solo tienen
        // historial local en este Mac (caldera y lluvia instantánea).
        let locales: Set<String> = ["caldera.encendida", "lluvia.actual"]
        for campo in CAMPOS_GRAFICA where locales.contains(campo.clave) {
            salida.append(CampoGrafica(
                clave: campo.clave,
                nombre: campo.nombre,
                nombreCorto: campo.nombreCorto,
                unidad: campo.unidad,
                decimales: campo.decimales,
                idModulo: nil,
                serieRemota: campo.serieRemota,
                modulo: nil,
                tipo: campo.tipo,
                grupo: L("Este Mac"),
                campoBase: campo.campoBase
            ))
        }
        return salida.isEmpty ? CAMPOS_GRAFICA : salida
    }

    private func nombreTipoModulo(_ tipo: String) -> String {
        switch tipo {
        case "exterior": return L("Exterior")
        case "interior": return L("Interior")
        case "viento": return L("Viento")
        case "lluvia": return L("Lluvia")
        case "termostato": return L("Termostato")
        default: return L("Sensor")
        }
    }

    private struct CampoModulo {
        let clave: String
        let nombre: String
        let unidad: String
        let decimales: Int
    }

    private func camposDeModulo(tipo: String, datos: [String: Any]) -> [CampoModulo] {
        func hay(_ clave: String) -> Bool { num(datos[clave]) != nil }
        var campos: [CampoModulo] = []
        func añadir(_ clave: String, _ nombre: String, _ unidad: String, _ decimales: Int) {
            guard hay(clave) else { return }
            campos.append(CampoModulo(
                clave: clave,
                nombre: nombre,
                unidad: unidad,
                decimales: decimales
            ))
        }

        switch tipo {
        case "exterior":
            añadir("temperatura", L("Temperatura"), "°C", 1)
            añadir("humedad", L("Humedad"), "%", 0)
        case "interior":
            añadir("temperatura", L("Temperatura"), "°C", 1)
            añadir("humedad", L("Humedad"), "%", 0)
            añadir("co2", L("CO₂"), "ppm", 0)
            añadir("presion", L("Presión"), "hPa", 0)
            añadir("ruido", L("Ruido"), "dB", 0)
        case "viento":
            añadir("viento", L("Viento"), "km/h", 0)
            añadir("racha", L("Racha"), "km/h", 0)
        case "lluvia":
            añadir("lluvia", L("Lluvia en 24 h"), "mm", 1)
        case "termostato":
            añadir("temperatura", L("Temperatura"), "°C", 1)
        default:
            añadir("temperatura", L("Temperatura"), "°C", 1)
            añadir("humedad", L("Humedad"), "%", 0)
            añadir("co2", L("CO₂"), "ppm", 0)
            añadir("presion", L("Presión"), "hPa", 0)
            añadir("ruido", L("Ruido"), "dB", 0)
            añadir("viento", L("Viento"), "km/h", 0)
            añadir("racha", L("Racha"), "km/h", 0)
            añadir("lluvia", L("Lluvia en 24 h"), "mm", 1)
        }
        return campos
    }

    private func seleccionarCampoGrafica(_ clave: String, en popup: NSPopUpButton) {
        if let item = popup.itemArray.first(where: {
            ($0.representedObject as? String) == clave
        }) {
            popup.select(item)
        }
    }

    private func actualizarCamposGrafica() {
        guard let popup = popupGrafica else { return }
        let campos = camposGraficaDisponibles()
        if catalogoGraficaListo,
           !campos.contains(where: { $0.clave == cfg.graphField }) {
            // Por defecto, la temperatura exterior de la primera estación. Si
            // no hay exterior, el primer campo disponible. No se guarda nada
            // mientras el catálogo es el de respaldo: si las lecturas aún no
            // han llegado, se perdería la elección del usuario.
            let preferido = campos.first {
                $0.tipo == "exterior" && $0.campoBase == "temperatura"
            } ?? campos.first
            if let preferido {
                cfg.graphField = preferido.clave
                cfg.save()
            }
        }

        let claves = campos.map { $0.clave }
        if claves != camposGraficaClaves {
            popup.removeAllItems()
            var grupoAnterior = ""
            for campo in campos {
                if !campo.grupo.isEmpty && campo.grupo != grupoAnterior {
                    if popup.numberOfItems > 0 {
                        popup.menu?.addItem(.separator())
                    }
                    grupoAnterior = campo.grupo
                }
                let item = NSMenuItem(
                    title: campo.nombre,
                    action: nil,
                    keyEquivalent: ""
                )
                item.representedObject = campo.clave
                popup.menu?.addItem(item)
            }
            camposGraficaClaves = claves
        }
        seleccionarCampoGrafica(cfg.graphField, en: popup)
    }

    @objc private func cambiarCampoGrafica(_ sender: NSPopUpButton) {
        guard let clave = sender.selectedItem?.representedObject as? String,
              camposGraficaDisponibles().contains(where: {
                  $0.clave == clave
              }) else { return }
        cfg.graphField = clave
        cfg.save()
        actualizarGrafica()
    }

    private func actualizarGrafica() {
        actualizarCamposGrafica()
        let campos = camposGraficaDisponibles()
        guard let campo = campos.first(where: { $0.clave == cfg.graphField })
            ?? campos.first else { return }
        if catalogoGraficaListo, cfg.graphField != campo.clave {
            cfg.graphField = campo.clave
            cfg.save()
        }

        ventanaGrafica?.title = L("Gráfica 24 h") + " · " + campo.nombreCorto
        vistaGrafica.campo = campo.clave
        vistaGrafica.nombreCampo = campo.nombre
        vistaGrafica.unidadCampo = campo.unidad
        vistaGrafica.decimalesCampo = campo.decimales

        if let remota = historialNetatmo[campo.clave], remota.puntos.count >= 2 {
            vistaGrafica.puntos = remota.puntos
            vistaGrafica.origen = "Netatmo"
            vistaGrafica.nota = ""
        } else {
            // Solo los campos heredados tienen muestras locales.
            vistaGrafica.puntos = campo.idModulo == nil
                ? leerHistorialGrafica(campo: campo.clave)
                : []
            vistaGrafica.origen = "local"
            // Si el módulo ya respondió 404, Netatmo no publica histórico de
            // ese campo: se avisa en el pie para que no parezca un fallo.
            if !modoLocalidad,
               let objetivo = objetivoHistorial(campo),
               moduloSinHistorial.contains(objetivo.etiqueta) {
                vistaGrafica.nota = L("sin histórico de Netatmo")
            } else {
                vistaGrafica.nota = ""
            }
        }
        vistaGrafica.needsDisplay = true
        NSAccessibility.post(element: vistaGrafica, notification: .valueChanged)
        refrescarHistorialNetatmo(campo: campo)
    }

    // Consulta al Worker para un campo: por `id` de módulo (recomendado) o por
    // la forma antigua `modulo=`. La caldera no tiene serie en getmeasure.
    private func objetivoHistorial(
        _ campo: CampoGrafica
    ) -> (consulta: String, etiqueta: String, prefijo: String)? {
        if let id = campo.idModulo, !id.isEmpty {
            let codificado = id.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed
            ) ?? id
            return ("id=" + codificado, "id:" + id, "mod:" + id + ":")
        }
        if let modulo = campo.modulo {
            return ("modulo=" + modulo, "modulo:" + modulo, "")
        }
        return nil
    }

    // Pide a Netatmo (a través del Worker) la serie de 24 h del módulo que
    // muestra la gráfica. Se cachea 15 min: en ese tiempo no se repite la
    // consulta ni al cambiar de campo ni al abrir el menú varias veces.
    private func refrescarHistorialNetatmo(campo: CampoGrafica) {
        guard !modoLocalidad,
              isConnected, let credential = credential,
              let objetivo = objetivoHistorial(campo),
              !moduloSinHistorial.contains(objetivo.etiqueta),
              !cargandoHistorial.contains(objetivo.etiqueta) else { return }
        if let actual = historialNetatmo[campo.clave],
           Date().timeIntervalSince(actual.cargado) < 15 * 60 { return }
        if let intento = intentoHistorial[objetivo.etiqueta],
           Date().timeIntervalSince(intento) < 5 * 60 { return }

        intentoHistorial[objetivo.etiqueta] = Date()
        cargandoHistorial.insert(objetivo.etiqueta)
        let url = cfg.serviceUrl + "/v1/history?" + objetivo.consulta
        let prefijo = objetivo.prefijo
        let etiqueta = objetivo.etiqueta
        DispatchQueue.global(qos: .utility).async {
            do {
                let result = try httpJSON(
                    url,
                    bearer: credential,
                    timeZone: TimeZone.current.identifier
                )
                DispatchQueue.main.async {
                    self.cargandoHistorial.remove(etiqueta)
                    if result.status == 404 {
                        // El módulo no existe en esta cuenta o no tiene serie:
                        // se usa el historial local cuando lo haya.
                        self.moduloSinHistorial.insert(etiqueta)
                    } else if (200..<300).contains(result.status),
                              let series = result.json?["series"] as? [String: Any] {
                        var cargados = 0
                        for (clave, valor) in series {
                            guard let filas = valor as? [[Any]] else { continue }
                            var puntos: [(ts: Double, valor: Double)] = []
                            for fila in filas where fila.count >= 2 {
                                if let ts = num(fila[0]), let v = num(fila[1]) {
                                    puntos.append((ts: ts, valor: v))
                                }
                            }
                            if puntos.count >= 2 {
                                self.historialNetatmo[prefijo + clave] = (puntos, Date())
                                cargados += 1
                            }
                        }
                        if cargados == 0 { self.moduloSinHistorial.insert(etiqueta) }
                    }
                    self.actualizarGrafica()
                }
            } catch {
                DispatchQueue.main.async {
                    self.cargandoHistorial.remove(etiqueta)
                }
            }
        }
    }

    @objc private func borrarHistorial(_ sender: Any?) {
        let alerta = NSAlert()
        alerta.messageText = L("¿Borrar el historial local?")
        alerta.informativeText = L(
            "Se eliminarán las muestras guardadas en este Mac. La gráfica seguirá mostrando el histórico de Netatmo cuando ese campo lo tenga; para los demás empezará de cero y las tendencias de 30/60 min necesitarán nuevos datos. Los avisos y sus reglas no se tocan."
        )
        alerta.addButton(withTitle: L("Borrar historial local"))
        alerta.addButton(withTitle: L("Cancelar"))
        guard alerta.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: AVISOS_HIST_PATH)
        actualizarGrafica()
    }

    @objc private func abrirWeb(_ sender: Any?) {
        if let url = URL(string: NETATMO_WEB) {
            NSWorkspace.shared.open(url)
        }
    }

    // ------------------------- avisos -------------------------
    private func reconstruirSubmenuAvisos() {
        guard itAvisos != nil else { return }
        let s = motorAvisos.snapshot()
        let act = s.activados
        let reglas = s.reglas
        let sub = NSMenu()

        let conf = NSMenuItem(
            title: L("Configurar avisos…"),
            action: #selector(abrirAvisos(_:)),
            keyEquivalent: ""
        )
        conf.target = self
        sub.addItem(conf)

        let probar = NSMenuItem(
            title: L("Probar notificación"),
            action: #selector(probarNotificacion(_:)),
            keyEquivalent: ""
        )
        probar.target = self
        sub.addItem(probar)
        sub.addItem(.separator())

        let toggle = NSMenuItem(
            title: L("Activar avisos"),
            action: #selector(alternarAvisos(_:)),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = act ? .on : .off
        sub.addItem(toggle)
        sub.addItem(.separator())

        let n = reglas.filter { $0.activo }.count
        let ahora = Date().timeIntervalSince1970
        let silenciadas = reglas.filter { ahora < (s.silencios[$0.id] ?? 0) }.count
        var cabTxt = act ? L("Reglas activas: %d de %d", n, reglas.count) : L("Avisos desactivados")
        if silenciadas > 0 {
            cabTxt += silenciadas == 1
                ? L(" · 1 silenciada")
                : L(" · %d silenciadas", silenciadas)
        }
        let cab = NSMenuItem(title: cabTxt, action: #selector(noop(_:)), keyEquivalent: "")
        cab.target = self
        sub.addItem(cab)

        let ultimos = motorAvisos.registroAvisos()
        if ultimos.isEmpty {
            let it = NSMenuItem(
                title: L("Sin avisos disparados todavía"),
                action: #selector(noop(_:)),
                keyEquivalent: ""
            )
            it.target = self
            sub.addItem(it)
        } else {
            let f = DateFormatter()
            f.dateFormat = "dd/MM HH:mm"
            for a in ultimos.suffix(8) {
                var t = a.texto
                if t.count > 64 { t = String(t.prefix(63)) + "…" }
                let it = NSMenuItem(
                    title: f.string(from: Date(timeIntervalSince1970: a.ts)) + " · " + t,
                    action: #selector(noop(_:)),
                    keyEquivalent: ""
                )
                it.target = self
                sub.addItem(it)
            }
        }
        itAvisos.title = act ? L("Avisos (%d activos)", n) : L("Avisos (desactivados)")
        itAvisos.submenu = sub
    }

    @objc private func abrirAvisos(_ sender: Any?) {
        abrirAjustes(seccion: .avisos)
    }

    @objc private func alternarAvisos(_ sender: Any?) {
        let activo = motorAvisos.snapshot().activados
        motorAvisos.modificar { $0.activados = !activo }
        if !activo { NotificationPresenter.shared.pedirPermiso() }
        reconstruirSubmenuAvisos()
        updateMenu()
    }

    @objc private func probarNotificacion(_ sender: Any?) {
        let enviar = {
            _ = NotificationPresenter.shared.enviar(
                titulo: L("Mirlo Weather · Prueba"),
                cuerpo: L("Si ves este aviso, las notificaciones funcionan.")
            )
        }
        NotificationPresenter.shared.refrescarPermiso { estado in
            if estado == .authorized || estado == .provisional {
                enviar()
            } else {
                NotificationPresenter.shared.pedirPermiso { ok in
                    if ok {
                        enviar()
                    } else {
                        DispatchQueue.main.async {
                            let alerta = NSAlert()
                            alerta.messageText = L("Notificaciones no permitidas")
                            alerta.informativeText = L(
                                "Actívalas en Ajustes del Sistema › Notificaciones › Mirlo Weather. Mientras tanto, los avisos se muestran en el menú y suenan."
                            )
                            alerta.runModal()
                        }
                    }
                }
            }
        }
    }

    private func mostrarAvisoPendiente(_ texto: String) {
        avisoPendiente = texto
        avisoPendienteTimer?.invalidate()
        itAvisoPendiente.title = "⚠︎ " + (texto.count > 80
            ? String(texto.prefix(79)) + "…" : texto)
        itAvisoPendiente.isHidden = false
        // Sin permiso de notificaciones, la barra también lo anuncia unos
        // segundos (icono de campana y "Aviso") para que no pase inadvertido.
        avisoBarraHasta = Date().addingTimeInterval(20)
        avisoBarraTimer?.invalidate()
        avisoBarraTimer = Timer.scheduledTimer(
            withTimeInterval: 20,
            repeats: false
        ) { [weak self] _ in
            self?.avisoBarraHasta = nil
            self?.updateMenu()
        }
        reconstruirSubmenuAvisos()
        updateMenu()
        avisoPendienteTimer = Timer.scheduledTimer(
            withTimeInterval: 20,
            repeats: false
        ) { [weak self] _ in
            self?.avisoPendiente = nil
            self?.itAvisoPendiente.isHidden = true
            self?.updateMenu()
        }
    }

    // `muestra` solo se activa tras un refresco real de lecturas: así se guarda
    // una línea por consulta (~5 min) en vez de tres (lecturas, caldera y
    // estación cercana) con los mismos datos. Los avisos se evalúan siempre.
    private func evaluarAvisos(muestra: Bool = false) {
        guard let datos = datos else { return }
        let valores = valoresAvisos(datos: datos)
        if muestra { guardarMuestraAvisos(valores) }
        let actualizado = fechaDelServicio(datos["actualizado"] as? String) ?? lastSuccess
        let necesitaHistorial = motorAvisos.snapshot().reglas.contains {
            $0.activo && $0.campo.contains("_cambio_")
        }
        let historial = necesitaHistorial ? leerHistorialAvisos(horas: 2) : []
        motorAvisos.evaluar(valores: valores, actualizado: actualizado,
                            historial: historial)
    }

    private func valoresAvisos(datos: [String: Any]) -> [String: Double] {
        var v: [String: Double] = [:]
        func poner(_ clave: String, _ valor: Double?) {
            if let valor = valor { v[clave] = valor }
        }
        let ext = datos["exterior"] as? [String: Any]
        poner("exterior.temperatura", num(ext?["temperatura"]))
        poner("exterior.humedad", num(ext?["humedad"]))
        poner("exterior.min", num(ext?["min"]))
        poner("exterior.max", num(ext?["max"]))

        let inte = datos["interior"] as? [String: Any]
        poner("interior.temperatura", num(inte?["temperatura"]))
        poner("interior.humedad", num(inte?["humedad"]))
        poner("interior.co2", num(inte?["co2"]))
        poner("interior.ruido", num(inte?["ruido"]))
        poner("interior.presion", num(inte?["presion"]))

        let termo = datos["termostato"] as? [String: Any]
        poner("termostato.temperatura", num(termo?["temperatura"]))
        poner("termostato.consigna", num(termo?["consigna"]))
        if let on = termo?["caldera"] as? Bool {
            v["caldera.encendida"] = on ? 1 : 0
        }
        if let remota = caldera {
            v["caldera.hoy_min"] = Double(remota.hoyMin)
            v["caldera.ayer_min"] = Double(remota.ayerMin)
            v["caldera.mes_h"] = Double(remota.mesMin) / 60
        }

        let modulos = datos["modulos"] as? [[String: Any]] ?? []
        func datosModulo(_ tipo: String) -> [String: Any]? {
            modulos.first { ($0["tipo"] as? String) == tipo }?["datos"] as? [String: Any]
        }
        if let viento = datosModulo("viento") {
            poner("viento.velocidad", num(viento["viento"]))
            poner("viento.racha", num(viento["racha"]))
            poner("viento.direccion", num(viento["direccion"]))
        } else if let viento = favoritoDatos?["viento"] as? [String: Any] {
            poner("viento.velocidad", num(viento["velocidad"]))
            poner("viento.racha", num(viento["racha"]))
            poner("viento.direccion", num(viento["direccion"]))
        }
        if let lluvia = datosModulo("lluvia") {
            poner("lluvia.actual", num(lluvia["lluvia"]))
            poner("lluvia.ultima_hora", num(lluvia["lluvia_1h"]))
            poner("lluvia.24h", num(lluvia["lluvia_24h"]))
        } else if let lluvia = favoritoDatos?["lluvia"] as? [String: Any] {
            poner("lluvia.actual", num(lluvia["actual"]))
            poner("lluvia.ultima_hora", num(lluvia["hace_1h"]))
            poner("lluvia.24h", num(lluvia["hace_24h"]))
        }
        return v
    }

    private func comprobarAvisosPeriodicos() {
        guard activo else { return }
        let ahora = Date()
        let actualizado = datos.flatMap {
            fechaDelServicio($0["actualizado"] as? String)
        } ?? lastSuccess
        let edad = actualizado.map { ahora.timeIntervalSince($0) }
        motorAvisos.comprobarObsoletos(
            edadSegundos: edad,
            ultimoIntento: lastAttempt,
            error: lastError
        )
        motorAvisos.comprobarResumen(lineas: lineasResumen())
    }

    private func lineasResumen() -> [String] {
        var lineas: [String] = []
        if modoLocalidad {
            if let datos = datos {
                let ext = datos["exterior"] as? [String: Any]
                var linea = L("Exterior: %@ · %@", fmtTemp(ext?["temperatura"]), fmtPct(ext?["humedad"]))
                if let presion = num(ext?["presion"]) {
                    linea += " · \(fmtNum(presion, 0)) mbar"
                }
                lineas.append(linea)
                let modulos = datos["modulos"] as? [[String: Any]] ?? []
                if let viento = modulos.first(where: { ($0["tipo"] as? String) == "viento" }),
                   let valores = viento["datos"] as? [String: Any] {
                    lineas.append(L("Viento: %@ km/h · racha %@ km/h", fmtNum(num(valores["viento"]), 0), fmtNum(num(valores["racha"]), 0)))
                }
                if let lluvia = modulos.first(where: { ($0["tipo"] as? String) == "lluvia" }),
                   let valores = lluvia["datos"] as? [String: Any] {
                    lineas.append(L("Lluvia: %@ mm · %@ mm en 24 h", fmtNum(num(valores["lluvia"]), 2), fmtNum(num(valores["lluvia_24h"]), 1)))
                }
                if let nombre = datos["localidad"] as? String {
                    lineas.append(L("Localidad: %@", nombre))
                }
            } else {
                lineas.append(L("Sin datos de estaciones públicas todavía."))
            }
            lineas.append(L("Avisos registrados hoy: %d", motorAvisos.contarAvisosHoy()))
            return lineas
        }
        if let datos = datos {
            let ext = datos["exterior"] as? [String: Any]
            let inte = datos["interior"] as? [String: Any]
            let termo = datos["termostato"] as? [String: Any]
            lineas.append(
                L("Exterior: mín %@ (%@) · máx %@ (%@)",
                  fmtTemp(ext?["min"]),
                  ext?["min_hora"] as? String ?? "--",
                  fmtTemp(ext?["max"]),
                  ext?["max_hora"] as? String ?? "--")
            )
            lineas.append(
                L("Interior ahora: %@ · %@ · CO₂ %@ ppm",
                  fmtTemp(inte?["temperatura"]),
                  fmtPct(inte?["humedad"]),
                  fmtNum(num(inte?["co2"]), 0))
            )
            if let temp = num(termo?["temperatura"]) {
                var linea = L("Termostato: %@", fmtTemp(temp))
                if let consigna = num(termo?["consigna"]) {
                    linea += L(" · consigna %@", fmtTemp(consigna))
                }
                lineas.append(linea)
            }
        } else {
            lineas.append(L("Sin lecturas recientes del servicio."))
        }
        if let c = caldera {
            lineas.append(
                L("Caldera: %@ hoy · %@ este mes", fmtMinutos(c.hoyMin), fmtMinutos(c.mesMin))
            )
        }
        lineas.append(L("Avisos registrados hoy: %d", motorAvisos.contarAvisosHoy()))
        return lineas
    }

    @objc private func despertar(_ notification: Notification) {
        refresh()
    }

    @objc private func salir(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    // ------------------------- ajustes -------------------------
    private func cambiarIdioma(_ codigo: String) {
        guard cfg.idioma != codigo else { return }
        cfg.idioma = codigo
        IdiomaApp.aplicar(codigo)
        cfg.save()

        // Reconstruir el menú y las ventanas secundarias con el nuevo idioma.
        buildMenu()
        reconstruirSubmenuAvisos()
        updateMenu()

        if let g = ventanaGrafica {
            let visible = g.isVisible
            g.close()
            ventanaGrafica = nil
            popupGrafica = nil
            camposGraficaClaves.removeAll()
            if visible { abrirGrafica(nil) }
        }
        if ventanaEstacion != nil {
            ventanaEstacion?.cerrar()
            ventanaEstacion = nil
        }
        if onboardingWindow != nil {
            onboardingWindow = nil
        }
        if connectWindow != nil {
            connectWindow = nil
        }

        let pos = settingsWindow?.frameOrigin
        settingsWindow?.close()
        settingsWindow = nil
        mostrarAjustes(nil)
        if let pos = pos {
            settingsWindow?.setFrameOrigin(pos)
        }
    }

    @objc private func mostrarAjustes(_ sender: Any?) {
        abrirAjustes(seccion: nil)
    }

    private func abrirAjustes(seccion: SeccionAjustes?) {
        if settingsWindow == nil {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let window = SettingsWindow(
                currentVersion: version,
                motor: motorAvisos,
                pollSeconds: cfg.pollSeconds
            )
            window.onLanguageChanged = { [weak self] codigo in
                self?.cambiarIdioma(codigo)
            }
            window.onHighlightChanged = { [weak self] enabled, color, textColor, items in
                guard let self = self else { return }
                self.cfg.highlight = enabled
                self.cfg.highlightColor = color.hexRGB
                self.cfg.highlightTextColor = textColor
                self.cfg.highlightItems = items.sorted()
                self.cfg.save()
                self.updateMenu()
            }
            window.onBarValueChanged = { [weak self] clave in
                guard let self = self else { return }
                self.cfg.barValue = clave
                self.cfg.save()
                self.updateMenu()
            }
            window.onSectionChanged = { [weak self] valor in
                guard let self = self else { return }
                self.cfg.ajustesSection = valor
                self.cfg.save()
            }
            window.onResetConnection = { [weak self] in
                self?.restablecer(nil)
            }
            window.onCambiarServicio = { [weak self] in
                self?.cambiarServicio(nil)
            }
            window.onClearHistory = { [weak self] in
                self?.borrarHistorial(nil)
            }
            window.onDiagnostics = { [weak self] in
                self?.copiarDiagnostico()
            }
            window.onBuscarEstacion = { [weak self] in
                self?.mostrarEstacionCercana(nil)
            }
            window.onEstacionPrincipalChanged = { [weak self] nombre in
                guard let self = self else { return }
                self.cfg.estacionPrincipal = nombre
                self.cfg.save()
                if let bruto = self.datosBrutos {
                    self.datos = self.datosConEstacionPrincipal(bruto)
                }
                self.updateMenu()
                self.settingsWindow?.actualizarEstaciones(
                    self.resumenEstacionesAjustes())
            }
            window.onTestNotification = { [weak self] in
                self?.probarNotificacion(nil)
            }
            #if !APPSTORE
            window.onAutoUpdateChanged = { [weak self] enabled in
                guard let self = self else { return }
                self.cfg.autoUpdate = enabled
                self.cfg.save()
                if enabled {
                    self.updateStatus = L("Comprobación automática activada.")
                    self.settingsWindow?.setStatus(self.updateStatus)
                    self.scheduleUpdateChecks()
                } else {
                    self.updateTimer?.invalidate()
                    self.updateTimer = nil
                    self.updateStatus = L("Comprobación automática desactivada.")
                    self.settingsWindow?.setStatus(self.updateStatus)
                }
            }
            window.onCheckNow = { [weak self] in
                self?.checkForUpdates(manual: true)
            }
            #endif
            settingsWindow = window
        }

        let barra = barraDisponibleAjustes()
        let resumen = resumenEstacionesAjustes()
        let seccionElegida = seccion?.rawValue ?? cfg.ajustesSection
        #if APPSTORE
        settingsWindow?.show(
            language: cfg.idioma,
            barValue: cfg.barValue,
            barra: barra,
            highlight: cfg.highlight,
            color: NSColor.desdeHex(cfg.highlightColor) ?? .systemOrange,
            textColor: cfg.highlightTextColor,
            highlightItems: Set(cfg.highlightItems),
            seccion: seccionElegida,
            resumen: resumen,
            serviceUrl: cfg.serviceUrl.isEmpty ? L("Sin configurar") : cfg.serviceUrl
        )
        #else
        settingsWindow?.show(
            language: cfg.idioma,
            barValue: cfg.barValue,
            barra: barra,
            autoUpdate: cfg.autoUpdate,
            status: updateStatus,
            highlight: cfg.highlight,
            color: NSColor.desdeHex(cfg.highlightColor) ?? .systemOrange,
            textColor: cfg.highlightTextColor,
            highlightItems: Set(cfg.highlightItems),
            seccion: seccionElegida,
            resumen: resumen,
            serviceUrl: cfg.serviceUrl.isEmpty ? L("Sin configurar") : cfg.serviceUrl
        )
        #endif
        settingsWindow?.refrescarAvisos()
    }

    private func barraDisponibleAjustes() -> [(clave: String, titulo: String)] {
        let permitidos: Set<String> = [
            "exterior", "humedad_ext", "viento", "lluvia", "ninguno",
        ]
        return VALORES_BARRA.filter { !modoLocalidad || permitidos.contains($0.0) }
    }

    // Resumen de estaciones y módulos para la sección Estaciones. Se calcula
    // al abrir Ajustes y cada vez que llega una lectura mientras está visible.
    private func resumenEstacionesAjustes() -> ResumenEstacionesAjustes {
        let publica = cfg.favorito.map {
            L("%@ (%@ km)", $0.nombre, fmtNum($0.distanciaKm, 1))
        }

        if modoLocalidad {
            var estaciones: [EstacionAjustes] = []
            if let favorito = cfg.favorito {
                estaciones.append(EstacionAjustes(nombre: favorito.nombre, modulos: []))
            }
            return ResumenEstacionesAjustes(
                modo: L("Estación pública"),
                detalle: L("Sin cuenta de Netatmo. Los datos vienen de la estación pública elegida."),
                estaciones: estaciones,
                publica: publica,
                principalActual: nil,
                principales: []
            )
        }

        guard isConnected else {
            return ResumenEstacionesAjustes(
                modo: L("Sin conexión"),
                detalle: L("Conecta tu cuenta de Netatmo para ver las estaciones y sus módulos."),
                estaciones: [],
                publica: publica,
                principalActual: nil,
                principales: []
            )
        }

        let modulos = datos?["modulos"] as? [[String: Any]] ?? []
        var orden: [String] = []
        var porEstacion: [String: [ModuloAjustes]] = [:]
        for modulo in modulos {
            var estacion = (modulo["estacion"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if estacion.isEmpty { estacion = L("Mi casa") }
            let nombre = (modulo["nombre"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let tipo = modulo["tipo"] as? String ?? ""
            let visible = nombre.isEmpty ? nombreTipoModulo(tipo) : nombre
            if porEstacion[estacion] == nil {
                porEstacion[estacion] = []
                orden.append(estacion)
            }
            porEstacion[estacion]?.append(
                ModuloAjustes(nombre: visible, tipo: nombreTipoModulo(tipo))
            )
        }

        let estaciones = orden.map {
            EstacionAjustes(nombre: $0, modulos: porEstacion[$0] ?? [])
        }
        let detalle = estaciones.isEmpty
            ? L("Aún no hay lecturas. La primera consulta rellenará esta lista.")
            : L("%d estaciones, %d módulos.", estaciones.count, modulos.count)
        return ResumenEstacionesAjustes(
            modo: L("Cuenta de Netatmo"),
            detalle: detalle,
            estaciones: estaciones,
            publica: publica,
            principalActual: cfg.estacionPrincipal.isEmpty ? nil : cfg.estacionPrincipal,
            principales: orden
        )
    }

    @objc private func copiarDiagnosticoObjc(_ sender: Any?) {
        copiarDiagnostico()
    }

    private func copiarDiagnostico() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let modo: String
        if modoLocalidad {
            modo = "localidad"
        } else if isConnected {
            modo = "cuenta"
        } else {
            modo = "sin conexión"
        }
        let modulos = (datos?["modulos"] as? [[String: Any]])?.count ?? 0
        let avisos = motorAvisos.snapshot()
        let activos = avisos.reglas.filter { $0.activo }.count
        let ultimo = (datos?["actualizado"] as? String) ?? "sin datos"
        let muestras = historialNetatmo.values.reduce(0) { $0 + $1.puntos.count }
        let consulta = lastSuccess.map {
            ISO8601DateFormatter().string(from: $0)
        } ?? "ninguna"
        let lineas = [
            "Mirlo Weather \(version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Modo: \(modo)",
            "Servicio: \(cfg.serviceUrl.isEmpty ? "sin configurar" : cfg.serviceUrl)",
            "Idioma: \(cfg.idioma)",
            "Último dato: \(ultimo)",
            "Última consulta: \(consulta)",
            "Último error: \(lastError ?? "ninguno")",
            "Módulos: \(modulos)",
            "Historial local: \(muestras) muestras",
            "Avisos: \(activos) activos de \(avisos.reglas.count)",
            "Generado: \(ISO8601DateFormatter().string(from: Date()))",
        ]
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lineas.joined(separator: "\n"), forType: .string)

        NSApp.activate(ignoringOtherApps: true)
        let alerta = NSAlert()
        alerta.messageText = L("Diagnóstico copiado")
        alerta.informativeText = L("Pégalo en el informe de un problema. No incluye tu credencial de Netatmo.")
        alerta.addButton(withTitle: L("Aceptar"))
        alerta.runModal()
    }

    #if !APPSTORE
    private func scheduleUpdateChecks() {
        #if APPSTORE
        return
        #endif
        updateTimer?.invalidate()
        updateTimer = nil
        guard cfg.autoUpdate else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.checkForUpdates(manual: false)
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates(manual: false)
        }
    }

    private func checkForUpdates(manual: Bool) {
        #if APPSTORE
        return
        #endif
        guard !checkingUpdate else { return }
        guard cfg.autoUpdate || manual else { return }
        checkingUpdate = true
        if manual {
            settingsWindow?.setChecking(true)
        }

        Updater.shared.checkForUpdate { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.checkingUpdate = false
                self.settingsWindow?.setChecking(false)

                switch result {
                case .failure(let error):
                    let message = error.localizedDescription
                    self.updateStatus = message
                    self.settingsWindow?.setStatus(message)
                    if manual {
                        self.showError(L("No se pudo buscar actualizaciones"), message)
                    }

                case .success(let release):
                    if let release = release {
                        self.availableRelease = release
                        self.updateStatus = L("Nueva versión %@ disponible.", release.version)
                        self.settingsWindow?.setStatus(self.updateStatus)
                        self.updateMenu()

                        if manual {
                            self.promptInstall(release)
                        } else if self.cfg.notifiedUpdate != release.version {
                            self.cfg.notifiedUpdate = release.version
                            self.cfg.save()
                            NotificationPresenter.shared.updateAvailable(version: release.version)
                        }
                    } else {
                        self.availableRelease = nil
                        let message = L("Estás en la última versión (%@).", Updater.shared.currentVersion)
                        self.updateStatus = message
                        self.settingsWindow?.setStatus(message)
                        self.updateMenu()

                        if manual {
                            NSApp.activate(ignoringOtherApps: true)
                            let alert = NSAlert()
                            alert.messageText = L("No hay actualizaciones")
                            alert.informativeText = L("Ya tienes la última versión disponible (%@).", Updater.shared.currentVersion)
                            alert.addButton(withTitle: L("Aceptar"))
                            alert.runModal()
                        }
                    }
                }
            }
        }
    }

    @objc private func instalarDisponible(_ sender: Any?) {
        if let release = availableRelease {
            promptInstall(release)
        }
    }

    private func promptInstall(_ release: AppRelease) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Mirlo Weather \(release.version)"
        var info = L("Tienes la versión %@. ¿Quieres descargarla e instalarla ahora?", Updater.shared.currentVersion)
        if !release.notes.isEmpty {
            info += "\n\n" + String(release.notes.prefix(900))
        }
        alert.informativeText = info
        alert.addButton(withTitle: L("Instalar y reiniciar"))
        alert.addButton(withTitle: L("Más tarde"))
        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall(release)
        }
    }

    private func downloadAndInstall(_ release: AppRelease) {
        mostrarAjustes(nil)
        updateStatus = L("Descargando la versión %@…", release.version)
        settingsWindow?.setStatus(updateStatus)
        settingsWindow?.setChecking(true)

        Updater.shared.download(release) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    self.settingsWindow?.setChecking(false)
                    self.updateStatus = L("No se pudo descargar la actualización.")
                    self.settingsWindow?.setStatus(self.updateStatus)
                    self.showError(L("No se pudo descargar la actualización"), error.localizedDescription)

                case .success(let zip):
                    self.updateStatus = L("Instalando la versión %@…", release.version)
                    self.settingsWindow?.setStatus(self.updateStatus)
                    Updater.shared.install(zipURL: zip) { installResult in
                        DispatchQueue.main.async {
                            self.settingsWindow?.setChecking(false)
                            switch installResult {
                            case .failure(let error):
                                self.updateStatus = L("No se pudo instalar la actualización.")
                                self.settingsWindow?.setStatus(self.updateStatus)
                                self.showError(L("No se pudo instalar la actualización"), error.localizedDescription)
                            case .success:
                                self.updateStatus = L("Actualización lista. Reiniciando…")
                                self.settingsWindow?.setStatus(self.updateStatus)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                    NSApp.terminate(nil)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    #endif

    @objc private func noop(_ sender: Any?) {}

    // ------------------------- avisos -------------------------
    private func showError(_ titulo: String, _ mensaje: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = titulo
        alert.informativeText = mensaje
        alert.addButton(withTitle: L("Aceptar"))
        alert.runModal()
    }

    private func pedirTexto(titulo: String, mensaje: String, valor: String,
                            completion: @escaping (String) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        let alerta = NSAlert()
        alerta.messageText = titulo
        alerta.informativeText = mensaje
        alerta.addButton(withTitle: L("Guardar"))
        alerta.addButton(withTitle: L("Cancelar"))
        let campo = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        campo.stringValue = valor
        alerta.accessoryView = campo
        alerta.window.initialFirstResponder = campo
        guard alerta.runModal() == .alertFirstButtonReturn else { return }
        completion(campo.stringValue)
    }

    // ------------------------- localidades guardadas -------------------------
    private func reconstruirSubmenuLocalidades() {
        let menu = NSMenu()
        let actual = cfg.localidad
        for (indice, loc) in cfg.localidades.enumerated() {
            let item = NSMenuItem(
                title: loc.nombre,
                action: #selector(elegirLocalidadGuardada(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = indice
            item.state = loc.nombre == actual?.nombre ? .on : .off
            item.toolTip = L("Estaciones públicas en %d km a la redonda", loc.radioKm)
            menu.addItem(item)
        }
        if !cfg.localidades.isEmpty { menu.addItem(.separator()) }

        let anadir = NSMenuItem(
            title: L("Añadir localidad…"),
            action: #selector(cambiarLocalidad(_:)),
            keyEquivalent: ""
        )
        anadir.target = self
        menu.addItem(anadir)

        let renombrar = NSMenuItem(
            title: L("Renombrar esta localidad…"),
            action: #selector(renombrarLocalidad(_:)),
            keyEquivalent: ""
        )
        renombrar.target = self
        renombrar.isEnabled = actual != nil
        menu.addItem(renombrar)

        let quitar = NSMenuItem(
            title: L("Quitar esta localidad…"),
            action: #selector(quitarLocalidad(_:)),
            keyEquivalent: ""
        )
        quitar.target = self
        quitar.isEnabled = cfg.localidades.count > 1
        menu.addItem(quitar)

        itCambiarLocalidad.title = L("Localidad")
        itCambiarLocalidad.action = nil
        itCambiarLocalidad.submenu = menu
    }

    @objc private func elegirLocalidadGuardada(_ sender: NSMenuItem) {
        guard let indice = sender.representedObject as? Int,
              indice >= 0, indice < cfg.localidades.count else { return }
        activarLocalidadGuardada(cfg.localidades[indice])
    }

    private func activarLocalidadGuardada(_ localidad: LocalidadConfig) {
        if let actual = cfg.localidad,
           actual.nombre == localidad.nombre,
           actual.lat == localidad.lat,
           actual.lon == localidad.lon {
            return
        }
        cfg.modo = "localidad"
        cfg.localidad = localidad
        if cfg.serviceUrl.isEmpty { cfg.serviceUrl = DEFAULT_SERVICE_URL }
        cfg.save()

        generacionLocalidad += 1
        refreshing = false
        datos = nil
        datosBrutos = nil
        composicionLocalidad = nil
        avisoLocalidad = nil
        estacionesLocalidad = []
        historialNetatmo.removeAll()
        moduloSinHistorial.removeAll()
        lastSuccess = nil
        lastError = nil
        needsReconnect = false
        updateMenu()
        refrescarLocalidad(manual: true)
    }

    @objc private func renombrarLocalidad(_ sender: Any?) {
        guard let actual = cfg.localidad else { return }
        pedirTexto(
            titulo: L("Renombrar localidad"),
            mensaje: L("El nombre solo se usa en este Mac para reconocerla en el menú."),
            valor: actual.nombre
        ) { [weak self] texto in
            guard let self = self else { return }
            let nuevo = texto.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nuevo.isEmpty, nuevo != actual.nombre else { return }
            guard !self.cfg.localidades.contains(where: { $0.nombre == nuevo }) else {
                self.showError(
                    L("Nombre repetido"),
                    L("Ya hay una localidad guardada con ese nombre.")
                )
                return
            }
            var renombrada = actual
            renombrada.nombre = nuevo
            if let indice = self.cfg.localidades.firstIndex(where: {
                $0.nombre == actual.nombre
            }) {
                self.cfg.localidades[indice] = renombrada
            }
            self.cfg.localidad = renombrada
            self.cfg.save()
            self.updateMenu()
        }
    }

    @objc private func quitarLocalidad(_ sender: Any?) {
        guard cfg.localidades.count > 1, let actual = cfg.localidad else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alerta = NSAlert()
        alerta.alertStyle = .warning
        alerta.messageText = L("¿Quitar «%@»?", actual.nombre)
        alerta.informativeText = L(
            "Se elimina de la lista guardada. No se borra ningún historial de lecturas."
        )
        alerta.addButton(withTitle: L("Quitar"))
        alerta.addButton(withTitle: L("Cancelar"))
        guard alerta.runModal() == .alertFirstButtonReturn else { return }
        cfg.localidades.removeAll { $0.nombre == actual.nombre }
        cfg.save()
        if let siguiente = cfg.localidades.first {
            activarLocalidadGuardada(siguiente)
        }
    }
}

// ----------------------------- entrada -----------------------------
if CommandLine.arguments.contains("--version") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "desconocida"
    print("Mirlo Weather \(version)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
