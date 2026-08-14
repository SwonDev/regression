import CSQLite
import Dispatch
import Foundation

/// Persistencia de la autoridad de lanzamiento. La base conserva qué fue autorizado y qué se
/// observó; no contiene un payload capaz de iniciar Wine, copiar DLLs ni modificar una botella.
extension CompatibilityRepository {
    /// Costura de cola para probar que el reloj del límite se consulta después de entrar en el
    /// actor. No se invoca desde producto y no modifica SQLite.
    package func blockLaunchEnvelopeActorForTesting(
        started: DispatchSemaphore,
        release: DispatchSemaphore
    ) {
        started.signal()
        _ = release.wait(timeout: .now() + 5)
    }

    /// Capacidad opaca emitida únicamente por un envelope durable autorizado. Ni la interfaz,
    /// ni el CLI, ni los datos SQLite pueden construirla: solo transporta el callback sellado
    /// que revalida y marca el límite anterior a `Process.run()`.
    package struct GameLaunchSpawnAuthority: Sendable {
        private let appID: String
        private let envelopeID: UUID
        private let consumption: LaunchEnvelopeSpawnConsumption

        fileprivate init(
            appID: String,
            envelopeID: UUID,
            markImmediatelyBeforeSpawn: @escaping @Sendable () async throws -> Void,
            failAfterMarkedSpawn: @escaping @Sendable () async throws -> Void
        ) {
            self.appID = appID
            self.envelopeID = envelopeID
            self.consumption = LaunchEnvelopeSpawnConsumption(
                markImmediatelyBeforeSpawn: markImmediatelyBeforeSpawn,
                failAfterMarkedSpawn: failAfterMarkedSpawn
            )
        }

        /// El App ID no procede del caller de BackendCoordinator: está sellado con el envelope.
        package func appIDForBoundGameLaunch() throws -> String {
            guard SteamAppID.normalized(appID) == appID else {
                throw RegressionCoreError.invalidEvidence(
                    "la autoridad de spawn no contiene un Steam App ID canónico"
                )
            }
            return appID
        }

        func markSpawnStartedAtProcessBoundary() async throws {
            try await consumption.consume()
        }

        /// Solo el adaptador que acaba de recibir un throw síncrono de `Process.run()` puede
        /// invocarlo. La capacidad decide si realmente se consumió; así no se convierte un
        /// rechazo anterior al boundary en un falso "spawn iniciado".
        func recordProcessRunFailureBeforeSpawn() async throws {
            try await consumption.failAfterMarkedSpawn()
        }

        // No es una ruta de producto y no se condiciona a DEBUG: `swift test -c release` debe
        // compilar el mismo contrato. Solo los tests con `@testable` pueden crear este doble.
        static func testing(
            appID: String = "219990",
            markImmediatelyBeforeSpawn: @escaping @Sendable () async throws -> Void = {},
            failAfterMarkedSpawn: @escaping @Sendable () async throws -> Void = {}
        ) -> Self {
            Self(
                appID: appID,
                envelopeID: UUID(),
                markImmediatelyBeforeSpawn: markImmediatelyBeforeSpawn,
                failAfterMarkedSpawn: failAfterMarkedSpawn
            )
        }
    }

    /// Contexto durable que puede adoptar un monitor nuevo después de un lanzamiento hecho por
    /// CLI. El UUID del envelope es la nonce y `run_id UNIQUE` es el lease: un segundo run no
    /// puede reclamar la misma intención. No contiene la orden de lanzamiento ni rutas Wine.
    public struct DurableLaunchEnvelopeRun: Sendable {
        public let envelopeID: UUID
        public let context: RunContext

        public init(envelopeID: UUID, context: RunContext) {
            self.envelopeID = envelopeID
            self.context = context
        }
    }

