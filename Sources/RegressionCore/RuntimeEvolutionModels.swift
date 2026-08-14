import Foundation

public enum RuntimeTechnologyCategory: String, Codable, CaseIterable, Sendable {
    case cpuTranslation
    case windowsRuntime
    case graphicsTranslation
    case vulkanRuntime
    case referenceRuntime

    public var displayName: String {
        switch self {
        case .cpuTranslation: "Traducción de CPU"
        case .windowsRuntime: "Runtime de Windows"
        case .graphicsTranslation: "Traducción gráfica"
        case .vulkanRuntime: "Runtime de Vulkan"
        case .referenceRuntime: "Motor de referencia"
        }
    }
}

public enum RuntimeDistributionPolicy: String, Codable, CaseIterable, Sendable {
    case openSource
    case localUserProvided
    case systemProvided
    case licensedReference
}

public enum RuntimeUpdatePolicy: String, Codable, CaseIterable, Sendable {
    case pinnedStable
    case candidateOnly
    case systemManaged
    case referenceOnly
}

/// Tecnología conocida por Regression. `latestKnownVersion` es información para I+D:
/// nunca sustituye por sí sola a `stableVersion` ni altera un perfil blindado.
public struct RuntimeTechnology: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let category: RuntimeTechnologyCategory
    public let officialURL: URL
    public let releaseURL: URL?
    public let distributionPolicy: RuntimeDistributionPolicy
    public let updatePolicy: RuntimeUpdatePolicy
    public let stableVersion: String?
    public let latestKnownVersion: String?
    public let checkedAt: Date
    public let notes: String

    public init(
        id: String,
        displayName: String,
        category: RuntimeTechnologyCategory,
        officialURL: URL,
        releaseURL: URL? = nil,
        distributionPolicy: RuntimeDistributionPolicy,
        updatePolicy: RuntimeUpdatePolicy,
        stableVersion: String?,
        latestKnownVersion: String?,
        checkedAt: Date,
        notes: String
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.officialURL = officialURL
        self.releaseURL = releaseURL
        self.distributionPolicy = distributionPolicy
        self.updatePolicy = updatePolicy
        self.stableVersion = stableVersion
        self.latestKnownVersion = latestKnownVersion
        self.checkedAt = checkedAt
        self.notes = notes
    }

    public var hasResearchCandidate: Bool {
        guard updatePolicy == .candidateOnly,
              let latestKnownVersion,
              !latestKnownVersion.isEmpty else { return false }
        return latestKnownVersion != stableVersion
    }
}

public enum RuntimeCandidateScope: String, Codable, CaseIterable, Sendable {
    case perGame
    case globalResearch
}

public enum RuntimeCandidateState: String, Codable, CaseIterable, Sendable {
    case discovered
    case staged
    case testing
    case validated
    case promoted
    case rejected
    case retired
}

/// Candidato autocontenido de I+D. No contiene comandos ejecutables ni una receta de reparación.
public struct RuntimeCandidate: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let technologyID: String
    public let appID: String?
    public let targetVersion: String
    public let scope: RuntimeCandidateScope
    public let objective: String
    public let state: RuntimeCandidateState
    public let sourceURL: URL
    public let sourceFingerprint: String?
    public let sourceVerified: Bool
    public let isIsolated: Bool
    public let rollbackReference: String?
    public let baselineEngineFingerprint: String?
    public let candidateEngineFingerprint: String?
    public let validationMatrixPassed: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let notes: String

    public init(
        id: UUID = UUID(),
        technologyID: String,
        appID: String?,
        targetVersion: String,
        scope: RuntimeCandidateScope,
        objective: String,
        state: RuntimeCandidateState = .discovered,
        sourceURL: URL,
        sourceFingerprint: String? = nil,
        sourceVerified: Bool = false,
        isIsolated: Bool = false,
        rollbackReference: String? = nil,
        baselineEngineFingerprint: String? = nil,
        candidateEngineFingerprint: String? = nil,
        validationMatrixPassed: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        notes: String = ""
    ) {
        self.id = id
        self.technologyID = technologyID
        self.appID = appID
        self.targetVersion = targetVersion
        self.scope = scope
        self.objective = objective
        self.state = state
        self.sourceURL = sourceURL
        self.sourceFingerprint = sourceFingerprint
        self.sourceVerified = sourceVerified
        self.isIsolated = isIsolated
        self.rollbackReference = rollbackReference
        self.baselineEngineFingerprint = baselineEngineFingerprint
        self.candidateEngineFingerprint = candidateEngineFingerprint
        self.validationMatrixPassed = validationMatrixPassed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.notes = notes
    }
}

