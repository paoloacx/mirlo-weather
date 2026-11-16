// Localización (español / inglés). La clave es el texto en español: si no hay
// traducción (por ejemplo en la compilación sin .lproj) se muestra tal cual.
import Foundation

enum IdiomaApp {
    // "" o "auto" = idioma del sistema, "es" = español, "en" = inglés
    static var codigo: String = "auto"

    static var bundle: Bundle {
        let lang = codigo.trimmingCharacters(in: .whitespacesAndNewlines)
        if lang == "es" || lang == "en",
           let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }
        return Bundle.main
    }

    static var locale: Locale {
        let lang = codigo.trimmingCharacters(in: .whitespacesAndNewlines)
        if lang == "es" { return Locale(identifier: "es_ES") }
        if lang == "en" { return Locale(identifier: "en_US") }
        return Locale.current
    }

    static func aplicar(_ nuevoCodigo: String) {
        let limpio = ["es", "en"].contains(nuevoCodigo) ? nuevoCodigo : "auto"
        codigo = limpio
        if limpio == "es" || limpio == "en" {
            UserDefaults.standard.set([limpio], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }
}

/// Texto localizado. Admite argumentos con formato: L("Hay %d avisos", n).
func L(_ key: String, _ args: CVarArg...) -> String {
    let formato = IdiomaApp.bundle.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? formato : String(format: formato, locale: IdiomaApp.locale, arguments: args)
}
