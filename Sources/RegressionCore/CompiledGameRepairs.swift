import CryptoKit
import Foundation

/// Catálogo cerrado de reparaciones que Regression sabe ejecutar.
///
/// El aprendizaje local puede reconocer uno de estos identificadores, pero no puede aportar
/// variables, rutas de DLL ni comandos. Esa separación permite reutilizar conocimiento sin
/// convertir SQLite en una superficie de ejecución.
public enum CompiledRepairRecipe: String, Codable, CaseIterable, Sendable {
    case unrealD3D11DualOverlayIsolation = "unreal-d3d11-dual-overlay-isolation-v1"
    case unityIntroWineGStreamerIsolation = "unity-intro-winegstreamer-isolation-v1"
    case unityExclusiveFullscreenBorderless = "unity-macos-focus-borderless-v1"
    case gameMakerRetinaFullscreen = "gamemaker-retina-fullscreen-v1"
}

public enum CompiledRepairClassifier {
    /// Reconoce la colisión reproducida entre el overlay de Steam, el overlay de EOS y D3D11.
    /// Todos los marcadores son obligatorios para evitar atribuir cualquier crash de Unreal a
    /// esta receta.
    public static func recipe(forCrashLog log: String) -> CompiledRepairRecipe? {
        let normalized = log.lowercased()
        let markers = [
            "unhandled exception: exception_access_violation",
            "d3d11.dll",
            "gameoverlayrenderer64.dll",
            "eosovh-win64-shipping.dll",
            "eossdk-win64-shipping.dll"
        ]
        if markers.allSatisfy(normalized.contains) {
            return .unrealD3D11DualOverlayIsolation
        }

        // Unity puede delegar el vídeo de introducción en Media Foundation. La receta solo es
        // causal cuando aparecen juntos el reproductor de Unity, el worker MF y winegstreamer;
        // una mención aislada a Unity o GStreamer no basta para aprenderla.
        let unityMediaMarkers = [
            "unityplayer.dll",
            "rtworkq.dll",
            "winegstreamer.dll",
            "media foundation",
            "videoplayer"
        ]
        if unityMediaMarkers.allSatisfy(normalized.contains) {
            return .unityIntroWineGStreamerIsolation
        }

        // Unity deja evidencia inequívoca cuando el modo exclusivo no puede conservar la
        // superficie al cambiar de escritorio: falla dos veces y revierte a otra resolución.
        // Exigimos la secuencia completa para no convertir una mención suelta a fullscreen en
        // una reparación aprendida.
        let unityExclusiveFullscreenMarkers = [
            "initialize engine version:",
            "failed to apply requested exclusivefullscreen resolution",
            "unable to apply requested exclusivefullscreen resolution again",
            "reverting to current display resolution"
        ]
        if unityExclusiveFullscreenMarkers.allSatisfy(normalized.contains) {
            return .unityExclusiveFullscreenBorderless
        }
        return nil
    }
}

public struct CompiledRepairActivation: Codable, Equatable, Sendable {
    public let executable: String
    public let recipe: CompiledRepairRecipe

    public init(executable: String, recipe: CompiledRepairRecipe) {
        self.executable = executable
        self.recipe = recipe
    }
}

public struct CompiledRepairActivationReport: Equatable, Sendable {
    public let activation: CompiledRepairActivation
    public let activationURL: URL
    public let rollbackURL: URL
    public let beforeFingerprint: String
    public let afterFingerprint: String

    public init(
        activation: CompiledRepairActivation,
        activationURL: URL,
        rollbackURL: URL,
        beforeFingerprint: String,
        afterFingerprint: String
    ) {
        self.activation = activation
        self.activationURL = activationURL
        self.rollbackURL = rollbackURL
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
    }
}

/// Persistencia tipada que permite reutilizar una receta ya auditada en otro ejecutable exacto.
///
/// El formato no acepta rutas, DLL, variables ni acciones. Cada línea solo vincula un basename
/// PE validado con un caso de `CompiledRepairRecipe`; Wine contiene la traducción cerrada del ID
/// a la acción permitida. El fichero vive dentro de la botella y nunca se sigue si es un symlink.
public enum CompiledRepairActivationStore {
    private static let header = "REGRESSION-COMPILED-REPAIRS\t1\n"
    private static let relativePath = ".regression/compiled-repair-activations-v1.tsv"
    private static let maximumBytes = 64 * 1024
    private static let maximumActivations = 128

