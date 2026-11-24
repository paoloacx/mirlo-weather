// Avisos configurables de Mirlo Weather.
//
// Migrado de la app personal netatmo-menubar y adaptado a los datos del
// servicio multiusuario: reglas por umbral, operadores, duración, anti-spam,
// silencios, horario de no molestar, resumen diario, datos obsoletos y
// registro local. Todo se guarda solo en este Mac.
import Cocoa
import UniformTypeIdentifiers
import UserNotifications

let AVISOS_ESTADO_PATH = CONFIG_DIR.appendingPathComponent("avisos-estado.json")
let AVISOS_LOG_PATH = CONFIG_DIR.appendingPathComponent("avisos.jsonl")
let AVISOS_HIST_PATH = CONFIG_DIR.appendingPathComponent("historial.jsonl")
let AVISOS_HIST_MAX_BYTES = 700_000
let AVISOS_HIST_KEEP_LINEAS = 6_000

// ----------------------------- modelo de reglas -----------------------------
// Una regla compara un campo con un umbral. Operadores:
// gt, gte, lt, lte, eq (un valor), fuera / dentro (rango valor..valor2).
// duracionMin: la condición debe cumplirse tantos minutos seguidos (0 = ya).
// esperaMin: no repetir el aviso antes de esos minutos (anti-spam).
struct ReglaAviso {
    var id: String
    var nombre: String
    var campo: String
    var operador: String
    var valor: Double
    var valor2: Double?
    var duracionMin: Int
    var esperaMin: Int
    var activo: Bool

    var diccionario: [String: Any] {
        var d: [String: Any] = [
            "id": id, "nombre": nombre, "campo": campo,
            "operador": operador, "valor": valor,
            "duracion_min": duracionMin, "espera_min": esperaMin,
            "activo": activo,
        ]
        if let v2 = valor2 { d["valor2"] = v2 }
        return d
    }

    static func desde(_ d: [String: Any]) -> ReglaAviso? {
        guard let campo = d["campo"] as? String,
              let operador = d["operador"] as? String,
              let valor = num(d["valor"]),
              CAMPOS_AVISO.contains(where: { $0.clave == campo }),
              ["gt", "gte", "lt", "lte", "eq", "fuera", "dentro"].contains(operador)
        else { return nil }
        return ReglaAviso(
            id: d["id"] as? String ?? UUID().uuidString,
            nombre: d["nombre"] as? String ?? L("Aviso"),
            campo: campo,
            operador: operador,
            valor: valor,
            valor2: num(d["valor2"]),
            duracionMin: max(0, entero(d["duracion_min"]) ?? 0),
            esperaMin: max(1, entero(d["espera_min"]) ?? 60),
            activo: d["activo"] as? Bool ?? true
        )
    }
}

struct CampoAviso {
    let clave: String
    let nombre: String
    let unidad: String
    let decimales: Int
}

