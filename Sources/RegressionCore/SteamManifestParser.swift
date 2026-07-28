import Foundation

public enum SteamManifestParser {
    public static func parse(
        contents: String,
        manifestURL: URL,
        backend: BackendKind
    ) -> SteamGame? {
        guard
            let appID = value(for: "appid", in: contents),
            let name = value(for: "name", in: contents),
            let installDirectory = value(for: "installdir", in: contents)
        else {
            return nil
        }

        let bytes = value(for: "SizeOnDisk", in: contents).flatMap(Int64.init)
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
        let steamAppsURL = steamRootURL.appendingPathComponent("steamapps", isDirectory: true)
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
                safe.append(arguments[index + 1].filter(\.isNumber))
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