    public func recordLaunchEnvelope(_ intent: LaunchEnvelopeIntent) throws {
        try ensurePrepared()
        guard try launchEnvelopeViolationCount() == 0 else {
            throw RegressionCoreError.database(
                "la evidencia de envelopes existente no es íntegra; el lanzamiento queda bloqueado"
            )
        }
        try validateLaunchEnvelopeIntent(intent)
        let requirementJSON = try envelopeJSON(intent.requirementIdentities)
        let timestamp = dateFormatter.string(from: intent.createdAt)
        try transaction {
            try execute(
                """
                INSERT INTO launch_envelopes(
                    id, run_id, app_id, backend, preflight_id, preflight_checked_at,
                    requirement_generation, requirement_identities_json, phase, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    intent.id.uuidString, intent.runID.uuidString, intent.appID, intent.backend.rawValue,
                    intent.preflightID.uuidString, dateFormatter.string(from: intent.preflightCheckedAt),
                    intent.requirementGeneration, requirementJSON, intent.phase.rawValue,
                    timestamp, timestamp,
                ]
            )
        }
    }

    /// Emite la única capacidad con la que un App ID puede cruzar el límite de proceso. La
    /// capacidad no expone el UUID ni una closure fabricable al caller; la revalidación queda
    /// en el actor y sucede dentro de su propia transacción inmediatamente antes del spawn.
    package func gameLaunchSpawnAuthority(
        for envelopeID: UUID
    ) throws -> GameLaunchSpawnAuthority {
        try ensurePrepared()
        guard let envelope = try launchEnvelope(id: envelopeID),
              envelope.phase == .spawnAuthorized else {
            throw RegressionCoreError.invalidEvidence(
                "la autoridad de spawn exige un envelope autorizado y vigente"
            )
        }
        return GameLaunchSpawnAuthority(
            appID: envelope.appID,
            envelopeID: envelope.id
        ) { [repository = self, envelopeID, expectedAppID = envelope.appID] in
            guard try await repository.markLaunchEnvelopeSpawnStarted(
                id: envelopeID,
                expectedAppID: expectedAppID
            ) else {
                throw RegressionCoreError.invalidEvidence(
                    "la autoridad de spawn ya no puede consumirse para este envelope"
                )
            }
        } failAfterMarkedSpawn: { [repository = self, envelopeID, expectedAppID = envelope.appID] in
            try await repository.failLaunchEnvelopeAfterProcessRunRejection(
                id: envelopeID,
                expectedAppID: expectedAppID
            )
        }
    }

    public func launchEnvelope(id: UUID) throws -> LaunchEnvelopeIntent? {
        try ensurePrepared()
        return try launchEnvelopeRows(where: "id=?", bindings: [id.uuidString]).first
    }

    /// Recupera exclusivamente una intención todavía preparada para que la telemetría continúe
    /// el mismo run. El contrato no acepta un contexto construido por el caller y nunca adopta
    /// ejecuciones de otro backend ni cerradas.
    public func adoptableLaunchEnvelopeRun(
        appID: String,
        backend: BackendKind
    ) throws -> DurableLaunchEnvelopeRun? {
        try ensurePrepared()
        guard SteamAppID.normalized(appID) == appID, backend == .regression else { return nil }
        let localDecoder = JSONDecoder()
        let candidates: [DurableLaunchEnvelopeRun] = try query(
            """
            SELECT e.id, r.id, r.app_id, g.name, r.backend, r.bottle_name, r.provider_version,
                   r.started_at, r.command, r.arguments_json, r.system_json,
                   r.configuration_fingerprint, c.values_json
            FROM launch_envelopes e
            JOIN runs r ON r.id=e.run_id
            JOIN games g ON g.app_id=r.app_id
            JOIN configuration_snapshots c ON c.fingerprint=r.configuration_fingerprint
            WHERE e.app_id=? AND e.backend=? AND r.result='preparing' AND r.ended_at IS NULL
              AND e.phase IN ('spawnAuthorized','spawnStarted','awaitingTelemetry')
            ORDER BY e.created_at DESC, e.rowid DESC
            LIMIT 1;
            """,
            bindings: [appID, backend.rawValue]
        ) { statement in
            guard
                let envelopeID = UUID(uuidString: Self.text(statement, 0)),
                let runID = UUID(uuidString: Self.text(statement, 1)),
                let storedBackend = BackendKind(rawValue: Self.text(statement, 4)),
                let startedAt = dateFormatter.date(from: Self.text(statement, 7)),
                let argumentsData = Self.text(statement, 9).data(using: .utf8),
                let arguments = try? localDecoder.decode([String].self, from: argumentsData),
                let systemData = Self.text(statement, 10).data(using: .utf8),
                let system = try? localDecoder.decode(SystemSnapshot.self, from: systemData),
                let configurationData = Self.text(statement, 12).data(using: .utf8),
                let configuration = try? localDecoder.decode([String: String].self, from: configurationData)
            else { return nil }
            return DurableLaunchEnvelopeRun(
                envelopeID: envelopeID,
                context: RunContext(
                    id: runID,
                    appID: Self.text(statement, 2),
                    gameName: Self.text(statement, 3),
                    backend: storedBackend,
                    bottleName: Self.text(statement, 5),
                    providerVersion: Self.text(statement, 6),
                    startedAt: startedAt,
                    command: Self.text(statement, 8),
                    arguments: arguments,
                    system: system,
                    configuration: configuration,
                    configurationFingerprint: Self.text(statement, 11)
                )
            )
        }
        return candidates.first
    }

    public func launchEnvelopes(appID: String? = nil) throws -> [LaunchEnvelopeIntent] {
        try ensurePrepared()
        if let appID {
            guard SteamAppID.normalized(appID) == appID else {
                throw RegressionCoreError.invalidEvidence("el Steam App ID del envelope no es canónico")
            }
            return try launchEnvelopeRows(where: "app_id=?", bindings: [appID])
        }
        return try launchEnvelopeRows(where: nil, bindings: [])
    }

    public func launchEnvelopeEvents(id envelopeID: UUID) throws -> [LaunchEnvelopeEvent] {
        try ensurePrepared()
        return try query(
            """
            SELECT id, envelope_id, phase, recorded_at
            FROM launch_envelope_events
            WHERE envelope_id=?
            ORDER BY recorded_at ASC, rowid ASC;
            """,
            bindings: [envelopeID.uuidString]
        ) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let storedEnvelopeID = UUID(uuidString: Self.text(statement, 1)),
                let phase = LaunchEnvelopePhase(rawValue: Self.text(statement, 2)),
                let recordedAt = dateFormatter.date(from: Self.text(statement, 3))
            else { return nil }
            return LaunchEnvelopeEvent(
                id: id,
                envelopeID: storedEnvelopeID,
                phase: phase,
                recordedAt: recordedAt
            )
        }
    }

    /// Autoriza un único intento de spawn desde una intención durable. Las demás fases son
    /// internas: ningún cliente de UI/CLI puede adelantar `spawnStarted` sin cruzar la autoridad
    /// opaca en el borde real de `Process.run()`.
    public func authorizeLaunchEnvelopeSpawn(
        id: UUID,
        at: Date = Date()
    ) throws {
        try ensurePrepared()
        guard let current = try launchEnvelope(id: id), current.phase == .intentDurable else {
            throw RegressionCoreError.invalidEvidence("no existe el envelope de lanzamiento")
        }
        try transaction {
            try transitionLaunchEnvelope(
                id: id,
                from: .intentDurable,
                to: .spawnAuthorized,
                at: at
            )
        }
    }

    /// Único cierre previo al boundary para UI/CLI. Une envelope, run, evento y receipt antes
    /// de que el caller descarte su intención de telemetría en memoria; por tanto un crash entre
    /// ambos pasos no puede dejar un receipt terminal sobre un run abierto.
    package func failLaunchEnvelopeBeforeSpawn(id: UUID) throws {
        try ensurePrepared()
        guard let envelope = try launchEnvelope(id: id),
              envelope.phase == .intentDurable || envelope.phase == .spawnAuthorized else {
            throw RegressionCoreError.invalidEvidence(
                "el fallo previo exige un envelope que aún no haya cruzado el boundary"
            )
        }
        try transaction {
            guard try scalarInt(
                "SELECT COUNT(*) FROM runs WHERE id=? AND result='preparing' AND ended_at IS NULL;",
                bindings: [envelope.runID.uuidString]
            ) == 1 else {
                throw RegressionCoreError.invalidEvidence(
                    "el envelope previo al spawn ya no conserva una ejecución preparada"
                )
            }
            try terminallyFailInterruptedEnvelope(envelope, at: clock())
        }
    }

    /// Une el cambio de fase y su recibo observable en la misma transacción SQLite. Ningún
    /// caller de producción debe dejar una ventana entre ambos hechos durables.
    public func advanceLaunchEnvelopeWithReceipt(
        id: UUID,
        to next: LaunchEnvelopePhase,
        result: LaunchEnvelopeReceiptResult,
        at: Date = Date()
    ) throws {
        try ensurePrepared()
        guard result != .verificationRecorded,
              receiptPhase(for: result) == next,
              let current = try launchEnvelope(id: id),
              current.phase.canTransition(to: next) else {
            throw RegressionCoreError.invalidEvidence(
                "el recibo no puede separarse de una transición autorizada del envelope"
            )
        }
        try transaction {
            try advanceLaunchEnvelopeWithReceiptInTransaction(
                envelope: current,
                to: next,
                result: result,
                at: at
            )
        }
    }

    /// Marca exactamente una vez el límite durable anterior a `Process.run()`. Es idempotente
    /// para los bootstrap de Steam que pueden emitir más de un proceso físico para la misma
    /// intención, pero no permite convertir una intención aún no autorizada en spawn iniciado.
    @discardableResult
    private func markLaunchEnvelopeSpawnStarted(
        id: UUID,
        expectedAppID: String
    ) throws -> Bool {
        try ensurePrepared()
        guard SteamAppID.normalized(expectedAppID) == expectedAppID else {
            throw RegressionCoreError.invalidEvidence("la autoridad de spawn tiene un App ID no canónico")
        }
        try transaction {
            try validateDatabase()
            let requirements = try gameTechnologyRequirementProjection(appID: expectedAppID)
            guard try launchEnvelopeViolationCount() == 0,
                  let envelope = try launchEnvelope(id: id),
                  envelope.appID == expectedAppID,
                  envelope.phase == .spawnAuthorized,
                  let scanState = requirements.scanState,
                  scanState.freshness == .current,
                  scanState.generation == envelope.requirementGeneration,
                  scanState.lastSuccessfulGeneration == envelope.requirementGeneration,
                  LaunchEnvelopeService.requirementIdentities(from: requirements)
                    == envelope.requirementIdentities else {
                throw RegressionCoreError.invalidEvidence(
                    "el envelope ya no coincide con su App ID, run y requisitos sellados"
                )
            }
            // Captura final dentro de BEGIN IMMEDIATE: las comprobaciones anteriores pueden
            // ocupar el actor, pero no pueden volver fresca una observación ya caducada.
            let at = clock()
            guard at.timeIntervalSince(envelope.preflightCheckedAt) >= 0,
                  at.timeIntervalSince(envelope.preflightCheckedAt)
                    <= LaunchEnvelopeService.maximumSealedPreflightAge,
                  try scalarInt(
                      "SELECT COUNT(*) FROM runs WHERE id=? AND app_id=? AND result='preparing' AND ended_at IS NULL;",
                      bindings: [envelope.runID.uuidString, expectedAppID]
                  ) == 1,
                  try sealedPreflightAuthorityCount(for: envelope) == 1 else {
                throw RegressionCoreError.invalidEvidence(
                    "el envelope ya no coincide con su run y preflight sellados"
                )
            }
            try transitionLaunchEnvelope(id: id, from: .spawnAuthorized, to: .spawnStarted, at: at)
        }
        return true
    }

    /// Cierra la intención cuando Foundation rechazó `Process.run()` después de que el marker
    /// durable se hubiera escrito. Nunca se usa tras un PID o una fila de proceso: ese caso es
    /// telemetría real y conserva su posible crash para la verificación explícita.
    private func failLaunchEnvelopeAfterProcessRunRejection(
        id: UUID,
        expectedAppID: String
    ) throws {
        try ensurePrepared()
        guard SteamAppID.normalized(expectedAppID) == expectedAppID else {
            throw RegressionCoreError.invalidEvidence("la autoridad de spawn tiene un App ID no canónico")
        }
        try transaction {
            let at = clock()
            guard let envelope = try launchEnvelope(id: id),
                  envelope.appID == expectedAppID,
                  envelope.phase == .spawnStarted,
                  try runHasNoRecordedProcess(envelope.runID),
                  try scalarInt(
                      "SELECT COUNT(*) FROM runs WHERE id=? AND result='preparing' AND ended_at IS NULL;",
                      bindings: [envelope.runID.uuidString]
                  ) == 1 else {
                throw RegressionCoreError.invalidEvidence(
                    "un rechazo de Process.run no puede cerrar un envelope con evidencia de proceso"
                )
            }
            try transitionLaunchEnvelope(
                id: id,
                from: .spawnStarted,
                to: .failedBeforeSpawn,
                at: at
            )
            try execute(
                "UPDATE runs SET ended_at=?, result=? WHERE id=? AND result='preparing' AND ended_at IS NULL;",
                bindings: [
                    dateFormatter.string(from: at),
                    RunResult.failed.rawValue,
                    envelope.runID.uuidString,
                ]
            )
            try recordEvent(
                runID: envelope.runID,
                phase: "launch-failed-before-spawn",
                value: "Process.run rechazó el lanzamiento antes de devolver un PID."
            )
            try ensureLaunchEnvelopeReceiptInTransaction(
                envelopeID: envelope.id,
                appID: envelope.appID,
                backend: envelope.backend,
                result: .failedBeforeSpawn,
                at: at
            )
        }
    }

    /// Predicado único del preflight sellado para el límite de spawn. Conserva literalmente la
    /// identidad usada al crear el envelope; una fila posterior del mismo run no puede sustituirla.
    private func sealedPreflightAuthorityCount(for envelope: LaunchEnvelopeIntent) throws -> Int {
        try scalarInt(
            """
            SELECT COUNT(*) FROM run_preflight_reports p
            WHERE p.run_id=? AND p.capture_phase='preLaunch' AND p.status!='blocked'
              AND p.created_at=? AND json_extract(p.report_json, '$.id')=?;
            """,
            bindings: [
                envelope.runID.uuidString,
                dateFormatter.string(from: envelope.preflightCheckedAt),
                envelope.preflightID.uuidString,
            ]
        )
    }

    /// El cierre de procesos solo mueve el envelope a la espera de una verificación explícita.
    /// No puede producir un blindado ni siquiera cuando el proceso terminó con código cero.
    @discardableResult
    public func reconcileLaunchEnvelopeAfterTelemetry(
        runID: UUID,
        at: Date = Date()
    ) throws -> Bool {
        try ensurePrepared()
        guard let envelope = try launchEnvelopes().first(where: { $0.runID == runID }) else {
            return false
        }
        let closedRuns: [Bool] = try query(
            "SELECT ended_at IS NOT NULL AND result!='preparing' FROM runs WHERE id=?;",
            bindings: [runID.uuidString]
        ) { statement in
            sqlite3_column_int(statement, 0) != 0
        }
        guard closedRuns == [true] else { return false }
        switch envelope.phase {
        case .spawnStarted:
            try transaction {
                try advanceLaunchEnvelopeWithReceiptInTransaction(
                    envelope: envelope,
                    to: .awaitingTelemetry,
                    result: .awaitingTelemetry,
                    at: at
                )
                try transitionLaunchEnvelope(
                    id: envelope.id, from: .awaitingTelemetry, to: .awaitingVerification, at: at
                )
            }
            return true
        case .awaitingTelemetry:
            try transaction {
                try ensureLaunchEnvelopeReceiptInTransaction(
                    envelope: envelope,
                    result: .awaitingTelemetry,
                    at: at
                )
                try transitionLaunchEnvelope(
                    id: envelope.id,
                    from: .awaitingTelemetry,
                    to: .awaitingVerification,
                    at: at
                )
            }
            return true
        case .intentDurable, .spawnAuthorized, .awaitingVerification, .completed,
             .failedBeforeSpawn, .rollbackPending, .rolledBack:
            return false
        }
    }

    public func launchEnvelopeReceipts(id envelopeID: UUID? = nil) throws -> [LaunchEnvelopeReceipt] {
        try ensurePrepared()
        let predicate = envelopeID == nil ? "" : "WHERE envelope_id=?"
        return try query(
            """
            SELECT id, envelope_id, app_id, backend, result, created_at
            FROM launch_envelope_receipts
            \(predicate)
            ORDER BY created_at ASC, rowid ASC;
            """,
            bindings: envelopeID.map { [$0.uuidString] } ?? []
        ) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let storedEnvelopeID = UUID(uuidString: Self.text(statement, 1)),
                let backend = BackendKind(rawValue: Self.text(statement, 3)),
                let result = LaunchEnvelopeReceiptResult(rawValue: Self.text(statement, 4)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 5))
            else { return nil }
            return LaunchEnvelopeReceipt(
                id: id,
                envelopeID: storedEnvelopeID,
                appID: Self.text(statement, 2),
                backend: backend,
                result: result,
                createdAt: createdAt
            )
        }
    }

    /// Recuperación tras un cierre inesperado. No certifica: deriva la fase desde el run durable
    /// y conserva la secuencia mediante los recibos acumulativos tipados que correspondan.
    @discardableResult
    public func reconcileInterruptedLaunchEnvelopes(at: Date = Date()) throws -> [UUID] {
        try ensurePrepared()
        let interrupted = try launchEnvelopes().filter {
            $0.phase == .intentDurable || $0.phase == .spawnAuthorized
                || $0.phase == .spawnStarted || $0.phase == .awaitingTelemetry
        }
        guard !interrupted.isEmpty else { return [] }
        try transaction {
            for candidate in interrupted {
                guard let envelope = try launchEnvelope(id: candidate.id) else { continue }
                switch envelope.phase {
                case .intentDurable, .spawnAuthorized:
                    try terminallyFailInterruptedEnvelope(envelope, at: at)
                case .spawnStarted, .awaitingTelemetry:
                    let evidence = try launchEnvelopeProcessEvidence(for: envelope.runID)
                    if evidence.hasClosedRepresentativeSession {
                        try transitionInterruptedEnvelopeToAwaitingVerification(envelope, at: at)
                    } else if evidence.isFailedBeforeProcess {
                        try terminallyFailInterruptedEnvelope(envelope, at: at)
                    } else {
                        // Un marker durable sin PID tampoco demuestra que no existiera un
                        // proceso. Conservamos el caso ambiguo para rollback/revisión y no lo
                        // degradamos a un falso fallo previo al spawn.
                        try transitionLaunchEnvelope(
                            id: envelope.id,
                            from: envelope.phase,
                            to: .rollbackPending,
                            at: at
                        )
                    }
                case .awaitingVerification, .completed, .failedBeforeSpawn,
                     .rollbackPending, .rolledBack:
                    break
                }
            }
        }
        return interrupted.map(\.id)
    }

    /// Cierra una cuarentena ambigua únicamente después de una recuperación explícita del
    /// operador. No ejecuta rollback, no relanza Steam y no puede certificar un juego: registra
    /// que la evidencia incompleta se resolvió fuera del envelope antes de permitir una nueva
    /// investigación aislada.
    package func resolveLaunchEnvelopeRollbackAfterExplicitRecovery(
        id: UUID,
        at: Date = Date()
    ) throws {
        try ensurePrepared()
        guard let envelope = try launchEnvelope(id: id), envelope.phase == .rollbackPending else {
            throw RegressionCoreError.invalidEvidence(
                "solo un envelope en cuarentena puede cerrarse tras recuperación explícita"
            )
        }
        try transaction {
            try transitionLaunchEnvelope(
                id: envelope.id,
                from: .rollbackPending,
                to: .rolledBack,
                at: at
            )
            try ensureLaunchEnvelopeReceiptInTransaction(
                envelopeID: envelope.id,
                appID: envelope.appID,
                backend: envelope.backend,
                result: .rolledBack,
                at: at
            )
        }
    }

    private struct LaunchEnvelopeProcessEvidence {
        let runIsClosed: Bool
        let result: RunResult?
        let hasRunProcessID: Bool
        let hasProcessRows: Bool
        let hasClosedRepresentative: Bool
        let allProcessesClosed: Bool

        var hasClosedRepresentativeSession: Bool {
            runIsClosed && hasRunProcessID && hasProcessRows
                && hasClosedRepresentative && allProcessesClosed
        }

        var isFailedBeforeProcess: Bool {
            runIsClosed && result == .failed && !hasRunProcessID && !hasProcessRows
        }
    }

    private func launchEnvelopeProcessEvidence(
        for runID: UUID
    ) throws -> LaunchEnvelopeProcessEvidence {
        let rows: [LaunchEnvelopeProcessEvidence] = try query(
            """
            SELECT r.ended_at IS NOT NULL, r.result, r.process_id IS NOT NULL,
                   EXISTS(SELECT 1 FROM run_processes p WHERE p.run_id=r.id),
                   EXISTS(
                       SELECT 1 FROM run_processes p
                       WHERE p.run_id=r.id AND p.process_id=r.process_id
                         AND p.is_representative=1 AND p.ended_at IS NOT NULL
                   ),
                   NOT EXISTS(
                       SELECT 1 FROM run_processes p
                       WHERE p.run_id=r.id AND p.ended_at IS NULL
                   )
            FROM runs r WHERE r.id=?;
            """,
            bindings: [runID.uuidString]
        ) { statement in
            guard let result = RunResult(rawValue: Self.text(statement, 1)) else { return nil }
            return LaunchEnvelopeProcessEvidence(
                runIsClosed: sqlite3_column_int(statement, 0) != 0,
                result: result,
                hasRunProcessID: sqlite3_column_int(statement, 2) != 0,
                hasProcessRows: sqlite3_column_int(statement, 3) != 0,
                hasClosedRepresentative: sqlite3_column_int(statement, 4) != 0,
                allProcessesClosed: sqlite3_column_int(statement, 5) != 0
            )
        }
        guard let evidence = rows.first else {
            throw RegressionCoreError.invalidEvidence("el envelope no conserva una ejecución asociada")
        }
        return evidence
    }

    private func runHasNoRecordedProcess(_ runID: UUID) throws -> Bool {
        let evidence = try launchEnvelopeProcessEvidence(for: runID)
        return !evidence.hasRunProcessID && !evidence.hasProcessRows
    }

    private func terminallyFailInterruptedEnvelope(
        _ envelope: LaunchEnvelopeIntent,
        at: Date
    ) throws {
        guard envelope.phase == .intentDurable || envelope.phase == .spawnAuthorized
            || envelope.phase == .spawnStarted || envelope.phase == .awaitingTelemetry else {
            return
        }
        try transitionLaunchEnvelope(
            id: envelope.id,
            from: envelope.phase,
            to: .failedBeforeSpawn,
            at: at
        )
        try execute(
            "UPDATE runs SET ended_at=?, result=? WHERE id=? AND ended_at IS NULL;",
            bindings: [dateFormatter.string(from: at), RunResult.failed.rawValue, envelope.runID.uuidString]
        )
        try recordEvent(
            runID: envelope.runID,
            phase: "launch-failed-before-spawn",
            value: "La recuperación confirmó que no existe un proceso de juego registrado."
        )
        try ensureLaunchEnvelopeReceiptInTransaction(
            envelopeID: envelope.id,
            appID: envelope.appID,
            backend: envelope.backend,
            result: .failedBeforeSpawn,
            at: at
        )
    }

    private func transitionInterruptedEnvelopeToAwaitingVerification(
        _ envelope: LaunchEnvelopeIntent,
        at: Date
    ) throws {
        switch envelope.phase {
        case .spawnStarted:
            try advanceLaunchEnvelopeWithReceiptInTransaction(
                envelope: envelope,
                to: .awaitingTelemetry,
                result: .awaitingTelemetry,
                at: at
            )
            try transitionLaunchEnvelope(
                id: envelope.id,
                from: .awaitingTelemetry,
                to: .awaitingVerification,
                at: at
            )
        case .awaitingTelemetry:
            try ensureLaunchEnvelopeReceiptInTransaction(
                envelope: envelope,
                result: .awaitingTelemetry,
                at: at
            )
            try transitionLaunchEnvelope(
                id: envelope.id,
                from: .awaitingTelemetry,
                to: .awaitingVerification,
                at: at
            )
        default:
            break
        }
    }

    func validateLaunchEnvelopeData() throws {
        let envelopes = try launchEnvelopes()
        guard try scalarInt("SELECT COUNT(*) FROM launch_envelopes;") == envelopes.count else {
            throw RegressionCoreError.database("hay filas de envelope malformadas que no se pueden decodificar")
        }
        var observedEventRows = 0
        var observedReceiptRows = 0
        for envelope in envelopes {
            guard envelope.backend == .regression,
                  SteamAppID.normalized(envelope.appID) == envelope.appID,
                  envelope.requirementGeneration > 0,
                  isSafeEnvelopeIdentitySet(envelope.requirementIdentities) else {
                throw RegressionCoreError.database("hay un envelope de lanzamiento con contenido no autorizado")
            }
            let events = try launchEnvelopeEvents(id: envelope.id)
            let eventRowCount = try scalarInt(
                "SELECT COUNT(*) FROM launch_envelope_events WHERE envelope_id=?;",
                bindings: [envelope.id.uuidString]
            )
            observedEventRows += eventRowCount
            guard events.first?.phase == .intentDurable,
                  events.last?.phase == envelope.phase,
                  events.count == eventRowCount,
                  events.allSatisfy({ $0.envelopeID == envelope.id }),
                  zip(events, events.dropFirst()).allSatisfy({ $0.0.phase.canTransition(to: $0.1.phase) }) else {
                throw RegressionCoreError.database("el historial del envelope no es una secuencia válida")
            }
            let receipts = try launchEnvelopeReceipts(id: envelope.id)
            let receiptRowCount = try scalarInt(
                "SELECT COUNT(*) FROM launch_envelope_receipts WHERE envelope_id=?;",
                bindings: [envelope.id.uuidString]
            )
            observedReceiptRows += receiptRowCount
            let receiptsAreValid = receipts.allSatisfy {
                $0.appID == envelope.appID && $0.backend == envelope.backend
            }
            guard receipts.count <= LaunchEnvelopeReceiptResult.allCases.count,
                  receipts.count == receiptRowCount,
                  Set(receipts.map(\.result)).count == receipts.count,
                  receiptsAreValid,
                  receiptSetIsConsistent(receipts, with: envelope.phase) else {
                throw RegressionCoreError.database("el recibo del envelope no coincide con su estado")
            }
        }
        let totalEventRows = try scalarInt("SELECT COUNT(*) FROM launch_envelope_events;")
        let totalReceiptRows = try scalarInt("SELECT COUNT(*) FROM launch_envelope_receipts;")
        guard observedEventRows == totalEventRows,
              observedReceiptRows == totalReceiptRows else {
            throw RegressionCoreError.database("hay eventos o recibos de envelope sin una autoridad decodificable")
        }
    }

    func launchEnvelopeViolationCount() throws -> Int {
        do {
            try validateLaunchEnvelopeData()
            return 0
        } catch {
            return 1
        }
    }

    private func validateLaunchEnvelopeIntent(_ intent: LaunchEnvelopeIntent) throws {
        guard intent.phase == .intentDurable,
              intent.backend == .regression,
              SteamAppID.normalized(intent.appID) == intent.appID,
              intent.requirementGeneration > 0,
              isSafeEnvelopeIdentitySet(intent.requirementIdentities) else {
            throw RegressionCoreError.invalidEvidence("el envelope contiene autoridad no canónica")
        }
        let snapshots = try preflightSnapshots()
        guard let snapshot = snapshots.first(where: {
            $0.runID == intent.runID
                && $0.report.id == intent.preflightID
                && $0.report.checkedAt == intent.preflightCheckedAt
                && $0.report.appID == intent.appID
                && $0.report.backend == intent.backend
                && $0.report.capturePhase == .preLaunch
                && $0.report.status != .blocked
                && $0.report.hasCompleteCheckSet
        }) else {
            throw RegressionCoreError.invalidEvidence("el preflight durable no coincide con el envelope")
        }
        _ = snapshot
        let requirements = try gameTechnologyRequirementProjection(appID: intent.appID)
        guard let state = requirements.scanState,
              state.freshness == .current,
              state.generation == intent.requirementGeneration,
              state.lastSuccessfulGeneration == intent.requirementGeneration,
              LaunchEnvelopeService.requirementIdentities(from: requirements)
                == intent.requirementIdentities else {
            throw RegressionCoreError.invalidEvidence("los requisitos del envelope no son actuales")
        }
        let runs: [Bool] = try query(
            "SELECT result='preparing' FROM runs WHERE id=? AND app_id=? AND backend=?;",
            bindings: [intent.runID.uuidString, intent.appID, intent.backend.rawValue]
        ) { statement in
            sqlite3_column_int(statement, 0) != 0
        }
        guard runs == [true] else {
            throw RegressionCoreError.invalidEvidence("el envelope no pertenece a una ejecución preparada")
        }
    }

    func launchEnvelopeRows(where predicate: String?, bindings: [Any]) throws -> [LaunchEnvelopeIntent] {
        let filter = predicate.map { "WHERE \($0)" } ?? ""
        let localDecoder = JSONDecoder()
        return try query(
            """
            SELECT id, run_id, app_id, backend, preflight_id, preflight_checked_at,
                   requirement_generation, requirement_identities_json, phase, created_at
            FROM launch_envelopes
            \(filter)
            ORDER BY created_at ASC, rowid ASC;
            """,
            bindings: bindings
        ) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let runID = UUID(uuidString: Self.text(statement, 1)),
                let backend = BackendKind(rawValue: Self.text(statement, 3)),
                let preflightID = UUID(uuidString: Self.text(statement, 4)),
                let preflightCheckedAt = dateFormatter.date(from: Self.text(statement, 5)),
                let identitiesData = Self.text(statement, 7).data(using: .utf8),
                let identities = try? localDecoder.decode([LaunchEnvelopeRequirementIdentity].self, from: identitiesData),
                let phase = LaunchEnvelopePhase(rawValue: Self.text(statement, 8)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 9))
            else { return nil }
            return LaunchEnvelopeIntent(
                id: id,
                runID: runID,
                appID: Self.text(statement, 2),
                backend: backend,
                preflightID: preflightID,
                preflightCheckedAt: preflightCheckedAt,
                requirementGeneration: Int(sqlite3_column_int64(statement, 6)),
                requirementIdentities: identities,
                phase: phase,
                createdAt: createdAt
            )
        }
    }

    func transitionLaunchEnvelope(
        id: UUID,
        from current: LaunchEnvelopePhase,
        to next: LaunchEnvelopePhase,
        at: Date
    ) throws {
        let timestamp = dateFormatter.string(from: at)
        try execute(
            "UPDATE launch_envelopes SET phase=?, updated_at=? WHERE id=? AND phase=?;",
            bindings: [next.rawValue, timestamp, id.uuidString, current.rawValue]
        )
        try insertLaunchEnvelopeEvent(envelopeID: id, phase: next, at: at)
    }

    private func advanceLaunchEnvelopeWithReceiptInTransaction(
        envelope: LaunchEnvelopeIntent,
        to next: LaunchEnvelopePhase,
        result: LaunchEnvelopeReceiptResult,
        at: Date
    ) throws {
        guard envelope.phase.canTransition(to: next), receiptPhase(for: result) == next else {
            throw RegressionCoreError.invalidEvidence("la transición con recibo no está permitida")
        }
        try transitionLaunchEnvelope(id: envelope.id, from: envelope.phase, to: next, at: at)
        try ensureLaunchEnvelopeReceiptInTransaction(
            envelopeID: envelope.id,
            appID: envelope.appID,
            backend: envelope.backend,
            result: result,
            at: at
        )
    }

    func ensureLaunchEnvelopeReceiptInTransaction(
        envelope: LaunchEnvelopeIntent,
        result: LaunchEnvelopeReceiptResult,
        at: Date
    ) throws {
        try ensureLaunchEnvelopeReceiptInTransaction(
            envelopeID: envelope.id,
            appID: envelope.appID,
            backend: envelope.backend,
            result: result,
            at: at
        )
    }

    func ensureLaunchEnvelopeReceiptInTransaction(
        envelopeID: UUID,
        appID: String,
        backend: BackendKind,
        result: LaunchEnvelopeReceiptResult,
        at: Date
    ) throws {
        try execute(
            """
            INSERT OR IGNORE INTO launch_envelope_receipts(
                id, envelope_id, app_id, backend, result, created_at
            ) VALUES(?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                UUID().uuidString, envelopeID.uuidString, appID, backend.rawValue,
                result.rawValue, dateFormatter.string(from: at),
            ]
        )
    }

    private func insertLaunchEnvelopeEvent(
        envelopeID: UUID,
        phase: LaunchEnvelopePhase,
        at: Date
    ) throws {
        try execute(
            "INSERT INTO launch_envelope_events(id, envelope_id, phase, recorded_at) VALUES(?, ?, ?, ?);",
            bindings: [UUID().uuidString, envelopeID.uuidString, phase.rawValue, dateFormatter.string(from: at)]
        )
    }

    private func receiptPhase(for result: LaunchEnvelopeReceiptResult) -> LaunchEnvelopePhase {
        switch result {
        case .awaitingTelemetry: .awaitingTelemetry
        case .verificationRecorded: .completed
        case .failedBeforeSpawn: .failedBeforeSpawn
        case .rolledBack: .rolledBack
        }
    }

    private func receiptResult(for phase: LaunchEnvelopePhase) -> LaunchEnvelopeReceiptResult? {
        switch phase {
        case .awaitingTelemetry: .awaitingTelemetry
        case .completed: .verificationRecorded
        case .failedBeforeSpawn: .failedBeforeSpawn
        case .rolledBack: .rolledBack
        case .intentDurable, .spawnAuthorized, .spawnStarted, .awaitingVerification, .rollbackPending:
            nil
        }
    }

    private func receiptSetIsConsistent(
        _ receipts: [LaunchEnvelopeReceipt],
        with phase: LaunchEnvelopePhase
    ) -> Bool {
        let results = Set(receipts.map(\.result))
        switch phase {
        case .intentDurable, .spawnAuthorized, .spawnStarted:
            return results.isEmpty
        case .awaitingTelemetry, .awaitingVerification:
            return results == [.awaitingTelemetry]
        case .completed:
            return results == [.awaitingTelemetry, .verificationRecorded]
        case .failedBeforeSpawn:
            // La recuperación v17 conserva el recibo de telemetría cuando descubre después
            // que no existe ningún proceso registrable.
            return results == [.failedBeforeSpawn]
                || results == [.awaitingTelemetry, .failedBeforeSpawn]
        case .rollbackPending:
            // La cuarentena puede nacer antes o después del recibo de telemetría.
            return results.isEmpty || results == [.awaitingTelemetry]
        case .rolledBack:
            return results == [.rolledBack]
                || results == [.awaitingTelemetry, .rolledBack]
        }
    }

    private func envelopeJSON(_ identities: [LaunchEnvelopeRequirementIdentity]) throws -> String {
        String(decoding: try JSONEncoder().encode(identities), as: UTF8.self)
    }

    private func isSafeEnvelopeIdentitySet(_ identities: [LaunchEnvelopeRequirementIdentity]) -> Bool {
        guard Set(identities).count == identities.count else { return false }
        return identities.allSatisfy { identity in
            let parts: [String] = switch identity.resolution {
            case let .sealedComponent(componentID, componentVersion): [identity.identifier, componentID, componentVersion]
            case let .compiledProfile(identifier, _): [identity.identifier, identifier]
            case let .legacyComponent(componentID, componentVersion, _):
                [identity.identifier, componentID, componentVersion]
            case .informational: [identity.identifier]
            }
            return parts.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 160
                    && !$0.contains("/") && !$0.contains("\\")
                    && !$0.localizedCaseInsensitiveContains(".dll")
                    && !$0.contains(where: { $0.isNewline || $0 == "\u{0}" })
            }
        }
    }
}