public enum OptimizationAssessmentState: String, Codable, CaseIterable, Sendable {
    case unmeasured
    case baselineMeasured
    case candidateMeasured
    case bestKnown
    case regressed
}

/// Evidencia de rendimiento separada del veredicto funcional.
public struct OptimizationAssessment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let appID: String
    public let backend: BackendKind
    public let engineFingerprint: String
    public let candidateID: UUID?
    public let state: OptimizationAssessmentState
    public let resolution: String?
    public let qualityPreset: String?
    public let averageFPS: Double?
    public let onePercentLowFPS: Double?
    public let frameTimeP95Milliseconds: Double?
    public let notes: String
    public let measuredAt: Date

    public init(
        id: UUID = UUID(),
        appID: String,
        backend: BackendKind,
        engineFingerprint: String,
        candidateID: UUID? = nil,
        state: OptimizationAssessmentState,
        resolution: String? = nil,
        qualityPreset: String? = nil,
        averageFPS: Double? = nil,
        onePercentLowFPS: Double? = nil,
        frameTimeP95Milliseconds: Double? = nil,
        notes: String = "",
        measuredAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.backend = backend
        self.engineFingerprint = engineFingerprint
        self.candidateID = candidateID
        self.state = state
        self.resolution = resolution
        self.qualityPreset = qualityPreset
        self.averageFPS = averageFPS
        self.onePercentLowFPS = onePercentLowFPS
        self.frameTimeP95Milliseconds = frameTimeP95Milliseconds
        self.notes = notes
        self.measuredAt = measuredAt
    }

    public var hasMeasuredPerformance: Bool {
        averageFPS != nil || onePercentLowFPS != nil || frameTimeP95Milliseconds != nil
    }
}

public enum RuntimeRequirementKind: String, Codable, CaseIterable, Sendable {
    case runtimeComponent
    case graphicsBackend
    case architecture
    case dependency
    case permission
}

/// Requisito declarativo observado. Deliberadamente no admite scripts ni comandos arbitrarios.
public struct GameRuntimeRequirement: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(appID)-\(kind.rawValue)-\(identifier)" }

    public let appID: String
    public let kind: RuntimeRequirementKind
    public let identifier: String
    public let versionConstraint: String?
    public let source: VerificationSource
    public let notes: String
    public let observedAt: Date

    public init(
        appID: String,
        kind: RuntimeRequirementKind,
        identifier: String,
        versionConstraint: String? = nil,
        source: VerificationSource,
        notes: String = "",
        observedAt: Date = Date()
    ) {
        self.appID = appID
        self.kind = kind
        self.identifier = identifier
        self.versionConstraint = versionConstraint
        self.source = source
        self.notes = notes
        self.observedAt = observedAt
    }
}

/// Resultado cerrado al consumir un requisito observado.
///
/// Solo estas salidas cerradas son posibles. En particular, ningún identificador procedente del
/// inventario puede convertirse en una ruta, URL, comando o instalador ejecutable.
public enum GameRuntimeRequirementResolution: Codable, Equatable, Sendable {
    case sealedComponent(componentID: String, componentVersion: String)
    case compiledProfile(identifier: String, revision: Int)
    case legacyComponent(
        componentID: String,
        componentVersion: String,
        state: LegacyRuntimeComponentState
    )
    case informational
}

public struct ResolvedGameRuntimeRequirement: Codable, Equatable, Sendable {
    public let requirement: GameRuntimeRequirement
    public let resolution: GameRuntimeRequirementResolution

    public init(
        requirement: GameRuntimeRequirement,
        resolution: GameRuntimeRequirementResolution
    ) {
        self.requirement = requirement
        self.resolution = resolution
    }

    /// La evidencia de inventario no autoriza mutaciones ni relanzamientos automáticos.
    public var automaticRetryEligible: Bool { false }
}

