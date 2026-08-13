import Foundation

public enum GameTestReadinessStatus: String, Codable, CaseIterable, Sendable {
    case ready
    case warning
    case blocked

    public var displayName: String {
        switch self {
        case .ready: "Listo para probar"
        case .warning: "Listo con avisos"
        case .blocked: "Preparación bloqueada"
        }
    }

    fileprivate var priority: Int {
        switch self {
        case .ready: 0
        case .warning: 1
        case .blocked: 2
        }
    }
}

public enum GameTestPreflightCheckID: String, Codable, CaseIterable, Sendable {
    case databaseIntegrity
    case backendAvailability
    case backendIsolation
    case gameInstallation
    case wineRuntimeIsolation
    case wineServiceLifecycle
    case dxmtPresentationState
    case storageCapacity
    case telemetryAccess
    case sharedLibrary
}

/// Indica en qué punto del lanzamiento se observó el entorno.
///
/// `preLaunch` es la garantía fuerte usada por los botones de Regression. Cuando el usuario
/// pulsa «Jugar» dentro del cliente completo de Steam no existe un hook previo oficial; en ese
/// caso se conserva una instantánea en el primer límite de proceso observado y se etiqueta como
/// `processStartBoundary` para no presentar evidencia posterior como si fuese previa.
public enum GameTestPreflightCapturePhase: String, Codable, CaseIterable, Sendable {
    case preLaunch
    case processStartBoundary

    public var displayName: String {
        switch self {
        case .preLaunch: "Antes del lanzamiento"
        case .processStartBoundary: "Al observar el inicio en Steam"
        }
    }
}

public struct GameTestPreflightCheck: Codable, Equatable, Identifiable, Sendable {
    public var id: GameTestPreflightCheckID { checkID }

    public let checkID: GameTestPreflightCheckID
    public let status: GameTestReadinessStatus
    public let title: String
    public let detail: String
    public let recoveryAction: String?

    public init(
        checkID: GameTestPreflightCheckID,
        status: GameTestReadinessStatus,
        title: String,
        detail: String,
        recoveryAction: String? = nil
    ) {
        self.checkID = checkID
        self.status = status
        self.title = title
        self.detail = detail
        self.recoveryAction = recoveryAction
    }
}

/// Instantánea saneada del entorno vinculada a una prueba y a su fase temporal exacta.
///
/// No contiene comandos completos, rutas personales, nombres de cuenta ni PID. Su objetivo es
/// distinguir una regresión del juego de un problema ambiental sin convertir la base local en
/// una fuente de comandos ejecutables.
public struct GameTestPreflightReport: Codable, Equatable, Identifiable, Sendable {
    public static let protocolVersion = 2

    public let id: UUID
    public let protocolVersion: Int
    public let appID: String?
    public let gameName: String?
    public let backend: BackendKind
    public let checkedAt: Date
    public let capturePhase: GameTestPreflightCapturePhase
    public let captureDelayMilliseconds: Int?
    public let checks: [GameTestPreflightCheck]

    public init(
        id: UUID = UUID(),
        protocolVersion: Int = GameTestPreflightReport.protocolVersion,
        appID: String?,
        gameName: String?,
        backend: BackendKind,
        checkedAt: Date = Date(),
        capturePhase: GameTestPreflightCapturePhase = .preLaunch,
        captureDelayMilliseconds: Int? = nil,
        checks: [GameTestPreflightCheck]
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.appID = appID.flatMap(SteamAppID.normalized)
        self.gameName = gameName.map {
            SteamGameName.normalized($0, appID: appID ?? "desconocido")
        }
        self.backend = backend
        self.checkedAt = checkedAt
        self.capturePhase = capturePhase
        self.captureDelayMilliseconds = capturePhase == .processStartBoundary
            ? max(0, captureDelayMilliseconds ?? 0)
            : nil
        self.checks = checks
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case protocolVersion
        case appID
        case gameName
        case backend
        case checkedAt
        case capturePhase
        case captureDelayMilliseconds
        case checks
    }

