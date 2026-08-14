import Foundation

public enum BackendKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case crossOver
    case regression

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .crossOver: "CrossOver"
        case .regression: "Regression"
        }
    }

    /// Las preferencias antiguas se conservan en almacenamiento, pero ya no conceden autoridad
    /// operativa: Regression es el único motor seleccionable.
    public static func launchSelection(storedRawValue: String?) -> BackendKind {
        _ = storedRawValue
        return .regression
    }

    /// La disponibilidad histórica de CrossOver no altera la selección de producto.
    public static func availableSelection(
        preferred: BackendKind,
        crossOverAvailable: Bool
    ) -> BackendKind {
        _ = preferred
        _ = crossOverAvailable
        return .regression
    }
}

public enum SteamAppID {
    public static func normalized(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              candidate.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let appID = UInt32(candidate),
              appID > 0 else {
            return nil
        }
        return String(appID)
    }
}

public enum SteamGameName {
    public static func placeholder(for appID: String) -> String {
        let canonicalAppID = SteamAppID.normalized(appID) ?? appID
        return "Steam App \(canonicalAppID)"
    }

    public static func normalized(_ value: String, appID: String) -> String {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? placeholder(for: appID) : candidate
    }

    public static func isPlaceholder(_ value: String, appID: String) -> Bool {
        normalized(value, appID: appID)
            .caseInsensitiveCompare(placeholder(for: appID)) == .orderedSame
    }
}

public enum InstallationHealth: String, Codable, Sendable {
    case ready
    case updateRequired
    case missing
    case damaged
    case unknown
}

public enum InstallationIssueCode: String, Codable, Sendable {
    case crossOverNotInstalled
    case steamBottleNotFound
    case steamNotInstalled
    case bottleDamaged
}

public struct InstallationIssue: Codable, Equatable, Sendable {
    public let code: InstallationIssueCode
    public let message: String
    public let recoveryAction: String

    public init(code: InstallationIssueCode, message: String, recoveryAction: String) {
        self.code = code
        self.message = message
        self.recoveryAction = recoveryAction
    }
}

public struct CrossOverInstallation: Codable, Equatable, Sendable {
    public let applicationURL: URL
    public let version: String
    public let build: String
    public let bottleName: String
    public let bottleURL: URL
    public let steamExecutableURL: URL
    public let wineCLIURL: URL
    public let bottleCLIURL: URL
    public let feedURL: URL?
    public let defaultGraphicsBackend: String?
    public let health: InstallationHealth
    public let healthDetail: String

    public init(
        applicationURL: URL,
        version: String,
        build: String,
        bottleName: String,
        bottleURL: URL,
        steamExecutableURL: URL,
        wineCLIURL: URL,
        bottleCLIURL: URL,
        feedURL: URL?,
        defaultGraphicsBackend: String? = nil,
        health: InstallationHealth,
        healthDetail: String
    ) {
        self.applicationURL = applicationURL
        self.version = version
        self.build = build
        self.bottleName = bottleName
        self.bottleURL = bottleURL
        self.steamExecutableURL = steamExecutableURL
        self.wineCLIURL = wineCLIURL
        self.bottleCLIURL = bottleCLIURL
        self.feedURL = feedURL
        self.defaultGraphicsBackend = defaultGraphicsBackend
        self.health = health
        self.healthDetail = healthDetail
    }

    public var steamRootURL: URL {
        steamExecutableURL.deletingLastPathComponent()
    }
}

public struct RegressionInstallation: Codable, Equatable, Sendable {
    public let applicationURL: URL
    public let bottleURL: URL
    public let steamExecutableURL: URL
    public let engineLauncherURL: URL
    public let health: InstallationHealth
    public let healthDetail: String

    public init(
        applicationURL: URL,
        bottleURL: URL,
        steamExecutableURL: URL,
        engineLauncherURL: URL,
        health: InstallationHealth,
        healthDetail: String
    ) {
        self.applicationURL = applicationURL
        self.bottleURL = bottleURL
        self.steamExecutableURL = steamExecutableURL
        self.engineLauncherURL = engineLauncherURL
        self.health = health
        self.healthDetail = healthDetail
    }