    public static func activations(in bottleURL: URL) throws -> [CompiledRepairActivation] {
        let url = activationURL(in: bottleURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard !isSymbolicLink(url) else {
            throw RegressionCoreError.invalidEvidence("el catálogo tipado de reparación es un enlace simbólico")
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decode(data)
    }

    @discardableResult
    public static func activate(
        executable: String,
        recipe: CompiledRepairRecipe,
        in bottleURL: URL
    ) throws -> CompiledRepairActivationReport? {
        let basename = try executableBasename(executable)
        let activation = CompiledRepairActivation(executable: basename, recipe: recipe)
        var current = try activations(in: bottleURL)
        guard !current.contains(activation) else { return nil }
        guard current.count < maximumActivations else {
            throw RegressionCoreError.invalidEvidence("el catálogo tipado de reparación alcanzó su límite")
        }
        current.append(activation)
        current.sort {
            ($0.executable, $0.recipe.rawValue) < ($1.executable, $1.recipe.rawValue)
        }

        let url = activationURL(in: bottleURL)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        guard !isSymbolicLink(directory), !isSymbolicLink(url) else {
            throw RegressionCoreError.invalidEvidence("la ruta del catálogo tipado no es segura")
        }

        let before = (try? Data(contentsOf: url, options: [.mappedIfSafe])) ?? Data(header.utf8)
        let after = encode(current)
        let rollbackDirectory = directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)
        guard !isSymbolicLink(rollbackDirectory) else {
            throw RegressionCoreError.invalidEvidence("la ruta de rollback del catálogo tipado no es segura")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rollbackDirectory.path
        )
        let rollbackURL = rollbackDirectory.appendingPathComponent(
            "compiled-repair-activations-before-\(UUID().uuidString).tsv"
        )
        try before.write(to: rollbackURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: rollbackURL.path
        )
        try after.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )

        return CompiledRepairActivationReport(
            activation: activation,
            activationURL: url,
            rollbackURL: rollbackURL,
            beforeFingerprint: fingerprint(before),
            afterFingerprint: fingerprint(after)
        )
    }

    public static func activationURL(in bottleURL: URL) -> URL {
        bottleURL.appendingPathComponent(relativePath)
    }

    private static func executableBasename(_ executable: String) throws -> String {
        let components = executable.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw RegressionCoreError.invalidEvidence("el ejecutable de la activación no es válido")
        }
        let basename = String(components[components.count - 1]).lowercased()
        guard basename.hasSuffix(".exe"), basename.utf8.count < 120,
              basename.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x61...0x7a).contains(byte)
                      || byte == 0x2d || byte == 0x5f || byte == 0x2e
              }) else {
            throw RegressionCoreError.invalidEvidence("el basename PE de la activación no es válido")
        }
        return basename
    }

    private static func encode(_ activations: [CompiledRepairActivation]) -> Data {
        let body = activations.map { "\($0.executable)\t\($0.recipe.rawValue)\n" }.joined()
        return Data((header + body).utf8)
    }

    private static func decode(_ data: Data) throws -> [CompiledRepairActivation] {
        guard data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix(header) else {
            throw RegressionCoreError.invalidEvidence("el catálogo tipado de reparación no es válido")
        }
        let lines = text.dropFirst(header.count).split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count <= maximumActivations else {
            throw RegressionCoreError.invalidEvidence("el catálogo tipado de reparación excede su límite")
        }
        var result: [CompiledRepairActivation] = []
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let recipe = CompiledRepairRecipe(rawValue: String(fields[1])) else {
                throw RegressionCoreError.invalidEvidence("el catálogo contiene una receta desconocida")
            }
            let executable = try executableBasename(String(fields[0]))
            let activation = CompiledRepairActivation(executable: executable, recipe: recipe)
            guard !result.contains(activation) else {
                throw RegressionCoreError.invalidEvidence("el catálogo contiene activaciones duplicadas")
            }
            result.append(activation)
        }
        return result
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CompiledCrashRepairLearningReport: Equatable, Sendable {
    public let appID: String
    public let executable: String
    public let recipe: CompiledRepairRecipe
    public let crashLogURL: URL
    public let activation: CompiledRepairActivationReport

    public init(
        appID: String,
        executable: String,
        recipe: CompiledRepairRecipe,
        crashLogURL: URL,
        activation: CompiledRepairActivationReport
    ) {
        self.appID = appID
        self.executable = executable
        self.recipe = recipe
        self.crashLogURL = crashLogURL
        self.activation = activation
    }
}