    /// Conserva la lectura de los informes v1. La fase ausente era necesariamente previa porque
    /// esa versión solo se persistía desde el botón de lanzamiento de Regression.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        appID = try container.decodeIfPresent(String.self, forKey: .appID)
        gameName = try container.decodeIfPresent(String.self, forKey: .gameName)
        backend = try container.decode(BackendKind.self, forKey: .backend)
        checkedAt = try container.decode(Date.self, forKey: .checkedAt)
        capturePhase = try container.decodeIfPresent(
            GameTestPreflightCapturePhase.self,
            forKey: .capturePhase
        ) ?? .preLaunch
        captureDelayMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .captureDelayMilliseconds
        )
        checks = try container.decode([GameTestPreflightCheck].self, forKey: .checks)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encodeIfPresent(appID, forKey: .appID)
        try container.encodeIfPresent(gameName, forKey: .gameName)
        try container.encode(backend, forKey: .backend)
        try container.encode(checkedAt, forKey: .checkedAt)
        try container.encode(capturePhase, forKey: .capturePhase)
        try container.encodeIfPresent(
            captureDelayMilliseconds,
            forKey: .captureDelayMilliseconds
        )
        try container.encode(checks, forKey: .checks)
    }

    public var status: GameTestReadinessStatus {
        checks.map(\.status).max { $0.priority < $1.priority } ?? .ready
    }

    public var blockerCount: Int {
        checks.count { $0.status == .blocked }
    }

    public var warningCount: Int {
        checks.count { $0.status == .warning }
    }

    public var requiresAttention: Bool {
        status != .ready
    }

    public var hasCompleteCheckSet: Bool {
        checks.count == GameTestPreflightCheckID.allCases.count
            && Set(checks.map { $0.checkID.rawValue }).count
                == GameTestPreflightCheckID.allCases.count
    }

    public var blockingSummary: String {
        let blockers = checks.filter { $0.status == .blocked }
        guard !blockers.isEmpty else { return "" }
        return blockers.map { check in
            if let recovery = check.recoveryAction, !recovery.isEmpty {
                return "\(check.title): \(check.detail) \(recovery)"
            }
            return "\(check.title): \(check.detail)"
        }
        .joined(separator: " ")
    }
}

public struct RunPreflightSnapshot: Codable, Equatable, Sendable {
    public let runID: UUID
    public let reportFingerprint: String
    public let report: GameTestPreflightReport

    public init(
        runID: UUID,
        reportFingerprint: String,
        report: GameTestPreflightReport
    ) {
        self.runID = runID
        self.reportFingerprint = reportFingerprint
        self.report = report
    }
}

struct GameTestProcessRecord: Equatable, Sendable {
    let processID: Int32
    let parentProcessID: Int32
    let executable: String

    var normalizedExecutable: String {
        executable.lowercased()
    }

    var isWineServer: Bool {
        Self.lastPathComponent(of: normalizedExecutable) == "wineserver"
    }

    var isWineServicesProcess: Bool {
        Self.lastPathComponent(of: normalizedExecutable) == "services.exe"
    }

    var isKnownRegressionWineServer: Bool {
        isWineServer
            && normalizedExecutable.contains("regression.app/contents/sharedsupport/wine-root")
    }

    var isKnownCrossOverWineServer: Bool {
        isWineServer
            && normalizedExecutable.contains("crossover.app/contents/sharedsupport/crossover")
    }

    private static func lastPathComponent(of executable: String) -> String {
        let normalized = executable.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? normalized
    }
}

