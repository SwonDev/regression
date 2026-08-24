import CryptoKit
import Darwin
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
    /// Cada motor redacta su cabecera de crash a su manera. La causa no está en esa redacción,
    /// así que se acepta cualquiera de las conocidas y la atribución la deciden los marcadores
    /// causales, que siguen siendo obligatorios todos.
    private static let crashHeaders = [
        "unhandled exception: exception_access_violation",  // Unreal
        "crash!!!",                                         // Unity
        "end of stacktrace",                                // Unity
        "unhandled page fault"                              // el depurador de Wine
    ]

    /// Reconoce la colisión reproducida entre el overlay de Steam, el overlay de EOS y D3D11.
    ///
    /// Los cuatro módulos son obligatorios: son la cadena causal —el overlay de Steam y el de
    /// Epic encadenan hooks sobre el mismo dispositivo D3D11 y la llamada salta a un puntero
    /// sobrescrito—. Exigir además la cabecera **de Unreal** era un error: la colisión se ha
    /// reproducido en Unreal (Cloudheim, Dragonwilds), en FNA (TMNT) y en Unity (Beyond Contact),
    /// y Unity escribe `Crash!!!` donde Unreal escribe `Unhandled exception`. Por esa palabra, la
    /// autorreparación no reconocía un crash que traía la firma completa.
    public static func recipe(forCrashLog log: String) -> CompiledRepairRecipe? {
        let normalized = log.lowercased()
        let collisionMarkers = [
            "d3d11.dll",
            "gameoverlayrenderer64.dll",
            "eosovh-win64-shipping.dll",
            "eossdk-win64-shipping.dll"
        ]
        if crashHeaders.contains(where: normalized.contains),
           collisionMarkers.allSatisfy(normalized.contains) {
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
    public let appID: String?
    public let executable: String
    public let recipe: CompiledRepairRecipe

    public init(
        appID: String,
        executable: String,
        recipe: CompiledRepairRecipe
    ) {
        self.appID = appID
        self.executable = executable
        self.recipe = recipe
    }

    /// Compatibilidad de lectura con el catálogo v1, que no conocía el App ID.
    public init(executable: String, recipe: CompiledRepairRecipe) {
        self.appID = nil
        self.executable = executable
        self.recipe = recipe
    }
}

public enum CompiledRepairActivationReconciliation: Equatable, Sendable {
    case applied
    case rolledBack
    case drifted
}

public struct CompiledRepairActivationReport: Equatable, Sendable {
    public let activation: CompiledRepairActivation
    public let activationURL: URL
    public let rollbackURL: URL
    public let beforeFingerprint: String
    public let afterFingerprint: String
    public let legacyActivationURL: URL?
    public let legacyRollbackURL: URL?
    public let legacyBeforeFingerprint: String?
    public let legacyAfterFingerprint: String?

    public init(
        activation: CompiledRepairActivation,
        activationURL: URL,
        rollbackURL: URL,
        beforeFingerprint: String,
        afterFingerprint: String,
        legacyActivationURL: URL? = nil,
        legacyRollbackURL: URL? = nil,
        legacyBeforeFingerprint: String? = nil,
        legacyAfterFingerprint: String? = nil
    ) {
        self.activation = activation
        self.activationURL = activationURL
        self.rollbackURL = rollbackURL
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.legacyActivationURL = legacyActivationURL
        self.legacyRollbackURL = legacyRollbackURL
        self.legacyBeforeFingerprint = legacyBeforeFingerprint
        self.legacyAfterFingerprint = legacyAfterFingerprint
    }
}

/// Lector tipado de activaciones compiladas existentes.
///
/// El formato no acepta rutas, DLL, variables ni acciones. La escritura permanece bloqueada:
/// el loader estable solo conoce basename+receta (v1), así que todavía no puede aislar dos App ID
/// con el mismo ejecutable. V2 conserva el contrato futuro App ID+basename sin promoverlo a Wine.
public enum CompiledRepairActivationStore {
    private static let legacyHeader = "REGRESSION-COMPILED-REPAIRS\t1\n"
    private static let header = "REGRESSION-COMPILED-REPAIRS\t2\n"
    private static let relativePath = ".regression/compiled-repair-activations-v2.tsv"
    private static let legacyRelativePath = ".regression/compiled-repair-activations-v1.tsv"
    private static let legacyQuarantineRelativePath =
        ".regression/compiled-repair-activations-v1.quarantined.tsv"
    private static let backupsDirectoryName = "Backups"
    private static let backupsRelativePath = ".regression/Backups"
    private static let maximumBytes = 64 * 1024
    private static let maximumActivations = 128

    public static func activations(in bottleURL: URL) throws -> [CompiledRepairActivation] {
        if let data = try anchoredRead(
            fileName: "compiled-repair-activations-v2.tsv",
            in: bottleURL
        ) {
            return try decode(data)
        }
        guard let legacy = try anchoredRead(
            fileName: "compiled-repair-activations-v1.tsv",
            in: bottleURL
        ) else { return [] }
        return try decodeLegacy(legacy)
    }

    /// Impide que Wine consuma el formato v1 mientras la migración a cuarentena no haya
    /// terminado. Ese formato solo identifica basename+receta y no puede aislar dos App ID.
    /// La comprobación se repite en el último punto común de todos los lanzamientos, incluso
    /// cuando bootstrap o un cliente CLI no hayan preparado todavía el repositorio SQLite.
    static func validateLaunchSafety(in bottleURL: URL) throws {
        guard try anchoredRead(fileName: legacyFileName, in: bottleURL) == nil else {
            throw RegressionCoreError.unsafeLibraryState(
                "Hay una reparación heredada pendiente de poner en cuarentena. "
                    + "Regression no abrirá Steam hasta completar esa protección."
            )
        }
    }

    static func legacySnapshot(
        in bottleURL: URL
    ) throws -> (activations: [CompiledRepairActivation], fingerprint: String)? {
        let active = try anchoredRead(fileName: legacyFileName, in: bottleURL)
        let quarantined = try anchoredRead(fileName: legacyQuarantineFileName, in: bottleURL)
        guard active == nil || quarantined == nil else {
            throw RegressionCoreError.invalidEvidence(
                "coexisten una activación legacy viva y su cuarentena"
            )
        }
        guard let data = active ?? quarantined else { return nil }
        return (try decodeLegacy(data, quarantineAmbiguity: false), fingerprint(data))
    }

    static func quarantineLegacyActivation(
        expectedFingerprint: String,
        in bottleURL: URL
    ) throws {
        let active = try anchoredRead(fileName: legacyFileName, in: bottleURL)
        let quarantined = try anchoredRead(fileName: legacyQuarantineFileName, in: bottleURL)
        guard active == nil || quarantined == nil else {
            throw RegressionCoreError.invalidEvidence(
                "coexisten una activación legacy viva y su cuarentena"
            )
        }
        if let quarantined {
            guard fingerprint(quarantined) == expectedFingerprint else {
                throw RegressionCoreError.invalidEvidence("la cuarentena legacy presenta drift")
            }
            return
        }
        guard let active, fingerprint(active) == expectedFingerprint else {
            throw RegressionCoreError.invalidEvidence("la activación legacy cambió antes de aislarse")
        }

        let rootFD = Darwin.open(bottleURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw RegressionCoreError.invalidEvidence("la raíz de la botella no es segura")
        }
        defer { Darwin.close(rootFD) }
        let directoryFD = Darwin.openat(
            rootFD,
            ".regression",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            throw RegressionCoreError.invalidEvidence("el directorio de activaciones no es seguro")
        }
        defer { Darwin.close(directoryFD) }
        guard Darwin.renameatx_np(
            directoryFD,
            legacyFileName,
            directoryFD,
            legacyQuarantineFileName,
            UInt32(RENAME_EXCL)
        ) == 0 else {
            throw RegressionCoreError.invalidEvidence("no se pudo aislar la activación legacy")
        }
        guard let moved = try anchoredRead(fileName: legacyQuarantineFileName, in: bottleURL),
              fingerprint(moved) == expectedFingerprint else {
            throw RegressionCoreError.invalidEvidence("la cuarentena legacy no conserva su huella")
        }
    }

    /// Escribe una activación v2 en la botella para que el loader la aplique en el siguiente
    /// arranque del proceso exacto.
    ///
    /// El registro solo puede nombrar un App ID, un basename PE y una receta enumerada en
    /// código: nunca una ruta, una DLL arbitraria, un argumento ni un comando. Wine acredita
    /// además que el proceso pertenece de verdad a ese App ID leyendo el `appmanifest` que
    /// Steam mantiene, así que dos juegos con el mismo ejecutable no pueden confundirse.
    ///
    /// Devuelve `nil` cuando la activación ya estaba presente: repetir un aprendizaje no
    /// reescribe la botella ni multiplica registros.
    @discardableResult
    public static func activate(
        appID: String,
        executable: String,
        recipe: CompiledRepairRecipe,
        in bottleURL: URL
    ) throws -> CompiledRepairActivationReport? {
        guard let normalizedAppID = SteamAppID.normalized(appID) else {
            throw RegressionCoreError.invalidEvidence("la activación exige un App ID válido")
        }
        let basename = try executableBasename(executable)

        // Una activación heredada viva bloquea el arranque; no se amplía sobre ella.
        try validateLaunchSafety(in: bottleURL)

        let existing = try activations(in: bottleURL)
        let activation = CompiledRepairActivation(
            appID: normalizedAppID,
            executable: basename,
            recipe: recipe
        )
        if existing.contains(activation) { return nil }
        guard existing.count + 1 <= maximumActivations else {
            throw RegressionCoreError.invalidEvidence(
                "el catálogo de activaciones alcanzó su límite"
            )
        }

        let before = try anchoredRead(fileName: fileName, in: bottleURL) ?? Data()
        let after = encode(existing + [activation])
        guard after.count <= maximumBytes else {
            throw RegressionCoreError.invalidEvidence("el catálogo excedería su límite de bytes")
        }

        // El respaldo se publica ANTES de tocar el catálogo vivo: si la escritura siguiente
        // fallara a medias, el estado anterior ya es recuperable. El nombre es el contenido,
        // así que repetir la misma activación reutiliza el respaldo en lugar de acumularlos.
        let beforeFingerprint = fingerprint(before)
        let backupName = backupFileName(for: beforeFingerprint)
        if let existingBackup = try anchoredRead(
            fileName: backupName,
            subdirectory: backupsDirectoryName,
            in: bottleURL
        ) {
            guard fingerprint(existingBackup) == beforeFingerprint else {
                throw RegressionCoreError.invalidEvidence("el respaldo de activaciones presenta drift")
            }
        } else {
            try anchoredWrite(
                before,
                fileName: backupName,
                subdirectory: backupsDirectoryName,
                in: bottleURL
            )
        }

        try anchoredWrite(after, fileName: fileName, in: bottleURL)

        // La segunda entrada del manifiesto acredita que la activación NO tocó el formato v1:
        // su huella es idéntica antes y después, y su respaldo es la cuarentena donde vive.
        let legacyQuarantined = try anchoredRead(fileName: legacyQuarantineFileName, in: bottleURL)
        let legacyFingerprint = fingerprint(legacyQuarantined ?? Data())

        return CompiledRepairActivationReport(
            activation: activation,
            activationURL: activationURL(in: bottleURL),
            rollbackURL: backupURL(in: bottleURL, fingerprint: beforeFingerprint),
            beforeFingerprint: beforeFingerprint,
            afterFingerprint: fingerprint(after),
            legacyActivationURL: legacyActivationURL(in: bottleURL),
            legacyRollbackURL: legacyQuarantineURL(in: bottleURL),
            legacyBeforeFingerprint: legacyFingerprint,
            legacyAfterFingerprint: legacyFingerprint
        )
    }

    private static func backupFileName(for fingerprint: String) -> String {
        "compiled-repair-activations-v2.\(fingerprint).tsv"
    }

    public static func backupURL(in bottleURL: URL, fingerprint: String) -> URL {
        bottleURL
            .appendingPathComponent(backupsRelativePath)
            .appendingPathComponent(backupFileName(for: fingerprint))
    }

    private static func encode(_ activations: [CompiledRepairActivation]) -> Data {
        var text = header
        for activation in activations {
            text += "\(activation.appID ?? "")\t\(activation.executable)\t\(activation.recipe.rawValue)\n"
        }
        return Data(text.utf8)
    }

    /// Escritura anclada y simétrica a `anchoredRead`: nunca sigue enlaces, crea el directorio
    /// privado con 0700, escribe con 0600 y publica el resultado con un rename atómico para que
    /// Wine no pueda leer jamás un catálogo a medias.
    private static func anchoredWrite(
        _ data: Data,
        fileName: String,
        subdirectory: String? = nil,
        in bottleURL: URL
    ) throws {
        let rootFD = Darwin.open(bottleURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw RegressionCoreError.invalidEvidence("la raíz de la botella no es segura")
        }
        defer { Darwin.close(rootFD) }

        if Darwin.mkdirat(rootFD, ".regression", 0o700) != 0, errno != EEXIST {
            throw RegressionCoreError.invalidEvidence("no se pudo crear el directorio privado")
        }
        let privateFD = Darwin.openat(
            rootFD,
            ".regression",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard privateFD >= 0 else {
            throw RegressionCoreError.invalidEvidence("el directorio de activaciones no es seguro")
        }
        defer { Darwin.close(privateFD) }

        let directoryFD: Int32
        if let subdirectory {
            if Darwin.mkdirat(privateFD, subdirectory, 0o700) != 0, errno != EEXIST {
                throw RegressionCoreError.invalidEvidence("no se pudo crear el directorio de respaldo")
            }
            directoryFD = Darwin.openat(
                privateFD,
                subdirectory,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directoryFD >= 0 else {
                throw RegressionCoreError.invalidEvidence("el directorio de respaldo no es seguro")
            }
        } else {
            directoryFD = Darwin.dup(privateFD)
            guard directoryFD >= 0 else {
                throw RegressionCoreError.invalidEvidence("el directorio de activaciones no es seguro")
            }
        }
        defer { Darwin.close(directoryFD) }

        let temporaryName = "\(fileName).partial"
        _ = Darwin.unlinkat(directoryFD, temporaryName, 0)
        let fileFD = Darwin.openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard fileFD >= 0 else {
            throw RegressionCoreError.invalidEvidence("no se pudo crear el catálogo anclado")
        }
        var written = 0
        let bytes = [UInt8](data)
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBufferPointer {
                Darwin.write(fileFD, $0.baseAddress, $0.count)
            }
            guard count > 0 else {
                if errno == EINTR { continue }
                Darwin.close(fileFD)
                _ = Darwin.unlinkat(directoryFD, temporaryName, 0)
                throw RegressionCoreError.invalidEvidence("no se pudo escribir el catálogo anclado")
            }
            written += count
        }
        guard Darwin.fsync(fileFD) == 0 else {
            Darwin.close(fileFD)
            _ = Darwin.unlinkat(directoryFD, temporaryName, 0)
            throw RegressionCoreError.invalidEvidence("no se pudo sincronizar el catálogo anclado")
        }
        Darwin.close(fileFD)

        guard Darwin.renameat(directoryFD, temporaryName, directoryFD, fileName) == 0 else {
            _ = Darwin.unlinkat(directoryFD, temporaryName, 0)
            throw RegressionCoreError.invalidEvidence("no se pudo publicar el catálogo anclado")
        }
    }

    /// Overload temporal para consumidores que aún producen activaciones v1 sin App ID.
    @discardableResult
    public static func activate(
        executable: String,
        recipe: CompiledRepairRecipe,
        in bottleURL: URL
    ) throws -> CompiledRepairActivationReport? {
        _ = executable
        _ = recipe
        _ = bottleURL
        throw RegressionCoreError.invalidEvidence(
            "las activaciones v1 quedan en cuarentena y no pueden ampliarse"
        )
    }

    public static func activationURL(in bottleURL: URL) -> URL {
        bottleURL.appendingPathComponent(relativePath)
    }

    public static func legacyActivationURL(in bottleURL: URL) -> URL {
        bottleURL.appendingPathComponent(legacyRelativePath)
    }

    public static func legacyQuarantineURL(in bottleURL: URL) -> URL {
        bottleURL.appendingPathComponent(legacyQuarantineRelativePath)
    }

    /// Contrasta el catálogo vivo con el recibo: `applied` si sigue siendo el estado que la
    /// activación publicó, `rolledBack` si alguien lo devolvió al anterior y `drifted` para
    /// cualquier otro contenido. Es de solo lectura y nunca corrige por su cuenta.
    public static func reconcile(
        _ report: CompiledRepairActivationReport,
        in bottleURL: URL
    ) throws -> CompiledRepairActivationReconciliation {
        let live = fingerprint(try anchoredRead(fileName: fileName, in: bottleURL) ?? Data())
        if live == report.afterFingerprint { return .applied }
        if live == report.beforeFingerprint { return .rolledBack }
        return .drifted
    }

    /// Deshace una activación devolviendo el catálogo al contenido exacto que su recibo respaldó.
    ///
    /// Solo actúa cuando el estado vivo coincide con la huella posterior del recibo: si la botella
    /// cambió entre medias, la restauración se niega en lugar de pisar evidencia ajena.
    @discardableResult
    public static func restore(
        _ report: CompiledRepairActivationReport,
        in bottleURL: URL
    ) throws -> [CompiledRepairActivation] {
        let live = try anchoredRead(fileName: fileName, in: bottleURL) ?? Data()
        guard fingerprint(live) == report.afterFingerprint else {
            throw RegressionCoreError.invalidEvidence(
                "el catálogo cambió después de la activación y no se restaura a ciegas"
            )
        }
        guard let backup = try anchoredRead(
            fileName: backupFileName(for: report.beforeFingerprint),
            subdirectory: backupsDirectoryName,
            in: bottleURL
        ), fingerprint(backup) == report.beforeFingerprint else {
            throw RegressionCoreError.invalidEvidence("el respaldo de la activación no es recuperable")
        }
        guard !backup.isEmpty else {
            try anchoredRemove(fileName: fileName, in: bottleURL)
            return []
        }
        try anchoredWrite(backup, fileName: fileName, in: bottleURL)
        return try decode(backup)
    }

    /// Borrado anclado: el catálogo desaparece por completo cuando el estado previo era su
    /// ausencia, en vez de dejar un archivo vacío que Wine tendría que interpretar.
    private static func anchoredRemove(fileName: String, in bottleURL: URL) throws {
        let rootFD = Darwin.open(bottleURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw RegressionCoreError.invalidEvidence("la raíz de la botella no es segura")
        }
        defer { Darwin.close(rootFD) }
        let directoryFD = Darwin.openat(
            rootFD,
            ".regression",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryFD >= 0 else {
            if errno == ENOENT { return }
            throw RegressionCoreError.invalidEvidence("el directorio de activaciones no es seguro")
        }
        defer { Darwin.close(directoryFD) }
        guard Darwin.unlinkat(directoryFD, fileName, 0) == 0 || errno == ENOENT else {
            throw RegressionCoreError.invalidEvidence("no se pudo retirar el catálogo anclado")
        }
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
            guard fields.count == 3,
                  let appID = SteamAppID.normalized(String(fields[0])),
                  let recipe = CompiledRepairRecipe(rawValue: String(fields[2])) else {
                throw RegressionCoreError.invalidEvidence("el catálogo contiene una receta desconocida")
            }
            let executable = try executableBasename(String(fields[1]))
            let activation = CompiledRepairActivation(
                appID: appID,
                executable: executable,
                recipe: recipe
            )
            guard !result.contains(activation) else {
                throw RegressionCoreError.invalidEvidence("el catálogo contiene activaciones duplicadas")
            }
            result.append(activation)
        }
        return result
    }

    private static func decodeLegacy(
        _ data: Data,
        quarantineAmbiguity: Bool = true
    ) throws -> [CompiledRepairActivation] {
        guard data.count <= maximumBytes,
              let text = String(data: data, encoding: .utf8),
              text.hasPrefix(legacyHeader) else {
            throw RegressionCoreError.invalidEvidence("el catálogo tipado legacy no es válido")
        }
        let lines = text.dropFirst(legacyHeader.count)
            .split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count <= maximumActivations else {
            throw RegressionCoreError.invalidEvidence("el catálogo tipado legacy excede su límite")
        }
        var result: [CompiledRepairActivation] = []
        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let recipe = CompiledRepairRecipe(rawValue: String(fields[1])) else {
                throw RegressionCoreError.invalidEvidence("el catálogo legacy contiene una receta desconocida")
            }
            let activation = CompiledRepairActivation(
                executable: try executableBasename(String(fields[0])),
                recipe: recipe
            )
            guard !result.contains(activation) else {
                throw RegressionCoreError.invalidEvidence("el catálogo legacy contiene duplicados")
            }
            result.append(activation)
        }
        let ambiguous = Dictionary(grouping: result, by: \.executable).values.contains { values in
            Set(values.map(\.recipe)).count > 1
        }
        guard !quarantineAmbiguity || !ambiguous else {
            throw RegressionCoreError.invalidEvidence(
                "el catálogo legacy es ambiguo y queda en cuarentena"
            )
        }
        return result
    }

    /// Lectura anclada a descriptores. Cada componente se abre con `O_NOFOLLOW`, el fichero debe
    /// ser regular, privado y con un único enlace físico. Así un swap entre comprobación y lectura
    /// no puede redirigir el inventario fuera de la botella.
    private static func anchoredRead(
        fileName: String,
        subdirectory: String? = nil,
        in bottleURL: URL
    ) throws -> Data? {
        let rootFD = Darwin.open(bottleURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            if errno == ENOENT { return nil }
            throw RegressionCoreError.invalidEvidence("la raíz de la botella no es segura")
        }
        defer { Darwin.close(rootFD) }

        let privateFD = Darwin.openat(
            rootFD,
            ".regression",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard privateFD >= 0 else {
            if errno == ENOENT { return nil }
            throw RegressionCoreError.invalidEvidence("el directorio de activaciones no es seguro")
        }
        defer { Darwin.close(privateFD) }

        let directoryFD: Int32
        if let subdirectory {
            directoryFD = Darwin.openat(
                privateFD,
                subdirectory,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard directoryFD >= 0 else {
                if errno == ENOENT { return nil }
                throw RegressionCoreError.invalidEvidence("el directorio de respaldo no es seguro")
            }
        } else {
            directoryFD = Darwin.dup(privateFD)
            guard directoryFD >= 0 else {
                throw RegressionCoreError.invalidEvidence("el directorio de activaciones no es seguro")
            }
        }
        defer { Darwin.close(directoryFD) }

        let fileFD = Darwin.openat(directoryFD, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fileFD >= 0 else {
            if errno == ENOENT { return nil }
            throw RegressionCoreError.invalidEvidence("el catálogo de activaciones no es seguro")
        }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= maximumBytes else {
            throw RegressionCoreError.invalidEvidence(
                "el catálogo debe ser regular, acotado y sin hardlinks"
            )
        }
        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = Darwin.read(fileFD, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw RegressionCoreError.invalidEvidence("no se pudo leer el catálogo anclado")
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else {
                throw RegressionCoreError.invalidEvidence("el catálogo excede su límite")
            }
        }
        return data
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let fileName = "compiled-repair-activations-v2.tsv"
    private static let legacyFileName = "compiled-repair-activations-v1.tsv"
    private static let legacyQuarantineFileName =
        "compiled-repair-activations-v1.quarantined.tsv"
}

extension CompiledRepairActivationReport {
    /// Traduce el recibo al manifiesto durable que exige el repositorio: una entrada por cada
    /// archivo que el subsistema de reparaciones gobierna —el catálogo v2 que sí cambió y el
    /// formato v1 en cuarentena, cuya huella idéntica antes y después acredita que no se tocó—.
    public func rollbackManifest(createdAt: Date = Date()) -> RepairRollbackManifest? {
        guard let legacyActivationURL,
              let legacyRollbackURL,
              let legacyBeforeFingerprint,
              let legacyAfterFingerprint else { return nil }
        return RepairRollbackManifest(
            entries: [
                RepairRollbackEntry(
                    targetPath: activationURL.standardizedFileURL.path,
                    backupPath: rollbackURL.standardizedFileURL.path,
                    beforeFingerprint: beforeFingerprint,
                    afterFingerprint: afterFingerprint
                ),
                RepairRollbackEntry(
                    targetPath: legacyActivationURL.standardizedFileURL.path,
                    backupPath: legacyRollbackURL.standardizedFileURL.path,
                    beforeFingerprint: legacyBeforeFingerprint,
                    afterFingerprint: legacyAfterFingerprint
                )
            ],
            createdAt: createdAt
        )
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

public struct CompiledCrashRepairDetection: Equatable, Sendable {
    public let appID: String
    public let executable: String
    public let recipe: CompiledRepairRecipe
    public let crashLogURL: URL

    public init(
        appID: String,
        executable: String,
        recipe: CompiledRepairRecipe,
        crashLogURL: URL
    ) {
        self.appID = appID
        self.executable = executable
        self.recipe = recipe
        self.crashLogURL = crashLogURL
    }
}

/// Aprende únicamente una receta conocida desde un log reciente de la ejecución que acaba de
/// fallar. El recorrido se limita a AppData/Local, no sigue symlinks y tiene límites de profundidad,
/// cantidad y tamaño para que un juego no pueda convertir el diagnóstico en una exploración libre.
public enum CompiledCrashRepairLearner {
    // El recorrido está acotado, pero 4096 entradas no alcanzaban ni para cruzar
    // `AppData/Local` —que en una botella real ronda las 6300—, y como el recorrido iba en orden
    // alfabético, `Local` se comía el presupuesto entero antes de llegar a `LocalLow`, que es
    // justo donde **todos** los juegos Unity escriben su `Player.log`. Por eso la autorreparación
    // no reconocía ni un solo crash de Unity: nunca llegaba a leer la traza.
    private static let maximumFiles = 65_536
    private static let maximumDepth = 9
    private static let maximumLogBytes = 4 * 1024 * 1024

    public static func learn(
        appID: String,
        executable: String,
        bottleURL: URL,
        startedAt: Date,
        endedAt: Date
    ) throws -> CompiledCrashRepairLearningReport? {
        guard let detection = try detect(
            appID: appID,
            executable: executable,
            bottleURL: bottleURL,
            startedAt: startedAt,
            endedAt: endedAt
        ) else { return nil }

        // El loader acredita por su cuenta que el proceso pertenece al App ID declarado, así
        // que la activación puede escribirse: identifica un basename exacto, un App ID exacto
        // y una receta enumerada en código. Si ya estaba activa no se reescribe nada.
        guard let activation = try CompiledRepairActivationStore.activate(
            appID: detection.appID,
            executable: detection.executable,
            recipe: detection.recipe,
            in: bottleURL
        ) else { return nil }

        return CompiledCrashRepairLearningReport(
            appID: detection.appID,
            executable: detection.executable,
            recipe: detection.recipe,
            crashLogURL: detection.crashLogURL,
            activation: activation
        )
    }

    /// Detecta una receta conocida sin escribir en la botella ni en SQLite.
    public static func detect(
        appID: String,
        executable: String,
        bottleURL: URL,
        startedAt: Date,
        endedAt: Date
    ) throws -> CompiledCrashRepairDetection? {
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
                  let basename = executable
                    .split(whereSeparator: { $0 == "/" || $0 == "\\" })
                    .last else { continue }
            return CompiledCrashRepairDetection(
                appID: normalizedAppID,
                executable: String(basename).lowercased(),
                recipe: recipe,
                crashLogURL: candidate.url
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
        // Se busca evidencia **reciente**, así que se mira primero lo que se ha tocado hace poco.
        // Con un recorrido alfabético, un presupuesto agotado deja fuera precisamente el árbol que
        // el juego acaba de escribir; ordenando por fecha, lo primero que se visita es lo que
        // cambió durante la ejecución. La ruta desempata para que el recorrido sea determinista.
        var dated: [(url: URL, modifiedAt: Date)] = []
        dated.reserveCapacity(entries.count)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
            dated.append((entry, values?.contentModificationDate ?? Date.distantPast))
        }
        dated.sort { left, right in
            if left.modifiedAt == right.modifiedAt {
                return left.url.path < right.url.path
            }
            return left.modifiedAt > right.modifiedAt
        }
        let ordered: [URL] = dated.map { $0.url }

        for entry in ordered where budget > 0 {
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
    public let aggregateBeforeFingerprint: String
    public let aggregateAfterFingerprint: String
    public let intentURL: URL?

    public init(
        entries: [GameDisplayStateRepairEntry],
        aggregateBeforeFingerprint: String? = nil,
        aggregateAfterFingerprint: String? = nil,
        intentURL: URL? = nil
    ) {
        self.entries = entries
        self.aggregateBeforeFingerprint = aggregateBeforeFingerprint
            ?? Self.aggregateFingerprint(entries.map { ($0.optionsURL.path, $0.beforeFingerprint) })
        self.aggregateAfterFingerprint = aggregateAfterFingerprint
            ?? Self.aggregateFingerprint(entries.map { ($0.optionsURL.path, $0.afterFingerprint) })
        self.intentURL = intentURL
    }

    public var repairedFiles: [URL] { entries.map(\.optionsURL) }
    public var rollbackFiles: [URL] { entries.map(\.rollbackURL) }

    private static func aggregateFingerprint(_ values: [(String, String)]) -> String {
        let canonical = values
            .sorted { $0.0 < $1.0 }
            .enumerated()
            .map { "\($0.offset)\t\($0.element.1)\n" }
            .joined()
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct GameDisplayStateRepairReceiptContext: Equatable, Sendable {
    public let receiptID: UUID
    public let beforeFingerprint: String
    public let afterFingerprint: String
    public let intentURL: URL
    public let repairedFileCount: Int
    public let result: RepairReceiptResult

    public init(
        receiptID: UUID,
        beforeFingerprint: String,
        afterFingerprint: String,
        intentURL: URL,
        repairedFileCount: Int,
        result: RepairReceiptResult
    ) {
        self.receiptID = receiptID
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.intentURL = intentURL
        self.repairedFileCount = repairedFileCount
        self.result = result
    }
}

public struct GameDisplayStateRepairUnsafeFailure: Equatable, Sendable {
    public let mutationOccurred: Bool
    public let message: String

    public init(mutationOccurred: Bool, message: String) {
        self.mutationOccurred = mutationOccurred
        self.message = message
    }
}

public enum GameDisplayStateRepairTransactionOutcome: Equatable, Sendable {
    case noOp
    case committed(GameDisplayStateRepairReport)
    case rolledBack(GameDisplayStateRepairReport)
    case unsafe(GameDisplayStateRepairUnsafeFailure)

    /// El launcher solo puede continuar con bytes originales, un commit completo o un rollback
    /// comprobado. Un fallo previo a cualquier mutación conserva el estado anterior intacto.
    public var allowsLaunch: Bool {
        switch self {
        case .noOp, .committed, .rolledBack:
            true
        case let .unsafe(failure):
            !failure.mutationOccurred
        }
    }
}

enum GameDisplayStateRepairFaultInjection: Equatable, Sendable {
    case none
    case receipt
    case rollback
    case crashAfterIntent
    case crashAfterFirstMutation
    case crashAfterMutation
    case crashAfterReceipt
    case cleanupAfterReceipt
    case targetAfterRename
}

public enum GameDisplayStateRepair {
    private static let maximumOptionsBytes = 64 * 1024
    private static let relativeOptionsPath = "AppData/Local/Tinkerlands/useroptions.conf"
    private static let rollbackSuffix = ".regression-windowed-backup"
    private static let journalDirectory = ".regression/repair-transactions"

    private struct PlannedEntry: Sendable {
        let targetRelativePath: String
        let rollbackRelativePath: String
        let optionsURL: URL
        let rollbackURL: URL
        let original: Data
        let repaired: Data
        let permissions: Int?
        let beforeFingerprint: String
        let afterFingerprint: String
    }

    private enum JournalPhase: String, Codable, Sendable {
        case pending
        case mutated
    }

    private struct JournalEntry: Codable, Sendable {
        let targetRelativePath: String
        let rollbackRelativePath: String
        let permissions: Int
        let beforeFingerprint: String
        let afterFingerprint: String
    }

    private struct Journal: Codable, Sendable {
        let schema: Int
        let transactionID: UUID
        let successReceiptID: UUID
        let rollbackReceiptID: UUID
        var phase: JournalPhase
        let entries: [JournalEntry]
    }

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

    /// Ejecuta la receta compilada como una transacción observable. El ledger se prepara antes
    /// incluso de inspeccionar la botella; la intención durable precede a la primera escritura
    /// del estado del juego y cualquier fallo posterior restaura y verifica los bytes exactos.
    public static func prepareTinkerlandsTransaction(
        in bottleURL: URL,
        prepareLedger: () async throws -> Void,
        recordReceipt: (GameDisplayStateRepairReceiptContext) async throws -> Void
    ) async -> GameDisplayStateRepairTransactionOutcome {
        await prepareTinkerlandsTransaction(
            in: bottleURL,
            prepareLedger: prepareLedger,
            recordReceipt: recordReceipt,
            faultInjection: .none,
            beforeMutation: nil
        )
    }

    static func prepareTinkerlandsTransaction(
        in bottleURL: URL,
        prepareLedger: () async throws -> Void,
        recordReceipt: (GameDisplayStateRepairReceiptContext) async throws -> Void,
        faultInjection: GameDisplayStateRepairFaultInjection,
        beforeMutation: (() throws -> Void)? = nil
    ) async -> GameDisplayStateRepairTransactionOutcome {
        let storage: AnchoredBottleStorage
        let transactionLock: AnchoredBottleStorage.ExclusiveLock
        let hasPendingJournal: Bool
        do {
            storage = try AnchoredBottleStorage(rootURL: bottleURL)
            try storage.ensureDirectory(journalDirectory, permissions: 0o700)
            transactionLock = try storage.acquireExclusiveLock(
                "\(journalDirectory)/.lock",
                permissions: 0o600
            )
            hasPendingJournal = try storage.directoryEntries(journalDirectory)
                .contains { $0.hasSuffix(".json") }
        } catch {
            return .unsafe(GameDisplayStateRepairUnsafeFailure(
                mutationOccurred: true,
                message: "No se pudo acreditar la exclusión o el journal: \(error.localizedDescription)"
            ))
        }
        defer { withExtendedLifetime(transactionLock) {} }

        do {
            try await prepareLedger()
        } catch {
            return .unsafe(GameDisplayStateRepairUnsafeFailure(
                mutationOccurred: hasPendingJournal,
                message: "No se pudo preparar el ledger: \(error.localizedDescription)"
            ))
        }

        let recovery = await recoverInterruptedTransactions(
            storage: storage,
            bottleURL: bottleURL,
            recordReceipt: recordReceipt
        )
        switch recovery {
        case .noOp:
            break
        case .committed, .rolledBack, .unsafe:
            return recovery
        }

        let plan: [PlannedEntry]
        do {
            plan = try tinkerlandsRepairPlan(in: bottleURL, storage: storage)
        } catch {
            return .unsafe(GameDisplayStateRepairUnsafeFailure(
                mutationOccurred: false,
                message: "No se pudo inspeccionar la reparación: \(error.localizedDescription)"
            ))
        }
        guard !plan.isEmpty else { return .noOp }

        var journal = Journal(
            schema: 1,
            transactionID: UUID(),
            successReceiptID: UUID(),
            rollbackReceiptID: UUID(),
            phase: .pending,
            entries: plan.map {
                JournalEntry(
                    targetRelativePath: $0.targetRelativePath,
                    rollbackRelativePath: $0.rollbackRelativePath,
                    permissions: $0.permissions ?? 0o600,
                    beforeFingerprint: $0.beforeFingerprint,
                    afterFingerprint: $0.afterFingerprint
                )
            }
        )
        let journalRelativePath = "\(journalDirectory)/\(journal.transactionID.uuidString).json"
        let intentURL = bottleURL.appendingPathComponent(journalRelativePath)
        do {
            try persist(journal, at: journalRelativePath, storage: storage)
        } catch {
            return .unsafe(GameDisplayStateRepairUnsafeFailure(
                mutationOccurred: false,
                message: "No se pudo registrar la intención durable: \(error.localizedDescription)"
            ))
        }

        if faultInjection == .crashAfterIntent {
            return .unsafe(GameDisplayStateRepairUnsafeFailure(
                mutationOccurred: false,
                message: "interrupción simulada después de la intención"
            ))
        }

        let entries = plan.map {
            GameDisplayStateRepairEntry(
                optionsURL: $0.optionsURL,
                rollbackURL: $0.rollbackURL,
                beforeFingerprint: $0.beforeFingerprint,
                afterFingerprint: $0.afterFingerprint
            )
        }
        let report = GameDisplayStateRepairReport(entries: entries, intentURL: intentURL)
        var mutationOccurred = false
        var mutatedEntries: [PlannedEntry] = []

        do {
            try beforeMutation?()
            for entry in plan {
                guard try storage.readRegularFile(entry.targetRelativePath).data == entry.original else {
                    throw RegressionCoreError.invalidEvidence(
                        "las opciones cambiaron después de registrar la intención"
                    )
                }
                try storage.createRegularFileIfAbsent(
                    entry.rollbackRelativePath,
                    data: entry.original,
                    permissions: entry.permissions ?? 0o600
                )
                guard try storage.readRegularFile(entry.rollbackRelativePath).data == entry.original else {
                    throw RegressionCoreError.invalidEvidence("el rollback no conserva los bytes originales")
                }
                mutationOccurred = true
                mutatedEntries.append(entry)
                try storage.replaceRegularFile(
                    entry.targetRelativePath,
                    data: entry.repaired,
                    permissions: entry.permissions ?? 0o600,
                    faultAfterRename: faultInjection == .targetAfterRename
                )
                guard try storage.readRegularFile(entry.targetRelativePath).data == entry.repaired else {
                    throw RegressionCoreError.invalidEvidence(
                        "la reparación no conserva los bytes previstos"
                    )
                }
                if faultInjection == .crashAfterFirstMutation {
                    return .unsafe(GameDisplayStateRepairUnsafeFailure(
                        mutationOccurred: true,
                        message: "interrupción simulada después de la primera mutación"
                    ))
                }
            }

            if faultInjection == .crashAfterMutation {
                return .unsafe(GameDisplayStateRepairUnsafeFailure(
                    mutationOccurred: true,
                    message: "interrupción simulada después de mutar"
                ))
            }

            journal.phase = .mutated
            try persist(journal, at: journalRelativePath, storage: storage)

            if faultInjection == .receipt {
                throw RegressionCoreError.database("fallo receipt inyectado")
            }
            try await recordReceipt(GameDisplayStateRepairReceiptContext(
                receiptID: journal.successReceiptID,
                beforeFingerprint: report.aggregateBeforeFingerprint,
                afterFingerprint: report.aggregateAfterFingerprint,
                intentURL: intentURL,
                repairedFileCount: entries.count,
                result: .succeeded
            ))
            if faultInjection == .crashAfterReceipt || faultInjection == .cleanupAfterReceipt {
                return .unsafe(GameDisplayStateRepairUnsafeFailure(
                    mutationOccurred: true,
                    message: faultInjection == .cleanupAfterReceipt
                        ? "fallo simulado al cerrar el journal después del recibo"
                        : "interrupción simulada después del recibo"
                ))
            }
            do {
                try storage.removeRegularFile(journalRelativePath)
            } catch {
                return .unsafe(GameDisplayStateRepairUnsafeFailure(
                    mutationOccurred: true,
                    message: "El commit existe, pero el journal no pudo cerrarse: \(error.localizedDescription)"
                ))
            }
            return .committed(report)
        } catch {
            guard mutationOccurred else {
                return .unsafe(GameDisplayStateRepairUnsafeFailure(
                    mutationOccurred: false,
                    message: "La reparación se detuvo sin modificar el juego: \(error.localizedDescription)"
                ))
            }
            do {
                if faultInjection == .rollback {
                    throw RegressionCoreError.invalidEvidence("fallo rollback inyectado")
                }
                try restoreExactBytes(mutatedEntries, storage: storage)
                try? await recordReceipt(GameDisplayStateRepairReceiptContext(
                    receiptID: journal.rollbackReceiptID,
                    beforeFingerprint: report.aggregateBeforeFingerprint,
                    afterFingerprint: report.aggregateAfterFingerprint,
                    intentURL: intentURL,
                    repairedFileCount: entries.count,
                    result: .rolledBack
                ))
                try storage.removeRegularFile(journalRelativePath)
                return .rolledBack(report)
            } catch {
                return .unsafe(GameDisplayStateRepairUnsafeFailure(
                    mutationOccurred: true,
                    message: "El rollback no pudo verificarse: \(error.localizedDescription)"
                ))
            }
        }
    }

    private static func tinkerlandsRepairPlan(
        in bottleURL: URL,
        storage: AnchoredBottleStorage
    ) throws -> [PlannedEntry] {
        let users = try storage.directoryEntries("drive_c/users")
        var plan: [PlannedEntry] = []
        for user in users.sorted() {
            let targetRelativePath = "drive_c/users/\(user)/\(relativeOptionsPath)"
            guard let file = try? storage.readRegularFile(targetRelativePath),
                  file.data.count <= maximumOptionsBytes else { continue }
            let original = file.data
            guard let repaired = repairedTinkerlandsOptions(original) else { continue }
            let rollbackRelativePath = targetRelativePath + rollbackSuffix
            let optionsURL = bottleURL.appendingPathComponent(targetRelativePath)
            let rollbackURL = bottleURL.appendingPathComponent(rollbackRelativePath)
            plan.append(PlannedEntry(
                targetRelativePath: targetRelativePath,
                rollbackRelativePath: rollbackRelativePath,
                optionsURL: optionsURL,
                rollbackURL: rollbackURL,
                original: original,
                repaired: repaired,
                permissions: file.permissions,
                beforeFingerprint: fingerprint(original),
                afterFingerprint: fingerprint(repaired)
            ))
        }
        return plan
    }

    private static func restoreExactBytes(
        _ plan: [PlannedEntry],
        storage: AnchoredBottleStorage
    ) throws {
        for entry in plan.reversed() {
            let rollback = try storage.readRegularFile(entry.rollbackRelativePath).data
            guard rollback == entry.original else {
                throw RegressionCoreError.invalidEvidence("el backup presenta drift antes del rollback")
            }
            try storage.replaceRegularFile(
                entry.targetRelativePath,
                data: rollback,
                permissions: entry.permissions ?? 0o600
            )
            let restored = try storage.readRegularFile(entry.targetRelativePath).data
            guard restored == entry.original, fingerprint(restored) == entry.beforeFingerprint else {
                throw RegressionCoreError.invalidEvidence("los bytes restaurados no coinciden exactamente")
            }
        }
    }

    private static func persist(
        _ journal: Journal,
        at relativePath: String,
        storage: AnchoredBottleStorage
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try storage.ensureDirectory(journalDirectory, permissions: 0o700)
        try storage.replaceRegularFile(
            relativePath,
            data: try encoder.encode(journal),
            permissions: 0o600
        )
    }

    private static func recoverInterruptedTransactions(
        storage: AnchoredBottleStorage,
        bottleURL: URL,
        recordReceipt: (GameDisplayStateRepairReceiptContext) async throws -> Void
    ) async -> GameDisplayStateRepairTransactionOutcome {
        let names: [String]
        do {
            names = try storage.directoryEntries(journalDirectory).filter { $0.hasSuffix(".json") }
        } catch {
            return .unsafe(.init(
                mutationOccurred: false,
                message: "No se pudo enumerar el journal: \(error.localizedDescription)"
            ))
        }
        guard !names.isEmpty else { return .noOp }
        var recoveredReports: [GameDisplayStateRepairReport] = []
        var committed = false
        for name in names.sorted() {
            let relativePath = "\(journalDirectory)/\(name)"
            do {
                let data = try storage.readRegularFile(relativePath).data
                let journal = try JSONDecoder().decode(Journal.self, from: data)
                guard journal.schema == 1, name == "\(journal.transactionID.uuidString).json",
                      !journal.entries.isEmpty else {
                    throw RegressionCoreError.invalidEvidence("journal de reparación no válido")
                }
                let plan = try journal.entries.map { entry -> PlannedEntry in
                    let current = try storage.readRegularFile(entry.targetRelativePath).data
                    let rollback = try? storage.readRegularFile(entry.rollbackRelativePath).data
                    guard fingerprint(current) == entry.beforeFingerprint
                            || fingerprint(current) == entry.afterFingerprint else {
                        throw RegressionCoreError.invalidEvidence("el target del journal presenta drift")
                    }
                    if fingerprint(current) == entry.afterFingerprint,
                       rollback.map(fingerprint) != entry.beforeFingerprint {
                        throw RegressionCoreError.invalidEvidence("falta un rollback exacto para el journal")
                    }
                    return PlannedEntry(
                        targetRelativePath: entry.targetRelativePath,
                        rollbackRelativePath: entry.rollbackRelativePath,
                        optionsURL: bottleURL.appendingPathComponent(entry.targetRelativePath),
                        rollbackURL: bottleURL.appendingPathComponent(entry.rollbackRelativePath),
                        original: rollback ?? current,
                        repaired: current,
                        permissions: entry.permissions,
                        beforeFingerprint: entry.beforeFingerprint,
                        afterFingerprint: entry.afterFingerprint
                    )
                }
                let report = GameDisplayStateRepairReport(
                    entries: plan.map {
                        .init(
                            optionsURL: $0.optionsURL,
                            rollbackURL: $0.rollbackURL,
                            beforeFingerprint: $0.beforeFingerprint,
                            afterFingerprint: $0.afterFingerprint
                        )
                    },
                    intentURL: bottleURL.appendingPathComponent(relativePath)
                )
                if journal.phase == .mutated,
                   try plan.allSatisfy({
                       fingerprint(try storage.readRegularFile($0.targetRelativePath).data)
                           == $0.afterFingerprint
                   }) {
                    do {
                        try await recordReceipt(.init(
                            receiptID: journal.successReceiptID,
                            beforeFingerprint: report.aggregateBeforeFingerprint,
                            afterFingerprint: report.aggregateAfterFingerprint,
                            intentURL: bottleURL.appendingPathComponent(relativePath),
                            repairedFileCount: plan.count,
                            result: .succeeded
                        ))
                    } catch {
                        // El ledger no pudo completar el commit recuperado: restaura abajo.
                        try restoreJournalEntries(journal.entries, storage: storage)
                        try? await recordReceipt(.init(
                            receiptID: journal.rollbackReceiptID,
                            beforeFingerprint: report.aggregateBeforeFingerprint,
                            afterFingerprint: report.aggregateAfterFingerprint,
                            intentURL: bottleURL.appendingPathComponent(relativePath),
                            repairedFileCount: plan.count,
                            result: .rolledBack
                        ))
                        try storage.removeRegularFile(relativePath)
                        recoveredReports.append(report)
                        continue
                    }
                    do {
                        try storage.removeRegularFile(relativePath)
                    } catch {
                        return .unsafe(.init(
                            mutationOccurred: true,
                            message: "El recibo recuperado existe, pero el journal no pudo cerrarse: \(error.localizedDescription)"
                        ))
                    }
                    committed = true
                    recoveredReports.append(report)
                    continue
                }
                try restoreJournalEntries(journal.entries, storage: storage)
                try? await recordReceipt(.init(
                    receiptID: journal.rollbackReceiptID,
                    beforeFingerprint: report.aggregateBeforeFingerprint,
                    afterFingerprint: report.aggregateAfterFingerprint,
                    intentURL: bottleURL.appendingPathComponent(relativePath),
                    repairedFileCount: plan.count,
                    result: .rolledBack
                ))
                try storage.removeRegularFile(relativePath)
                recoveredReports.append(report)
            } catch {
                return .unsafe(.init(
                    mutationOccurred: true,
                    message: "No se pudo reconciliar el journal \(name): \(error.localizedDescription)"
                ))
            }
        }
        let merged = GameDisplayStateRepairReport(entries: recoveredReports.flatMap(\.entries))
        return committed ? .committed(merged) : .rolledBack(merged)
    }

    private static func restoreJournalEntries(
        _ entries: [JournalEntry],
        storage: AnchoredBottleStorage
    ) throws {
        for entry in entries.reversed() {
            let current = try storage.readRegularFile(entry.targetRelativePath).data
            if fingerprint(current) == entry.beforeFingerprint { continue }
            guard fingerprint(current) == entry.afterFingerprint else {
                throw RegressionCoreError.invalidEvidence("el target cambió fuera de la transacción")
            }
            let backup = try storage.readRegularFile(entry.rollbackRelativePath).data
            guard fingerprint(backup) == entry.beforeFingerprint else {
                throw RegressionCoreError.invalidEvidence("el backup del journal presenta drift")
            }
            try storage.replaceRegularFile(
                entry.targetRelativePath,
                data: backup,
                permissions: entry.permissions
            )
            guard fingerprint(try storage.readRegularFile(entry.targetRelativePath).data)
                    == entry.beforeFingerprint else {
                throw RegressionCoreError.invalidEvidence("el rollback recuperado no coincide")
            }
        }
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let type = String(cString: number.objCType)
        guard type != "c", type != "B", number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Acceso a la botella anclado a un descriptor. Cada componente intermedio se abre con
/// `O_NOFOLLOW`; las sustituciones usan el descriptor del padre y sincronizan fichero y directorio.
private final class AnchoredBottleStorage {
    final class ExclusiveLock {
        private let descriptor: Int32

        fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

        deinit {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
    }

    struct RegularFile {
        let data: Data
        let permissions: Int
    }

    private let rootFD: Int32

    init(rootURL: URL) throws {
        rootFD = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else {
            throw RegressionCoreError.invalidEvidence("la raíz de la botella no es un directorio físico")
        }
    }

    deinit { Darwin.close(rootFD) }

    func ensureDirectory(_ relativePath: String, permissions: Int) throws {
        let components = try validatedComponents(relativePath)
        var currentFD = Darwin.dup(rootFD)
        guard currentFD >= 0 else { throw posixFailure("no se pudo duplicar la raíz") }
        defer { Darwin.close(currentFD) }
        for component in components {
            var nextFD = Darwin.openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            if nextFD < 0, errno == ENOENT {
                guard Darwin.mkdirat(currentFD, component, mode_t(permissions)) == 0
                        || errno == EEXIST else {
                    throw posixFailure("no se pudo crear un directorio anclado")
                }
                nextFD = Darwin.openat(
                    currentFD,
                    component,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextFD >= 0 else { throw posixFailure("un directorio anclado no es seguro") }
            guard Darwin.fchmod(nextFD, mode_t(permissions)) == 0 else {
                Darwin.close(nextFD)
                throw posixFailure("no se pudieron fijar permisos privados")
            }
            Darwin.close(currentFD)
            currentFD = nextFD
        }
        guard Darwin.fsync(currentFD) == 0 else {
            throw posixFailure("no se pudo sincronizar el directorio")
        }
    }

    func directoryEntries(_ relativePath: String) throws -> [String] {
        let directoryFD = try openDirectory(relativePath)
        let duplicateFD = Darwin.dup(directoryFD)
        Darwin.close(directoryFD)
        guard duplicateFD >= 0, let directory = Darwin.fdopendir(duplicateFD) else {
            if duplicateFD >= 0 { Darwin.close(duplicateFD) }
            throw posixFailure("no se pudo enumerar el directorio anclado")
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != "..", isSafeComponent(name) else { continue }
            names.append(name)
        }
        return names
    }

    func readRegularFile(_ relativePath: String) throws -> RegularFile {
        let (parentFD, name) = try openParent(relativePath)
        defer { Darwin.close(parentFD) }
        let fileFD = Darwin.openat(parentFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fileFD >= 0 else { throw posixFailure("no se pudo abrir un fichero anclado") }
        defer { Darwin.close(fileFD) }
        var status = stat()
        guard Darwin.fstat(fileFD, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= 1_048_576 else {
            throw RegressionCoreError.invalidEvidence("el fichero anclado no es regular y único")
        }
        var data = Data(count: Int(status.st_size))
        let count = try data.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.read(fileFD, base.advanced(by: offset), buffer.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result >= 0 else { throw posixFailure("no se pudo leer el fichero anclado") }
                if result == 0 { break }
                offset += result
            }
            return offset
        }
        guard count == data.count else {
            throw RegressionCoreError.invalidEvidence("la lectura anclada quedó incompleta")
        }
        return RegularFile(data: data, permissions: Int(status.st_mode & 0o777))
    }

    func createRegularFileIfAbsent(
        _ relativePath: String,
        data: Data,
        permissions: Int
    ) throws {
        let (parentFD, name) = try openParent(relativePath)
        defer { Darwin.close(parentFD) }
        let fileFD = Darwin.openat(
            parentFD,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(permissions)
        )
        if fileFD < 0, errno == EEXIST { return }
        guard fileFD >= 0 else { throw posixFailure("no se pudo crear el rollback anclado") }
        do {
            try writeAll(data, to: fileFD)
            guard Darwin.fchmod(fileFD, mode_t(permissions)) == 0,
                  Darwin.fsync(fileFD) == 0,
                  Darwin.fsync(parentFD) == 0 else {
                throw posixFailure("no se pudo sincronizar el rollback")
            }
            Darwin.close(fileFD)
        } catch {
            Darwin.close(fileFD)
            _ = Darwin.unlinkat(parentFD, name, 0)
            throw error
        }
    }

    func acquireExclusiveLock(_ relativePath: String, permissions: Int) throws -> ExclusiveLock {
        let (parentFD, name) = try openParent(relativePath)
        defer { Darwin.close(parentFD) }
        let descriptor = Darwin.openat(
            parentFD,
            name,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            mode_t(permissions)
        )
        guard descriptor >= 0 else { throw posixFailure("no se pudo abrir el lock transaccional") }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              Darwin.fchmod(descriptor, mode_t(permissions)) == 0,
              Darwin.fsync(descriptor) == 0,
              Darwin.fsync(parentFD) == 0 else {
            Darwin.close(descriptor)
            throw RegressionCoreError.invalidEvidence("el lock transaccional no es regular y durable")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw RegressionCoreError.invalidEvidence("ya existe otra reparación transaccional activa")
        }
        return ExclusiveLock(descriptor: descriptor)
    }

    func replaceRegularFile(
        _ relativePath: String,
        data: Data,
        permissions: Int,
        faultAfterRename: Bool = false
    ) throws {
        let (parentFD, name) = try openParent(relativePath)
        defer { Darwin.close(parentFD) }
        let temporary = ".regression-tmp-\(UUID().uuidString)"
        let temporaryFD = Darwin.openat(
            parentFD,
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(permissions)
        )
        guard temporaryFD >= 0 else { throw posixFailure("no se pudo crear el temporal anclado") }
        var temporaryIsOpen = true
        do {
            try writeAll(data, to: temporaryFD)
            guard Darwin.fchmod(temporaryFD, mode_t(permissions)) == 0,
                  Darwin.fsync(temporaryFD) == 0 else {
                throw posixFailure("no se pudo sincronizar el temporal")
            }
            Darwin.close(temporaryFD)
            temporaryIsOpen = false
            guard Darwin.renameat(parentFD, temporary, parentFD, name) == 0 else {
                throw posixFailure("no se pudo comprometer el fichero anclado")
            }
            if faultAfterRename {
                throw RegressionCoreError.invalidEvidence("fallo inyectado después de rename y antes de fsync")
            }
            guard Darwin.fsync(parentFD) == 0 else {
                throw posixFailure("no se pudo sincronizar el directorio del fichero anclado")
            }
        } catch {
            if temporaryIsOpen { Darwin.close(temporaryFD) }
            _ = Darwin.unlinkat(parentFD, temporary, 0)
            throw error
        }
    }

    func removeRegularFile(_ relativePath: String) throws {
        let (parentFD, name) = try openParent(relativePath)
        defer { Darwin.close(parentFD) }
        var status = stat()
        guard Darwin.fstatat(parentFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw RegressionCoreError.invalidEvidence("el journal a eliminar no es regular")
        }
        guard Darwin.unlinkat(parentFD, name, 0) == 0, Darwin.fsync(parentFD) == 0 else {
            throw posixFailure("no se pudo cerrar durablemente el journal")
        }
    }

    private func openDirectory(_ relativePath: String) throws -> Int32 {
        let components = try validatedComponents(relativePath)
        var currentFD = Darwin.dup(rootFD)
        guard currentFD >= 0 else { throw posixFailure("no se pudo duplicar la raíz") }
        for component in components {
            let nextFD = Darwin.openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            Darwin.close(currentFD)
            guard nextFD >= 0 else { throw posixFailure("la ruta anclada atraviesa un enlace") }
            currentFD = nextFD
        }
        return currentFD
    }

    private func openParent(_ relativePath: String) throws -> (Int32, String) {
        var components = try validatedComponents(relativePath)
        guard let name = components.popLast() else {
            throw RegressionCoreError.invalidEvidence("falta el nombre de fichero")
        }
        let parent = components.isEmpty ? Darwin.dup(rootFD) : try openDirectory(components.joined(separator: "/"))
        guard parent >= 0 else { throw posixFailure("no se pudo abrir el padre anclado") }
        return (parent, name)
    }

    private func validatedComponents(_ relativePath: String) throws -> [String] {
        guard !relativePath.hasPrefix("/") else {
            throw RegressionCoreError.invalidEvidence("una ruta anclada no puede ser absoluta")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy(isSafeComponent) else {
            throw RegressionCoreError.invalidEvidence("la ruta anclada contiene componentes inválidos")
        }
        return components
    }

    private func isSafeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let result = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw posixFailure("no se pudo escribir el fichero anclado") }
                offset += result
            }
        }
    }

    private func posixFailure(_ message: String) -> RegressionCoreError {
        RegressionCoreError.invalidEvidence("\(message): \(String(cString: strerror(errno)))")
    }
}
