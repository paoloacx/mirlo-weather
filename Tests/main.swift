// Pruebas mínimas de la lógica de Mirlo Weather.
//
// Cubren el motor de avisos y el histórico local, que es donde una regresión
// se nota tarde y mal (avisos que no llegan o que llegan de más). No prueban
// la interfaz: eso se valida a mano con la app abierta.
//
// Uso: ./pruebas.command (compila Avisos.swift y ejecuta esta suite).

import Foundation

var total = 0
var fallos = 0

func comprobar(_ condicion: Bool, _ nombre: String) {
    total += 1
    if condicion {
        print("  ok    \(nombre)")
    } else {
        fallos += 1
        print("  FALLO \(nombre)")
    }
}

func seccion(_ titulo: String) {
    print("\n\(titulo)")
}

func limpiar() {
    try? FileManager.default.removeItem(at: CONFIG_DIR)
    try? FileManager.default.createDirectory(at: CONFIG_DIR,
                                             withIntermediateDirectories: true)
}

func regla(_ id: String, _ campo: String, _ operador: String, _ valor: Double,
           duracion: Int = 0, espera: Int = 60, activo: Bool = true) -> ReglaAviso {
    ReglaAviso(id: id, nombre: id, campo: campo, operador: operador,
               valor: valor, valor2: nil, duracionMin: duracion,
               esperaMin: espera, activo: activo)
}

// Escribe muestras con instantes controlados (hace N segundos).
func escribirHistorial(_ muestras: [(segundos: Double, valores: [String: Double])]) {
    limpiar()
    let ahora = Date().timeIntervalSince1970
    var texto = ""
    for m in muestras {
        var fila = m.valores
        fila["ts"] = ahora - m.segundos
        guard let data = try? JSONSerialization.data(withJSONObject: fila),
              let linea = String(data: data, encoding: .utf8) else { continue }
        texto += linea + "\n"
    }
    try? texto.write(to: AVISOS_HIST_PATH, atomically: true, encoding: .utf8)
}