public actor GameTestPreflight {
    private static let warningCapacityBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    private static let blockingCapacityBytes: Int64 = 1 * 1_024 * 1_024 * 1_024

    private let runner: any ProcessRunning
    private let fileManager: FileManager
    private let applicationSupportURL: URL

    public init(
        runner: any ProcessRunning,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) {
        self.runner = runner
        self.fileManager = fileManager
        self.applicationSupportURL = applicationSupportURL
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Regression",
                    isDirectory: true
                )
    }

    public func evaluate(
        backend: BackendKind,
        installations: InstallationSnapshot,
        runningState: RunningBackendState,
        databaseHealth: CompatibilityDatabaseHealth,
        sharedLibraryAssessment: SharedLibraryAssessment?,
        physicalCustodyAssessment: PhysicalLibraryCustodyAssessment? = nil,
        game: SteamGame? = nil,
        targetAppID: String? = nil,
        targetGameName: String? = nil,
        checkedAt: Date = Date(),
        capturePhase: GameTestPreflightCapturePhase = .preLaunch,
        processStartedAt: Date? = nil
    ) async -> GameTestPreflightReport {
        let steamRootURL = selectedSteamRoot(
            backend: backend,
            installations: installations
        )
        var checks: [GameTestPreflightCheck] = [
            databaseCheck(databaseHealth),
            backendAvailabilityCheck(backend: backend, installations: installations),
            backendIsolationCheck(backend: backend, runningState: runningState),
            gameInstallationCheck(
                game: game,
                targetAppID: targetAppID,
                steamRootURL: steamRootURL
            ),
        ]

        let processResult = try? await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"),
            // `comm` contiene únicamente el ejecutable real, sin argumentos que puedan fingir
            // `wineserver`, y conserva rutas con espacios como una única tercera columna.
            arguments: ["-axo", "pid=,ppid=,comm="],
            environment: nil
        )
        if let processResult, processResult.exitCode == 0 {
            let records = Self.parseProcessList(processResult.standardOutput)
            checks.append(wineRuntimeCheck(records))
            checks.append(wineServiceCheck(records))
        } else {
            checks.append(GameTestPreflightCheck(
                checkID: .wineRuntimeIsolation,
                status: .warning,
                title: "Aislamiento de Wine",
                detail: "No se pudo inspeccionar el árbol de procesos.",
                recoveryAction: "Vuelve a comprobar el entorno antes de atribuir un fallo al juego."
            ))
            checks.append(GameTestPreflightCheck(
                checkID: .wineServiceLifecycle,
                status: .warning,
                title: "Servicios de Wine",
                detail: "No se pudo descartar la presencia de servicios huérfanos.",
                recoveryAction: "Actualiza el estado de Regression y repite la comprobación."
            ))
        }

        checks.append(dxmtStateCheck(
            backend: backend,
            installations: installations,
            runningState: runningState
        ))
        checks.append(storageCheck(steamRootURL: steamRootURL))
        checks.append(telemetryCheck(steamRootURL: steamRootURL))
        checks.append(sharedLibraryCheck(
            installations: installations,
            assessment: sharedLibraryAssessment,
            physicalCustody: physicalCustodyAssessment
        ))

        return GameTestPreflightReport(
            appID: game?.appID ?? targetAppID,
            gameName: game?.name ?? targetGameName,
            backend: backend,
            checkedAt: checkedAt,
            capturePhase: capturePhase,
            captureDelayMilliseconds: processStartedAt.map {
                max(0, Int(checkedAt.timeIntervalSince($0) * 1_000))
            },
            checks: checks
        )
    }

    static func parseProcessList(_ output: String) -> [GameTestProcessRecord] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                  let processID = Int32(fields[0]),
                  let parentProcessID = Int32(fields[1]) else {
                return nil
            }
            let executable = fields[2].trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))
            )
            guard !executable.isEmpty else { return nil }
            return GameTestProcessRecord(
                processID: processID,
                parentProcessID: parentProcessID,
                executable: executable
            )
        }
    }

    private func selectedSteamRoot(
        backend: BackendKind,
        installations: InstallationSnapshot
    ) -> URL? {
        switch backend {
        case .crossOver: installations.crossOver?.steamRootURL
        case .regression: installations.regression.steamRootURL
        }
    }

    private func databaseCheck(
        _ health: CompatibilityDatabaseHealth
    ) -> GameTestPreflightCheck {
        if health.isHealthy, health.schemaVersion == CompatibilityRepository.currentSchemaVersion {
            return GameTestPreflightCheck(
                checkID: .databaseIntegrity,
                status: .ready,
                title: "Base de aprendizaje",
                detail: "SQLite está íntegra y usa el esquema v\(health.schemaVersion)."
            )
        }
        return GameTestPreflightCheck(
            checkID: .databaseIntegrity,
            status: .blocked,
            title: "Base de aprendizaje",
            detail: "La base local no supera sus comprobaciones de integridad o migración.",
            recoveryAction: "No inicies una prueba hasta restaurar o reparar la base."
        )
    }

    private func backendAvailabilityCheck(
        backend: BackendKind,
        installations: InstallationSnapshot
    ) -> GameTestPreflightCheck {
        switch backend {
        case .crossOver:
            guard let installation = installations.crossOver else {
                return GameTestPreflightCheck(
                    checkID: .backendAvailability,
                    status: .blocked,
                    title: "Motor CrossOver",
                    detail: installations.crossOverIssue?.message
                        ?? "No se detectó una instalación utilizable.",
                    recoveryAction: installations.crossOverIssue?.recoveryAction
                        ?? "Abre CrossOver para revisar la instalación."
                )
            }
            switch installation.health {
            case .ready:
                return GameTestPreflightCheck(
                    checkID: .backendAvailability,
                    status: .ready,
                    title: "Motor CrossOver",
                    detail: "La botella \(installation.bottleName) y su CLI oficial están disponibles."
                )
            case .updateRequired, .unknown:
                return GameTestPreflightCheck(
                    checkID: .backendAvailability,
                    status: .warning,
                    title: "Motor CrossOver",
                    detail: installation.healthDetail,
                    recoveryAction: "Permite que CrossOver complete cualquier actualización antes de validar el juego."
                )
            case .missing, .damaged:
                return GameTestPreflightCheck(
                    checkID: .backendAvailability,
                    status: .blocked,
                    title: "Motor CrossOver",
                    detail: installation.healthDetail,
                    recoveryAction: "Repara la instalación desde CrossOver."
                )
            }
        case .regression:
            let installation = installations.regression
            guard installation.health == .ready,
                  fileManager.isExecutableFile(atPath: installation.engineLauncherURL.path) else {
                return GameTestPreflightCheck(
                    checkID: .backendAvailability,
                    status: .blocked,
                    title: "Motor propio",
                    detail: installation.healthDetail,
                    recoveryAction: "Reinstala el bundle canónico antes de probar juegos."
                )
            }
            return GameTestPreflightCheck(
                checkID: .backendAvailability,
                status: .ready,
                title: "Motor propio",
                detail: "El lanzador canónico y la botella propia están disponibles."
            )
        }
    }

    private func backendIsolationCheck(
        backend: BackendKind,
        runningState: RunningBackendState
    ) -> GameTestPreflightCheck {
        if runningState.hasConflict {
            return GameTestPreflightCheck(
                checkID: .backendIsolation,
                status: .blocked,
                title: "Aislamiento de Steam",
                detail: "CrossOver y Regression tienen clientes de Steam activos a la vez.",
                recoveryAction: "Cierra uno de forma normal y vuelve a comprobar."
            )
        }
        if let active = runningState.activeBackend, active != backend {
            return GameTestPreflightCheck(
                checkID: .backendIsolation,
                status: .blocked,
                title: "Aislamiento de Steam",
                detail: "Steam está activo con \(active.displayName), no con \(backend.displayName).",
                recoveryAction: "Usa el cambio de motor de Regression antes de lanzar el juego."
            )
        }
        return GameTestPreflightCheck(
            checkID: .backendIsolation,
            status: .ready,
            title: "Aislamiento de Steam",
            detail: runningState.activeBackend == backend
                ? "Solo está activo el backend seleccionado."
                : "No hay otro cliente de Steam interfiriendo."
        )
    }

    private func gameInstallationCheck(
        game: SteamGame?,
        targetAppID: String?,
        steamRootURL: URL?
    ) -> GameTestPreflightCheck {
        guard let game else {
            if let targetAppID = targetAppID.flatMap(SteamAppID.normalized) {
                return GameTestPreflightCheck(
                    checkID: .gameInstallation,
                    status: .warning,
                    title: "Instalación del juego",
                    detail: "Steam inició el App ID \(targetAppID), pero su manifest aún no estaba en el inventario de Regression.",
                    recoveryAction: "Actualiza la biblioteca antes de certificar esta ejecución."
                )
            }
            return GameTestPreflightCheck(
                checkID: .gameInstallation,
                status: .ready,
                title: "Juego objetivo",
                detail: "La comprobación general no requiere seleccionar un juego."
            )
        }
        guard let steamRootURL else {
            return GameTestPreflightCheck(
                checkID: .gameInstallation,
                status: .blocked,
                title: "Instalación del juego",
                detail: "No se pudo resolver la carpeta de Steam del backend seleccionado.",
                recoveryAction: "Actualiza la detección de instalaciones."
            )
        }

        let steamAppsRoot = steamRootURL
            .appendingPathComponent("steamapps", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let manifestURL = game.manifestURL.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isContained(manifestURL, in: steamAppsRoot),
              fileManager.fileExists(atPath: manifestURL.path),
              let contents = try? String(contentsOf: manifestURL, encoding: .utf8),
              SteamManifestParser.parse(
                  contents: contents,
                  manifestURL: manifestURL,
                  backend: game.sourceBackend
              )?.appID == game.appID else {
            return GameTestPreflightCheck(
                checkID: .gameInstallation,
                status: .blocked,
                title: "Instalación del juego",
                detail: "El manifest de Steam no existe, está fuera de la biblioteca o no coincide con el App ID.",
                recoveryAction: "Verifica los archivos desde Steam y actualiza Regression."
            )
        }

        if SteamManifestParser.installReadiness(in: contents) == .inProgress {
            return GameTestPreflightCheck(
                checkID: .gameInstallation,
                status: .blocked,
                title: "Instalación del juego",
                detail: "Steam todavía está descargando, actualizando o preparando el juego.",
                recoveryAction: "Espera a que Steam complete la instalación y repite el preflight."
            )
        }

        let commonRoot = steamAppsRoot
            .appendingPathComponent("common", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let gameRoot = commonRoot
            .appendingPathComponent(game.installDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard Self.isContained(gameRoot, in: commonRoot),
              fileManager.fileExists(atPath: gameRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return GameTestPreflightCheck(
                checkID: .gameInstallation,
                status: .blocked,
                title: "Instalación del juego",
                detail: "Steam declara el juego, pero su carpeta no está disponible de forma segura.",
                recoveryAction: "Completa o repara la instalación desde Steam."
            )
        }

        return GameTestPreflightCheck(
            checkID: .gameInstallation,
            status: .ready,
            title: "Instalación del juego",
            detail: "Manifest, App ID y carpeta instalada son coherentes."
        )
    }

    private func wineRuntimeCheck(
        _ records: [GameTestProcessRecord]
    ) -> GameTestPreflightCheck {
        let wineServers = records.filter(\.isWineServer)
        let foreign = wineServers.filter {
            !$0.isKnownRegressionWineServer && !$0.isKnownCrossOverWineServer
        }
        let definiteForeign = foreign.filter { $0.executable.hasPrefix("/") }
        if !definiteForeign.isEmpty {
            return GameTestPreflightCheck(
                checkID: .wineRuntimeIsolation,
                status: .blocked,
                title: "Aislamiento de Wine",
                detail: "Se detectaron \(definiteForeign.count) wineserver de otro runtime.",
                recoveryAction: "Cierra su aplicación propietaria antes de probar; Regression no terminará procesos ajenos automáticamente."
            )
        }
        if !foreign.isEmpty {
            return GameTestPreflightCheck(
                checkID: .wineRuntimeIsolation,
                status: .warning,
                title: "Aislamiento de Wine",
                detail: "Hay \(foreign.count) wineserver cuyo origen no pudo atribuirse con certeza.",
                recoveryAction: "Comprueba que no haya otra aplicación Wine activa."
            )
        }
        return GameTestPreflightCheck(
            checkID: .wineRuntimeIsolation,
            status: .ready,
            title: "Aislamiento de Wine",
            detail: wineServers.isEmpty
                ? "No hay wineservers activos."
                : "Todos los wineservers activos pertenecen a Regression o CrossOver."
        )
    }

    private func wineServiceCheck(
        _ records: [GameTestProcessRecord]
    ) -> GameTestPreflightCheck {
        let wineServers = records.filter(\.isWineServer)
        let orphanServices = records.filter {
            $0.isWineServicesProcess && $0.parentProcessID == 1 && wineServers.isEmpty
        }
        if !orphanServices.isEmpty {
            return GameTestPreflightCheck(
                checkID: .wineServiceLifecycle,
                status: .blocked,
                title: "Servicios de Wine",
                detail: "Se detectaron \(orphanServices.count) services.exe huérfanos sin wineserver.",
                recoveryAction: "Cierra esos restos de la sesión anterior antes de atribuir un fallo al juego."
            )
        }
        return GameTestPreflightCheck(
            checkID: .wineServiceLifecycle,
            status: .ready,
            title: "Servicios de Wine",
            detail: "No hay servicios huérfanos capaces de contaminar la prueba."
        )
    }

    private func dxmtStateCheck(
        backend: BackendKind,
        installations: InstallationSnapshot,
        runningState: RunningBackendState
    ) -> GameTestPreflightCheck {
        guard backend == .regression else {
            return GameTestPreflightCheck(
                checkID: .dxmtPresentationState,
                status: .ready,
                title: "Estado de presentación DXMT",
                detail: "No aplica al backend de referencia."
            )
        }
        let temporaryDirectory = installations.regression.bottleURL
            .appendingPathComponent("drive_c/windows/temp", isDirectory: true)
        let markers = ((try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix("dxmt-cxpresent-") && $0.pathExtension == "id"
        }
        if markers.isEmpty {
            return GameTestPreflightCheck(
                checkID: .dxmtPresentationState,
                status: .ready,
                title: "Estado de presentación DXMT",
                detail: "No hay marcadores de presentación pendientes."
            )
        }
        if runningState.regressionIsRunning {
            return GameTestPreflightCheck(
                checkID: .dxmtPresentationState,
                status: .ready,
                title: "Estado de presentación DXMT",
                detail: "Hay \(markers.count) marcadores asociados a la sesión activa; el lanzador los reinicia antes de cada solicitud."
            )
        }
        return GameTestPreflightCheck(
            checkID: .dxmtPresentationState,
            status: .warning,
            title: "Estado de presentación DXMT",
            detail: "Quedan \(markers.count) marcadores de una sesión cerrada.",
            recoveryAction: "El lanzador canónico los limpiará automáticamente; no abras el juego con Wine a mano."
        )
    }

    private func storageCheck(steamRootURL: URL?) -> GameTestPreflightCheck {
        let probeURL = steamRootURL ?? applicationSupportURL
        let capacity = try? probeURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        guard let capacity else {
            return GameTestPreflightCheck(
                checkID: .storageCapacity,
                status: .warning,
                title: "Espacio de trabajo",
                detail: "macOS no informó del espacio disponible para cachés y logs.",
                recoveryAction: "Comprueba el almacenamiento antes de una prueba prolongada."
            )
        }
        if capacity < Self.blockingCapacityBytes {
            return GameTestPreflightCheck(
                checkID: .storageCapacity,
                status: .blocked,
                title: "Espacio de trabajo",
                detail: "Queda menos de 1 GB disponible.",
                recoveryAction: "Libera espacio antes de iniciar el juego."
            )
        }
        if capacity < Self.warningCapacityBytes {
            return GameTestPreflightCheck(
                checkID: .storageCapacity,
                status: .warning,
                title: "Espacio de trabajo",
                detail: "Quedan menos de 5 GB para shader caches, logs y actualizaciones.",
                recoveryAction: "Libera espacio si la prueba va a instalar o recompilar contenido."
            )
        }
        return GameTestPreflightCheck(
            checkID: .storageCapacity,
            status: .ready,
            title: "Espacio de trabajo",
            detail: "Hay capacidad suficiente para una prueba reproducible."
        )
    }

    private func telemetryCheck(steamRootURL: URL?) -> GameTestPreflightCheck {
        guard let steamRootURL else {
            return GameTestPreflightCheck(
                checkID: .telemetryAccess,
                status: .blocked,
                title: "Telemetría local",
                detail: "No se pudo resolver la instalación de Steam.",
                recoveryAction: "Actualiza la detección antes de probar."
            )
        }
        let logsURL = steamRootURL.appendingPathComponent("logs", isDirectory: true)
        if fileManager.fileExists(atPath: logsURL.path) {
            guard fileManager.isReadableFile(atPath: logsURL.path) else {
                return GameTestPreflightCheck(
                    checkID: .telemetryAccess,
                    status: .blocked,
                    title: "Telemetría local",
                    detail: "La carpeta de logs de Steam no es legible.",
                    recoveryAction: "Revisa los permisos de la carpeta de Steam."
                )
            }
            return GameTestPreflightCheck(
                checkID: .telemetryAccess,
                status: .ready,
                title: "Telemetría local",
                detail: "Regression puede observar los logs locales de Steam."
            )
        }
        let parent = logsURL.deletingLastPathComponent()
        return GameTestPreflightCheck(
            checkID: .telemetryAccess,
            status: fileManager.isWritableFile(atPath: parent.path) ? .warning : .blocked,
            title: "Telemetría local",
            detail: "Steam todavía no ha creado su carpeta de logs.",
            recoveryAction: "Abre Steam una vez y vuelve a comprobar antes de validar el resultado."
        )
    }

    private func sharedLibraryCheck(
        installations: InstallationSnapshot,
        assessment: SharedLibraryAssessment?,
        physicalCustody: PhysicalLibraryCustodyAssessment?
    ) -> GameTestPreflightCheck {
        if let physicalCustody {
            switch physicalCustody.status {
            case .independent:
                return GameTestPreflightCheck(
                    checkID: .sharedLibrary,
                    status: .ready,
                    title: "Biblioteca propia",
                    detail: "La única instalación física de los juegos está dentro de la botella de Regression."
                )
            case .pendingValidation, .validating:
                return GameTestPreflightCheck(
                    checkID: .sharedLibrary,
                    status: .warning,
                    title: "Biblioteca propia",
                    detail: "La biblioteca ya está en Regression y espera completar su validación funcional.",
                    recoveryAction: "Valida Steam y un juego con Regression antes de finalizar la custodia."
                )
            case .cutover, .verifying, .rollingBack:
                return GameTestPreflightCheck(
                    checkID: .sharedLibrary,
                    status: .blocked,
                    title: "Custodia de la biblioteca",
                    detail: "La biblioteca está atravesando una fase transaccional y no admite lanzamientos.",
                    recoveryAction: "Espera a que Regression alcance un estado recuperable."
                )
            case let .blocked(reason):
                return GameTestPreflightCheck(
                    checkID: .sharedLibrary,
                    status: .blocked,
                    title: "Custodia de la biblioteca",
                    detail: PrivacySanitizer.redactedLogExcerpt(reason, limit: 300),
                    recoveryAction: "Abre el diagnóstico de custodia antes de lanzar Steam."
                )
            case .eligibleForTransfer, .preparing, .preCutover:
                break
            }
        }
        guard installations.crossOver != nil else {
            return GameTestPreflightCheck(
                checkID: .sharedLibrary,
                status: .ready,
                title: "Biblioteca de Regression",
                detail: "Regression usa su propia ubicación para los archivos de los juegos."
            )
        }
        guard let assessment else {
            return GameTestPreflightCheck(
                checkID: .sharedLibrary,
                status: .warning,
                title: "Biblioteca compartida",
                detail: "No se pudo evaluar si ambos backends usan los mismos archivos.",
                recoveryAction: "Actualiza el estado de Regression."
            )
        }
        switch assessment.status {
        case .ready:
            return GameTestPreflightCheck(
                checkID: .sharedLibrary,
                status: .ready,
                title: "Biblioteca compartida",
                detail: "CrossOver y Regression usan una única instalación física de los juegos."
            )
        case .notConfigured:
            return GameTestPreflightCheck(
                checkID: .sharedLibrary,
                status: .warning,
                title: "Biblioteca compartida",
                detail: "Las bibliotecas aún no están unificadas.",
                recoveryAction: "Unifícalas desde Regression para que la comparación A/B use exactamente los mismos archivos."
            )
        case let .blocked(reason):
            return GameTestPreflightCheck(
                checkID: .sharedLibrary,
                status: .warning,
                title: "Biblioteca compartida",
                detail: "La unificación necesita atención: \(PrivacySanitizer.redactedLogExcerpt(reason, limit: 300))",
                recoveryAction: "No muevas archivos manualmente; revisa la sección Motor y biblioteca."
            )
        }
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