/// Resuelve exclusivamente identidades que ya forman parte del código firmado de Regression.
public enum GameRuntimeRequirementResolver {
    public static func resolve(
        _ requirement: GameRuntimeRequirement
    ) -> ResolvedGameRuntimeRequirement {
        guard requirement.source == .automatic,
              SteamAppID.normalized(requirement.appID) == requirement.appID else {
            return ResolvedGameRuntimeRequirement(
                requirement: requirement,
                resolution: .informational
            )
        }

        if requirement.kind == .runtimeComponent,
           ["microsoft-vc-runtime-x86", "microsoft-vc-runtime-x64"]
            .contains(requirement.identifier) {
            return ResolvedGameRuntimeRequirement(
                requirement: requirement,
                resolution: .sealedComponent(
                    componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
                    componentVersion: TrustedComponentCatalog
                        .steamRuntimePrerequisitesComponentVersion
                )
            )
        }

        if requirement.kind == .runtimeComponent,
           requirement.identifier == TrustedComponentCatalog.windowsMediaComponentID {
            return ResolvedGameRuntimeRequirement(
                requirement: requirement,
                resolution: .sealedComponent(
                    componentID: TrustedComponentCatalog.windowsMediaComponentID,
                    componentVersion: TrustedComponentCatalog.windowsMediaComponentVersion
                )
            )
        }

        if requirement.kind == .runtimeComponent,
           let legacy = LegacyRuntimeComponentCatalog.resolution(
               forRequirementIdentifier: requirement.identifier
           ) {
            return ResolvedGameRuntimeRequirement(
                requirement: requirement,
                resolution: .legacyComponent(
                    componentID: legacy.componentID,
                    componentVersion: legacy.componentVersion,
                    state: legacy.state
                )
            )
        }

        if let profile = GameRuntimeProfileCatalog.profile(
               for: requirement.appID,
               backend: .regression
           ), profileMatches(requirement, profile: profile) {
            return ResolvedGameRuntimeRequirement(
                requirement: requirement,
                resolution: .compiledProfile(
                    identifier: profile.identifier,
                    revision: profile.revision
                )
            )
        }

        return ResolvedGameRuntimeRequirement(
            requirement: requirement,
            resolution: .informational
        )
    }

    private static func profileMatches(
        _ requirement: GameRuntimeRequirement,
        profile: CompiledGameRuntimeProfile
    ) -> Bool {
        let family = profile.configurationValues["profile.engine.family"]
        return switch (requirement.kind, requirement.identifier) {
        case (.dependency, "unity-player"):
            family?.hasPrefix("unity") == true
        case (.dependency, "unreal-engine"):
            family == "unreal"
        case (.dependency, "gamemaker-runner"):
            family == "gamemaker"
        default:
            false
        }
    }
}

public enum GameTechnologyScanFreshness: String, Codable, Equatable, Sendable {
    case current
    case stale
}

/// Estado durable del último intento de inventario para un App ID.
///
/// `generation` avanza en cada intento. `lastSuccessfulGeneration` identifica la generación de
/// los requisitos automáticos conservados; tras un fallo ambas dejan de coincidir y el estado es
/// necesariamente `stale`.
public struct GameTechnologyScanState: Codable, Equatable, Sendable {
    public let appID: String
    public let generation: Int
    public let lastSuccessfulGeneration: Int?
    public let freshness: GameTechnologyScanFreshness
    public let attemptedAt: Date
    public let lastSuccessfulAt: Date?
    public let error: String?

    public init(
        appID: String,
        generation: Int,
        lastSuccessfulGeneration: Int?,
        freshness: GameTechnologyScanFreshness,
        attemptedAt: Date,
        lastSuccessfulAt: Date?,
        error: String?
    ) {
        self.appID = appID
        self.generation = generation
        self.lastSuccessfulGeneration = lastSuccessfulGeneration
        self.freshness = freshness
        self.attemptedAt = attemptedAt
        self.lastSuccessfulAt = lastSuccessfulAt
        self.error = error
    }
}

/// Proyección que mantiene accesible la evidencia anterior sin presentarla como vigente.
public struct GameTechnologyRequirementProjection: Codable, Equatable, Sendable {
    public let scanState: GameTechnologyScanState?
    public let requirements: [ResolvedGameRuntimeRequirement]

    public init(
        scanState: GameTechnologyScanState?,
        requirements: [ResolvedGameRuntimeRequirement]
    ) {
        self.scanState = scanState
        self.requirements = requirements
    }