var CAMPOS_AVISO: [CampoAviso] {
    [
        CampoAviso(clave: "exterior.temperatura", nombre: L("Temperatura exterior"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "exterior.humedad", nombre: L("Humedad exterior"), unidad: "%", decimales: 0),
        CampoAviso(clave: "exterior.min", nombre: L("Mínima exterior de hoy"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "exterior.max", nombre: L("Máxima exterior de hoy"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "interior.temperatura", nombre: L("Temperatura interior"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "interior.humedad", nombre: L("Humedad interior"), unidad: "%", decimales: 0),
        CampoAviso(clave: "interior.co2", nombre: L("CO₂ interior"), unidad: "ppm", decimales: 0),
        CampoAviso(clave: "interior.ruido", nombre: L("Ruido interior"), unidad: "dB", decimales: 0),
        CampoAviso(clave: "interior.presion", nombre: L("Presión interior"), unidad: "mbar", decimales: 0),
        CampoAviso(clave: "termostato.temperatura", nombre: L("Temperatura del termostato"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "termostato.consigna", nombre: L("Consigna del termostato"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "caldera.encendida", nombre: L("Caldera encendida (1 = sí, 0 = no)"), unidad: "", decimales: 0),
        CampoAviso(clave: "caldera.hoy_min", nombre: L("Caldera encendida hoy"), unidad: "min", decimales: 0),
        CampoAviso(clave: "caldera.ayer_min", nombre: L("Caldera encendida ayer"), unidad: "min", decimales: 0),
        CampoAviso(clave: "caldera.mes_h", nombre: L("Caldera encendida este mes"), unidad: "h", decimales: 1),
        // Viento y lluvia: propios o de la estación cercana favorita.
        CampoAviso(clave: "viento.velocidad", nombre: L("Viento"), unidad: "km/h", decimales: 0),
        CampoAviso(clave: "viento.racha", nombre: L("Racha de viento"), unidad: "km/h", decimales: 0),
        CampoAviso(clave: "viento.direccion", nombre: L("Dirección del viento"), unidad: "°", decimales: 0),
        CampoAviso(clave: "lluvia.actual", nombre: L("Lluvia actual"), unidad: "mm", decimales: 2),
        CampoAviso(clave: "lluvia.ultima_hora", nombre: L("Lluvia en la última hora"), unidad: "mm", decimales: 1),
        CampoAviso(clave: "lluvia.24h", nombre: L("Lluvia en 24 h"), unidad: "mm", decimales: 1),
        // Tendencias: diferencia entre el valor actual y el de hace 30/60 min.
        // Un valor negativo en temperatura/CO₂ significa que está bajando.
        CampoAviso(clave: "interior.temperatura_cambio_30m", nombre: L("Cambio de temperatura interior en 30 min"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "interior.temperatura_cambio_60m", nombre: L("Cambio de temperatura interior en 60 min"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "interior.co2_cambio_30m", nombre: L("Cambio de CO₂ interior en 30 min"), unidad: "ppm", decimales: 0),
        CampoAviso(clave: "interior.humedad_cambio_30m", nombre: L("Cambio de humedad interior en 30 min"), unidad: "%", decimales: 0),
        CampoAviso(clave: "exterior.temperatura_cambio_30m", nombre: L("Cambio de temperatura exterior en 30 min"), unidad: "°C", decimales: 1),
        CampoAviso(clave: "exterior.temperatura_cambio_60m", nombre: L("Cambio de temperatura exterior en 60 min"), unidad: "°C", decimales: 1),
    ]
}

func campoAviso(_ clave: String) -> CampoAviso {
    CAMPOS_AVISO.first(where: { $0.clave == clave })
        ?? CampoAviso(clave: clave, nombre: clave, unidad: "", decimales: 1)
}

func operadorNombre(_ op: String) -> String {
    switch op {
    case "gt": return L("por encima de")
    case "gte": return L("igual o por encima de")
    case "lt": return L("por debajo de")
    case "lte": return L("igual o por debajo de")
    case "eq": return L("igual a")
    case "fuera": return L("fuera del rango")
    case "dentro": return L("dentro del rango")
    default: return op
    }
}

func descripcionRegla(_ r: ReglaAviso) -> String {
    let c = campoAviso(r.campo)
    let v1 = fmtNum(r.valor, c.decimales)
    let u = c.unidad.isEmpty ? "" : " " + c.unidad
    let base: String
    if r.operador == "fuera" || r.operador == "dentro" {
        let v2 = fmtNum(r.valor2, c.decimales)
        base = "\(c.nombre) \(operadorNombre(r.operador)) \(v1)–\(v2)\(u)"
    } else {
        base = "\(c.nombre) \(operadorNombre(r.operador)) \(v1)\(u)"
    }
    var extras: [String] = []
    if r.duracionMin > 0 { extras.append(L("durante %d min", r.duracionMin)) }
    if r.esperaMin > 0 { extras.append(L("máx. 1 aviso cada %d min", r.esperaMin)) }
    return extras.isEmpty ? base : base + " · " + extras.joined(separator: " · ")
}

func reglasAvisoPorDefecto() -> [ReglaAviso] {
    [
        ReglaAviso(id: "ejemplo-co2", nombre: L("CO₂ alto"), campo: "interior.co2",
                   operador: "gt", valor: 1200, valor2: nil,
                   duracionMin: 10, esperaMin: 120, activo: false),
        ReglaAviso(id: "ejemplo-humedad", nombre: L("Humedad interior alta"), campo: "interior.humedad",
                   operador: "gt", valor: 65, valor2: nil,
                   duracionMin: 30, esperaMin: 240, activo: false),
        ReglaAviso(id: "ejemplo-frio", nombre: L("Frío exterior"), campo: "exterior.temperatura",
                   operador: "lt", valor: 2, valor2: nil,
                   duracionMin: 0, esperaMin: 180, activo: false),
        ReglaAviso(id: "ejemplo-caldera", nombre: L("Caldera encendida muchas horas hoy"),
                   campo: "caldera.hoy_min", operador: "gte", valor: 240, valor2: nil,
                   duracionMin: 0, esperaMin: 240, activo: false),
        ReglaAviso(id: "ejemplo-lluvia", nombre: L("Lluvia acumulada"), campo: "lluvia.24h",
                   operador: "gte", valor: 10, valor2: nil,
                   duracionMin: 0, esperaMin: 360, activo: false),
    ]
}

// ----------------------------- configuración -----------------------------
struct ConfigAvisos {
    var activados: Bool = true
    var reglas: [ReglaAviso] = reglasAvisoPorDefecto()
    // Aviso si el servicio deja de enviar lecturas.
    var obsoletosActivo: Bool = true
    var obsoletosMin: Int = 20
    // Resumen diario a una hora concreta.
    var resumenActivo: Bool = false
    var resumenHora: Int = 21
    var resumenMinuto: Int = 0
    // Horario de no molestar (minutos desde medianoche).
    var silencioActivo: Bool = false
    var silencioDesde: Int = 22 * 60
    var silencioHasta: Int = 8 * 60
    // Reglas silenciadas temporalmente: id -> instante hasta el que no avisan.
    var silencios: [String: Double] = [:]

    static func desde(_ a: [String: Any]) -> ConfigAvisos {
        var c = ConfigAvisos()
        c.activados = a["activados"] as? Bool ?? true
        if let lista = a["reglas"] as? [[String: Any]] {
            c.reglas = lista.compactMap { ReglaAviso.desde($0) }
        }
        c.obsoletosActivo = a["obsoletos_activo"] as? Bool ?? true
        c.obsoletosMin = max(5, entero(a["obsoletos_min"]) ?? 20)
        c.resumenActivo = a["resumen_activo"] as? Bool ?? false
        c.resumenHora = min(23, max(0, entero(a["resumen_hora"]) ?? 21))
        c.resumenMinuto = min(59, max(0, entero(a["resumen_minuto"]) ?? 0))
        c.silencioActivo = a["silencio_activo"] as? Bool ?? false
        c.silencioDesde = min(1439, max(0, entero(a["silencio_desde"]) ?? 22 * 60))
        c.silencioHasta = min(1439, max(0, entero(a["silencio_hasta"]) ?? 8 * 60))
        return c
    }

    var diccionario: [String: Any] {
        [
            "activados": activados,
            "reglas": reglas.map { $0.diccionario },
            "obsoletos_activo": obsoletosActivo,
            "obsoletos_min": obsoletosMin,
            "resumen_activo": resumenActivo,
            "resumen_hora": resumenHora,
            "resumen_minuto": resumenMinuto,
            "silencio_activo": silencioActivo,
            "silencio_desde": silencioDesde,
            "silencio_hasta": silencioHasta,
        ]
    }
}

func minutosDelDia(_ fecha: Date = Date()) -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: fecha)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

func enHorarioSilencio(_ s: ConfigAvisos, _ fecha: Date = Date()) -> Bool {
    guard s.silencioActivo else { return false }
    let ahora = minutosDelDia(fecha)
    let desde = s.silencioDesde, hasta = s.silencioHasta
    if desde == hasta { return false }
    if desde < hasta { return ahora >= desde && ahora < hasta }
    // Rango nocturno, por ejemplo 22:00 -> 08:00.
    return ahora >= desde || ahora < hasta
}

func textoNumero(_ v: Double) -> String {
    if v == v.rounded() { return String(Int(v)) }
    return fmtNum(v, 2)
}

// ----------------------------- historial para tendencias -----------------------------
struct MuestraHistorial {
    let ts: Double
    let valores: [String: Double]
}

func guardarMuestraAvisos(_ valores: [String: Double]) {
    guard !valores.isEmpty else { return }
    var fila = valores
    fila["ts"] = Date().timeIntervalSince1970
    guard let data = try? JSONSerialization.data(withJSONObject: fila),
          let base = String(data: data, encoding: .utf8) else { return }
    let linea = base + "\n"
    try? FileManager.default.createDirectory(at: CONFIG_DIR, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: AVISOS_HIST_PATH.path) {
        try? linea.write(to: AVISOS_HIST_PATH, atomically: true, encoding: .utf8)
    } else if let h = try? FileHandle(forWritingTo: AVISOS_HIST_PATH) {
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(linea.utf8))
    }
    recortarHistorialAvisos()
}

func recortarHistorialAvisos() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: AVISOS_HIST_PATH.path),
          let size = attrs[FileAttributeKey.size] as? Int,
          size > AVISOS_HIST_MAX_BYTES else { return }
    guard let txt = try? String(contentsOf: AVISOS_HIST_PATH, encoding: .utf8) else { return }
    let lineas = txt.split(separator: "\n", omittingEmptySubsequences: true)
    let keep = lineas.suffix(AVISOS_HIST_KEEP_LINEAS)
    try? (keep.joined(separator: "\n") + "\n").write(
        to: AVISOS_HIST_PATH, atomically: true, encoding: .utf8
    )
}

func leerHistorialAvisos(horas: Double = 2) -> [MuestraHistorial] {
    guard let txt = try? String(contentsOf: AVISOS_HIST_PATH, encoding: .utf8) else { return [] }
    let corte = Date().timeIntervalSince1970 - horas * 3600
    var out: [MuestraHistorial] = []
    for linea in txt.split(separator: "\n") {
        guard let data = linea.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = num(d["ts"]), ts >= corte else { continue }
        var vals: [String: Double] = [:]
        for (k, v) in d where k != "ts" {
            if let n = num(v) { vals[k] = n }
        }
        if !vals.isEmpty { out.append(MuestraHistorial(ts: ts, valores: vals)) }
    }
    return out
}

// ----------------------------- archivo de avisos -----------------------------
// Formato de exportación: solo reglas, con versión. Nunca incluye historial,
// silencios ni estados de anti-spam, para que un archivo se pueda compartir
// sin llevar datos de este Mac.
enum ErrorArchivoAvisos: Error {
    case formato
    case version(Int)
    case sinReglasValidas

    var descripcion: String {
        switch self {
        case .formato:
            return L("El archivo no tiene el formato de avisos de Mirlo Weather.")
        case .version(let v):
            return L("El archivo usa una versión (%d) que esta app no entiende.", v)
        case .sinReglasValidas:
            return L("El archivo no contiene ninguna regla válida.")
        }
    }
}

enum ArchivoAvisos {
    static let version = 1

    static func exportar(_ reglas: [ReglaAviso]) -> Data? {
        let d: [String: Any] = [
            "app": "Mirlo Weather",
            "version": version,
            "reglas": reglas.map { $0.diccionario },
        ]
        return try? JSONSerialization.data(
            withJSONObject: d,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func leer(_ data: Data) -> Result<[ReglaAviso], ErrorArchivoAvisos> {
        guard let objeto = try? JSONSerialization.jsonObject(with: data),
              let d = objeto as? [String: Any] else {
            return .failure(.formato)
        }
        guard let v = entero(d["version"]) else { return .failure(.formato) }
        guard v == version else { return .failure(.version(v)) }
        guard let lista = d["reglas"] as? [[String: Any]], !lista.isEmpty else {
            return .failure(.sinReglasValidas)
        }
        var reglas: [ReglaAviso] = []
        var ids = Set<String>()
        for cruda in lista {
            guard var regla = ReglaAviso.desde(cruda) else { continue }
            // Un archivo con ids repetidos no debe hacer que dos reglas
            // compartan silencio ni historial de anti-spam.
            if ids.contains(regla.id) { regla.id = UUID().uuidString }
            ids.insert(regla.id)
            reglas.append(regla)
        }
        guard !reglas.isEmpty else { return .failure(.sinReglasValidas) }
        return .success(reglas)
    }
}

// ----------------------------- motor de avisos -----------------------------
final class MotorAvisos {
    private let lock = NSLock()
    private var cfg: ConfigAvisos
    private var ultimoDisparo: [String: Double] = [:]
    private var condDesde: [String: Double] = [:]
    private var ultimoResumenDia = ""
    private var ultimoAvisoObsoleto: Double = 0
    private var registro: [(ts: Double, texto: String)] = []
    private let appStart = Date()

    // La app guarda la config completa cuando cambia una regla o un ajuste.
    var onConfigChanged: (() -> Void)?
    // Sin permiso de notificaciones: mostrar el aviso en el menú y sonar.
    var onAvisoVisible: ((String) -> Void)?

    init(config: ConfigAvisos) {
        cfg = config
        cargarEstado()
    }

    func snapshot() -> ConfigAvisos {
        lock.lock(); defer { lock.unlock() }
        return cfg
    }

    func modificar(_ f: (inout ConfigAvisos) -> Void) {
        lock.lock()
        f(&cfg)
        lock.unlock()
        guardarEstado()
        onConfigChanged?()
    }

    func setReglas(_ reglas: [ReglaAviso]) {
        let ids = Set(reglas.map { $0.id })
        modificar { c in
            c.reglas = reglas
            c.silencios = c.silencios.filter { ids.contains($0.key) }
        }
        if reglas.contains(where: { $0.activo }) {
            NotificationPresenter.shared.pedirPermiso()
        }
    }

    func silenciarRegla(_ id: String, hasta: Double) {
        modificar { $0.silencios[id] = hasta }
        guardarEstado()
    }

    func reactivarRegla(_ id: String) {
        modificar { $0.silencios.removeValue(forKey: id) }
        guardarEstado()
    }

    func registroAvisos() -> [(ts: Double, texto: String)] {
        lock.lock(); defer { lock.unlock() }
        return registro
    }

    // ------------------------- exportar e importar -------------------------
    func exportarReglas() -> Data? {
        ArchivoAvisos.exportar(snapshot().reglas)
    }

    // Devuelve cuántas reglas se han añadido. Con `fusionar` se conservan las
    // actuales y solo entran las que no compartan id; si no, se reemplazan.
    func importarReglas(_ data: Data, fusionar: Bool)
        -> Result<Int, ErrorArchivoAvisos> {
        switch ArchivoAvisos.leer(data) {
        case .failure(let error):
            return .failure(error)
        case .success(let nuevas):
            let actuales = snapshot().reglas
            if fusionar {
                let ids = Set(actuales.map { $0.id })
                let anadidas = nuevas.filter { !ids.contains($0.id) }
                setReglas(actuales + anadidas)
                return .success(anadidas.count)
            }
            setReglas(nuevas)
            return .success(nuevas.count)
        }
    }

    func contarAvisosHoy() -> Int {
        let inicio = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        guard let txt = try? String(contentsOf: AVISOS_LOG_PATH, encoding: .utf8) else { return 0 }
        var n = 0
        for linea in txt.split(separator: "\n") {
            guard let data = linea.data(using: .utf8),
                  let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let ts = num(d["ts"]), ts >= inicio else { continue }
            n += 1
        }
        return n
    }

    // ------------------------- evaluación -------------------------
    func evaluar(valores: [String: Double], actualizado: Date?,
                 historial: [MuestraHistorial]) {
        let s = snapshot()
        guard s.activados else { return }
        let activas = s.reglas.filter { $0.activo }
        guard !activas.isEmpty else { return }
        // Nunca avisar con lecturas viejas: mejor no decir nada que mentir.
        if let actualizado = actualizado,
           Date().timeIntervalSince(actualizado) > STALE_SECONDS { return }

        let ahora = Date().timeIntervalSince1970
        let necesitaHistorial = activas.contains { $0.campo.contains("_cambio_") }
        let muestras = necesitaHistorial ? historial : []
        var disparadas: [(ReglaAviso, Double)] = []

        for r in activas {
            if ahora < (s.silencios[r.id] ?? 0) { continue }
            guard let v = valorCampo(r.campo, valores: valores, historial: muestras) else {
                condDesde.removeValue(forKey: r.id)
                continue
            }
            if !cumpleCondicion(r, v) {
                condDesde.removeValue(forKey: r.id)
                continue
            }
            if r.duracionMin > 0 {
                if let desde = condDesde[r.id] {
                    if ahora - desde < Double(r.duracionMin) * 60 { continue }
                } else {
                    condDesde[r.id] = ahora
                    continue
                }
            }
            lock.lock()
            let ultimo = ultimoDisparo[r.id] ?? 0
            lock.unlock()
            if ahora - ultimo < Double(r.esperaMin) * 60 { continue }
            lock.lock()
            ultimoDisparo[r.id] = ahora
            lock.unlock()
            condDesde.removeValue(forKey: r.id)
            disparadas.append((r, v))
        }
        guard !disparadas.isEmpty else { return }
        guardarEstado()
        for (r, v) in disparadas { dispararAviso(r, valor: v, momento: ahora) }
    }

    private func valorCampo(_ clave: String, valores: [String: Double],
                            historial: [MuestraHistorial]) -> Double? {
        if let r = clave.range(of: "_cambio_") {
            let base = String(clave[..<r.lowerBound])
            let sufijo = String(clave[r.upperBound...])   // "30m" / "60m"
            let ventana = Int(sufijo.dropLast()) ?? 30
            guard let actual = valores[base] else { return nil }
            return valorTendencia(base, actual: actual, historial: historial,
                                  ventanaMin: ventana)
        }
        return valores[clave]
    }

    // Tendencia visible en el menú y en la barra: reutiliza el mismo cálculo
    // que las reglas de aviso, con el historial local de este Mac.
    func tendencia(_ campo: String, actual: Double, ventanaMin: Int) -> Double? {
        valorTendencia(campo, actual: actual,
                       historial: leerHistorialAvisos(horas: 2),
                       ventanaMin: ventanaMin)
    }

    private func valorTendencia(_ campo: String, actual: Double,
                                historial: [MuestraHistorial],
                                ventanaMin: Int) -> Double? {
        let objetivo = Date().timeIntervalSince1970 - Double(ventanaMin) * 60
        let tolerancia = 900.0
        var mejor: MuestraHistorial?
        for m in historial where m.ts <= objetivo && m.valores[campo] != nil {
            if mejor == nil || m.ts > mejor!.ts { mejor = m }
        }
        guard let m = mejor, let pasado = m.valores[campo],
              objetivo - m.ts <= tolerancia else { return nil }
        return actual - pasado
    }

    private func cumpleCondicion(_ r: ReglaAviso, _ v: Double) -> Bool {
        switch r.operador {
        case "gt": return v > r.valor
        case "gte": return v >= r.valor
        case "lt": return v < r.valor
        case "lte": return v <= r.valor
        case "eq": return abs(v - r.valor) <= 0.05
        case "fuera", "dentro":
            let v2 = r.valor2 ?? r.valor
            let bajo = min(r.valor, v2), alto = max(r.valor, v2)
            return r.operador == "fuera" ? (v < bajo || v > alto) : (v >= bajo && v <= alto)
        default: return false
        }
    }

    // ------------------------- datos obsoletos y resumen -------------------------
    func comprobarObsoletos(edadSegundos: Double?, ultimoIntento: Date?,
                            error: String?) {
        let s = snapshot()
        guard s.activados, s.obsoletosActivo else { return }
        let ahora = Date()
        let margen = 150.0
        guard let intento = ultimoIntento,
              ahora.timeIntervalSince(intento) <= margen else { return }
        let edad = edadSegundos ?? ahora.timeIntervalSince(appStart)
        let minutos = Int(edad / 60)
        guard minutos >= s.obsoletosMin else { return }
        lock.lock()
        let yaAvisado = ahora.timeIntervalSince1970 - ultimoAvisoObsoleto < 3600
        if !yaAvisado { ultimoAvisoObsoleto = ahora.timeIntervalSince1970 }
        lock.unlock()
        guard !yaAvisado else { return }
        guardarEstado()
        let detalle = error.map { " " + L("Último error: %@.", $0) } ?? ""
        entregarAviso(
            titulo: L("Mirlo Weather · Sin datos"),
            cuerpo: L("No llegan lecturas nuevas desde hace %d min. Revisa la conexión o el servicio.", minutos) + detalle,
            texto: L("Sin datos desde hace %d min", minutos),
            id: "datos-obsoletos",
            momento: ahora.timeIntervalSince1970
        )
    }

    func comprobarResumen(lineas: [String]) {
        let s = snapshot()
        guard s.activados, s.resumenActivo else { return }
        let ahora = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: ahora)
        let dia = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        lock.lock()
        let yaEnviado = ultimoResumenDia == dia
        lock.unlock()
        guard !yaEnviado else { return }
        guard minutosDelDia(ahora) >= s.resumenHora * 60 + s.resumenMinuto else { return }
        lock.lock()
        ultimoResumenDia = dia
        lock.unlock()
        guardarEstado()
        let cuerpo = lineas.joined(separator: "\n")
        entregarAviso(
            titulo: L("Mirlo Weather · Resumen del día"),
            cuerpo: cuerpo,
            texto: L("Resumen diario: ") + lineas.joined(separator: " · "),
            id: "resumen-diario",
            momento: ahora.timeIntervalSince1970
        )
    }

    // ------------------------- entrega y registro -------------------------
    func entregarAviso(titulo: String, cuerpo: String, texto: String,
                       id: String, momento: Double, reglaId: String? = nil) {
        let s = snapshot()
        let silenciado = enHorarioSilencio(s)
        var entregado = false
        if !silenciado {
            entregado = NotificationPresenter.shared.enviar(
                titulo: titulo, cuerpo: cuerpo, reglaId: reglaId)
            if !entregado {
                DispatchQueue.main.async { [weak self] in
                    self?.onAvisoVisible?(texto)
                    NSSound(named: NSSound.Name("Glass"))?.play()
                }
            }
        }
        var fila: [String: Any] = ["ts": momento, "id": id, "texto": texto]
        if silenciado { fila["silenciado"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: fila),
              let base = String(data: data, encoding: .utf8) else { return }
        let linea = base + "\n"
        try? FileManager.default.createDirectory(at: CONFIG_DIR, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: AVISOS_LOG_PATH.path) {
            try? linea.write(to: AVISOS_LOG_PATH, atomically: true, encoding: .utf8)
        } else if let h = try? FileHandle(forWritingTo: AVISOS_LOG_PATH) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(linea.utf8))
        }
        lock.lock()
        registro.append((ts: momento, texto: (silenciado ? L("[silenciado] ") : "") + texto))
        if registro.count > 20 { registro.removeFirst(registro.count - 20) }
        lock.unlock()
    }

    private func dispararAviso(_ r: ReglaAviso, valor: Double, momento: Double) {
        let c = campoAviso(r.campo)
        let valorTxt = fmtNum(valor, c.decimales) + (c.unidad.isEmpty ? "" : " " + c.unidad)
        let texto = "\(r.nombre): \(c.nombre) = \(valorTxt)"
        let cuerpo = descripcionRegla(r) + "\n" + L("Valor actual: %@", valorTxt)
        entregarAviso(titulo: "Mirlo Weather · \(r.nombre)", cuerpo: cuerpo,
                      texto: texto, id: r.id, momento: momento, reglaId: r.id)
    }

    // ------------------------- persistencia -------------------------
    private func cargarEstado() {
        if let data = try? Data(contentsOf: AVISOS_ESTADO_PATH),
           let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let ult = d["ultimo"] as? [String: Any] {
                var m: [String: Double] = [:]
                for (k, v) in ult { if let t = num(v) { m[k] = t } }
                ultimoDisparo = m
            }
            if let sil = d["silencios"] as? [String: Any] {
                let ahora = Date().timeIntervalSince1970
                var m: [String: Double] = [:]
                for (k, v) in sil { if let t = num(v), t > ahora { m[k] = t } }
                cfg.silencios = m
            }
            if let dia = d["resumen_dia"] as? String { ultimoResumenDia = dia }
            if let t = num(d["ultimo_obsoleto"]) { ultimoAvisoObsoleto = t }
        }
        if let txt = try? String(contentsOf: AVISOS_LOG_PATH, encoding: .utf8) {
            var filas: [(ts: Double, texto: String)] = []
            for linea in txt.split(separator: "\n").suffix(20) {
                guard let data = linea.data(using: .utf8),
                      let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let ts = num(d["ts"]), let texto = d["texto"] as? String else { continue }
                filas.append((ts: ts, texto: texto))
            }
            registro = filas
        }
    }

    private func guardarEstado() {
        lock.lock()
        let s = cfg
        let ultimo = ultimoDisparo
        let dia = ultimoResumenDia
        let obsoleto = ultimoAvisoObsoleto
        lock.unlock()
        let d: [String: Any] = [
            "ultimo": ultimo,
            "silencios": s.silencios,
            "resumen_dia": dia,
            "ultimo_obsoleto": obsoleto,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: d,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? FileManager.default.createDirectory(at: CONFIG_DIR, withIntermediateDirectories: true)
        try? data.write(to: AVISOS_ESTADO_PATH, options: .atomic)
    }
}

// ----------------------------- ventana de avisos -----------------------------
final class VistaVolcado: NSView {
    override var isFlipped: Bool { true }
}

// Contenido de la sección de avisos. Es una vista reutilizable para poder
// montarla dentro de la ventana única de Ajustes sin duplicar el motor ni el
// estado. La hoja del editor se presenta sobre la ventana que la contiene.
final class VistaAvisos: NSView {
    private let motor: MotorAvisos
    private let pollSeconds: Int
    var onTestNotification: (() -> Void)?
    var hostWindow: (() -> NSWindow?)?
    private var pilaReglas: NSStackView!
    private var chkActivar: NSButton!
    private var chkObsoletos: NSButton!
    private var campoObsoletosMin: NSTextField!
    private var chkResumen: NSButton!
    private var pickerResumen: NSDatePicker!
    private var chkSilencio: NSButton!
    private var pickerDesde: NSDatePicker!
    private var pickerHasta: NSDatePicker!
    private var lblPermiso: NSTextField!
    private var btnPermiso: NSButton!
    private var editor: EditorAviso?

    init(motor: MotorAvisos, pollSeconds: Int) {
        self.motor = motor
        self.pollSeconds = pollSeconds
        super.init(frame: .zero)
        construir()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no está disponible")
    }

    private func espaciador() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    private func horaPicker(_ minutos: Int) -> NSDatePicker {
        let p = NSDatePicker()
        p.datePickerStyle = .textFieldAndStepper
        p.datePickerElements = .hourMinute
        p.dateValue = fechaConHora(minutos)
        p.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return p
    }

    private func fechaConHora(_ minutos: Int) -> Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: minutos / 60, minute: minutos % 60,
                        second: 0, of: Date()) ?? Date()
    }

    private func minutosDePicker(_ p: NSDatePicker) -> Int {
        minutosDelDia(p.dateValue)
    }

    private func construir() {
        translatesAutoresizingMaskIntoConstraints = false
        let raiz = self

        let titulo = NSTextField(labelWithString: L("Avisos por umbral"))
        titulo.font = .systemFont(ofSize: 17, weight: .semibold)
        titulo.alignment = .left

        let explicacion = NSTextField(wrappingLabelWithString:
            L("La app compara cada lectura con tus reglas y envía una notificación cuando se cumple una. Puedes exigir que la condición se mantenga unos minutos y limitar la frecuencia. También hay reglas de tendencia (cambio en 30/60 min), aviso de datos obsoletos, resumen diario y horario de no molestar. Todo se guarda solo en este Mac y se evalúa cada %d min. Los tiempos de caldera vienen del histórico oficial de Netatmo.", max(1, pollSeconds / 60)))
        explicacion.font = .systemFont(ofSize: 11)
        explicacion.textColor = .secondaryLabelColor

        chkActivar = NSButton(checkboxWithTitle: L("Activar todos los avisos"),
                              target: self, action: #selector(cambiarActivados(_:)))
        chkActivar.font = .systemFont(ofSize: 13)
        chkActivar.alignment = .left

        lblPermiso = NSTextField(labelWithString: L("Notificaciones: comprobando…"))
        lblPermiso.font = .systemFont(ofSize: 11)
        lblPermiso.textColor = .secondaryLabelColor

        btnPermiso = NSButton(title: L("Permitir"), target: self, action: #selector(accionPermiso(_:)))
        btnPermiso.bezelStyle = .rounded
        btnPermiso.controlSize = .small
        btnPermiso.isHidden = true

        let filaPermiso = NSStackView(views: [lblPermiso, espaciador(), btnPermiso])
        filaPermiso.orientation = .horizontal
        filaPermiso.alignment = .centerY
        filaPermiso.spacing = 8

        // Aviso de datos obsoletos.
        chkObsoletos = NSButton(checkboxWithTitle: L("Avisar si no hay datos durante"),
                                target: self, action: #selector(cambiarObsoletos(_:)))
        chkObsoletos.font = .systemFont(ofSize: 12)
        campoObsoletosMin = NSTextField(string: "20")
        campoObsoletosMin.alignment = .right
        campoObsoletosMin.widthAnchor.constraint(equalToConstant: 48).isActive = true
        campoObsoletosMin.target = self
        campoObsoletosMin.action = #selector(cambiarObsoletosMin(_:))
        let lblMin = NSTextField(labelWithString: L("min"))
        lblMin.textColor = .secondaryLabelColor
        let filaObsoletos = NSStackView(views: [chkObsoletos, campoObsoletosMin, lblMin, espaciador()])
        filaObsoletos.orientation = .horizontal
        filaObsoletos.alignment = .centerY
        filaObsoletos.spacing = 6

        // Resumen diario.
        chkResumen = NSButton(checkboxWithTitle: L("Resumen diario a las"),
                              target: self, action: #selector(cambiarResumen(_:)))
        chkResumen.font = .systemFont(ofSize: 12)
        pickerResumen = horaPicker(21 * 60)
        pickerResumen.target = self
        pickerResumen.action = #selector(cambiarHoraResumen(_:))
        let filaResumen = NSStackView(views: [chkResumen, pickerResumen, espaciador()])
        filaResumen.orientation = .horizontal
        filaResumen.alignment = .centerY
        filaResumen.spacing = 6

        // Horario de no molestar.
        chkSilencio = NSButton(checkboxWithTitle: L("No molestar de"),
                               target: self, action: #selector(cambiarSilencio(_:)))
        chkSilencio.font = .systemFont(ofSize: 12)
        pickerDesde = horaPicker(22 * 60)
        pickerHasta = horaPicker(8 * 60)
        pickerDesde.target = self
        pickerDesde.action = #selector(cambiarHorarioSilencio(_:))
        pickerHasta.target = self
        pickerHasta.action = #selector(cambiarHorarioSilencio(_:))
        let lblA = NSTextField(labelWithString: L("a"))
        lblA.textColor = .secondaryLabelColor
        let filaSilencio = NSStackView(views: [chkSilencio, pickerDesde, lblA, pickerHasta, espaciador()])
        filaSilencio.orientation = .horizontal
        filaSilencio.alignment = .centerY
        filaSilencio.spacing = 6

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        pilaReglas = NSStackView()
        pilaReglas.orientation = .vertical
        pilaReglas.alignment = .width
        pilaReglas.spacing = 6
        pilaReglas.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        pilaReglas.translatesAutoresizingMaskIntoConstraints = false

        let doc = VistaVolcado()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(pilaReglas)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            pilaReglas.topAnchor.constraint(equalTo: doc.topAnchor),
            pilaReglas.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            pilaReglas.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            pilaReglas.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])

        let btnAnadir = NSButton(title: L("Añadir aviso…"), target: self, action: #selector(anadirRegla(_:)))
        btnAnadir.bezelStyle = .rounded
        let btnProbar = NSButton(title: L("Probar notificación"), target: self,
                                 action: #selector(probarAviso(_:)))
        btnProbar.bezelStyle = .rounded

        // Exportar e importar viven en un menú para no llenar el pie.
        let mas = NSPopUpButton(frame: .zero, pullsDown: true)
        mas.addItem(withTitle: L("Más"))
        mas.menu?.addItem(NSMenuItem(
            title: L("Exportar avisos…"),
            action: #selector(exportarAvisos(_:)),
            keyEquivalent: ""
        ))
        mas.menu?.items.last?.target = self
        mas.menu?.addItem(NSMenuItem(
            title: L("Importar avisos…"),
            action: #selector(importarAvisos(_:)),
            keyEquivalent: ""
        ))
        mas.menu?.items.last?.target = self

        let pie = NSStackView(views: [btnAnadir, btnProbar, espaciador(), mas])
        pie.orientation = .horizontal
        pie.alignment = .centerY
        pie.spacing = 8

        let contenido = NSStackView(views: [titulo, explicacion, chkActivar,
                                            filaPermiso, filaObsoletos, filaResumen,
                                            filaSilencio, scroll, pie])
        contenido.orientation = .vertical
        contenido.alignment = .leading
        contenido.spacing = 10
        contenido.translatesAutoresizingMaskIntoConstraints = false
        raiz.addSubview(contenido)
        NSLayoutConstraint.activate([
            contenido.topAnchor.constraint(equalTo: raiz.topAnchor, constant: 16),
            contenido.leadingAnchor.constraint(equalTo: raiz.leadingAnchor, constant: 16),
            contenido.trailingAnchor.constraint(equalTo: raiz.trailingAnchor, constant: -16),
            contenido.bottomAnchor.constraint(equalTo: raiz.bottomAnchor, constant: -16),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            explicacion.widthAnchor.constraint(equalTo: contenido.widthAnchor),
            filaPermiso.widthAnchor.constraint(equalTo: contenido.widthAnchor),
            filaObsoletos.widthAnchor.constraint(equalTo: contenido.widthAnchor),
            filaResumen.widthAnchor.constraint(equalTo: contenido.widthAnchor),
            filaSilencio.widthAnchor.constraint(equalTo: contenido.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: contenido.widthAnchor),
            pie.widthAnchor.constraint(equalTo: contenido.widthAnchor),
        ])

        refresh()
    }

    func refresh() {
        let s = motor.snapshot()
        chkActivar.state = s.activados ? .on : .off
        chkObsoletos.state = s.obsoletosActivo ? .on : .off
        campoObsoletosMin.stringValue = String(s.obsoletosMin)
        campoObsoletosMin.isEnabled = s.obsoletosActivo
        chkResumen.state = s.resumenActivo ? .on : .off
        pickerResumen.dateValue = fechaConHora(s.resumenHora * 60 + s.resumenMinuto)
        pickerResumen.isEnabled = s.resumenActivo
        chkSilencio.state = s.silencioActivo ? .on : .off
        pickerDesde.dateValue = fechaConHora(s.silencioDesde)
        pickerHasta.dateValue = fechaConHora(s.silencioHasta)
        pickerDesde.isEnabled = s.silencioActivo
        pickerHasta.isEnabled = s.silencioActivo
        for v in pilaReglas.arrangedSubviews {
            pilaReglas.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if s.reglas.isEmpty {
            let vacio = NSTextField(wrappingLabelWithString:
                L("No hay avisos todavía. Crea uno con «Añadir aviso…». Ejemplos: CO₂ interior > 1200 ppm, temperatura exterior < 2 °C, caldera encendida hoy ≥ 240 min, temperatura interior baja 1,5 °C en 30 min."))
            vacio.font = .systemFont(ofSize: 12)
            vacio.textColor = .secondaryLabelColor
            pilaReglas.addArrangedSubview(vacio)
        } else {
            for r in s.reglas {
                pilaReglas.addArrangedSubview(
                    construirFila(r, snoozeHasta: s.silencios[r.id] ?? 0)
                )
            }
        }
        actualizarPermiso()
    }

    private func construirFila(_ r: ReglaAviso, snoozeHasta: Double) -> NSView {
        let fila = NSStackView()
        fila.orientation = .horizontal
        fila.alignment = .centerY
        fila.spacing = 8

        let chk = NSButton(checkboxWithTitle: "", target: self, action: #selector(cambiarRegla(_:)))
        chk.state = r.activo ? .on : .off
        chk.identifier = NSUserInterfaceItemIdentifier(r.id)
        chk.toolTip = L("Activar o pausar este aviso")

        let nombre = NSTextField(labelWithString: r.nombre)
        nombre.font = .systemFont(ofSize: 13, weight: .medium)
        let desc = NSTextField(labelWithString: descripcionRegla(r))
        desc.font = .systemFont(ofSize: 11)
        desc.textColor = .secondaryLabelColor
        let textos = NSStackView(views: [nombre, desc])
        textos.orientation = .vertical
        textos.alignment = .leading
        textos.spacing = 1
        textos.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let snoozed = snoozeHasta > Date().timeIntervalSince1970
        if snoozed {
            let f = DateFormatter()
            f.dateFormat = "dd/MM HH:mm"
            let aviso = NSTextField(labelWithString: L("Silenciada hasta %@", f.string(from: Date(timeIntervalSince1970: snoozeHasta))))
            aviso.font = .systemFont(ofSize: 10)
            aviso.textColor = .systemOrange
            textos.addArrangedSubview(aviso)
        }

        // Un solo botón «…» con las acciones de la regla. Mantiene la fila
        // compacta dentro del panel y deja el texto con espacio suficiente.
        let acciones = NSButton()
        acciones.bezelStyle = .accessoryBarAction
        acciones.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: L("Acciones del aviso")
        )
        acciones.imagePosition = .imageOnly
        acciones.target = self
        acciones.action = #selector(mostrarAccionesAviso(_:))
        acciones.identifier = NSUserInterfaceItemIdentifier(r.id)
        acciones.toolTip = L("Silenciar, editar o eliminar este aviso")
        acciones.contentTintColor = snoozed ? .systemOrange : nil

        fila.addArrangedSubview(chk)
        fila.addArrangedSubview(textos)
        fila.addArrangedSubview(espaciador())
        fila.addArrangedSubview(acciones)
        return fila
    }

    @objc private func mostrarAccionesAviso(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let estado = motor.snapshot()
        let snoozed = (estado.silencios[id] ?? 0) > Date().timeIntervalSince1970
        let menu = NSMenu()

        if snoozed {
            let reactivar = NSMenuItem(
                title: L("Reactivar"),
                action: #selector(reactivarRegla(_:)),
                keyEquivalent: ""
            )
            reactivar.target = self
            reactivar.representedObject = id
            menu.addItem(reactivar)
        } else {
            let ahora = Date().timeIntervalSince1970
            let manana = Calendar.current.date(
                bySettingHour: 8, minute: 0, second: 0,
                of: Date().addingTimeInterval(86_400)
            ) ?? Date()

            let silenciar = NSMenuItem(title: L("Silenciar"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let unaHora = NSMenuItem(
                title: L("Durante 1 hora"),
                action: #selector(aplicarSilencio(_:)),
                keyEquivalent: ""
            )
            unaHora.target = self
            unaHora.representedObject = ["id": id, "hasta": ahora + 3600]
            submenu.addItem(unaHora)
            let hastaManana = NSMenuItem(
                title: L("Hasta mañana a las 08:00"),
                action: #selector(aplicarSilencio(_:)),
                keyEquivalent: ""
            )
            hastaManana.target = self
            hastaManana.representedObject = ["id": id,
                                             "hasta": manana.timeIntervalSince1970]
            submenu.addItem(hastaManana)
            silenciar.submenu = submenu
            menu.addItem(silenciar)
        }

        let editar = NSMenuItem(title: L("Editar"), action: #selector(editarRegla(_:)),
                                keyEquivalent: "")
        editar.target = self
        editar.representedObject = id
        menu.addItem(editar)

        menu.addItem(.separator())
        let eliminar = NSMenuItem(title: L("Eliminar"), action: #selector(eliminarRegla(_:)),
                                  keyEquivalent: "")
        eliminar.target = self
        eliminar.representedObject = id
        menu.addItem(eliminar)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // Los controles de la fila y los elementos del menú llegan por vías
    // distintas; este ayudante unifica la lectura del identificador.
    private func idDeRemitente(_ sender: Any?) -> String? {
        if let boton = sender as? NSButton {
            return boton.identifier?.rawValue
        }
        if let item = sender as? NSMenuItem {
            return item.representedObject as? String
        }
        return nil
    }

    private func actualizarPermiso() {
        lblPermiso.stringValue = L("Notificaciones: comprobando…")
        btnPermiso.isHidden = true
        NotificationPresenter.shared.refrescarPermiso { [weak self] estado in
            guard let self = self else { return }
            switch estado {
            case .authorized, .provisional:
                self.lblPermiso.stringValue = L("Notificaciones: permitidas")
                self.btnPermiso.isHidden = true
            case .denied:
                self.lblPermiso.stringValue = L("Notificaciones: denegadas · el aviso sonará y quedará en el menú")
                self.btnPermiso.title = L("Abrir Ajustes")
                self.btnPermiso.isHidden = false
            case .notDetermined:
                self.lblPermiso.stringValue = L("Notificaciones: aún no autorizadas")
                self.btnPermiso.title = L("Permitir")
                self.btnPermiso.isHidden = false
            default:
                self.lblPermiso.stringValue = L("Notificaciones: estado desconocido")
                self.btnPermiso.isHidden = true
            }
        }
    }

    @objc private func cambiarActivados(_ sender: NSButton) {
        let activo = sender.state == .on
        motor.modificar { $0.activados = activo }
        if activo { NotificationPresenter.shared.pedirPermiso() }
        actualizarPermiso()
    }

    @objc private func cambiarObsoletos(_ sender: NSButton) {
        motor.modificar { $0.obsoletosActivo = sender.state == .on }
        campoObsoletosMin.isEnabled = sender.state == .on
    }

    @objc private func cambiarObsoletosMin(_ sender: NSTextField) {
        let v = min(1440, max(5, entero(sender.stringValue) ?? 20))
        sender.stringValue = String(v)
        motor.modificar { $0.obsoletosMin = v }
    }

    @objc private func cambiarResumen(_ sender: NSButton) {
        motor.modificar { $0.resumenActivo = sender.state == .on }
        pickerResumen.isEnabled = sender.state == .on
    }

    @objc private func cambiarHoraResumen(_ sender: NSDatePicker) {
        let m = minutosDePicker(sender)
        motor.modificar {
            $0.resumenHora = m / 60
            $0.resumenMinuto = m % 60
        }
    }

    @objc private func cambiarSilencio(_ sender: NSButton) {
        motor.modificar { $0.silencioActivo = sender.state == .on }
        pickerDesde.isEnabled = sender.state == .on
        pickerHasta.isEnabled = sender.state == .on
    }

    @objc private func cambiarHorarioSilencio(_ sender: NSDatePicker) {
        let desde = minutosDePicker(pickerDesde)
        let hasta = minutosDePicker(pickerHasta)
        motor.modificar {
            $0.silencioDesde = desde
            $0.silencioHasta = hasta
        }
    }

    @objc private func aplicarSilencio(_ sender: NSMenuItem) {
        guard let d = sender.representedObject as? [String: Any],
              let id = d["id"] as? String, let hasta = num(d["hasta"]) else { return }
        motor.silenciarRegla(id, hasta: hasta)
        refresh()
    }

    @objc private func reactivarRegla(_ sender: Any?) {
        guard let id = idDeRemitente(sender) else { return }
        motor.reactivarRegla(id)
        refresh()
    }

    @objc private func cambiarRegla(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var reglas = motor.snapshot().reglas
        for i in reglas.indices where reglas[i].id == id {
            reglas[i].activo = sender.state == .on
        }
        motor.setReglas(reglas)
        refresh()
    }

    @objc private func editarRegla(_ sender: Any?) {
        guard let id = idDeRemitente(sender) else { return }
        guard let r = motor.snapshot().reglas.first(where: { $0.id == id }) else { return }
        abrirEditor(r)
    }

    @objc private func eliminarRegla(_ sender: Any?) {
        guard let id = idDeRemitente(sender) else { return }
        let alerta = NSAlert()
        alerta.messageText = L("¿Eliminar este aviso?")
        alerta.informativeText = L("Podrás volver a crearlo cuando quieras.")
        alerta.addButton(withTitle: L("Eliminar"))
        alerta.addButton(withTitle: L("Cancelar"))
        if alerta.runModal() == .alertFirstButtonReturn {
            motor.setReglas(motor.snapshot().reglas.filter { $0.id != id })
            refresh()
        }
    }

    @objc private func anadirRegla(_ sender: NSButton) {
        let nueva = ReglaAviso(id: UUID().uuidString, nombre: L("Nuevo aviso"),
                               campo: "exterior.temperatura", operador: "gt",
                               valor: 30, valor2: 5, duracionMin: 0,
                               esperaMin: 60, activo: true)
        abrirEditor(nueva)
    }

    @objc private func probarAviso(_ sender: NSButton) {
        onTestNotification?()
    }

    // ------------------------- exportar e importar -------------------------
    private func alerta(_ titulo: String, _ detalle: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alerta = NSAlert()
        alerta.alertStyle = .warning
        alerta.messageText = titulo
        alerta.informativeText = detalle
        alerta.addButton(withTitle: L("Aceptar"))
        alerta.runModal()
    }

    @objc private func exportarAvisos(_ sender: Any?) {
        guard let data = motor.exportarReglas() else {
            alerta(L("No se pudieron exportar los avisos"),
                   L("No hay ninguna regla que guardar."))
            return
        }
        let panel = NSSavePanel()
        panel.title = L("Exportar avisos")
        panel.nameFieldStringValue = "Mirlo-avisos.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        let terminar: (NSApplication.ModalResponse) -> Void = { [weak self] respuesta in
            guard respuesta == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self?.alerta(L("No se pudo guardar"), error.localizedDescription)
            }
        }
        if let ventana = hostWindow?() {
            panel.beginSheetModal(for: ventana, completionHandler: terminar)
        } else {
            terminar(panel.runModal())
        }
    }

    @objc private func importarAvisos(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = L("Importar avisos")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let terminar: (NSApplication.ModalResponse) -> Void = { [weak self] respuesta in
            guard let self = self, respuesta == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else {
                self.alerta(L("No se pudo leer el archivo"),
                            L("Comprueba que el archivo existe y que puedes abrirlo."))
                return
            }
            switch ArchivoAvisos.leer(data) {
            case .failure(let error):
                self.alerta(L("No se pudo importar"), error.descripcion)
            case .success(let reglas):
                let pregunta = NSAlert()
                pregunta.messageText = L("¿Cómo quieres importar %d avisos?", reglas.count)
                pregunta.informativeText = L(
                    "Fusionar conserva los avisos actuales y añade los que no existan. Reemplazar sustituye todos por los del archivo."
                )
                pregunta.addButton(withTitle: L("Fusionar"))
                pregunta.addButton(withTitle: L("Reemplazar"))
                pregunta.addButton(withTitle: L("Cancelar"))
                let eleccion = pregunta.runModal()
                guard eleccion != .alertThirdButtonReturn else { return }
                let fusionar = eleccion == .alertFirstButtonReturn
                switch self.motor.importarReglas(data, fusionar: fusionar) {
                case .failure(let error):
                    self.alerta(L("No se pudo importar"), error.descripcion)
                case .success(let cuantas):
                    self.refresh()
                    if cuantas == 0 {
                        self.alerta(L("Avisos ya presentes"),
                                    L("No había ninguna regla nueva que añadir."))
                    }
                }
            }
        }
        if let ventana = hostWindow?() {
            panel.beginSheetModal(for: ventana, completionHandler: terminar)
        } else {
            terminar(panel.runModal())
        }
    }

    @objc private func accionPermiso(_ sender: NSButton) {
        if NotificationPresenter.shared.permiso == .denied {
            abrirAjustesNotificaciones()
        } else {
            NotificationPresenter.shared.pedirPermiso { [weak self] _ in
                self?.actualizarPermiso()
            }
        }
    }

    private func abrirAjustesNotificaciones() {
        let opciones = ["x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                        "x-apple.systempreferences:com.apple.preference.notifications"]
        for s in opciones {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    private func abrirEditor(_ regla: ReglaAviso) {
        let e = EditorAviso(regla: regla)
        e.onGuardar = { [weak self] resultado in
            guard let self = self else { return }
            defer { self.editor = nil; self.refresh() }
            guard let r = resultado else { return }
            var lista = self.motor.snapshot().reglas
            if let i = lista.firstIndex(where: { $0.id == r.id }) { lista[i] = r }
            else { lista.append(r) }
            self.motor.setReglas(lista)
        }
        editor = e
        guard let ventana = hostWindow?() ?? window else { return }
        ventana.beginSheet(e.panel) { [weak self] _ in self?.editor = nil }
    }
}

// Editor de una regla (hoja modal sobre la ventana de avisos).
final class EditorAviso: NSObject {
    var onGuardar: ((ReglaAviso?) -> Void)?
    let panel: NSPanel
    private var regla: ReglaAviso
    private var campoPopup: NSPopUpButton!
    private var operadorPopup: NSPopUpButton!
    private var valorCampo: NSTextField!
    private var valor2Campo: NSTextField!
    private var filaValor2: NSGridRow!
    private var nombreCampo: NSTextField!
    private var duracionCampo: NSTextField!
    private var esperaCampo: NSTextField!
    private var activoCheck: NSButton!
    private var errorLabel: NSTextField!
    private var lblUnidad: NSTextField!
    private var lblUnidad2: NSTextField!

    init(regla: ReglaAviso) {
        self.regla = regla
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 390),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        construir()
    }

    private func construir() {
        panel.title = L("Editar aviso")
        panel.isReleasedWhenClosed = false
        let raiz = NSView()
        panel.contentView = raiz

        nombreCampo = NSTextField(string: regla.nombre)

        campoPopup = NSPopUpButton()
        for c in CAMPOS_AVISO {
            campoPopup.addItem(withTitle: c.nombre)
            campoPopup.lastItem?.representedObject = c.clave
        }
        campoPopup.selectItem(at: CAMPOS_AVISO.firstIndex(where: { $0.clave == regla.campo }) ?? 0)
        campoPopup.target = self
        campoPopup.action = #selector(campoCambiado)

        operadorPopup = NSPopUpButton()
        let ops: [(String, String)] = [
            ("gt", L("Por encima de")), ("gte", L("Igual o por encima de")),
            ("lt", L("Por debajo de")), ("lte", L("Igual o por debajo de")),
            ("eq", L("Igual a")), ("fuera", L("Fuera del rango")),
            ("dentro", L("Dentro del rango")),
        ]
        for (clave, nombre) in ops {
            operadorPopup.addItem(withTitle: nombre)
            operadorPopup.lastItem?.representedObject = clave
        }
        operadorPopup.selectItem(at: ops.firstIndex(where: { $0.0 == regla.operador }) ?? 0)
        operadorPopup.target = self
        operadorPopup.action = #selector(operadorCambiado)

        valorCampo = NSTextField(string: textoNumero(regla.valor))
        valor2Campo = NSTextField(string: textoNumero(regla.valor2 ?? (regla.valor + 5)))
        lblUnidad = NSTextField(labelWithString: "")
        lblUnidad.textColor = .secondaryLabelColor
        lblUnidad2 = NSTextField(labelWithString: "")
        lblUnidad2.textColor = .secondaryLabelColor

        let filaValor = NSStackView(views: [valorCampo, lblUnidad])
        filaValor.orientation = .horizontal
        filaValor.spacing = 6
        let filaValor2Stack = NSStackView(views: [valor2Campo, lblUnidad2])
        filaValor2Stack.orientation = .horizontal
        filaValor2Stack.spacing = 6

        duracionCampo = NSTextField(string: String(regla.duracionMin))
        esperaCampo = NSTextField(string: String(regla.esperaMin))
        activoCheck = NSButton(checkboxWithTitle: L("Aviso activo"), target: nil, action: nil)
        activoCheck.state = regla.activo ? .on : .off

        errorLabel = NSTextField(labelWithString: "")
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11)

        let grid = NSGridView(views: [])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [etiqueta(L("Nombre")), nombreCampo])
        grid.addRow(with: [etiqueta(L("Campo")), campoPopup])
        grid.addRow(with: [etiqueta(L("Condición")), operadorPopup])
        grid.addRow(with: [etiqueta(L("Valor")), filaValor])
        filaValor2 = grid.addRow(with: [etiqueta(L("Hasta")), filaValor2Stack])
        grid.addRow(with: [etiqueta(L("Durante")), filaMinutos(duracionCampo, L("min (0 = inmediato)"))])
        grid.addRow(with: [etiqueta(L("No repetir antes de")), filaMinutos(esperaCampo, L("min"))])
        grid.addRow(with: [NSView(), activoCheck])
        grid.addRow(with: [NSView(), errorLabel])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 130
        grid.column(at: 1).xPlacement = .fill

        let guardar = NSButton(title: L("Guardar"), target: self, action: #selector(guardarRegla))
        guardar.bezelStyle = .rounded
        guardar.keyEquivalent = "\r"
        let cancelar = NSButton(title: L("Cancelar"), target: self, action: #selector(cancelar))
        cancelar.bezelStyle = .rounded
        cancelar.keyEquivalent = "\u{1b}"
        let pie = NSStackView(views: [espaciadorVacio(), cancelar, guardar])
        pie.orientation = .horizontal
        pie.spacing = 8
        pie.translatesAutoresizingMaskIntoConstraints = false

        raiz.addSubview(grid)
        raiz.addSubview(pie)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: raiz.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: raiz.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: raiz.trailingAnchor, constant: -20),
            pie.topAnchor.constraint(greaterThanOrEqualTo: grid.bottomAnchor, constant: 16),
            pie.trailingAnchor.constraint(equalTo: raiz.trailingAnchor, constant: -20),
            pie.bottomAnchor.constraint(equalTo: raiz.bottomAnchor, constant: -16),
            pie.leadingAnchor.constraint(greaterThanOrEqualTo: raiz.leadingAnchor, constant: 20),
            raiz.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
        ])

        actualizarUnidades()
        operadorCambiado()
    }

    private func etiqueta(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.alignment = .right
        return l
    }

    private func espaciadorVacio() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    private func filaMinutos(_ campo: NSTextField, _ sufijo: String) -> NSView {
        campo.widthAnchor.constraint(equalToConstant: 70).isActive = true
        let l = NSTextField(labelWithString: sufijo)
        l.textColor = .secondaryLabelColor
        l.font = .systemFont(ofSize: 11)
        let s = NSStackView(views: [campo, l])
        s.orientation = .horizontal
        s.spacing = 6
        return s
    }

    private func actualizarUnidades() {
        guard let clave = campoPopup.selectedItem?.representedObject as? String else { return }
        let u = campoAviso(clave).unidad
        lblUnidad.stringValue = u
        lblUnidad2.stringValue = u
    }

    @objc private func campoCambiado() {
        actualizarUnidades()
    }

    @objc private func operadorCambiado() {
        let op = operadorPopup.selectedItem?.representedObject as? String ?? "gt"
        filaValor2.isHidden = !(op == "fuera" || op == "dentro")
    }

    @objc private func cancelar() {
        panel.sheetParent?.endSheet(panel)
        onGuardar?(nil)
    }

    @objc private func guardarRegla() {
        let nombre = nombreCampo.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nombre.isEmpty else { mostrarError(L("Pon un nombre al aviso.")); return }
        guard let campo = campoPopup.selectedItem?.representedObject as? String else { return }
        guard let operador = operadorPopup.selectedItem?.representedObject as? String else { return }
        guard let v1 = num(valorCampo.stringValue) else {
            mostrarError(L("El valor debe ser un número.")); return
        }
        var v2: Double?
        if operador == "fuera" || operador == "dentro" {
            guard let x = num(valor2Campo.stringValue) else {
                mostrarError(L("El segundo valor del rango debe ser un número.")); return
            }
            v2 = x
        }
        let dur = max(0, Int(num(duracionCampo.stringValue) ?? 0))
        let esp = max(1, Int(num(esperaCampo.stringValue) ?? 60))
        let r = ReglaAviso(id: regla.id, nombre: nombre, campo: campo,
                           operador: operador, valor: v1, valor2: v2,
                           duracionMin: dur, esperaMin: esp,
                           activo: activoCheck.state == .on)
        panel.sheetParent?.endSheet(panel)
        onGuardar?(r)
    }

    private func mostrarError(_ t: String) {
        errorLabel.stringValue = t
    }
}
