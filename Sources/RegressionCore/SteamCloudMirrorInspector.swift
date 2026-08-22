import Foundation

/// Estado de un archivo declarado por la caché de Steam Cloud frente a lo que hay en disco.
public enum SteamCloudMirrorFileState: String, Equatable, Sendable {
    /// El archivo existe en el espejo local con el tamaño que la caché declara.
    case coherent
    /// La caché lo declara sincronizado pero el archivo no está en el espejo.
    case missing
    /// El archivo existe pero su tamaño no es el declarado.
    case sizeMismatch
}

public struct SteamCloudMirrorFile: Equatable, Sendable {
    public let path: String
    public let declaredSize: Int
    public let actualSize: Int?
    public let state: SteamCloudMirrorFileState

    public init(path: String, declaredSize: Int, actualSize: Int?, state: SteamCloudMirrorFileState) {
        self.path = path
        self.declaredSize = declaredSize
        self.actualSize = actualSize
        self.state = state
    }
}

public struct SteamCloudMirrorReport: Equatable, Sendable {
    public let appID: String
    public let accountID: String
    public let remoteDirectoryURL: URL
    public let files: [SteamCloudMirrorFile]

    public init(
        appID: String,
        accountID: String,
        remoteDirectoryURL: URL,
        files: [SteamCloudMirrorFile]
    ) {
        self.appID = appID
        self.accountID = accountID
        self.remoteDirectoryURL = remoteDirectoryURL
        self.files = files
    }

    public var isCoherent: Bool { files.allSatisfy { $0.state == .coherent } }
    public var incoherentFiles: [SteamCloudMirrorFile] { files.filter { $0.state != .coherent } }
}

/// Contrasta lo que `remotecache.vdf` declara sincronizado con lo que existe de verdad en el
/// espejo local de Steam Cloud.
///
/// Existe por un fallo real y caro de diagnosticar: un juego que «arranca y se cierra solo», sin
/// ventana y sin crash, porque Steam creía tener sincronizados unos archivos que no estaban donde
/// el juego los busca. Con la caché en ese estado, Steam responde «nada que descargar» y ningún
/// cambio en Wine, DXMT o los perfiles arregla nada. Ver `docs/games/core-keeper.md`.
///
/// Es **de solo lectura**: informa y no toca ni un byte de los datos del usuario.
public enum SteamCloudMirrorInspector {
    private static let maximumCacheBytes = 4 * 1024 * 1024
    private static let maximumFiles = 4_096

    /// Cuentas de usuario con datos de Steam Cloud bajo `userdata/`.
    public static func accountIDs(in steamRootURL: URL) throws -> [String] {
        let userdata = steamRootURL.appendingPathComponent("userdata", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: userdata,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            .sorted()
    }

    /// Informe por cuenta para un App ID. Devuelve vacío si ese juego no tiene caché de nube.
    public static func reports(
        appID: String,
        in steamRootURL: URL
    ) throws -> [SteamCloudMirrorReport] {
        guard let normalizedAppID = SteamAppID.normalized(appID), normalizedAppID == appID else {
            throw RegressionCoreError.invalidEvidence("el informe de nube exige un App ID válido")
        }
        var reports: [SteamCloudMirrorReport] = []
        for accountID in try accountIDs(in: steamRootURL) {
            let base = steamRootURL
                .appendingPathComponent("userdata", isDirectory: true)
                .appendingPathComponent(accountID, isDirectory: true)
                .appendingPathComponent(normalizedAppID, isDirectory: true)
            let cacheURL = base.appendingPathComponent("remotecache.vdf")
            guard let declared = try declaredFiles(at: cacheURL) else { continue }
            let remote = base.appendingPathComponent("remote", isDirectory: true)
            let files = declared.map { entry -> SteamCloudMirrorFile in
                let url = remote.appendingPathComponent(entry.path)
                let actual = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                let state: SteamCloudMirrorFileState
                if actual == nil {
                    state = .missing
                } else if actual != entry.size {
                    state = .sizeMismatch
                } else {
                    state = .coherent
                }
                return SteamCloudMirrorFile(
                    path: entry.path,
                    declaredSize: entry.size,
                    actualSize: actual,
                    state: state
                )
            }
            reports.append(SteamCloudMirrorReport(
                appID: normalizedAppID,
                accountID: accountID,
                remoteDirectoryURL: remote,
                files: files
            ))
        }
        return reports
    }

    /// Analiza `remotecache.vdf` quedándose solo con lo que aquí importa: la ruta relativa de cada
    /// archivo y el tamaño que Steam declara. El formato es VDF anidado; no se interpreta nada más
    /// para no depender de campos que Valve puede cambiar.
    private static func declaredFiles(at cacheURL: URL) throws -> [(path: String, size: Int)]? {
        guard let values = try? cacheURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maximumCacheBytes,
              let text = try? String(contentsOf: cacheURL, encoding: .utf8) else { return nil }

        var files: [(path: String, size: Int)] = []
        var pendingPath: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = quotedFields(in: line).first else { continue }
            let fields = quotedFields(in: line)
            if fields.count == 1 {
                // Una única cadena en la línea abre un bloque: es el nombre del archivo.
                pendingPath = first == "ChangeNumber" || first == "OSType" ? nil : first
            } else if fields.count >= 2, fields[0] == "size", let declared = Int(fields[1]) {
                if let path = pendingPath, declared >= 0 {
                    files.append((path, declared))
                    pendingPath = nil
                }
            }
            guard files.count <= maximumFiles else { break }
        }
        return files.isEmpty ? nil : files
    }

    private static func quotedFields(in line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inside = false
        for character in line {
            if character == "\"" {
                if inside { fields.append(current); current = "" }
                inside.toggle()
            } else if inside {
                current.append(character)
            }
        }
        return fields
    }
}
