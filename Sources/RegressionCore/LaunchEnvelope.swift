import Foundation

/// Fases persistibles, deliberadamente libres de comandos, rutas, DLLs y argumentos.
/// El envelope no sustituye la telemetría ni puede convertir un cierre de proceso en una
/// certificación funcional.
public enum LaunchEnvelopePhase: String, Codable, CaseIterable, Sendable {
    case intentDurable
    case spawnAuthorized
    case spawnStarted
    case awaitingTelemetry
    case awaitingVerification
    case completed
    case failedBeforeSpawn
    case rollbackPending
    case rolledBack

    public func canTransition(to next: LaunchEnvelopePhase) -> Bool {
        switch (self, next) {
        case (.intentDurable, .spawnAuthorized),
             (.intentDurable, .failedBeforeSpawn),
             (.spawnAuthorized, .spawnStarted),
             (.spawnAuthorized, .failedBeforeSpawn),
             (.spawnStarted, .awaitingTelemetry),
             (.spawnStarted, .failedBeforeSpawn),
             (.spawnStarted, .rollbackPending),
             (.awaitingTelemetry, .awaitingVerification),
             (.awaitingTelemetry, .failedBeforeSpawn),
             (.awaitingTelemetry, .rollbackPending),
             (.awaitingVerification, .completed),
             (.awaitingVerification, .rollbackPending),
             (.rollbackPending, .rolledBack):
            true
        default:
            false
        }
    }
}

public struct LaunchEnvelopeEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let envelopeID: UUID
    public let phase: LaunchEnvelopePhase
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        envelopeID: UUID,
        phase: LaunchEnvelopePhase,
        recordedAt: Date = Date()
    ) {
        self.id = id
        self.envelopeID = envelopeID
        self.phase = phase
        self.recordedAt = recordedAt
    }
}

public enum LaunchEnvelopeReceiptResult: String, Codable, CaseIterable, Sendable {
    case awaitingTelemetry
    case verificationRecorded
    case failedBeforeSpawn
    case rolledBack
}

/// Recibo inmutable del envelope. Solo contiene el estado observable de la orquestación; no
/// equivale a una verificación perfecta y no puede representar comandos ni rutas.
public struct LaunchEnvelopeReceipt: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let envelopeID: UUID
    public let appID: String
    public let backend: BackendKind
    public let result: LaunchEnvelopeReceiptResult
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        envelopeID: UUID,
        appID: String,
        backend: BackendKind,
        result: LaunchEnvelopeReceiptResult,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.envelopeID = envelopeID
        self.appID = appID
        self.backend = backend
        self.result = result
        self.createdAt = createdAt
    }
}

/// Identidad cerrada de un requisito usada en el recibo durable de lanzamiento. No permite
/// reconstruir acciones: `resolution` solo enumera componentes y perfiles compilados.
public struct LaunchEnvelopeRequirementIdentity: Codable, Equatable, Hashable, Sendable {
    public let kind: RuntimeRequirementKind
    public let identifier: String
    public let resolution: LaunchEnvelopeRequirementResolution

    public init(
        kind: RuntimeRequirementKind,
        identifier: String,
        resolution: LaunchEnvelopeRequirementResolution
    ) {
        self.kind = kind
        self.identifier = identifier
        self.resolution = resolution
    }
}

public enum LaunchEnvelopeRequirementResolution: Codable, Equatable, Hashable, Sendable {
    case sealedComponent(componentID: String, componentVersion: String)
    case compiledProfile(identifier: String, revision: Int)
    case legacyComponent(
        componentID: String,
        componentVersion: String,
        state: LegacyRuntimeComponentState
    )
    case informational
}

