import Foundation

public enum CompatibilityResearchCaseState: String, Codable, CaseIterable, Sendable {
    case open
    case investigating
    case validationPending
    case verified
    case pausedExternalDependency
}

/// Expediente persistente de un problema de compatibilidad.
///
/// Un expediente verificado no sustituye al blindado local: solo documenta el proceso que llevó
/// hasta él. La certificación exacta de Regression continúa ligada a su ejecución y motor.
public struct CompatibilityResearchCase: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let appID: String
    public let gameName: String
    public let symptom: String
    public let expectedBehavior: String
    public let referenceBackend: BackendKind
    public let state: CompatibilityResearchCaseState
    public let blocker: String?
    public let winningExperimentID: UUID?
    public let resolutionSummary: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        appID: String,
        gameName: String,
        symptom: String,
        expectedBehavior: String,
        referenceBackend: BackendKind = .regression,
        state: CompatibilityResearchCaseState = .open,
        blocker: String? = nil,
        winningExperimentID: UUID? = nil,
        resolutionSummary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.appID = appID
        self.gameName = gameName
        self.symptom = symptom
        self.expectedBehavior = expectedBehavior
        self.referenceBackend = referenceBackend
        self.state = state
        self.blocker = blocker
        self.winningExperimentID = winningExperimentID
        self.resolutionSummary = resolutionSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ResearchHypothesisStatus: String, Codable, CaseIterable, Sendable {
    case proposed
    case testing
    case supported
    case falsified
}

/// Hipótesis falsable y ordenada. `prediction` describe qué observación distinguirá éxito y fallo.
public struct ResearchHypothesis: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public let rank: Int
    public let statement: String
    public let prediction: String
    public let status: ResearchHypothesisStatus
    public let evidence: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        caseID: UUID,
        rank: Int,
        statement: String,
        prediction: String,
        status: ResearchHypothesisStatus = .proposed,
        evidence: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.caseID = caseID
        self.rank = rank
        self.statement = statement
        self.prediction = prediction
        self.status = status
        self.evidence = evidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ResearchExperimentDimension: String, Codable, CaseIterable, Sendable {
    case environment
    case windowsRuntime
    case graphicsBackend
    case dynamicLibraries
    case dllOverride
    case registry
    case display
    case launcher
    case dependency
    case permission
    case sourcePatch
}

public enum ResearchExperimentState: String, Codable, CaseIterable, Sendable {
    case planned
    case ready
    case running
    case validation
    case passed
    case failed
    case rolledBack
}

/// Prueba A/B de una sola dimensión. No contiene comandos ejecutables.
public struct ResearchExperiment: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let caseID: UUID
    public let hypothesisID: UUID?
    public let dimension: ResearchExperimentDimension
    public let changeSummary: String
    public let state: ResearchExperimentState
    public let isIsolated: Bool
    public let rollbackReference: String?
    public let baselineEngineFingerprint: String?
    public let candidateEngineFingerprint: String?
    public let runID: UUID?
    public let runtimeCandidateID: UUID?
    public let notes: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        caseID: UUID,
        hypothesisID: UUID? = nil,
        dimension: ResearchExperimentDimension,
        changeSummary: String,
        state: ResearchExperimentState = .planned,
        isIsolated: Bool = false,
        rollbackReference: String? = nil,
        baselineEngineFingerprint: String? = nil,
        candidateEngineFingerprint: String? = nil,
        runID: UUID? = nil,
        runtimeCandidateID: UUID? = nil,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.caseID = caseID
        self.hypothesisID = hypothesisID
        self.dimension = dimension
        self.changeSummary = changeSummary
        self.state = state
        self.isIsolated = isIsolated
        self.rollbackReference = rollbackReference
        self.baselineEngineFingerprint = baselineEngineFingerprint
        self.candidateEngineFingerprint = candidateEngineFingerprint
        self.runID = runID
        self.runtimeCandidateID = runtimeCandidateID
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ResearchValidationGate: String, Codable, CaseIterable, Sendable {
    /// Raw value histórico. Solo se exige al cerrar expedientes heredados.
    case crossOverReference
    case baselineReference
    case rendering
    case inputPrecision
    case graphicsSettings
    case gameplay
    case ownResources
    case regressionMatrix
    case rollbackVerified
}

public enum ResearchGateStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case passed
    case failed
}

public struct ResearchGateResult: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(experimentID.uuidString):\(gate.rawValue)" }

    public let experimentID: UUID
    public let gate: ResearchValidationGate
    public let status: ResearchGateStatus
    public let evidenceReference: String
    public let checkedAt: Date

    public init(
        experimentID: UUID,
        gate: ResearchValidationGate,
        status: ResearchGateStatus,
        evidenceReference: String = "",
        checkedAt: Date = Date()
    ) {
        self.experimentID = experimentID
        self.gate = gate
        self.status = status
        self.evidenceReference = evidenceReference
        self.checkedAt = checkedAt
    }
}

public enum ResearchArtifactKind: String, Codable, CaseIterable, Sendable {
    /// Raw value histórico. Solo se exige al cerrar expedientes heredados.
    case crossOverCapture
    case baselineCapture
    case regressionCapture
    case moduleInventory
    case configurationSnapshot
    case buildReport
    case testReport
    case signatureReport
    case rollbackManifest
    case logExcerpt
    case performanceCapture
}

/// Referencia privada a una evidencia y su huella. La base no incorpora el fichero ni su contenido.
public struct ResearchArtifact: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let experimentID: UUID
    public let kind: ResearchArtifactKind
    public let reference: String
    public let fingerprint: String?
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        experimentID: UUID,
        kind: ResearchArtifactKind,
        reference: String,
        fingerprint: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.experimentID = experimentID
        self.kind = kind
        self.reference = reference
        self.fingerprint = fingerprint
        self.capturedAt = capturedAt
    }
}

public struct ResearchCompletionDecision: Codable, Equatable, Sendable {
    public let isEligible: Bool
    public let blockers: [String]

    public init(isEligible: Bool, blockers: [String]) {
        self.isEligible = isEligible
        self.blockers = blockers
    }
}

public enum CompatibilityResearchProtocol {
    public static let revision = 2

    public static let mandatoryGates: [ResearchValidationGate] = [
        .baselineReference,
        .rendering,
        .inputPrecision,
        .graphicsSettings,
        .gameplay,
        .ownResources,
        .regressionMatrix,
        .rollbackVerified
    ]

    public static let mandatoryArtifacts: [ResearchArtifactKind] = [
        .baselineCapture,
        .regressionCapture,
        .moduleInventory,
        .configurationSnapshot,
        .buildReport,
        .testReport,
        .signatureReport,
        .rollbackManifest
    ]

    /// Conserva el contrato de expedientes históricos sin contaminar los nuevos con una
    /// dependencia operativa externa.
    public static func mandatoryGates(
        for referenceBackend: BackendKind
    ) -> [ResearchValidationGate] {
        switch referenceBackend {
        case .regression:
            mandatoryGates
        case .crossOver:
            [.crossOverReference] + Array(mandatoryGates.dropFirst())
        }
    }

    public static func mandatoryArtifacts(
        for referenceBackend: BackendKind
    ) -> [ResearchArtifactKind] {
        switch referenceBackend {
        case .regression:
            mandatoryArtifacts
        case .crossOver:
            [.crossOverCapture] + Array(mandatoryArtifacts.dropFirst())
        }
    }
}