    public var steamRootURL: URL {
        steamExecutableURL.deletingLastPathComponent()
    }
}

public struct InstallationSnapshot: Sendable {
    public let crossOver: CrossOverInstallation?
    public let crossOverIssue: InstallationIssue?
    public let regression: RegressionInstallation
    public let discoveredAt: Date

    public init(
        crossOver: CrossOverInstallation?,
        crossOverIssue: InstallationIssue? = nil,
        regression: RegressionInstallation,
        discoveredAt: Date = Date()
    ) {
        self.crossOver = crossOver
        self.crossOverIssue = crossOverIssue
        self.regression = regression
        self.discoveredAt = discoveredAt
    }
}

public struct SteamGame: Codable, Hashable, Identifiable, Sendable {
    public let appID: String
    public let name: String
    public let installDirectory: String
    public let manifestURL: URL
    public let sourceBackend: BackendKind
    public let installedBytes: Int64?

    public var id: String { appID }

    public init(
        appID: String,
        name: String,
        installDirectory: String,
        manifestURL: URL,
        sourceBackend: BackendKind,
        installedBytes: Int64? = nil
    ) {
        self.appID = appID
        self.name = name
        self.installDirectory = installDirectory
        self.manifestURL = manifestURL
        self.sourceBackend = sourceBackend
        self.installedBytes = installedBytes
    }
}

public struct RunningBackendState: Equatable, Sendable {
    public let crossOverPIDs: [Int32]
    public let regressionPIDs: [Int32]

    public init(crossOverPIDs: [Int32] = [], regressionPIDs: [Int32] = []) {
        self.crossOverPIDs = crossOverPIDs
        self.regressionPIDs = regressionPIDs
    }

    public var crossOverIsRunning: Bool { !crossOverPIDs.isEmpty }
    public var regressionIsRunning: Bool { !regressionPIDs.isEmpty }
    public var hasConflict: Bool { crossOverIsRunning && regressionIsRunning }

    public var activeBackend: BackendKind? {
        if hasConflict { return nil }
        if crossOverIsRunning { return .crossOver }
        if regressionIsRunning { return .regression }
        return nil
    }
}

public struct BackendLaunch: Codable, Equatable, Sendable {
    public let backend: BackendKind
    public let processID: Int32
    public let command: String
    public let arguments: [String]
    public let logURL: URL
    public let startedAt: Date

    public init(
        backend: BackendKind,
        processID: Int32,
        command: String,
        arguments: [String],
        logURL: URL,
        startedAt: Date = Date()
    ) {
        self.backend = backend
        self.processID = processID
        self.command = command
        self.arguments = arguments
        self.logURL = logURL
        self.startedAt = startedAt
    }
}

public struct SystemSnapshot: Codable, Equatable, Sendable {
    public let macOSVersion: String
    public let architecture: String
    public let deviceModel: String
    public let displayWidth: Int
    public let displayHeight: Int
    public let displayScale: Double

    public init(
        macOSVersion: String,
        architecture: String,
        deviceModel: String,
        displayWidth: Int,
        displayHeight: Int,
        displayScale: Double
    ) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.deviceModel = deviceModel
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.displayScale = displayScale
    }
}

public enum RunResult: String, Codable, Sendable {
    case preparing
    case launched
    case succeeded
    case failed
    case crashed
    case unknown
}

public enum VerificationVerdict: String, Codable, CaseIterable, Sendable {
    case perfect
    case playableWithIssues
    case failed
    case invalidated

    public var displayName: String {
        switch self {
        case .perfect: "Perfecto"
        case .playableWithIssues: "Funciona con incidencias"
        case .failed: "No funciona"
        case .invalidated: "Verificación anulada"
        }
    }
}

public enum VerificationDimension: String, Codable, Sendable {
    case passed
    case failed
    case notTested
}