public struct LaunchEnvelopeIntent: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible {
    public let id: UUID
    public let runID: UUID
    public let appID: String
    public let backend: BackendKind
    public let preflightID: UUID
    public let preflightCheckedAt: Date
    public let requirementGeneration: Int
    public let requirementIdentities: [LaunchEnvelopeRequirementIdentity]
    public let phase: LaunchEnvelopePhase
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        appID: String,
        backend: BackendKind,
        preflightID: UUID,
        preflightCheckedAt: Date,
        requirementGeneration: Int,
        requirementIdentities: [LaunchEnvelopeRequirementIdentity],
        phase: LaunchEnvelopePhase = .intentDurable,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.runID = runID
        self.appID = appID
        self.backend = backend
        self.preflightID = preflightID
        self.preflightCheckedAt = preflightCheckedAt
        self.requirementGeneration = requirementGeneration
        self.requirementIdentities = requirementIdentities
        self.phase = phase
        self.createdAt = createdAt
    }

    public var description: String {
        "LaunchEnvelope(appID: \(appID), backend: \(backend.rawValue), phase: \(phase.rawValue))"
    }
}

public struct LaunchEnvelopeComponentHealth: Sendable {
    public let runtime: ComponentHealthReport
    public let windowsMedia: ComponentHealthReport?

    public init(
        runtime: ComponentHealthReport,
        windowsMedia: ComponentHealthReport?
    ) {
        self.runtime = runtime
        self.windowsMedia = windowsMedia
    }
}

public struct LaunchEnvelopeRequest: Sendable {
    public let appID: String
    public let backend: BackendKind
    public let runID: UUID
    public let preflight: GameTestPreflightReport
    public let requirements: GameTechnologyRequirementProjection
    public let componentHealth: LaunchEnvelopeComponentHealth
    public let rendererIsEligible: Bool

    public init(
        appID: String,
        backend: BackendKind,
        runID: UUID,
        preflight: GameTestPreflightReport,
        requirements: GameTechnologyRequirementProjection,
        componentHealth: LaunchEnvelopeComponentHealth,
        rendererIsEligible: Bool
    ) {
        self.appID = appID
        self.backend = backend
        self.runID = runID
        self.preflight = preflight
        self.requirements = requirements
        self.componentHealth = componentHealth
        self.rendererIsEligible = rendererIsEligible
    }
}

public enum LaunchEnvelopeError: Error, Equatable, Sendable {
    case invalidAppID
    case unsupportedBackend
    case preflightDoesNotMatchRequest
    case preflightIncomplete
    case preflightBlocked
    case preflightStale
    case requirementsNotFresh(appID: String)
    case runtimeComponentNotReady
    case rendererIneligible
    case componentAuthorityMismatch(componentID: String)
    case explicitComponentRepairRequired(appID: String, componentID: String)
    case legacyComponentNotReady(appID: String, componentID: String, state: LegacyRuntimeComponentState)
    case legacyComponentNoSealedAuthority(appID: String, componentID: String)
}

public enum LaunchEnvelopeAttemptPhase: String, Codable, CaseIterable, Sendable {
    case detected
    case appliedAwaitingRelaunch
    case relaunching
    case awaitingTelemetry
    case awaitingVerification
    case rollbackPending
    case rolledBack
    case completed
}

/// Intento de reparación representado solo por una receta compilada, versión y origen. No
/// incluye el ejecutable ni el manifiesto de rollback privado: ambos pertenecen al repositorio
/// de reparaciones existente.
public struct LaunchEnvelopeRepairAttempt: Codable, Equatable, Sendable {
    public let appID: String
    public let launchOrigin: RepairAttemptLaunchOrigin
    public let recipe: CompiledRepairRecipe
    public let recipeVersion: Int
    public let priorAutomaticRetryCount: Int
    public let phase: LaunchEnvelopeAttemptPhase

    public init(
        appID: String,
        launchOrigin: RepairAttemptLaunchOrigin,
        recipe: CompiledRepairRecipe,
        recipeVersion: Int,
        priorAutomaticRetryCount: Int,
        phase: LaunchEnvelopeAttemptPhase
    ) {
        self.appID = appID
        self.launchOrigin = launchOrigin
        self.recipe = recipe
        self.recipeVersion = recipeVersion
        self.priorAutomaticRetryCount = priorAutomaticRetryCount
        self.phase = phase
    }
}

