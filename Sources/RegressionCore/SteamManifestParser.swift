import Foundation

public enum SteamManifestInstallReadiness: Equatable, Sendable {
    case installed
    case inProgress
    case unknown
}

public enum SteamManifestParser {
    public static func parse(
        contents: String,
        manifestURL: URL,
        backend: BackendKind
    ) -> SteamGame? {
        guard
            let rawAppID = value(for: "appid", in: contents),
            let appID = SteamAppID.normalized(rawAppID),
            let name = value(for: "name", in: contents),
            let installDirectory = value(for: "installdir", in: contents),
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !installDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let bytes = value(for: "SizeOnDisk", in: contents)
            .flatMap(Int64.init)
            .flatMap { $0 >= 0 ? $0 : nil }
        return SteamGame(
            appID: appID,
            name: name,
            installDirectory: installDirectory,
            manifestURL: manifestURL,
            sourceBackend: backend,
            installedBytes: bytes
        )
    }

    public static func games(in steamRootURL: URL, backend: BackendKind) -> [SteamGame] {
        // Foundation no siempre enumera una URL que representa un enlace de transición o de un
        // fixture como directorio. Resolverla conserva el catálogo durante recuperación; la
        // topología final de producción exige un `steamapps` físico dentro de Regression.
        let steamAppsURL = steamRootURL
            .appendingPathComponent("steamapps", isDirectory: true)
            .resolvingSymlinksInPath()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: steamAppsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return files
            .filter { $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf" }
            .compactMap { url -> SteamGame? in
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    return nil
                }
                return parse(contents: contents, manifestURL: url, backend: backend)
            }
            .filter { $0.appID != "228980" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Distingue un manifest ya creado por Steam de una instalación utilizable.
    ///
    /// Steam escribe el ACF y crea la carpeta `common` antes de descargar el primer byte. El bit
    /// `4` de `StateFlags` representa el estado instalado; además se bloquea una descarga con
    /// contador incompleto aunque el juego estuviese previamente presente. Los manifests antiguos
    /// sin estos campos conservan el comportamiento previo y quedan como `unknown`.
    public static func installReadiness(in contents: String) -> SteamManifestInstallReadiness {
        let bytesToDownload = value(for: "BytesToDownload", in: contents).flatMap(Int64.init)
        let bytesDownloaded = value(for: "BytesDownloaded", in: contents).flatMap(Int64.init)
        if let total = bytesToDownload, total > 0,
           let downloaded = bytesDownloaded, downloaded < total {
            return .inProgress
        }

        if let rawFlags = value(for: "StateFlags", in: contents),
           let flags = Int(rawFlags) {
            return flags & 4 == 4 ? .installed : .inProgress
        }
        return .unknown
    }

    private static func value(for key: String, in contents: String) -> String? {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(?im)^\s*"\#(escapedKey)"\s+"([^"]*)""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(contents.startIndex..<contents.endIndex, in: contents)
        guard
            let match = expression.firstMatch(in: contents, range: range),
            let valueRange = Range(match.range(at: 1), in: contents)
        else {
            return nil
        }
        return String(contents[valueRange])
    }
}

/// Serializa la E/S de manifests fuera del actor principal de la interfaz.
public actor SteamLibraryScanner {
    public init() {}

    public func games(in steamRootURL: URL, backend: BackendKind) -> [SteamGame] {
        SteamManifestParser.games(in: steamRootURL, backend: backend)
    }
}

public enum PrivacySanitizer {
    public static func normalizedPath(_ path: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let home = homeDirectory.standardizedFileURL.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "$HOME" + path.dropFirst(home.count)
    }

    public static func safeArguments(_ arguments: [String]) -> [String] {
        var safe: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-applaunch", index + 1 < arguments.count {
                safe.append(argument)
                if let appID = SteamAppID.normalized(arguments[index + 1]) {
                    safe.append(appID)
                }
                index += 2
                continue
            }
            if ["-shutdown", "-silent", "--bottle", "--cx-app"].contains(argument) {
                safe.append(argument)
                if ["--bottle", "--cx-app"].contains(argument), index + 1 < arguments.count {
                    safe.append(normalizedPath(arguments[index + 1]))
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            index += 1
        }
        return safe
    }

    public static func redactedLogExcerpt(_ text: String, limit: Int = 2_000) -> String {
        var redacted = text.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "<url-redactada>",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "$HOME"
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            with: "Bearer <secreto-redactado>",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)\b(password|passwd|token|access[_-]?token|refresh[_-]?token|authorization|cookie|session(?:id)?|steamloginsecure)\b\s*[:=]\s*(\"[^\"]*\"|'[^']*'|[^\s,;]+)"#,
            with: "$1=<secreto-redactado>",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
            with: "<correo-redactado>",
            options: .regularExpression
        )
        redacted = redacted.replacingOccurrences(
            of: #"(?i)C:\\users\\[^\\\s\"']+"#,
            with: "<ruta-de-usuario-redactada>",
            options: .regularExpression
        )
        return String(redacted.prefix(limit))
    }
}

public enum ConfigurationDiffer {
    public static func difference(before: [String: String], after: [String: String]) -> ConfigurationDelta {
        var added: [String: String] = [:]
        var removed: [String: String] = [:]
        var changed: [String: ConfigurationDelta.ValueChange] = [:]

        for (key, value) in after where before[key] == nil {
            added[key] = value
        }
        for (key, value) in before where after[key] == nil {
            removed[key] = value
        }
        for (key, oldValue) in before {
            guard let newValue = after[key], oldValue != newValue else { continue }
            changed[key] = .init(before: oldValue, after: newValue)
        }
        return ConfigurationDelta(added: added, removed: removed, changed: changed)
    }
}