/// Serializa el consumo de una capacidad concreta. El marcador SQLite se completa primero; si
/// falla no existió proceso y la capacidad no se gasta. Tras una marca durable correcta, ningún
/// segundo `Process.run()` puede reutilizar la misma autoridad, incluso desde tareas concurrentes.
private actor LaunchEnvelopeSpawnConsumption {
    private var consumed = false
    private var failureRecorded = false
    private let markImmediatelyBeforeSpawn: @Sendable () async throws -> Void
    private let failAfterMarkedSpawn: @Sendable () async throws -> Void

    init(
        markImmediatelyBeforeSpawn: @escaping @Sendable () async throws -> Void,
        failAfterMarkedSpawn: @escaping @Sendable () async throws -> Void
    ) {
        self.markImmediatelyBeforeSpawn = markImmediatelyBeforeSpawn
        self.failAfterMarkedSpawn = failAfterMarkedSpawn
    }

    func consume() async throws {
        guard !consumed else {
            throw RegressionCoreError.invalidEvidence(
                "la autoridad de spawn ya fue consumida por otro límite de proceso"
            )
        }
        try await markImmediatelyBeforeSpawn()
        consumed = true
    }

    func failAfterMarkedSpawn() async throws {
        guard consumed, !failureRecorded else { return }
        try await failAfterMarkedSpawn()
        failureRecorded = true
    }
}