public enum LaunchEnvelopeRetryBlocker: String, Codable, CaseIterable, Sendable {
    case steamObservedOrigin
    case retryLimitReached
    case recipeNotAllowed
    case invalidAttemptPhase
}

public enum LaunchEnvelopeRetryDecision: Equatable, Sendable {
    case automaticRetry
    case requiresUserGesture(LaunchEnvelopeRetryBlocker)
}

public enum LaunchEnvelopeRecoveryDecision: Equatable, Sendable {
    case noRecoveryRequired
    case reconcileTelemetryOnly
    case rollbackRequired
}

public enum LaunchEnvelopePostRunDecision: Equatable, Sendable {
    case awaitTelemetry
    case requiresExplicitVerification
    case verificationRecorded
}

/// Catálogo de reparación limitado a identidades compiladas. La base local puede referenciar
/// estas identidades, pero nunca añadir otra ni aportar una versión distinta.
public enum CompiledLaunchRepairAllowlist {
    public static func contains(_ recipe: CompiledRepairRecipe, version: Int) -> Bool {
        recipeVersion(recipe) == version
    }

    public static func recipeVersion(_ recipe: CompiledRepairRecipe) -> Int {
        switch recipe {
        case .unrealD3D11DualOverlayIsolation,
             .unityIntroWineGStreamerIsolation,
             .unityExclusiveFullscreenBorderless,
             .gameMakerRetinaFullscreen:
            1
        }
    }
}

/// Servicio puro para la autoridad de lanzamiento. Sus únicos outputs son un intent durable
/// saneado o un fallo tipado. La mutación de reparaciones, SQLite, el spawn y la certificación
/// quedan deliberadamente en adaptadores separados.
public struct LaunchEnvelopeService: Sendable {
    public static let maximumSealedPreflightAge: TimeInterval = 90
    private let now: @Sendable () -> Date

    public init(
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.now = now
    }

    public func prepare(_ request: LaunchEnvelopeRequest) throws -> LaunchEnvelopeIntent {
        guard let canonicalAppID = SteamAppID.normalized(request.appID),
              canonicalAppID == request.appID else {
            throw LaunchEnvelopeError.invalidAppID
        }
        guard request.backend == .regression else {
            throw LaunchEnvelopeError.unsupportedBackend
        }
        try validatePreflight(request.preflight, appID: canonicalAppID, backend: request.backend)
        let scanState = try validateFreshRequirements(request.requirements, appID: canonicalAppID)
        try validateComponents(request.componentHealth, requirements: request.requirements)
        guard request.rendererIsEligible else {
            throw LaunchEnvelopeError.rendererIneligible
        }
        return LaunchEnvelopeIntent(
            runID: request.runID,
            appID: canonicalAppID,
            backend: request.backend,
            preflightID: request.preflight.id,
            preflightCheckedAt: request.preflight.checkedAt,
            requirementGeneration: scanState.generation,
            requirementIdentities: Self.requirementIdentities(from: request.requirements),
            createdAt: now()
        )
    }

    public func retryDecision(for attempt: LaunchEnvelopeRepairAttempt) -> LaunchEnvelopeRetryDecision {
        guard attempt.launchOrigin == .regression else {
            return .requiresUserGesture(.steamObservedOrigin)
        }
        guard CompiledLaunchRepairAllowlist.contains(attempt.recipe, version: attempt.recipeVersion) else {
            return .requiresUserGesture(.recipeNotAllowed)
        }
        guard attempt.phase == .appliedAwaitingRelaunch else {
            return .requiresUserGesture(.invalidAttemptPhase)
        }
        guard attempt.priorAutomaticRetryCount < 1 else {
            return .requiresUserGesture(.retryLimitReached)
        }
        return .automaticRetry
    }