public struct VerificationEvidence: Codable, Equatable, Sendable {
    public let rendering: VerificationDimension
    public let inputPrecision: VerificationDimension
    public let graphicsSettings: VerificationDimension
    public let gameplay: VerificationDimension

    public init(
        rendering: VerificationDimension,
        inputPrecision: VerificationDimension,
        graphicsSettings: VerificationDimension,
        gameplay: VerificationDimension
    ) {
        self.rendering = rendering
        self.inputPrecision = inputPrecision
        self.graphicsSettings = graphicsSettings
        self.gameplay = gameplay
    }

    public static func manualDefault(for verdict: VerificationVerdict) -> Self {
        switch verdict {
        case .perfect:
            Self(
                rendering: .passed,
                inputPrecision: .passed,
                graphicsSettings: .passed,
                gameplay: .passed
            )
        case .playableWithIssues, .invalidated:
            Self(
                rendering: .notTested,
                inputPrecision: .notTested,
                graphicsSettings: .notTested,
                gameplay: .notTested
            )
        case .failed:
            Self(
                rendering: .failed,
                inputPrecision: .notTested,
                graphicsSettings: .notTested,
                gameplay: .notTested
            )
        }
    }

    public var isComplete: Bool {
        rendering == .passed
            && inputPrecision == .passed
            && graphicsSettings == .passed
            && gameplay == .passed
    }
}

public enum VerificationSource: String, Codable, Sendable {
    case automatic
    case user
    case visualInspection
    case imported
}

public struct RunVerification: Codable, Equatable, Sendable {
    public let runID: UUID
    public let verdict: VerificationVerdict
    public let rendering: VerificationDimension
    public let inputPrecision: VerificationDimension
    public let graphicsSettings: VerificationDimension
    public let gameplay: VerificationDimension
    public let source: VerificationSource
    public let notes: String
    public let verifiedAt: Date

    public init(
        runID: UUID,
        verdict: VerificationVerdict,
        rendering: VerificationDimension = .notTested,
        inputPrecision: VerificationDimension = .notTested,
        graphicsSettings: VerificationDimension = .notTested,
        gameplay: VerificationDimension = .notTested,
        source: VerificationSource,
        notes: String = "",
        verifiedAt: Date = Date()
    ) {
        self.runID = runID
        self.verdict = verdict
        self.rendering = rendering
        self.inputPrecision = inputPrecision
        self.graphicsSettings = graphicsSettings
        self.gameplay = gameplay
        self.source = source
        self.notes = notes
        self.verifiedAt = verifiedAt
    }

    public var hasCompletePerfectEvidence: Bool {
        verdict != .perfect || evidence.isComplete
    }

    public var evidence: VerificationEvidence {
        VerificationEvidence(
            rendering: rendering,
            inputPrecision: inputPrecision,
            graphicsSettings: graphicsSettings,
            gameplay: gameplay
        )
    }
}

public struct CompatibilityObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let appID: String
    public let gameName: String
    public let backend: BackendKind
    public let providerVersion: String
    public let verdict: VerificationVerdict
    public let rendering: VerificationDimension
    public let inputPrecision: VerificationDimension
    public let graphicsSettings: VerificationDimension
    public let gameplay: VerificationDimension
    public let configurationFingerprint: String
    public let configuration: [String: String]
    public let source: VerificationSource
    public let notes: String
    public let observedAt: Date

    public init(
        id: UUID = UUID(),
        appID: String,
        gameName: String,
        backend: BackendKind,
        providerVersion: String,
        verdict: VerificationVerdict,
        rendering: VerificationDimension = .notTested,
        inputPrecision: VerificationDimension = .notTested,
        graphicsSettings: VerificationDimension = .notTested,
        gameplay: VerificationDimension = .notTested,
        configurationFingerprint: String,
        configuration: [String: String],
        source: VerificationSource,
        notes: String,
        observedAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.gameName = gameName
        self.backend = backend
        self.providerVersion = providerVersion
        self.verdict = verdict
        self.rendering = rendering
        self.inputPrecision = inputPrecision
        self.graphicsSettings = graphicsSettings
        self.gameplay = gameplay
        self.configurationFingerprint = configurationFingerprint
        self.configuration = configuration
        self.source = source
        self.notes = notes
        self.observedAt = observedAt
    }

    public var hasCompletePerfectEvidence: Bool {
        verdict != .perfect || evidence.isComplete
    }

    public var evidence: VerificationEvidence {
        VerificationEvidence(
            rendering: rendering,
            inputPrecision: inputPrecision,
            graphicsSettings: graphicsSettings,
            gameplay: gameplay
        )
    }
}

