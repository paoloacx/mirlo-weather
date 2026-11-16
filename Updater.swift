// Actualizaciones de Mirlo Weather a través de las releases de GitHub.
//
// Flujo: se consulta la última release, se compara la versión con la del
// bundle, se descarga el .zip, se comprueba la firma de código y se sustituye
// la app con un pequeño script que se ejecuta cuando la app ya se ha cerrado.
import AppKit
import Foundation

struct AppRelease {
    let version: String
    let tag: String
    let notes: String
    let assetName: String
    let assetURL: URL
}

enum UpdateError: LocalizedError {
    case noRepository
    case badResponse
    case noRelease
    case noAsset
    case invalidPackage(String)
    case signature(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .noRepository:
            return "El repositorio de actualizaciones no está configurado."
        case .badResponse:
            return "GitHub devolvió una respuesta que no se pudo leer."
        case .noRelease:
            return "No hay ninguna versión publicada todavía."
        case .noAsset:
            return "La última versión no incluye un archivo .zip para instalar."
        case .invalidPackage(let detalle):
            return "El archivo descargado no contiene una app válida. \(detalle)"
        case .signature(let detalle):
            return "La firma de la versión descargada no es válida. \(detalle)"
        case .install(let detalle):
            return "No se pudo instalar la actualización. \(detalle)"
        }
    }
}

final class Updater {
    static let shared = Updater()

    let repository: String
    let currentVersion: String
    let currentBuild: String