    public func recoveryDecision(for attempt: LaunchEnvelopeRepairAttempt) -> LaunchEnvelopeRecoveryDecision {
        switch attempt.phase {
        case .detected, .completed, .rolledBack:
            .noRecoveryRequired
        case .relaunching, .awaitingTelemetry, .awaitingVerification:
            .reconcileTelemetryOnly
        case .appliedAwaitingRelaunch, .rollbackPending:
            .rollbackRequired
        }
    }

    public func postRunDecision(
        telemetryClosed: Bool,
        verificationCompleted: Bool
    ) -> LaunchEnvelopePostRunDecision {
        guard telemetryClosed else { return .awaitTelemetry }
        return verificationCompleted ? .verificationRecorded : .requiresExplicitVerification
    }

    private func validatePreflight(
        _ preflight: GameTestPreflightReport,
        appID: String,
        backend: BackendKind
    ) throws {
        guard preflight.appID == appID,
              preflight.backend == backend,
              preflight.capturePhase == .preLaunch else {
            throw LaunchEnvelopeError.preflightDoesNotMatchRequest
        }
        guard preflight.hasCompleteCheckSet else {
            throw LaunchEnvelopeError.preflightIncomplete
        }
        guard preflight.status != .blocked else {
            throw LaunchEnvelopeError.preflightBlocked
        }
        let age = now().timeIntervalSince(preflight.checkedAt)
        guard age >= 0, age <= Self.maximumSealedPreflightAge else {
            throw LaunchEnvelopeError.preflightStale
        }
    }

    private func validateFreshRequirements(
        _ projection: GameTechnologyRequirementProjection,
        appID: String
    ) throws -> GameTechnologyScanState {
        guard let state = projection.scanState,
              state.appID == appID,
              state.freshness == .current,
              state.generation > 0,
              state.lastSuccessfulGeneration == state.generation else {
            throw LaunchEnvelopeError.requirementsNotFresh(appID: appID)
        }
        return state
    }

    private func validateComponents(
        _ components: LaunchEnvelopeComponentHealth,
        requirements: GameTechnologyRequirementProjection
    ) throws {
        guard components.runtime.identity.componentID
                == TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
              components.runtime.identity.componentVersion
                == TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion,
              components.runtime.status == .ready else {
            throw LaunchEnvelopeError.runtimeComponentNotReady
        }

        for resolved in requirements.currentRequirements {
            if case let .legacyComponent(componentID, _, state) = resolved.resolution {
                // Aún no existe un descriptor legacy sellado ni una transacción de instalación
                // con hash/rollback. Un enum o ComponentHealth fabricado no puede adelantar esa
                // autoridad: incluso `ready` sigue bloqueado hasta la futura receta compilada.
                if state == .ready {
                    throw LaunchEnvelopeError.legacyComponentNoSealedAuthority(
                        appID: resolved.requirement.appID,
                        componentID: componentID
                    )
                }
                throw LaunchEnvelopeError.legacyComponentNotReady(
                    appID: resolved.requirement.appID,
                    componentID: componentID,
                    state: state
                )
            }
            guard case let .sealedComponent(componentID, componentVersion) = resolved.resolution else {
                continue
            }
            guard componentID == TrustedComponentCatalog.windowsMediaComponentID else { continue }
            guard componentVersion == TrustedComponentCatalog.windowsMediaComponentVersion,
                  let windowsMedia = components.windowsMedia,
                  windowsMedia.identity.componentID == componentID,
                  windowsMedia.identity.componentVersion == componentVersion else {
                throw LaunchEnvelopeError.componentAuthorityMismatch(componentID: componentID)
            }
            guard windowsMedia.status == .ready, windowsMedia.recovery == .none else {
                throw LaunchEnvelopeError.explicitComponentRepairRequired(
                    appID: resolved.requirement.appID,
                    componentID: componentID
                )
            }
        }
    }