    public var currentRequirements: [ResolvedGameRuntimeRequirement] {
        requirements.filter { resolved in
            resolved.requirement.source != .automatic || scanState?.freshness == .current
        }
    }

    public var staleAutomaticRequirements: [ResolvedGameRuntimeRequirement] {
        guard scanState?.freshness != .current else { return [] }
        return requirements.filter { $0.requirement.source == .automatic }
    }
}

/// Autoridad efímera emitida por un gesto explícito de lanzamiento o reparación para un App ID.
/// No contiene comandos, rutas ni datos aprendidos y no se persiste en SQLite.
public struct WindowsMediaComponentRepairAuthorization: Equatable, Sendable {
    public let appID: String

    public init?(explicitAppID appID: String) {
        guard let canonicalAppID = SteamAppID.normalized(appID), canonicalAppID == appID else {
            return nil
        }
        self.appID = canonicalAppID
    }
}

public enum WindowsMediaComponentRepairBlocker: String, Equatable, Sendable {
    case componentAuthorityMismatch
    case evidenceDoesNotMatchAuthorization
    case runtimeActive
    case staleEvidence
    case trustedPayloadRequiresReinstallation
}

/// Plan de datos cerrado. La evaluación nunca muta el enlace ni ejecuta el instalador.
public enum WindowsMediaComponentRepairPlan: Equatable, Sendable {
    case notRequired
    case blocked(WindowsMediaComponentRepairBlocker)
    case repair(ComponentRecoveryAction)
}

public enum WindowsMediaComponentRepairPlanner {
    public static func plan(
        projection: GameTechnologyRequirementProjection,
        health: ComponentHealthReport,
        authorization: WindowsMediaComponentRepairAuthorization,
        runtimeIsIdle: Bool
    ) -> WindowsMediaComponentRepairPlan {
        if let scanState = projection.scanState,
           scanState.appID != authorization.appID {
            return .blocked(.evidenceDoesNotMatchAuthorization)
        }

        guard let scanState = projection.scanState,
              scanState.freshness == .current,
              scanState.generation > 0,
              scanState.lastSuccessfulGeneration == scanState.generation else {
            return .blocked(.staleEvidence)
        }
        guard health.identity.componentID == TrustedComponentCatalog.windowsMediaComponentID,
              health.identity.componentVersion == TrustedComponentCatalog.windowsMediaComponentVersion else {
            return .blocked(.componentAuthorityMismatch)
        }
        if health.issue == .pendingTransaction {
            guard runtimeIsIdle else { return .blocked(.runtimeActive) }
            guard case .reconcilePendingTransaction = health.recovery else {
                return .blocked(.componentAuthorityMismatch)
            }
            return .repair(health.recovery)
        }

        let requiredResolution = GameRuntimeRequirementResolution.sealedComponent(
            componentID: TrustedComponentCatalog.windowsMediaComponentID,
            componentVersion: TrustedComponentCatalog.windowsMediaComponentVersion
        )
        let requiresWindowsMedia = projection.currentRequirements.contains { resolved in
            resolved.requirement.appID == authorization.appID
                && resolved.requirement.source == .automatic
                && resolved.requirement.kind == .runtimeComponent
                && resolved.requirement.identifier
                    == TrustedComponentCatalog.windowsMediaComponentID
                && resolved.resolution == requiredResolution
        }
        guard requiresWindowsMedia else {
            let staleWindowsMedia = projection.staleAutomaticRequirements.contains { resolved in
                resolved.requirement.appID == authorization.appID
                    && resolved.requirement.identifier
                        == TrustedComponentCatalog.windowsMediaComponentID
            }
            return staleWindowsMedia ? .blocked(.staleEvidence) : .notRequired
        }
        if health.status == .ready, health.recovery == .none {
            return .notRequired
        }
        guard runtimeIsIdle else { return .blocked(.runtimeActive) }
        switch (health.status, health.recovery) {
        case (.repairable, .createExternalLink),
             (.repairable, .reconcilePendingTransaction),
             (.brokenLink, .restoreExternalLinkAfterBackup):
            return .repair(health.recovery)
        default:
            return .blocked(.trustedPayloadRequiresReinstallation)
        }
    }
}

public enum RepairReceiptResult: String, Codable, CaseIterable, Sendable {
    case succeeded
    case failed
    case rolledBack
}