    private init() {
        repository = (Bundle.main.object(forInfoDictionaryKey: "MirloUpdateRepository") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    /// Busca una versión más nueva. `nil` significa que ya se está al día.
    func checkForUpdate(completion: @escaping (Result<AppRelease?, Error>) -> Void) {
        guard !repository.isEmpty else {
            completion(.failure(UpdateError.noRepository))
            return
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(.failure(UpdateError.noRepository))
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // GitHub devuelve la última release con caché de un minuto; para una
        // comprobación manual interesa el dato fresco, no el guardado.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MirloWeather/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(UpdateError.badResponse))
                return
            }
            // 404: el repositorio aún no tiene releases (o no existe). No es
            // un fallo para el usuario: simplemente no hay nada que instalar.
            if http.statusCode == 404 {
                completion(.success(nil))
                return
            }
            guard http.statusCode == 200, let data = data else {
                completion(.failure(UpdateError.badResponse))
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(.failure(UpdateError.badResponse))
                return
            }

            let tag = (json["tag_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let version = tag.lowercased().hasPrefix("v") ? String(tag.dropFirst()) : tag
            guard !version.isEmpty else {
                completion(.failure(UpdateError.noRelease))
                return
            }
            guard Updater.isVersion(version, newerThan: self.currentVersion) else {
                completion(.success(nil))
                return
            }

            let assets = json["assets"] as? [[String: Any]] ?? []
            let zips = assets.filter {
                (($0["name"] as? String) ?? "").lowercased().hasSuffix(".zip")
            }
            let chosen = zips.first {
                (($0["name"] as? String) ?? "").lowercased().contains("mirlo")
            } ?? zips.first
            guard let asset = chosen,
                  let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let assetURL = URL(string: urlString) else {
                completion(.failure(UpdateError.noAsset))
                return
            }

            let notes = (json["body"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(.success(AppRelease(
                version: version,
                tag: tag,
                notes: notes,
                assetName: name,
                assetURL: assetURL
            )))
        }.resume()
    }

    /// Descarga el .zip de la release en una carpeta temporal.
    func download(_ release: AppRelease, completion: @escaping (Result<URL, Error>) -> Void) {
        var request = URLRequest(url: release.assetURL)
        request.timeoutInterval = 120
        request.setValue("MirloWeather/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.downloadTask(with: request) { location, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let location = location else {
                completion(.failure(UpdateError.badResponse))
                return
            }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("MirloUpdate-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = release.assetName.isEmpty ? "MirloWeather.zip" : release.assetName
                let destination = folder.appendingPathComponent(name)
                try FileManager.default.moveItem(at: location, to: destination)
                completion(.success(destination))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Descomprime, verifica y programa la sustitución de la app. La app debe
    /// cerrarse justo después de recibir el éxito.
    func install(zipURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        let folder = zipURL.deletingLastPathComponent()
        let extracted = folder.appendingPathComponent("extraida", isDirectory: true)

        let unzip = Updater.runTool("/usr/bin/ditto", ["-x", "-k", zipURL.path, extracted.path])
        guard unzip.status == 0 else {
            completion(.failure(UpdateError.invalidPackage(unzip.output)))
            return
        }

        guard let newApp = Updater.findApp(in: extracted) else {
            completion(.failure(UpdateError.invalidPackage("No se encontró ninguna .app dentro del .zip.")))
            return
        }

        do {
            try verify(app: newApp)
        } catch {
            completion(.failure(error))
            return
        }

        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            completion(.failure(UpdateError.install(
                "La carpeta \(parent.path) no permite escribir. Mueve Mirlo Weather a Aplicaciones e inténtalo de nuevo."
            )))
            return
        }

        do {
            try scheduleReplacement(newApp: newApp, destination: destination, folder: folder)
            completion(.success(()))
        } catch {
            completion(.failure(UpdateError.install(error.localizedDescription)))
        }
    }

    // ------------------------- verificación -------------------------
    private func verify(app: URL) throws {
        let expectedID = Bundle.main.bundleIdentifier ?? "es.privado.netatmo-free"

        let newPlist = NSDictionary(contentsOf: app
            .appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let newID = newPlist?["CFBundleIdentifier"] as? String ?? ""
        guard newID == expectedID else {
            throw UpdateError.signature("El identificador del paquete no coincide.")
        }

        let verified = Updater.runTool("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verified.status == 0 else {
            throw UpdateError.signature(verified.output)
        }

        let details = Updater.runTool("/usr/bin/codesign", ["-dv", "--verbose=4", app.path]).output
        guard details.contains("Identifier=\(expectedID)") else {
            throw UpdateError.signature("La firma no corresponde a Mirlo Weather.")
        }

        // Si la app actual está firmada con un equipo, la nueva debe usar el
        // mismo. Así una release modificada por un tercero no se instala.
        if let team = Updater.teamIdentifier(of: Bundle.main.bundleURL), !team.isEmpty {
            guard details.contains("TeamIdentifier=\(team)") else {
                throw UpdateError.signature("El equipo de firma no coincide.")
            }
        }
    }

    private static func teamIdentifier(of app: URL) -> String? {
        let output = runTool("/usr/bin/codesign", ["-dv", "--verbose=4", app.path]).output
        for line in output.split(separator: "\n") {
            let text = String(line)
            if text.hasPrefix("TeamIdentifier=") {
                return String(text.dropFirst("TeamIdentifier=".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func findApp(in folder: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidate: URL?
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "app" else { continue }
            let executable = url.appendingPathComponent("Contents/MacOS")
            if FileManager.default.fileExists(atPath: executable.path) {
                if url.lastPathComponent == "Mirlo Weather.app" { return url }
                if candidate == nil { candidate = url }
            }
            enumerator.skipDescendants()
        }
        return candidate
    }

    // ------------------------- sustitución -------------------------
    private func scheduleReplacement(newApp: URL, destination: URL, folder: URL) throws {
        let scriptURL = folder.appendingPathComponent("instalar.sh")
        let logFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Mirlo Weather", isDirectory: true)
        try? FileManager.default.createDirectory(at: logFolder, withIntermediateDirectories: true)
        let logURL = logFolder.appendingPathComponent("actualizaciones.log")

        let script = """
        #!/bin/sh
        sleep 2
        DEST=\(Updater.quote(destination.path))
        NEW=\(Updater.quote(newApp.path))
        BACKUP="${DEST}.old"
        LOG=\(Updater.quote(logURL.path))
        exec >>"$LOG" 2>&1
        echo "--- $(date) ---"
        echo "Instalando $NEW en $DEST"
        rm -rf "$BACKUP"
        if ! mv "$DEST" "$BACKUP"; then
          echo "No se pudo apartar la app actual"
          /usr/bin/open "$DEST"
          exit 1
        fi
        if /usr/bin/ditto "$NEW" "$DEST"; then
          /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
          rm -rf "$BACKUP"
          echo "Actualización instalada"
        else
          echo "ditto falló; restaurando"
          rm -rf "$DEST"
          mv "$BACKUP" "$DEST"
        fi
        /usr/bin/open "$DEST"
        rm -rf \(Updater.quote(folder.path))
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runTool(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Compara versiones numéricas tipo 1.2.3 (ignora sufijos no numéricos).
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value
                .split(separator: ".", omittingEmptySubsequences: false)
                .map { component in
                    let digits = component.prefix { $0.isNumber }
                    return Int(digits) ?? 0
                }
        }
        let a = parts(candidate)
        let b = parts(current)
        let count = max(a.count, b.count)
        for index in 0..<count {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }
}