public struct RunContext: Codable, Equatable, Sendable {
    public let id: UUID
    public let appID: String
    public let gameName: String
    public let backend: BackendKind
    public let bottleName: String
    public let providerVersion: String
    public let startedAt: Date
    public let command: String
    public let arguments: [String]
    public let system: SystemSnapshot
    public let configuration: [String: String]
    public let configurationFingerprint: String

    public init(
        id: UUID = UUID(),
        appID: String,
        gameName: String,
        backend: BackendKind,
        bottleName: String,
        providerVersion: String,
        startedAt: Date = Date(),
        command: String,
        arguments: [String],
        system: SystemSnapshot,
        configuration: [String: String],
        configurationFingerprint: String
    ) {
        self.id = id
        self.appID = appID
        self.gameName = gameName
        self.backend = backend
        self.bottleName = bottleName
        self.providerVersion = providerVersion
        self.startedAt = startedAt
        self.command = command
        self.arguments = arguments
        self.system = system
        self.configuration = configuration
        self.configurationFingerprint = configurationFingerprint
    }
}

public struct RunSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let appID: String
    public let gameName: String
    public let backend: BackendKind
    public let startedAt: Date
    public let endedAt: Date?
    public let result: RunResult
    public let exitCode: Int32?
    public let processID: Int32?
    public let launchDurationMilliseconds: Int?
    public let configurationFingerprint: String
    public let verification: RunVerification?

    public init(
        id: UUID,
        appID: String,
        gameName: String,
        backend: BackendKind,
        startedAt: Date,
        endedAt: Date?,
        result: RunResult,
        exitCode: Int32?,
        processID: Int32? = nil,
        launchDurationMilliseconds: Int?,
        configurationFingerprint: String,
        verification: RunVerification? = nil
    ) {
        self.id = id
        self.appID = appID
        self.gameName = gameName
        self.backend = backend
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.result = result
        self.exitCode = exitCode
        self.processID = processID
        self.launchDurationMilliseconds = launchDurationMilliseconds
        self.configurationFingerprint = configurationFingerprint
        self.verification = verification
    }
}

public struct RunDetail: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let appID: String
    public let gameName: String
    public let backend: BackendKind
    public let bottleName: String
    public let providerVersion: String
    public let startedAt: Date
    public let endedAt: Date?
    public let result: RunResult
    public let exitCode: Int32?
    public let processID: Int32?
    public let executable: String?
    public let launchDurationMilliseconds: Int?
    public let command: String
    public let arguments: [String]
    public let system: SystemSnapshot
    public let configurationFingerprint: String
    public let configuration: [String: String]
    public let afterConfigurationFingerprint: String?
    public let configurationDelta: ConfigurationDelta?
    public let verification: RunVerification?
}

/// Proceso observado como parte de una sesión lógica de juego.
///
/// Un App ID puede arrancar un launcher y, después, el ejecutable real del juego. Ambos forman
/// una sola ejecución verificable, pero se conservan por separado para que el aprendizaje no
/// pierda la cadena de procesos ni atribuya dos pruebas al usuario.
public struct RunProcessRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(runID.uuidString):\(processID)" }

    public let runID: UUID
    public let processID: Int32
    public let executable: String
    public let startedAt: Date
    public let endedAt: Date?
    public let exitCode: Int32?
    public let isRepresentative: Bool

    public init(
        runID: UUID,
        processID: Int32,
        executable: String,
        startedAt: Date,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        isRepresentative: Bool
    ) {
        self.runID = runID
        self.processID = processID
        self.executable = executable
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.isRepresentative = isRepresentative
    }
}