    public static func requirementIdentities(
        from projection: GameTechnologyRequirementProjection
    ) -> [LaunchEnvelopeRequirementIdentity] {
        projection.currentRequirements.map { resolved in
            let resolution: LaunchEnvelopeRequirementResolution = switch resolved.resolution {
            case let .sealedComponent(componentID, componentVersion):
                .sealedComponent(componentID: componentID, componentVersion: componentVersion)
            case let .compiledProfile(identifier, revision):
                .compiledProfile(identifier: identifier, revision: revision)
            case let .legacyComponent(componentID, componentVersion, state):
                .legacyComponent(
                    componentID: componentID,
                    componentVersion: componentVersion,
                    state: state
                )
            case .informational:
                .informational
            }
            return LaunchEnvelopeRequirementIdentity(
                kind: resolved.requirement.kind,
                identifier: resolved.requirement.identifier,
                resolution: resolution
            )
        }
        .sorted { lhs, rhs in
            (lhs.kind.rawValue, lhs.identifier) < (rhs.kind.rawValue, rhs.identifier)
        }
    }
}

/// Esquema v16. El contenido persistido es evidencia de autoridad, nunca una receta ejecutable:
/// no almacena comandos, rutas, DLLs, argumentos ni un manifiesto de reparación.
enum LaunchEnvelopeSchema {
    static let sql = """
        CREATE TABLE IF NOT EXISTS launch_envelopes(
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL UNIQUE REFERENCES runs(id) ON DELETE RESTRICT,
            app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE RESTRICT,
            backend TEXT NOT NULL CHECK(backend='regression'),
            preflight_id TEXT NOT NULL CHECK(length(preflight_id)=36),
            preflight_checked_at TEXT NOT NULL,
            requirement_generation INTEGER NOT NULL CHECK(requirement_generation>0),
            requirement_identities_json TEXT NOT NULL
                CHECK(json_valid(requirement_identities_json)),
            phase TEXT NOT NULL CHECK(phase IN (
                'intentDurable','spawnAuthorized','spawnStarted','awaitingTelemetry',
                'awaitingVerification','completed','failedBeforeSpawn',
                'rollbackPending','rolledBack'
            )),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            CHECK(instr(requirement_identities_json, char(47))=0),
            CHECK(instr(requirement_identities_json, char(92))=0)
        );
        CREATE INDEX IF NOT EXISTS launch_envelopes_app_idx
            ON launch_envelopes(app_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS launch_envelopes_phase_idx
            ON launch_envelopes(phase, updated_at ASC);

        CREATE TABLE IF NOT EXISTS launch_envelope_events(
            id TEXT PRIMARY KEY,
            envelope_id TEXT NOT NULL REFERENCES launch_envelopes(id) ON DELETE CASCADE,
            phase TEXT NOT NULL CHECK(phase IN (
                'intentDurable','spawnAuthorized','spawnStarted','awaitingTelemetry',
                'awaitingVerification','completed','failedBeforeSpawn',
                'rollbackPending','rolledBack'
            )),
            recorded_at TEXT NOT NULL,
            UNIQUE(envelope_id, phase)
        );
        CREATE INDEX IF NOT EXISTS launch_envelope_events_envelope_idx
            ON launch_envelope_events(envelope_id, recorded_at ASC);

        CREATE TRIGGER IF NOT EXISTS launch_envelopes_initial_event
        AFTER INSERT ON launch_envelopes
        BEGIN
            INSERT INTO launch_envelope_events(id, envelope_id, phase, recorded_at)
            VALUES(
                lower(hex(randomblob(4))) || '-' || lower(hex(randomblob(2))) || '-4' ||
                substr(lower(hex(randomblob(2))), 2) || '-' ||
                substr('89ab', abs(random()) % 4 + 1, 1) || substr(lower(hex(randomblob(2))), 2) || '-' ||
                lower(hex(randomblob(6))),
                NEW.id, 'intentDurable', NEW.created_at
            );
        END;

        CREATE TRIGGER IF NOT EXISTS launch_envelope_events_insert_guard
        BEFORE INSERT ON launch_envelope_events
        WHEN NOT EXISTS (
            SELECT 1 FROM launch_envelopes e
            WHERE e.id=NEW.envelope_id AND e.phase=NEW.phase
        )
        BEGIN
            SELECT RAISE(ABORT, 'launch envelope event does not match state');
        END;
        CREATE TRIGGER IF NOT EXISTS launch_envelope_events_immutable_update
        BEFORE UPDATE ON launch_envelope_events
        BEGIN
            SELECT RAISE(ABORT, 'launch envelope events are immutable');
        END;
        CREATE TRIGGER IF NOT EXISTS launch_envelope_events_immutable_delete
        BEFORE DELETE ON launch_envelope_events
        BEGIN
            SELECT RAISE(ABORT, 'launch envelope events are immutable');
        END;

        CREATE TABLE IF NOT EXISTS launch_envelope_receipts(
            id TEXT PRIMARY KEY,
            envelope_id TEXT NOT NULL REFERENCES launch_envelopes(id) ON DELETE RESTRICT,
            app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE RESTRICT,
            backend TEXT NOT NULL CHECK(backend='regression'),
            result TEXT NOT NULL CHECK(result IN (
                'awaitingTelemetry','verificationRecorded','failedBeforeSpawn','rolledBack'
            )),
            created_at TEXT NOT NULL,
            UNIQUE(envelope_id, result)
        );
        CREATE INDEX IF NOT EXISTS launch_envelope_receipts_app_idx
            ON launch_envelope_receipts(app_id, created_at DESC);

        CREATE TRIGGER IF NOT EXISTS launch_envelopes_insert_guard
        BEFORE INSERT ON launch_envelopes
        WHEN NEW.phase!='intentDurable'
          OR NOT EXISTS (
              SELECT 1 FROM runs r
              WHERE r.id=NEW.run_id AND r.app_id=NEW.app_id
                AND r.backend=NEW.backend AND r.result='preparing'
          )
          OR NOT EXISTS (
              SELECT 1 FROM run_preflight_reports p
              WHERE p.run_id=NEW.run_id
                AND p.capture_phase='preLaunch'
                AND p.created_at=NEW.preflight_checked_at
                AND json_extract(p.report_json, '$.id')=NEW.preflight_id
          )
          OR NOT EXISTS (
              SELECT 1 FROM game_technology_scan_states s
              WHERE s.app_id=NEW.app_id AND s.freshness='current'
                AND s.generation=NEW.requirement_generation
                AND s.last_successful_generation=NEW.requirement_generation
          )
        BEGIN
            SELECT RAISE(ABORT, 'launch envelope authority is not current');
        END;

        CREATE TRIGGER IF NOT EXISTS launch_envelopes_transition_guard
        BEFORE UPDATE OF phase, app_id, backend, run_id, preflight_id, preflight_checked_at,
                         requirement_generation, requirement_identities_json ON launch_envelopes
        WHEN NEW.app_id!=OLD.app_id OR NEW.backend!=OLD.backend OR NEW.run_id!=OLD.run_id
          OR NEW.preflight_id!=OLD.preflight_id
          OR NEW.preflight_checked_at!=OLD.preflight_checked_at
          OR NEW.requirement_generation!=OLD.requirement_generation
          OR NEW.requirement_identities_json!=OLD.requirement_identities_json
          OR NOT (
              (OLD.phase='intentDurable' AND NEW.phase IN ('spawnAuthorized','failedBeforeSpawn')) OR
              (OLD.phase='spawnAuthorized' AND NEW.phase IN ('spawnStarted','failedBeforeSpawn')) OR
              (OLD.phase='spawnStarted' AND NEW.phase IN ('awaitingTelemetry','rollbackPending')) OR
              (OLD.phase='awaitingTelemetry' AND NEW.phase IN ('awaitingVerification','rollbackPending')) OR
              (OLD.phase='awaitingVerification' AND NEW.phase IN ('completed','rollbackPending')) OR
              (OLD.phase='rollbackPending' AND NEW.phase='rolledBack')
          )
        BEGIN
            SELECT RAISE(ABORT, 'invalid launch envelope transition');
        END;

        CREATE TRIGGER IF NOT EXISTS launch_envelope_receipts_insert_guard
        BEFORE INSERT ON launch_envelope_receipts
        WHEN NOT EXISTS (
            SELECT 1 FROM launch_envelopes e
            WHERE e.id=NEW.envelope_id AND e.app_id=NEW.app_id AND e.backend=NEW.backend
              AND (
                  (NEW.result='awaitingTelemetry' AND e.phase='awaitingTelemetry') OR
                  (NEW.result='verificationRecorded' AND e.phase='completed') OR
                  (NEW.result='failedBeforeSpawn' AND e.phase='failedBeforeSpawn') OR
                  (NEW.result='rolledBack' AND e.phase='rolledBack')
              )
        )
        BEGIN
            SELECT RAISE(ABORT, 'launch envelope receipt does not match state');
        END;
        CREATE TRIGGER IF NOT EXISTS launch_envelope_receipts_immutable_update
        BEFORE UPDATE ON launch_envelope_receipts
        BEGIN
            SELECT RAISE(ABORT, 'launch envelope receipts are immutable');
        END;
        CREATE TRIGGER IF NOT EXISTS launch_envelope_receipts_immutable_delete
        BEFORE DELETE ON launch_envelope_receipts
        BEGIN
            SELECT RAISE(ABORT, 'launch envelope receipts are immutable');
        END;
        """