func avisosRegistrados() -> [[String: Any]] {
    guard let texto = try? String(contentsOf: AVISOS_LOG_PATH, encoding: .utf8) else {
        return []
    }
    return texto.split(separator: "\n").compactMap { linea in
        guard let data = linea.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// ------------------------------ histórico ------------------------------
seccion("Histórico local")
escribirHistorial([
    (10 * 60, ["interior.temperatura": 21.0]),
    (30 * 60, ["interior.temperatura": 20.4]),
    (3 * 3600, ["interior.temperatura": 19.0]),
])
let historial2h = leerHistorialAvisos(horas: 2)
comprobar(historial2h.count == 2, "lee solo las muestras de las últimas 2 h")
comprobar(historial2h.compactMap { $0.valores["interior.temperatura"] }.sorted() == [20.4, 21.0],
          "conserva los valores de las muestras dentro de la ventana")

escribirHistorial([
    (31 * 60, ["interior.temperatura": 20.0]),
])
let motorTendencia = MotorAvisos(config: ConfigAvisos())
let subida = motorTendencia.tendencia("interior.temperatura", actual: 21.4,
                                      ventanaMin: 30)
comprobar(subida.map { abs($0 - 1.4) < 0.001 } == true,
          "tendencia de 30 min = actual − muestra de hace 31 min")
comprobar(motorTendencia.tendencia("interior.temperatura", actual: 21.4,
                                   ventanaMin: 120) == nil,
          "sin muestra dentro de la tolerancia no hay tendencia")
comprobar(motorTendencia.tendencia("exterior.temperatura", actual: 5,
                                   ventanaMin: 30) == nil,
          "un campo sin muestras no inventa tendencia")

// ------------------------------ avisos ------------------------------
seccion("Motor de avisos")
limpiar()
let motor = MotorAvisos(config: ConfigAvisos())
motor.setReglas([regla("calor", "exterior.temperatura", "gt", 25)])
motor.evaluar(valores: ["exterior.temperatura": 30], actualizado: Date(),
              historial: [])
comprobar(avisosRegistrados().count == 1, "una regla superada dispara un aviso")

motor.evaluar(valores: ["exterior.temperatura": 31], actualizado: Date(),
              historial: [])
comprobar(avisosRegistrados().count == 1,
          "la espera mínima evita repetir el mismo aviso")

limpiar()
let motorFrio = MotorAvisos(config: ConfigAvisos())
motorFrio.setReglas([regla("frio", "exterior.temperatura", "lt", 0)])
motorFrio.evaluar(valores: ["exterior.temperatura": 12], actualizado: Date(),
                  historial: [])
comprobar(avisosRegistrados().isEmpty,
          "una regla que no se cumple no dispara nada")

limpiar()
let motorApagado = MotorAvisos(config: ConfigAvisos())
motorApagado.setReglas([regla("apagada", "exterior.temperatura", "gt", 25,
                              activo: false)])
motorApagado.evaluar(valores: ["exterior.temperatura": 30], actualizado: Date(),
                     historial: [])
comprobar(avisosRegistrados().isEmpty, "una regla desactivada no dispara")

limpiar()
let motorSilencio = MotorAvisos(config: ConfigAvisos())
motorSilencio.setReglas([regla("silencio", "exterior.temperatura", "gt", 25)])
motorSilencio.silenciarRegla("silencio",
                             hasta: Date().timeIntervalSince1970 + 3600)
motorSilencio.evaluar(valores: ["exterior.temperatura": 30], actualizado: Date(),
                      historial: [])
comprobar(avisosRegistrados().isEmpty, "una regla silenciada no dispara")

limpiar()
let motorViejo = MotorAvisos(config: ConfigAvisos())
motorViejo.setReglas([regla("viejo", "exterior.temperatura", "gt", 25)])
motorViejo.evaluar(valores: ["exterior.temperatura": 30],
                   actualizado: Date().addingTimeInterval(-3600),
                   historial: [])
comprobar(avisosRegistrados().isEmpty,
          "con lecturas viejas no se avisa aunque se cumpla la regla")

limpiar()
let motorDuracion = MotorAvisos(config: ConfigAvisos())
motorDuracion.setReglas([regla("constante", "exterior.temperatura", "gt", 25,
                               duracion: 10)])
motorDuracion.evaluar(valores: ["exterior.temperatura": 30], actualizado: Date(),
                      historial: [])
comprobar(avisosRegistrados().isEmpty,
          "una regla con duración no dispara en la primera lectura")

limpiar()
let motorCambio = MotorAvisos(config: ConfigAvisos())
motorCambio.setReglas([regla("bajada", "interior.temperatura_cambio_30m",
                             "lt", -1)])
motorCambio.evaluar(valores: ["interior.temperatura": 18.4],
                    actualizado: Date(),
                    historial: [MuestraHistorial(
                        ts: Date().timeIntervalSince1970 - 31 * 60,
                        valores: ["interior.temperatura": 20.0]
                    )])
comprobar(avisosRegistrados().count == 1,
          "una regla de tendencia usa el histórico y dispara")

comprobar(motorCambio.contarAvisosHoy() == 1,
          "el contador diario incluye el aviso recién disparado")

// ------------------------------ configuración ------------------------------
seccion("Configuración")
comprobar(ReglaAviso.desde(["campo": "inventado", "operador": "gt",
                            "valor": 1]) == nil,
          "se rechaza una regla con un campo desconocido")
comprobar(ReglaAviso.desde(["campo": "interior.co2", "operador": "gt",
                            "valor": "900"]) != nil,
          "se acepta el umbral como texto numérico")
let defaults = ConfigAvisos.desde([
    "obsoletos_min": 0,
    "resumen_hora": 99,
    "silencio_desde": -5,
])
comprobar(defaults.obsoletosMin >= 5, "los minutos de datos obsoletos se acotan")
comprobar(defaults.resumenHora <= 23, "la hora del resumen se acota")
comprobar(defaults.silencioDesde >= 0, "el inicio del silencio se acota")

// --------------------------- archivo de avisos ---------------------------
seccion("Exportar e importar avisos")

limpiar()
let motorOrigen = MotorAvisos(config: ConfigAvisos())
motorOrigen.setReglas([
    regla("uno", "interior.co2", "gt", 1200),
    regla("dos", "exterior.temperatura", "lt", 2, duracion: 10),
])
guard let exportado = motorOrigen.exportarReglas() else {
    print("  FALLO no se pudo exportar")
    exit(1)
}
let objeto = (try? JSONSerialization.jsonObject(with: exportado)) as? [String: Any]
comprobar(objeto?["version"] as? Int == 1,
          "el archivo exportado lleva la versión 1")
comprobar((objeto?["reglas"] as? [[String: Any]])?.count == 2,
          "se exportan las dos reglas")
comprobar(objeto?["silencios"] == nil && objeto?["historial"] == nil,
          "el archivo no lleva silencios ni historial")

let motorDestino = MotorAvisos(config: ConfigAvisos())
let primera = motorDestino.importarReglas(exportado, fusionar: false)
comprobar((try? primera.get()) == 2,
          "importar en otro Mac reproduce las reglas")
comprobar(motorDestino.snapshot().reglas.map { $0.id } == ["uno", "dos"],
          "las reglas importadas conservan orden e identificador")
comprobar(motorDestino.snapshot().reglas.first { $0.id == "dos" }?.duracionMin == 10,
          "la duración también viaja en el archivo")

let motorFusion = MotorAvisos(config: ConfigAvisos())
motorFusion.setReglas([regla("tres", "viento.racha", "gt", 40)])
let fusion = motorFusion.importarReglas(exportado, fusionar: true)
comprobar((try? fusion.get()) == 2,
          "fusionar añade las reglas que faltan")
comprobar(motorFusion.snapshot().reglas.count == 3,
          "fusionar conserva la regla que ya existía")
comprobar((try? motorFusion.importarReglas(exportado, fusionar: true).get()) == 0,
          "volver a importar no duplica nada")

let reemplazo = motorFusion.importarReglas(exportado, fusionar: false)
comprobar((try? reemplazo.get()) == 2
            && motorFusion.snapshot().reglas.count == 2,
          "reemplazar sustituye la lista anterior")

func errorDe(_ datos: String) -> ErrorArchivoAvisos? {
    switch ArchivoAvisos.leer(Data(datos.utf8)) {
    case .failure(let e): return e
    case .success: return nil
    }
}
func esFormato(_ e: ErrorArchivoAvisos?) -> Bool {
    if case .formato? = e { return true }
    return false
}
func esVersion(_ e: ErrorArchivoAvisos?) -> Bool {
    if case .version? = e { return true }
    return false
}
func esSinReglas(_ e: ErrorArchivoAvisos?) -> Bool {
    if case .sinReglasValidas? = e { return true }
    return false
}

comprobar(esFormato(errorDe("esto no es json")),
          "un archivo que no es JSON se rechaza")
comprobar(esFormato(errorDe("{}")),
          "un archivo sin versión se rechaza")
comprobar(esVersion(errorDe(#"{"version": 99, "reglas": []}"#)),
          "una versión desconocida se rechaza")
comprobar(esSinReglas(errorDe(#"{"version": 1, "reglas": []}"#)),
          "un archivo sin reglas se rechaza")

let mezcla = #"{"version":1,"reglas":[{"id":"ok","campo":"interior.co2","operador":"gt","valor":900},{"id":"mal","campo":"inventado","operador":"gt","valor":1}]}"#
switch ArchivoAvisos.leer(Data(mezcla.utf8)) {
case .success(let reglas):
    comprobar(reglas.count == 1 && reglas[0].id == "ok",
              "las reglas no válidas se descartan sin romper el archivo")
case .failure:
    comprobar(false, "las reglas no válidas se descartan sin romper el archivo")
}

let repetidas = #"{"version":1,"reglas":[{"id":"misma","campo":"interior.co2","operador":"gt","valor":900},{"id":"misma","campo":"interior.co2","operador":"gt","valor":1000}]}"#
switch ArchivoAvisos.leer(Data(repetidas.utf8)) {
case .success(let reglas):
    comprobar(reglas.count == 2 && reglas[0].id != reglas[1].id,
              "dos reglas con el mismo id reciben identificadores distintos")
case .failure:
    comprobar(false, "dos reglas con el mismo id reciben identificadores distintos")
}

// --------------------------- localidades y estación ---------------------------
seccion("Localidades y estación principal")

let lectura: [String: Any] = [
    "exterior": ["temperatura": 99.0, "humedad": 1],
    "interior": ["temperatura": 88.0, "co2": 400],
    "termostato": ["temperatura": 21.0, "consigna": 22.0],
    "modulos": [
        ["estacion": "Casa", "tipo": "interior",
         "datos": ["temperatura": 19.8, "co2": 700]],
        ["estacion": "Casa", "tipo": "exterior",
         "datos": ["temperatura": 15.6, "humedad": 91]],
        ["estacion": "Pueblo", "tipo": "interior",
         "datos": ["temperatura": 17.2]],
        ["estacion": "Pueblo", "tipo": "exterior",
         "datos": ["temperatura": 11.4]],
    ],
]

// Netatmo marca «Casa» como principal; el usuario puede cambiarla a «Pueblo».
let porDefecto = aplicarEstacionPrincipal(lectura, estacion: "Casa")
comprobar(temperaturaExterior(porDefecto) == 15.6,
          "la estación elegida sustituye el exterior")
comprobar((porDefecto["interior"] as? [String: Any])?["temperatura"] as? Double == 19.8,
          "la estación elegida sustituye el interior")
comprobar((porDefecto["termostato"] as? [String: Any])?["consigna"] as? Double == 22.0,
          "el termostato no se toca al cambiar de estación")
comprobar((porDefecto["modulos"] as? [[String: Any]])?.count == 4,
          "la lista de módulos se conserva para la gráfica")

let otra = aplicarEstacionPrincipal(lectura, estacion: "Pueblo")
comprobar(temperaturaExterior(otra) == 11.4,
          "cambiar de estación usa sus datos exteriores")
comprobar((otra["interior"] as? [String: Any])?["temperatura"] as? Double == 17.2,
          "cambiar de estación usa sus datos interiores")

func temperaturaExterior(_ json: [String: Any]) -> Double? {
    (json["exterior"] as? [String: Any])?["temperatura"] as? Double
}

comprobar(temperaturaExterior(aplicarEstacionPrincipal(lectura, estacion: "")) == 99.0,
          "sin estación elegida se respeta la respuesta original")
comprobar(temperaturaExterior(aplicarEstacionPrincipal(lectura, estacion: "No existe")) == 99.0,
          "una estación que ya no existe no rompe la lectura")

let sinModulos: [String: Any] = ["exterior": ["temperatura": 5.0]]
comprobar(temperaturaExterior(aplicarEstacionPrincipal(sinModulos, estacion: "Casa")) == 5.0,
          "sin módulos se devuelve la lectura tal cual")

let vacia: [String: Any] = [
    "exterior": ["temperatura": 1.0],
    "modulos": [["estacion": "Casa", "tipo": "exterior", "datos": [String: Any]()]],
]
comprobar(temperaturaExterior(aplicarEstacionPrincipal(vacia, estacion: "Casa")) == 1.0,
          "un módulo sin datos no borra el exterior")

let guardada = LocalidadConfig(
    nombre: "Algete casa", lat: 40.5971, lon: -3.3744, radioKm: 12,
    automatico: false, principalId: "70:ee:50:03:be:8a",
    vientoId: nil, lluviaId: "02:00:00:03:c9:e4"
)
let idaVuelta = LocalidadConfig.desde(guardada.diccionario)
comprobar(idaVuelta?.nombre == "Algete casa"
            && idaVuelta?.radioKm == 12
            && idaVuelta?.automatico == false
            && idaVuelta?.principalId == "70:ee:50:03:be:8a"
            && idaVuelta?.lluviaId == "02:00:00:03:c9:e4",
          "una localidad guardada se lee igual que se escribió")

comprobar(LocalidadConfig.desde(["nombre": "Solo nombre"]) == nil,
          "una localidad sin coordenadas se descarta")
comprobar(LocalidadConfig.desde(["nombre": "   ", "lat": 1, "lon": 2]) == nil,
          "una localidad sin nombre se descarta")
comprobar(LocalidadConfig.desde(["nombre": "Cerca", "lat": 1, "lon": 2,
                                 "radio_km": 99])?.radioKm == 20,
          "el radio de una localidad se acota")
let conEspacios = LocalidadConfig.desde(["nombre": "  Cerca  ", "lat": 1, "lon": 2])
comprobar(conEspacios?.nombre == "Cerca",
          "el nombre de la localidad se recorta")

var listaVacia: [LocalidadConfig] = []
comprobar(!migrarLocalidades(activa: nil, lista: &listaVacia) && listaVacia.isEmpty,
          "sin localidad activa no hay nada que migrar")

let activa = LocalidadConfig(nombre: "Activa", lat: 1, lon: 2)
var listaConOtra = [LocalidadConfig(nombre: "Otra", lat: 3, lon: 4)]
comprobar(migrarLocalidades(activa: activa, lista: &listaConOtra)
            && listaConOtra.first?.nombre == "Activa"
            && listaConOtra.count == 2,
          "la localidad activa entra la primera en la lista")

var listaConActiva = [LocalidadConfig(nombre: "Activa", lat: 9, lon: 9)]
comprobar(!migrarLocalidades(activa: activa, lista: &listaConActiva)
            && listaConActiva.count == 1
            && listaConActiva[0].lat == 9,
          "si la activa ya está, no se duplica ni se pisa")

var seis = (1...6).map { LocalidadConfig(nombre: "L\($0)", lat: 1, lon: 2) }
comprobar(migrarLocalidades(activa: nil, lista: &seis) && seis.count == 5,
          "la lista se recorta a cinco localidades")

var duplicadas = [
    LocalidadConfig(nombre: "A", lat: 1, lon: 2),
    LocalidadConfig(nombre: "A", lat: 3, lon: 4),
    LocalidadConfig(nombre: "B", lat: 5, lon: 6),
]
comprobar(migrarLocalidades(activa: nil, lista: &duplicadas)
            && duplicadas.count == 2
            && duplicadas[0].lat == 1,
          "los nombres repetidos se consolidan sin reordenar")

// ------------------------------ resumen ------------------------------
print("")
if fallos == 0 {
    print("\(total) comprobaciones correctas.")
    exit(0)
} else {
    print("\(fallos) de \(total) comprobaciones han fallado.")
    exit(1)
}