/// Recibo auditable de una receta compilada y permitida por Regression.
/// La base solo guarda el identificador/versionado de la receta; nunca código ejecutable.
public struct RepairReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let appID: String
    public let backend: BackendKind
    public let recipeID: String
    public let recipeVersion: Int
    public let beforeFingerprint: String
    public let afterFingerprint: String?
    public let rollbackReference: String
    public let result: RepairReceiptResult
    public let notes: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        appID: String,
        backend: BackendKind,
        recipeID: String,
        recipeVersion: Int,
        beforeFingerprint: String,
        afterFingerprint: String? = nil,
        rollbackReference: String,
        result: RepairReceiptResult,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.backend = backend
        self.recipeID = recipeID
        self.recipeVersion = recipeVersion
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.rollbackReference = rollbackReference
        self.result = result
        self.notes = notes
        self.createdAt = createdAt
    }
}

/// Estado durable de un intento de reparación compilada.
///
/// La detección y la planificación no implican que se haya mutado la botella. Los estados
/// terminales tampoco se reinterpretan como una certificación perfecta: esa decisión continúa
/// perteneciendo a la verificación funcional explícita de la ejecución de reintento.
public enum RepairAttemptState: String, Codable, CaseIterable, Sendable {
    case detected
    case planned
    case appliedAwaitingRelaunch
    case relaunching
    case awaitingVerification
    case verified
    case acceptedWithIssues
    case failed
    case rollbackPending
    case rollbackFailed
    case rolledBack
    case blocked
    case legacyAppliedUnverified

    public var isActive: Bool {
        switch self {
        case .detected, .planned, .appliedAwaitingRelaunch, .relaunching, .awaitingVerification:
            true
        case .verified, .acceptedWithIssues, .failed, .rollbackFailed, .rolledBack, .blocked,
             .legacyAppliedUnverified:
            false
        case .rollbackPending:
            true
        }
    }

    public func canTransition(to next: RepairAttemptState) -> Bool {
        switch (self, next) {
        case (.detected, .planned),
             (.detected, .blocked),
             (.detected, .failed),
             (.planned, .appliedAwaitingRelaunch),
             (.planned, .blocked),
             (.planned, .failed),
             (.appliedAwaitingRelaunch, .relaunching),
             (.appliedAwaitingRelaunch, .rollbackPending),
             (.appliedAwaitingRelaunch, .blocked),
             (.relaunching, .awaitingVerification),
             (.relaunching, .rollbackPending),
             (.relaunching, .blocked),
             (.awaitingVerification, .verified),
             (.awaitingVerification, .acceptedWithIssues),
             (.awaitingVerification, .rollbackPending),
             (.awaitingVerification, .blocked),
             (.verified, .blocked),
             (.acceptedWithIssues, .blocked),
             (.rollbackPending, .rollbackFailed),
             (.rollbackFailed, .rollbackPending):
            true
        default:
            false
        }
    }
}

public struct RepairRollbackEntry: Codable, Equatable, Sendable {
    public let targetPath: String
    public let backupPath: String
    public let beforeFingerprint: String
    public let afterFingerprint: String

    public init(
        targetPath: String,
        backupPath: String,
        beforeFingerprint: String,
        afterFingerprint: String
    ) {
        self.targetPath = targetPath
        self.backupPath = backupPath
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
    }
}

/// Manifiesto privado completo necesario para restaurar una activación compuesta. No se exporta
/// en recibos públicos ni se sustituye por una ruta saneada que pierda la identidad del backup.
public struct RepairRollbackManifest: Codable, Equatable, Sendable {
    public let entries: [RepairRollbackEntry]
    public let createdAt: Date

    public init(entries: [RepairRollbackEntry], createdAt: Date = Date()) {
        self.entries = entries
        self.createdAt = createdAt
    }
}

public enum RepairAttemptLaunchOrigin: String, Codable, CaseIterable, Sendable {
    /// Regression preparó y lanzó la ejecución fuente, por lo que puede orquestar un reintento.
    case regression
    /// La ejecución se observó dentro de Steam y requiere un nuevo gesto explícito del usuario.
    case steamObserved
}