public struct CompatibilityProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(appID)-\(backend.rawValue)-\(configurationFingerprint)" }
    public let appID: String
    public let gameName: String
    public let backend: BackendKind
    public let configurationFingerprint: String
    public let successfulRuns: Int
    public let failedRuns: Int
    public let perfectRuns: Int
    public let playableRuns: Int
    public let unverifiedRuns: Int
    public let averageLaunchMilliseconds: Int?
    public let lastSuccessfulAt: Date?
}

public extension CompatibilityProfile {
    /// Elige primero la mejor evidencia validada del motor seleccionado.
    ///
    /// La comparación entre backends solo es un fallback: una fila lanzable con Regression no
    /// debe atribuir a CrossOver el estado visible cuando ambos tienen evidencia equivalente.
    static func preferredValidated(
        from candidates: [CompatibilityProfile],
        selectedBackend: BackendKind
    ) -> CompatibilityProfile? {
        let validated = candidates.filter { $0.perfectRuns > 0 || $0.playableRuns > 0 }
        guard !validated.isEmpty else { return nil }

        let selected = validated.filter { $0.backend == selectedBackend }
        return (selected.isEmpty ? validated : selected).sorted(by: isPreferred).first
    }

    private static func isPreferred(
        _ left: CompatibilityProfile,
        _ right: CompatibilityProfile
    ) -> Bool {
        if left.perfectRuns != right.perfectRuns { return left.perfectRuns > right.perfectRuns }
        if left.playableRuns != right.playableRuns { return left.playableRuns > right.playableRuns }
        if left.failedRuns != right.failedRuns { return left.failedRuns < right.failedRuns }
        if left.unverifiedRuns != right.unverifiedRuns {
            return left.unverifiedRuns < right.unverifiedRuns
        }
        if left.lastSuccessfulAt != right.lastSuccessfulAt {
            return (left.lastSuccessfulAt ?? .distantPast) > (right.lastSuccessfulAt ?? .distantPast)
        }
        return left.configurationFingerprint < right.configurationFingerprint
    }
}

/// Identidad normalizada de un stack de ejecución observado.
///
/// El fingerprint excluye la configuración propia del juego. Por ello varias ejecuciones y
/// juegos pueden compararse contra el mismo Wine/DXMT/DXVK/D3DMetal y la misma configuración
/// de botella sin confundir cambios de resolución o calidad del título.
public struct EngineProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String { fingerprint }

    public let fingerprint: String
    public let backend: BackendKind
    public let providerVersion: String
    public let values: [String: String]
    public let gameCount: Int
    public let perfectRuns: Int
    public let playableRuns: Int
    public let failedRuns: Int
    public let unverifiedRuns: Int
    public let lastObservedAt: Date?

    public var graphicsBackend: String? {
        values["profile.graphics.backend"]
            ?? values["bottle.CX_GRAPHICS_BACKEND"]
            ?? values["bottle.CX_D3DMETAL"]
            ?? values["bottle.WINED3DMETAL"]
            ?? values["bottle.CX_DXVK"]
            ?? values["bottle.WINEDXVK"]
            ?? values["graphics.crossover.default_probe"]
    }
}