    /// v17 sólo sustituye este guard dentro de una transacción `BEGIN IMMEDIATE` de la
    /// migración. Se conserva `sql` como topología v16 para que una base histórica recorra
    /// exactamente la misma evolución que una base real ya publicada.
    static let v17TransitionGuardSQL = """
        DROP TRIGGER IF EXISTS launch_envelopes_transition_guard;
        CREATE TRIGGER launch_envelopes_transition_guard
        BEFORE UPDATE OF phase, app_id, backend, run_id, preflight_id, preflight_checked_at,
                         requirement_generation, requirement_identities_json ON launch_envelopes
        WHEN NEW.app_id!=OLD.app_id OR NEW.backend!=OLD.backend OR NEW.run_id!=OLD.run_id
          OR NEW.preflight_id!=OLD.preflight_id
          OR NEW.preflight_checked_at!=OLD.preflight_checked_at
          OR NEW.requirement_generation!=OLD.requirement_generation
          OR NEW.requirement_identities_json!=OLD.requirement_identities_json
          OR NOT (
              (OLD.phase='intentDurable' AND NEW.phase IN ('spawnAuthorized','failedBeforeSpawn')) OR
              (OLD.phase='spawnAuthorized' AND NEW.phase IN ('spawnStarted','failedBeforeSpawn')) OR
              (OLD.phase='spawnStarted' AND NEW.phase IN ('awaitingTelemetry','failedBeforeSpawn','rollbackPending')) OR
              (OLD.phase='awaitingTelemetry' AND NEW.phase IN ('awaitingVerification','failedBeforeSpawn','rollbackPending')) OR
              (OLD.phase='awaitingVerification' AND NEW.phase IN ('completed','rollbackPending')) OR
              (OLD.phase='rollbackPending' AND NEW.phase='rolledBack')
          )
        BEGIN
            SELECT RAISE(ABORT, 'invalid launch envelope transition');
        END;
        """
}
