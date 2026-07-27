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

    public var displayName: String {
        switch self {
        case .perfect: "Perfecto"
        case .playableWithIssues: "Funciona con incidencias"
        case .failed: "No funciona"
        }
    }
}

public enum VerificationDimension: String, Codable, Sendable {
    case passed
    case failed
    case notTested
}

public enum VerificationSource: String, Codable, Sendable {
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
    public let source: VerificationSource
    public let notes: String
    public let verifiedAt: Date

    public init(
        runID: UUID,
        verdict: VerificationVerdict,
        rendering: VerificationDimension = .notTested,
        inputPrecision: VerificationDimension = .notTested,
        graphicsSettings: VerificationDimension = .notTested,
        source: VerificationSource,
        notes: String = "",
        verifiedAt: Date = Date()
    ) {
        self.runID = runID
        self.verdict = verdict
        self.rendering = rendering
        self.inputPrecision = inputPrecision
        self.graphicsSettings = graphicsSettings
        self.source = source
        self.notes = notes
        self.verifiedAt = verifiedAt
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
        self.configurationFingerprint = configurationFingerprint
        self.configuration = configuration
        self.source = source
        self.notes = notes
        self.observedAt = observedAt
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
        case let .database(detail):
            "La base de compatibilidad no está disponible: \(detail)"
        }
    }
}