/// Registro tipado de una reparación conocida. Solo contiene identidades, huellas y rollback;
/// nunca comandos, URLs, rutas de DLL aprendidas ni acciones ejecutables.
public struct RepairAttempt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceRunID: UUID?
    public let retryRunID: UUID?
    public let verificationID: UUID?
    public let appID: String
    public let executable: String
    public let launchOrigin: RepairAttemptLaunchOrigin
    public let recipe: CompiledRepairRecipe
    public let recipeVersion: Int
    public let state: RepairAttemptState
    public let beforeFingerprint: String?
    public let afterFingerprint: String?
    public let rollbackReference: String?
    public let rollbackManifest: RepairRollbackManifest?
    public let appliedAt: Date?
    public let notes: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourceRunID: UUID?,
        retryRunID: UUID? = nil,
        verificationID: UUID? = nil,
        appID: String,
        executable: String,
        launchOrigin: RepairAttemptLaunchOrigin = .regression,
        recipe: CompiledRepairRecipe,
        recipeVersion: Int,
        state: RepairAttemptState,
        beforeFingerprint: String? = nil,
        afterFingerprint: String? = nil,
        rollbackReference: String? = nil,
        rollbackManifest: RepairRollbackManifest? = nil,
        appliedAt: Date? = nil,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceRunID = sourceRunID
        self.retryRunID = retryRunID
        self.verificationID = verificationID
        self.appID = appID
        self.executable = executable
        self.launchOrigin = launchOrigin
        self.recipe = recipe
        self.recipeVersion = recipeVersion
        self.state = state
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
        self.rollbackReference = rollbackReference
        self.rollbackManifest = rollbackManifest
        self.appliedAt = appliedAt
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }


    public var automaticRetryEligible: Bool { launchOrigin == .regression }
}

/// Inventario en cuarentena de una activación v1. El formato histórico no llevaba App ID ni run;
/// ambos permanecen ausentes en vez de fabricar procedencia.
public struct LegacyRepairActivationInventory: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceRunID: UUID?
    public let appID: String?
    public let executable: String
    public let recipe: CompiledRepairRecipe
    public let state: RepairAttemptState
    public let sourceFingerprint: String
    public let observedAt: Date

    public init(
        id: UUID = UUID(),
        sourceRunID: UUID? = nil,
        appID: String? = nil,
        executable: String,
        recipe: CompiledRepairRecipe,
        state: RepairAttemptState = .legacyAppliedUnverified,
        sourceFingerprint: String,
        observedAt: Date = Date()
    ) {
        self.id = id
        self.sourceRunID = sourceRunID
        self.appID = appID
        self.executable = executable
        self.recipe = recipe
        self.state = state
        self.sourceFingerprint = sourceFingerprint
        self.observedAt = observedAt
    }
}

/// Proyección exportable del ciclo de reparación. Conserva trazabilidad y huellas, pero nunca
/// publica las rutas privadas del manifiesto ni de sus backups.
public struct RepairAttemptExport: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sourceRunID: UUID?
    public let retryRunID: UUID?
    public let verificationID: UUID?
    public let appID: String
    public let executable: String
    public let launchOrigin: RepairAttemptLaunchOrigin
    public let recipe: CompiledRepairRecipe
    public let recipeVersion: Int
    public let state: RepairAttemptState
    public let beforeFingerprint: String?
    public let afterFingerprint: String?
    public let hasRollbackManifest: Bool
    public let appliedAt: Date?
    public let notes: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(attempt: RepairAttempt) {
        id = attempt.id
        sourceRunID = attempt.sourceRunID
        retryRunID = attempt.retryRunID
        verificationID = attempt.verificationID
        appID = attempt.appID
        executable = attempt.executable
        launchOrigin = attempt.launchOrigin
        recipe = attempt.recipe
        recipeVersion = attempt.recipeVersion
        state = attempt.state
        beforeFingerprint = attempt.beforeFingerprint
        afterFingerprint = attempt.afterFingerprint
        hasRollbackManifest = attempt.rollbackManifest != nil
        appliedAt = attempt.appliedAt
        notes = attempt.notes
        createdAt = attempt.createdAt
        updatedAt = attempt.updatedAt
    }
}

public struct RuntimePromotionDecision: Codable, Equatable, Sendable {
    public let isEligible: Bool
    public let blockers: [String]

    public init(isEligible: Bool, blockers: [String]) {
        self.isEligible = isEligible
        self.blockers = blockers
    }
}
