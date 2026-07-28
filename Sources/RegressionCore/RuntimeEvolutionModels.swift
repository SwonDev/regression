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

public struct RuntimePromotionDecision: Codable, Equatable, Sendable {
    public let isEligible: Bool
    public let blockers: [String]

    public init(isEligible: Bool, blockers: [String]) {
        self.isEligible = isEligible
        self.blockers = blockers
    }
}
