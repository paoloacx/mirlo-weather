// Modo «solo localidad»: la app no necesita cuenta de Netatmo. El usuario
// escribe su localidad, el Worker busca estaciones públicas alrededor y aquí
// se elige el conjunto de datos más representativo.
import Foundation

// ----------------------------- configuración -----------------------------
struct LocalidadConfig {
    var nombre: String
    var lat: Double
    var lon: Double
    var radioKm: Int = 10
    // Si es true se ignora cualquier selección guardada y se compone sola.
    var automatico: Bool = true
    var principalId: String?
    var vientoId: String?
    var lluviaId: String?

    var diccionario: [String: Any] {
        var d: [String: Any] = [
            "nombre": nombre,
            "lat": lat,
            "lon": lon,
            "radio_km": radioKm,
            "automatico": automatico,
        ]
        if let principalId = principalId { d["principal_id"] = principalId }
        if let vientoId = vientoId { d["viento_id"] = vientoId }
        if let lluviaId = lluviaId { d["lluvia_id"] = lluviaId }
        return d
    }

    static func desde(_ raw: Any?) -> LocalidadConfig? {
        guard let d = raw as? [String: Any],
              let lat = num(d["lat"]), let lon = num(d["lon"]) else { return nil }
        let nombre = (d["nombre"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !nombre.isEmpty else { return nil }
        return LocalidadConfig(
            nombre: nombre,
            lat: lat,
            lon: lon,
            radioKm: max(1, min(20, entero(d["radio_km"]) ?? 10)),
            automatico: (d["automatico"] as? Bool) ?? true,
            principalId: d["principal_id"] as? String,
            vientoId: d["viento_id"] as? String,
            lluviaId: d["lluvia_id"] as? String
        )
    }
}

// Garantiza que la localidad activa esté en la lista, sin nombres repetidos y
// con un máximo de cinco. Devuelve true si hubo que tocar algo, para guardar
// la migración una sola vez.
func migrarLocalidades(activa: LocalidadConfig?,
                       lista: inout [LocalidadConfig]) -> Bool {
    var cambio = false
    if let activa = activa,
       !lista.contains(where: { $0.nombre == activa.nombre }) {
        lista.insert(activa, at: 0)
        cambio = true
    }
    var vistas = Set<String>()
    let sinDuplicados = lista.filter { vistas.insert($0.nombre).inserted }
    if sinDuplicados.count != lista.count {
        lista = sinDuplicados
        cambio = true
    }
    if lista.count > 5 {
        lista = Array(lista.prefix(5))
        cambio = true
    }
    return cambio
}

// ----------------------------- estación principal -----------------------------
// Sustituye las lecturas principales (interior y exterior) por las de la
// estación elegida. El termostato, el histórico y la lista de módulos no
// dependen de esta selección, así que se copian tal cual.
func aplicarEstacionPrincipal(_ json: [String: Any], estacion: String) -> [String: Any] {
    guard !estacion.isEmpty,
          let modulos = json["modulos"] as? [[String: Any]] else { return json }
    let elegidos = modulos.filter {
        (($0["estacion"] as? String) ?? "") == estacion
    }
    guard !elegidos.isEmpty else { return json }
    var copia = json
    if let exterior = elegidos.first(where: { ($0["tipo"] as? String) == "exterior" }),
       let datos = exterior["datos"] as? [String: Any], !datos.isEmpty {
        copia["exterior"] = datos
    }
    if let interior = elegidos.first(where: { ($0["tipo"] as? String) == "interior" }),
       let datos = interior["datos"] as? [String: Any], !datos.isEmpty {
        copia["interior"] = datos
    }
    return copia
}

// ----------------------------- medidas públicas -----------------------------
func medidaEstacion(_ estacion: [String: Any]?, _ clave: String) -> Double? {
    guard let medidas = estacion?["medidas"] as? [String: Any],
          let item = medidas[clave] as? [String: Any] else { return nil }
    return num(item["valor"])
}

func nombreEstacion(_ estacion: [String: Any]?) -> String {
    let nombre = (estacion?["nombre"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return nombre.isEmpty ? L("Estación cercana") : nombre
}

func distanciaEstacion(_ estacion: [String: Any]?) -> Double? {
    num(estacion?["distancia_km"])
}

func etiquetaEstacion(_ estacion: [String: Any]) -> String {
    let distancia = distanciaEstacion(estacion).map { fmtNum($0, 1) }
    let nombre = nombreEstacion(estacion)
    return distancia.map { "\(nombre) · \($0) km" } ?? nombre
}

private func mediana(_ valores: [Double]) -> Double {
    guard !valores.isEmpty else { return 0 }
    let orden = valores.sorted()
    let medio = orden.count / 2
    if orden.count % 2 == 0 {
        return (orden[medio - 1] + orden[medio]) / 2
    }
    return orden[medio]
}

private func mejorPorDistancia(
    _ estaciones: [[String: Any]],
    donde cumple: ([String: Any]) -> Bool
) -> [String: Any]? {
    estaciones.filter(cumple).min { a, b in
        let da = distanciaEstacion(a) ?? 9999
        let db = distanciaEstacion(b) ?? 9999
        if da != db { return da < db }
        return (num(a["calidad"]) ?? 0) > (num(b["calidad"]) ?? 0)
    }
}

private func estacionConId(
    _ estaciones: [[String: Any]],
    _ id: String?
) -> [String: Any]? {
    guard let id = id, !id.isEmpty else { return nil }
    return estaciones.first { ($0["id"] as? String) == id }
}

// ----------------------------- composición -----------------------------
struct ComposicionLocalidad {
    var datos: [String: Any]
    var principal: [String: Any]?
    var viento: [String: Any]?
    var lluvia: [String: Any]?
    var temperatura: Double?
    var humedad: Double?
    var presion: Double?
    var aviso: String?

    static func componer(
        estaciones: [[String: Any]],
        localidad: LocalidadConfig
    ) -> ComposicionLocalidad {
        // Estación principal: la que mejor representa la temperatura media de
        // la zona. Si no publica temperatura, se prueba humedad y presión.
        // Una selección manual manda sobre el cálculo automático.
        var principal = estacionConId(estaciones, localidad.principalId)
        if principal == nil {
            principal = mejorPorMediana(estaciones, clave: "temperatura")
                ?? mejorPorMediana(estaciones, clave: "humedad")
                ?? mejorPorMediana(estaciones, clave: "presion")
        }

        var temperatura = medidaEstacion(principal, "temperatura")
        var humedad = medidaEstacion(principal, "humedad")
        var presion = medidaEstacion(principal, "presion")
        // Si la principal no tiene alguna medida, se toma la estación cuya
        // lectura esté más cerca de la mediana de esa variable.
        if temperatura == nil {
            temperatura = medianaSeleccionada(estaciones, clave: "temperatura")
        }
        if humedad == nil {
            humedad = medianaSeleccionada(estaciones, clave: "humedad")
        }
        if presion == nil {
            presion = medianaSeleccionada(estaciones, clave: "presion")
        }

        var viento = estacionConId(estaciones, localidad.vientoId)
        if viento == nil || !tieneViento(viento) {
            viento = mejorPorDistancia(estaciones) { tieneViento($0) }
        }

        var lluvia = estacionConId(estaciones, localidad.lluviaId)
        if lluvia == nil || !tieneLluvia(lluvia) {
            lluvia = mejorPorDistancia(estaciones) { tieneLluvia($0) }
        }

        var exterior: [String: Any] = [:]
        if let temperatura = temperatura { exterior["temperatura"] = temperatura }
        if let humedad = humedad { exterior["humedad"] = humedad }
        if let presion = presion { exterior["presion"] = presion }
        let hora = Calendar.current.component(.hour, from: Date())
        exterior["es_de_dia"] = hora >= 7 && hora < 21

        var modulos: [[String: Any]] = []
        if let viento = viento, let datosViento = viento["viento"] as? [String: Any] {
            var valores: [String: Any] = [:]
            if let valor = num(datosViento["velocidad"]) { valores["viento"] = valor }
            if let valor = num(datosViento["racha"]) { valores["racha"] = valor }
            if let valor = num(datosViento["direccion"]) { valores["direccion"] = valor }
            if let valor = num(datosViento["direccion_racha"]) {
                valores["direccion_racha"] = valor
            }
            if !valores.isEmpty {
                modulos.append([
                    "tipo": "viento",
                    "estacion": nombreEstacion(viento),
                    "datos": valores,
                ])
            }
        }
        if let lluvia = lluvia, let datosLluvia = lluvia["lluvia"] as? [String: Any] {
            var valores: [String: Any] = [:]
            if let valor = num(datosLluvia["actual"]) { valores["lluvia"] = valor }
            if let valor = num(datosLluvia["hace_1h"]) { valores["lluvia_1h"] = valor }
            if let valor = num(datosLluvia["hace_24h"]) { valores["lluvia_24h"] = valor }
            if !valores.isEmpty {
                modulos.append([
                    "tipo": "lluvia",
                    "estacion": nombreEstacion(lluvia),
                    "datos": valores,
                ])
            }
        }

        var actualizadoTs = 0.0
        for estacion in [principal, viento, lluvia].compactMap({ $0 }) {
            if let ts = num(estacion["actualizado_ts"]), ts > actualizadoTs {
                actualizadoTs = ts
            }
        }
        if actualizadoTs == 0 {
            actualizadoTs = Date().timeIntervalSince1970
        }

        var datos: [String: Any] = [
            "actualizado": fechaServicioLocalidad(actualizadoTs),
            "exterior": exterior,
            "modulos": modulos,
            "localidad": localidad.nombre,
            "publico": true,
        ]

        // Se conserva la marca de tiempo para la línea «Último dato».
        datos["actualizado_ts"] = actualizadoTs

        var aviso: String?
        if temperatura == nil {
            aviso = L("No hay estaciones con temperatura cerca. Elige otra estación a mano.")
        } else if principal == nil {
            aviso = L("No se pudo elegir una estación principal. Elige una a mano.")
        }

        return ComposicionLocalidad(
            datos: datos,
            principal: principal,
            viento: viento,
            lluvia: lluvia,
            temperatura: temperatura,
            humedad: humedad,
            presion: presion,
            aviso: aviso
        )
    }

    private static func medianaSeleccionada(
        _ estaciones: [[String: Any]],
        clave: String
    ) -> Double? {
        mejorPorMediana(estaciones, clave: clave).flatMap {
            medidaEstacion($0, clave)
        }
    }

    private static func mejorPorMediana(
        _ estaciones: [[String: Any]],
        clave: String
    ) -> [String: Any]? {
        let conValor = estaciones.compactMap { estacion -> ([String: Any], Double)? in
            guard let valor = medidaEstacion(estacion, clave) else { return nil }
            return (estacion, valor)
        }
        guard !conValor.isEmpty else { return nil }
        let centro = mediana(conValor.map { $0.1 })
        return conValor.min { a, b in
            let diferenciaA = abs(a.1 - centro)
            let diferenciaB = abs(b.1 - centro)
            if diferenciaA != diferenciaB { return diferenciaA < diferenciaB }
            let distanciaA = distanciaEstacion(a.0) ?? 9999
            let distanciaB = distanciaEstacion(b.0) ?? 9999
            if distanciaA != distanciaB { return distanciaA < distanciaB }
            return (num(a.0["calidad"]) ?? 0) > (num(b.0["calidad"]) ?? 0)
        }?.0
    }

    private static func tieneViento(_ estacion: [String: Any]?) -> Bool {
        guard let viento = estacion?["viento"] as? [String: Any] else { return false }
        return num(viento["velocidad"]) != nil || num(viento["racha"]) != nil
    }

    private static func tieneLluvia(_ estacion: [String: Any]?) -> Bool {
        guard let lluvia = estacion?["lluvia"] as? [String: Any] else { return false }
        return num(lluvia["actual"]) != nil
            || num(lluvia["hace_1h"]) != nil
            || num(lluvia["hace_24h"]) != nil
    }
}

func fechaServicioLocalidad(_ ts: Double) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = .current
    return formatter.string(from: Date(timeIntervalSince1970: ts))
}
