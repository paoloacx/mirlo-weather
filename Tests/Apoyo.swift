// Apoyo para las pruebas de la lógica de avisos.
//
// Avisos.swift usa funciones y tipos que viven en main.swift (la parte de
// interfaz). Aquí se declaran versiones mínimas para poder compilar y probar
// el motor sin levantar la app. Si cambia la firma real, las pruebas dejan de
// compilar: es la señal de que hay que actualizar este archivo.

import Foundation
import UserNotifications

// Carpeta temporal propia: las pruebas nunca tocan la configuración real.
let CONFIG_DIR = FileManager.default.temporaryDirectory
    .appendingPathComponent("mirlo-pruebas", isDirectory: true)

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
    return String(format: "%.\(dec)f", v).replacingOccurrences(of: ".", with: ",")
}

let STALE_SECONDS: TimeInterval = 1200

// Las pruebas no entregan notificaciones del sistema: el motor cae en su
// camino de reserva y deja constancia en el registro local.
final class NotificationPresenter {
    static let shared = NotificationPresenter()
    var permiso: UNAuthorizationStatus = .notDetermined
    func prepare() {}
    func pedirPermiso() {}
    func pedirPermiso(completion: @escaping (Bool) -> Void) { completion(false) }
    func refrescarPermiso(completion: @escaping (UNAuthorizationStatus) -> Void) {
        completion(permiso)
    }
    func enviar(titulo: String, cuerpo: String, reglaId: String?) -> Bool { false }
}