public struct CompatibilityDatabaseHealth: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let integrity: String
    public let foreignKeyViolations: Int
    public let gameCount: Int
    public let runCount: Int
    public let processCount: Int
    public let verifiedRunCount: Int
    public let observationCount: Int
    public let certificationCount: Int
    public let externalRecordCount: Int
    public let engineSnapshotCount: Int
    public let runtimeTechnologyCount: Int
    public let runtimeCandidateCount: Int
    public let optimizationAssessmentCount: Int
    public let runtimeRequirementCount: Int
    public let repairReceiptCount: Int
    /// Opcionales solo para poder decodificar exportaciones anteriores a SQLite v13.
    public var repairAttemptCount: Int? = nil
    public var legacyRepairActivationCount: Int? = nil
    public let researchCaseCount: Int
    public let researchHypothesisCount: Int
    public let researchExperimentCount: Int
    public let researchGateCount: Int
    public let researchArtifactCount: Int
    public let preflightReportCount: Int
    /// Opcionales para decodificar exportaciones anteriores al endurecimiento de evidencia v14.
    public var perfectEvidenceViolationCount: Int? = nil
    public var activeCertificationViolationCount: Int? = nil
    public var repairAttemptEvidenceViolationCount: Int? = nil
    /// Opcionales para mantener decodificables las exportaciones anteriores al envelope v16.
    public var launchEnvelopeCount: Int? = nil
    public var launchEnvelopeEventCount: Int? = nil
    public var launchEnvelopeReceiptCount: Int? = nil
    public var launchEnvelopeViolationCount: Int? = nil

    public var isHealthy: Bool {
        integrity == "ok" && foreignKeyViolations == 0
            && (perfectEvidenceViolationCount ?? 0) == 0
            && (activeCertificationViolationCount ?? 0) == 0
            && (repairAttemptEvidenceViolationCount ?? 0) == 0
            && (launchEnvelopeViolationCount ?? 0) == 0
    }
}

public struct ConfigurationDelta: Codable, Equatable, Sendable {
    public let added: [String: String]
    public let removed: [String: String]
    public let changed: [String: ValueChange]

    public struct ValueChange: Codable, Equatable, Sendable {
        public let before: String
        public let after: String
    }
}

public enum RegressionCoreError: LocalizedError, Sendable {
    case crossOverNotInstalled
    case bottleNotFound
    case steamNotInstalled
    case bottleDamaged(String)
    case backendConflict
    case backendAlreadyRunning(BackendKind)
    case launcherMissing(URL)
    case launchFailed(String)
    case shutdownTimedOut(BackendKind)
    case unsafeLibraryState(String)
    case rendererIneligible([RendererIneligibilityReason])
    case testEnvironmentBlocked(String)
    case invalidEvidence(String)
    case externalCatalog(String)
    case database(String)

    public var errorDescription: String? {
        switch self {
        case .crossOverNotInstalled:
            "CrossOver no está instalado. Instálalo o selecciona el motor propio de Regression."
        case .bottleNotFound:
            "No se encontró una botella de CrossOver que contenga Steam."
        case .steamNotInstalled:
            "Steam no está instalado en la botella seleccionada."
        case let .bottleDamaged(detail):
            "La botella de CrossOver necesita reparación: \(detail)"
        case .backendConflict:
            "Hay dos instancias de Steam activas. Cierra una antes de continuar."
        case let .backendAlreadyRunning(backend):
            "Steam ya se está ejecutando con \(backend.displayName)."
        case let .launcherMissing(url):
            "No se encontró el lanzador necesario en \(url.path)."
        case let .launchFailed(detail):
            "No se pudo iniciar Steam: \(detail)"
        case let .shutdownTimedOut(backend):
            "\(backend.displayName) no cerró Steam a tiempo. Ciérralo manualmente y vuelve a intentarlo."
        case let .unsafeLibraryState(detail):
            "No se puede unificar la biblioteca de forma segura: \(detail)"
        case let .rendererIneligible(reasons):
            "La ruta gráfica no es elegible: \(reasons.map(\.diagnosticCode).joined(separator: ", "))"
        case let .testEnvironmentBlocked(detail):
            "La prueba se ha detenido para no generar un falso diagnóstico: \(detail)"
        case let .invalidEvidence(detail):
            "La verificación no es válida: \(detail)"
        case let .externalCatalog(detail):
            "No se pudo consultar el catálogo público: \(detail)"
        case let .database(detail):
            "La base de compatibilidad no está disponible: \(detail)"
        }
    }
}