/// Aprende únicamente una receta conocida desde un log reciente de la ejecución que acaba de
/// fallar. El recorrido se limita a AppData/Local, no sigue symlinks y tiene límites de profundidad,
/// cantidad y tamaño para que un juego no pueda convertir el diagnóstico en una exploración libre.
public enum CompiledCrashRepairLearner {
    private static let maximumFiles = 4_096
    private static let maximumDepth = 9
    private static let maximumLogBytes = 4 * 1024 * 1024

    public static func learn(
        appID: String,
        executable: String,
        bottleURL: URL,
        startedAt: Date,
        endedAt: Date
    ) throws -> CompiledCrashRepairLearningReport? {
        guard let normalizedAppID = SteamAppID.normalized(appID) else { return nil }
        let usersURL = bottleURL.appendingPathComponent("drive_c/users", isDirectory: true)
        guard FileManager.default.fileExists(atPath: usersURL.path) else { return nil }
        var budget = maximumFiles
        var candidates: [(url: URL, modifiedAt: Date)] = []
        let earliest = startedAt.addingTimeInterval(-30)
        let latest = endedAt.addingTimeInterval(30)
        try collectLogs(
            below: usersURL,
            depth: maximumDepth,
            budget: &budget,
            earliest: earliest,
            latest: latest,
            result: &candidates
        )

        for candidate in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            guard let log = try readTail(of: candidate.url),
                  logMentionsExecutable(log, executable: executable),
                  let recipe = CompiledRepairClassifier.recipe(forCrashLog: log),
                  let activation = try CompiledRepairActivationStore.activate(
                      executable: executable,
                      recipe: recipe,
                      in: bottleURL
                  ) else { continue }
            return CompiledCrashRepairLearningReport(
                appID: normalizedAppID,
                executable: activation.activation.executable,
                recipe: recipe,
                crashLogURL: candidate.url,
                activation: activation
            )
        }
        return nil
    }

    private static func collectLogs(
        below directory: URL,
        depth: Int,
        budget: inout Int,
        earliest: Date,
        latest: Date,
        result: inout [(url: URL, modifiedAt: Date)]
    ) throws {
        guard depth > 0, budget > 0,
              !isSymbolicLink(directory) else { return }
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles]
        )
        for entry in entries.sorted(by: { $0.path < $1.path }) where budget > 0 {
            budget -= 1
            let values = try entry.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                .contentModificationDateKey, .fileSizeKey
            ])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                try collectLogs(
                    below: entry,
                    depth: depth - 1,
                    budget: &budget,
                    earliest: earliest,
                    latest: latest,
                    result: &result
                )
            } else if values.isRegularFile == true,
                      entry.pathExtension.caseInsensitiveCompare("log") == .orderedSame,
                      let modifiedAt = values.contentModificationDate,
                      earliest...latest ~= modifiedAt,
                      (values.fileSize ?? maximumLogBytes + 1) <= maximumLogBytes {
                result.append((entry, modifiedAt))
            }
        }
    }

    private static func readTail(of url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > UInt64(maximumLogBytes) ? size - UInt64(maximumLogBytes) : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        return String(data: data, encoding: .utf8)
    }

    private static func logMentionsExecutable(_ log: String, executable: String) -> Bool {
        guard let component = executable
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last else { return false }
        let basename = String(component).lowercased()
        guard basename.hasSuffix(".exe") else { return false }
        return log.lowercased().contains(basename)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

public struct GameDisplayStateRepairEntry: Equatable, Sendable {
    public let optionsURL: URL
    public let rollbackURL: URL
    public let beforeFingerprint: String
    public let afterFingerprint: String

    public init(
        optionsURL: URL,
        rollbackURL: URL,
        beforeFingerprint: String,
        afterFingerprint: String
    ) {
        self.optionsURL = optionsURL
        self.rollbackURL = rollbackURL
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
    }
}

public struct GameDisplayStateRepairReport: Equatable, Sendable {
    public let entries: [GameDisplayStateRepairEntry]

    public init(entries: [GameDisplayStateRepairEntry]) {
        self.entries = entries
    }

    public var repairedFiles: [URL] { entries.map(\.optionsURL) }
    public var rollbackFiles: [URL] { entries.map(\.rollbackURL) }
}

public enum GameDisplayStateRepair {
    private static let maximumOptionsBytes = 64 * 1024
    private static let relativeOptionsPath = "AppData/Local/Tinkerlands/useroptions.conf"
    private static let rollbackSuffix = ".regression-windowed-backup"

    /// Corrige únicamente la combinación patológica que produce el desfase Retina conocido:
    /// resolución máxima de GameMaker dentro de una ventana decorada. Las ventanas válidas y
    /// las preferencias que ya usan pantalla completa permanecen intactas.
    public static func repairedTinkerlandsOptions(_ data: Data) -> Data? {
        guard data.count <= maximumOptionsBytes,
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fullscreen = finiteNumber(object["fullscreen"]),
              let resolution = finiteNumber(object["resolution"]),
              fullscreen == 0,
              resolution >= 6 else {
            return nil
        }

        object["fullscreen"] = 1.0
        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// Repara todos los usuarios Wine de la botella sin seguir enlaces simbólicos. Antes de la
    /// primera escritura crea un rollback inmutable al lado del fichero original; las llamadas
    /// siguientes son idempotentes.
    public static func repairTinkerlands(in bottleURL: URL) throws -> GameDisplayStateRepairReport {
        let usersURL = bottleURL.appendingPathComponent("drive_c/users", isDirectory: true)
        let users = try FileManager.default.contentsOfDirectory(
            at: usersURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [GameDisplayStateRepairEntry] = []

        for userURL in users.sorted(by: { $0.path < $1.path }) {
            let userValues = try userURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard userValues.isDirectory == true, userValues.isSymbolicLink != true else { continue }
            let optionsURL = userURL.appendingPathComponent(relativeOptionsPath)
            guard FileManager.default.isReadableFile(atPath: optionsURL.path),
                  !hasSymbolicLinkComponent(below: userURL, relativePath: relativeOptionsPath),
                  !isSymbolicLink(optionsURL) else { continue }

            let optionsValues = try optionsURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard optionsValues.isRegularFile == true,
                  (optionsValues.fileSize ?? maximumOptionsBytes + 1) <= maximumOptionsBytes else {
                continue
            }

            let original = try Data(contentsOf: optionsURL, options: [.mappedIfSafe])
            guard let repaired = repairedTinkerlandsOptions(original) else { continue }
            let rollbackURL = URL(fileURLWithPath: optionsURL.path + rollbackSuffix)
            guard !isSymbolicLink(rollbackURL) else { continue }

            let attributes = try FileManager.default.attributesOfItem(atPath: optionsURL.path)
            if !FileManager.default.fileExists(atPath: rollbackURL.path) {
                try original.write(to: rollbackURL, options: [.atomic])
                try preservePermissions(attributes, at: rollbackURL)
            }
            try repaired.write(to: optionsURL, options: [.atomic])
            try preservePermissions(attributes, at: optionsURL)

            entries.append(GameDisplayStateRepairEntry(
                optionsURL: optionsURL,
                rollbackURL: rollbackURL,
                beforeFingerprint: fingerprint(original),
                afterFingerprint: fingerprint(repaired)
            ))
        }
        return GameDisplayStateRepairReport(entries: entries)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard type != "c", type != "B", number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private static func hasSymbolicLinkComponent(below root: URL, relativePath: String) -> Bool {
        var current = root
        for component in relativePath.split(separator: "/") {
            current.appendPathComponent(String(component))
            if isSymbolicLink(current) { return true }
        }
        return false
    }

    private static func preservePermissions(_ attributes: [FileAttributeKey: Any], at url: URL) throws {
        guard let permissions = attributes[.posixPermissions] else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
