import CSQLite
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct EngineBackfillRecord {
    let id: String
    let backend: BackendKind
    let providerVersion: String
    let configuration: [String: String]
    let observedAt: Date
}

private struct CertificationEvidenceRecord {
    let kind: String
    let id: UUID
    let configurationFingerprint: String
    let engineFingerprint: String
    let verifiedAt: String
}

public actor CompatibilityRepository {
    public static let currentSchemaVersion = 12

    private let databaseURL: URL
    private var database: OpaquePointer?
    private var migrationBackupURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    let dateFormatter: ISO8601DateFormatter

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func close() throws {
        guard let database else { return }
        sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_FULL, nil, nil)
        let result = sqlite3_close_v2(database)
        guard result == SQLITE_OK else { throw databaseError(database) }
        self.database = nil
    }

    public func prepare() throws {
        guard database == nil else { return }
        try PrivateStorage.ensureDirectory(at: databaseURL.deletingLastPathComponent())
        let databaseExisted = FileManager.default.fileExists(atPath: databaseURL.path)
        if !databaseExisted {
            try PrivateStorage.createFile(at: databaseURL)
        }
        try secureDatabaseFiles()
        var handle: OpaquePointer?
        let openResult = sqlite3_open(databaseURL.path, &handle)
        guard openResult == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw RegressionCoreError.database("No se pudo abrir \(databaseURL.lastPathComponent)")
        }
        database = handle
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)

        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=FULL;")
            try execute("PRAGMA foreign_keys=ON;")
            try execute("PRAGMA trusted_schema=OFF;")
            try execute("PRAGMA wal_autocheckpoint=1000;")

            let startingVersion = try schemaVersion()
            guard startingVersion <= Self.currentSchemaVersion else {
                throw RegressionCoreError.database(
                    "La base usa el esquema \(startingVersion), más reciente que esta versión de Regression"
                )
            }
            if databaseExisted,
               startingVersion < Self.currentSchemaVersion,
               try containsUserDataTables() {
                migrationBackupURL = try createMigrationBackup(fromVersion: startingVersion)
            }
            try migrateSchema(from: startingVersion)
            try synchronizeEmbeddedCertifications()
            try synchronizeRuntimeTechnologyCatalog()
            try validateDatabase()
            try secureDatabaseFiles()
        } catch {
            sqlite3_close_v2(handle)
            database = nil
            throw error
        }
    }

    public func beginRun(_ context: RunContext) throws {
        try ensurePrepared()
        try transaction {
            try upsertGame(appID: context.appID, name: context.gameName, at: Date())
            let configurationJSON = try jsonString(context.configuration)
            try execute(
                "INSERT OR IGNORE INTO configuration_snapshots(fingerprint, values_json, created_at) VALUES(?, ?, ?);",
                bindings: [context.configurationFingerprint, configurationJSON, dateFormatter.string(from: context.startedAt)]
            )
            let engineFingerprint = try persistEngineSnapshot(
                configuration: context.configuration,
                backend: context.backend,
                providerVersion: context.providerVersion,
                observedAt: context.startedAt
            )
            let systemJSON = try jsonString(context.system)
            let argumentsJSON = try jsonString(context.arguments)
            try execute(
                """
                INSERT INTO runs(
                    id, app_id, backend, bottle_name, provider_version, started_at,
                    result, command, arguments_json, system_json, configuration_fingerprint
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    context.id.uuidString, context.appID, context.backend.rawValue,
                    context.bottleName, context.providerVersion,
                    dateFormatter.string(from: context.startedAt), RunResult.preparing.rawValue,
                    context.command, argumentsJSON, systemJSON, context.configurationFingerprint
                ]
            )
            try execute(
                "INSERT INTO run_engine_snapshots(run_id, engine_fingerprint) VALUES(?, ?);",
                bindings: [context.id.uuidString, engineFingerprint]
            )
        }
    }

    public func reconcileDiscoveredGames(_ games: [SteamGame], observedAt: Date = Date()) throws {
        try ensurePrepared()
        var namesByAppID: [String: String] = [:]
        for game in games {
            guard let appID = SteamAppID.normalized(game.appID) else { continue }
            namesByAppID[appID] = SteamGameName.normalized(game.name, appID: appID)
        }
        try transaction {
            for appID in namesByAppID.keys.sorted() {
                guard let name = namesByAppID[appID] else { continue }
                try upsertGame(appID: appID, name: name, at: observedAt)
            }
        }
    }

    public func markLaunched(
        id: UUID,
        processID: Int32,
        executable: String,
        startedAt: Date = Date(),
        launchMilliseconds: Int?
    ) throws {
        try ensurePrepared()
        let safeExecutable = PrivacySanitizer.redactedLogExcerpt(executable, limit: 1_000)
        try transaction {
            try execute(
                "UPDATE runs SET result=?, process_id=?, executable=?, launch_ms=? WHERE id=?;",
                bindings: [
                    RunResult.launched.rawValue,
                    processID,
                    safeExecutable,
                    launchMilliseconds ?? NSNull(),
                    id.uuidString
                ]
            )
            try execute(
                "UPDATE run_processes SET is_representative=0 WHERE run_id=?;",
                bindings: [id.uuidString]
            )
            try execute(
                """
                INSERT INTO run_processes(
                    run_id, process_id, executable, started_at, is_representative
                ) VALUES(?, ?, ?, ?, 1)
                ON CONFLICT(run_id, process_id) DO UPDATE SET
                    executable=excluded.executable,
                    started_at=excluded.started_at,
                    ended_at=NULL,
                    exit_code=NULL,
                    is_representative=1;
                """,
                bindings: [
                    id.uuidString,
                    processID,
                    safeExecutable,
                    dateFormatter.string(from: startedAt),
                ]
            )
            try recordEvent(
                runID: id,
                phase: "process-started",
                value: "pid=\(processID) executable=\(safeExecutable)"
            )
        }
    }

    public func markAdditionalProcessStarted(
        id: UUID,
        processID: Int32,
        executable: String,
        startedAt: Date
    ) throws {
        try ensurePrepared()
        let safeExecutable = PrivacySanitizer.redactedLogExcerpt(executable, limit: 1_000)
        try transaction {
            try execute(
                "UPDATE run_processes SET is_representative=0 WHERE run_id=?;",
                bindings: [id.uuidString]
            )
            try execute(
                """
                INSERT INTO run_processes(
                    run_id, process_id, executable, started_at, is_representative
                ) VALUES(?, ?, ?, ?, 1)
                ON CONFLICT(run_id, process_id) DO UPDATE SET
                    executable=excluded.executable,
                    started_at=excluded.started_at,
                    ended_at=NULL,
                    exit_code=NULL,
                    is_representative=1;
                """,
                bindings: [
                    id.uuidString,
                    processID,
                    safeExecutable,
                    dateFormatter.string(from: startedAt),
                ]
            )
            try execute(
                "UPDATE runs SET process_id=?, executable=? WHERE id=?;",
                bindings: [processID, safeExecutable, id.uuidString]
            )
            try recordEvent(
                runID: id,
                phase: "process-joined",
                value: "pid=\(processID) executable=\(safeExecutable)"
            )
        }
    }

    public func markProcessEnded(
        id: UUID,
        processID: Int32,
        endedAt: Date,
        exitCode: Int32
    ) throws {
        try ensurePrepared()
        try transaction {
            try execute(
                """
                UPDATE run_processes
                SET ended_at=?, exit_code=?
                WHERE run_id=? AND process_id=?;
                """,
                bindings: [
                    dateFormatter.string(from: endedAt),
                    exitCode,
                    id.uuidString,
                    processID,
                ]
            )
            try recordEvent(
                runID: id,
                phase: "process-ended",
                value: "pid=\(processID) exit=\(exitCode)"
            )
        }
    }

    public func failRunBeforeLaunch(
        id: UUID,
        endedAt: Date = Date(),
        reason: String
    ) throws {
        try ensurePrepared()
        try transaction {
            try execute(
                "UPDATE runs SET ended_at=?, result=? WHERE id=? AND result=?;",
                bindings: [
                    dateFormatter.string(from: endedAt),
                    RunResult.failed.rawValue,
                    id.uuidString,
                    RunResult.preparing.rawValue
                ]
            )
            try recordEvent(
                runID: id,
                phase: "launch-failed",
                value: reason
            )
        }
    }

    /// Cierra observaciones que quedaron abiertas porque Regression terminó o fue
    /// interrumpido. El estado es deliberadamente `unknown`: no infiere ni éxito ni fallo.
    @discardableResult
    public func reconcileInterruptedRuns(
        at date: Date = Date(),
        reason: String = "La observación terminó antes de recibir el cierre del proceso."
    ) throws -> Int {
        try ensurePrepared()
        let runIDs: [UUID] = try query(
            """
            SELECT id FROM runs
            WHERE ended_at IS NULL AND result IN ('preparing','launched');
            """
        ) { statement in
            UUID(uuidString: Self.text(statement, 0))
        }
        guard !runIDs.isEmpty else { return 0 }

        let endedAt = dateFormatter.string(from: date)
        try transaction {
            for runID in runIDs {
                try execute(
                    "UPDATE runs SET ended_at=?, result=? WHERE id=? AND ended_at IS NULL;",
                    bindings: [endedAt, RunResult.unknown.rawValue, runID.uuidString]
                )
                try recordEvent(
                    runID: runID,
                    phase: "monitoring-interrupted",
                    value: reason
                )
            }
        }
        return runIDs.count
    }

    public func finishRun(
        id: UUID,
        endedAt: Date,
        exitCode: Int32,
        result: RunResult,
        afterConfiguration: [String: String],
        delta: ConfigurationDelta
    ) throws {
        try ensurePrepared()
        let afterFingerprint = ConfigurationCollector.fingerprint(afterConfiguration)
        try transaction {
            try execute(
                "INSERT OR IGNORE INTO configuration_snapshots(fingerprint, values_json, created_at) VALUES(?, ?, ?);",
                bindings: [afterFingerprint, try jsonString(afterConfiguration), dateFormatter.string(from: endedAt)]
            )
            try execute(
                "UPDATE runs SET ended_at=?, result=?, exit_code=?, after_configuration_fingerprint=?, configuration_delta_json=? WHERE id=?;",
                bindings: [
                    dateFormatter.string(from: endedAt), result.rawValue, exitCode,
                    afterFingerprint, try jsonString(delta), id.uuidString
                ]
            )
            try recordEvent(runID: id, phase: "session-ended", value: "exit=\(exitCode)")
        }
    }

    public func recordEvent(runID: UUID, phase: String, value: String) throws {
        try ensurePrepared()
        try execute(
            "INSERT INTO run_events(run_id, occurred_at, phase, value) VALUES(?, ?, ?, ?);",
            bindings: [
                runID.uuidString,
                dateFormatter.string(from: Date()),
                phase,
                PrivacySanitizer.redactedLogExcerpt(value, limit: 1_000)
            ]
        )
    }

    public func verifyRun(_ verification: RunVerification) throws {
        try ensurePrepared()
        guard verification.hasCompletePerfectEvidence else {
            throw RegressionCoreError.invalidEvidence(
                "un perfil perfecto exige render, entrada, opciones gráficas y gameplay aprobados"
            )
        }
        if verification.verdict == .perfect {
            let eligible = try scalarInt(
                """
                SELECT COUNT(*) FROM runs
                WHERE id=? AND process_id IS NOT NULL AND result!='preparing';
                """,
                bindings: [verification.runID.uuidString]
            )
            guard eligible == 1 else {
                throw RegressionCoreError.invalidEvidence(
                    "una ejecución debe haber iniciado realmente antes de certificarse como perfecta"
                )
            }
        }
        let notes = PrivacySanitizer.redactedLogExcerpt(verification.notes, limit: 2_000)
        try transaction {
            try execute(
                """
                INSERT INTO run_verifications(
                    run_id, verdict, rendering, input_precision, graphics_settings, gameplay,
                    source, notes, verified_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET
                    verdict=excluded.verdict,
                    rendering=excluded.rendering,
                    input_precision=excluded.input_precision,
                    graphics_settings=excluded.graphics_settings,
                    gameplay=excluded.gameplay,
                    source=excluded.source,
                    notes=excluded.notes,
                    verified_at=excluded.verified_at;
                """,
                bindings: [
                    verification.runID.uuidString,
                    verification.verdict.rawValue,
                    verification.rendering.rawValue,
                    verification.inputPrecision.rawValue,
                    verification.graphicsSettings.rawValue,
                    verification.gameplay.rawValue,
                    verification.source.rawValue,
                    notes,
                    dateFormatter.string(from: verification.verifiedAt)
                ]
            )
            try recordEvent(
                runID: verification.runID,
                phase: "verification",
                value: "\(verification.verdict.rawValue): \(notes)"
            )
            try synchronizeLocalCertification(forRunID: verification.runID)
        }
    }

    /// Reasigna una ejecución histórica al perfil compilado que realmente la produjo.
    ///
    /// La operación es deliberadamente acotada: solo acepta una ejecución perfecta, real y del
    /// backend propio para la que exista una receta compilada. Conserva los snapshots anteriores,
    /// actualiza la procedencia del blindado y no interpreta datos ejecutables desde SQLite.
    public func reconcileCompiledRuntimeProfile(
        runID: UUID
    ) throws -> (configurationFingerprint: String, engineFingerprint: String) {
        try ensurePrepared()

        struct TargetRun {
            let appID: String
            let backend: BackendKind
            let providerVersion: String
            let startedAt: Date
            let result: RunResult
            let processID: Int32?
            let configuration: [String: String]
            let afterConfiguration: [String: String]?
            let verdict: VerificationVerdict
            let rendering: VerificationDimension
            let inputPrecision: VerificationDimension
            let graphicsSettings: VerificationDimension
            let gameplay: VerificationDimension
        }

        let targets: [TargetRun] = try query(
            """
            SELECT r.app_id, r.backend, r.provider_version, r.started_at, r.result,
                   r.process_id, before.values_json, after.values_json,
                   v.verdict, v.rendering, v.input_precision, v.graphics_settings,
                   v.gameplay
            FROM runs r
            JOIN configuration_snapshots before
              ON before.fingerprint=r.configuration_fingerprint
            LEFT JOIN configuration_snapshots after
              ON after.fingerprint=r.after_configuration_fingerprint
            JOIN run_verifications v ON v.run_id=r.id
            WHERE r.id=? LIMIT 1;
            """,
            bindings: [runID.uuidString]
        ) { statement in
            guard
                let backend = BackendKind(rawValue: Self.text(statement, 1)),
                let startedAt = dateFormatter.date(from: Self.text(statement, 3)),
                let result = RunResult(rawValue: Self.text(statement, 4)),
                let configurationData = Self.text(statement, 6).data(using: .utf8),
                let configuration = try? decoder.decode(
                    [String: String].self,
                    from: configurationData
                ),
                let verdict = VerificationVerdict(rawValue: Self.text(statement, 8)),
                let rendering = VerificationDimension(rawValue: Self.text(statement, 9)),
                let inputPrecision = VerificationDimension(rawValue: Self.text(statement, 10)),
                let graphicsSettings = VerificationDimension(rawValue: Self.text(statement, 11)),
                let gameplay = VerificationDimension(rawValue: Self.text(statement, 12))
            else { return nil }

            let afterConfiguration: [String: String]?
            if let text = Self.optionalText(statement, 7),
               let data = text.data(using: .utf8) {
                afterConfiguration = try? decoder.decode([String: String].self, from: data)
            } else {
                afterConfiguration = nil
            }

            return TargetRun(
                appID: Self.text(statement, 0),
                backend: backend,
                providerVersion: Self.text(statement, 2),
                startedAt: startedAt,
                result: result,
                processID: Self.optionalInt32(statement, 5),
                configuration: configuration,
                afterConfiguration: afterConfiguration,
                verdict: verdict,
                rendering: rendering,
                inputPrecision: inputPrecision,
                graphicsSettings: graphicsSettings,
                gameplay: gameplay
            )
        }

        guard let target = targets.first else {
            throw RegressionCoreError.invalidEvidence(
                "la ejecución no existe o no contiene una verificación completa"
            )
        }
        guard target.backend == .regression,
              target.processID != nil,
              target.result != .preparing,
              target.verdict == .perfect,
              target.rendering == .passed,
              target.inputPrecision == .passed,
              target.graphicsSettings == .passed,
              target.gameplay == .passed else {
            throw RegressionCoreError.invalidEvidence(
                "solo una ejecución perfecta y real de Regression puede reconciliarse"
            )
        }
        let profileValues = GameRuntimeProfileCatalog.configurationValues(
            for: target.appID,
            backend: target.backend
        )
        guard !profileValues.isEmpty else {
            throw RegressionCoreError.invalidEvidence(
                "no existe un perfil compilado para esta ejecución"
            )
        }

        func applyingProfile(to configuration: [String: String]) -> [String: String] {
            var reconciled = configuration.filter { !$0.key.hasPrefix("profile.") }
            reconciled.merge(profileValues) { _, compiledValue in compiledValue }
            return reconciled
        }

        let configuration = applyingProfile(to: target.configuration)
        let configurationFingerprint = ConfigurationCollector.fingerprint(configuration)
        let afterConfiguration = target.afterConfiguration.map(applyingProfile(to:))
        let afterFingerprint = afterConfiguration.map(ConfigurationCollector.fingerprint)

        var engineFingerprint = ""
        try transaction {
            try execute(
                "INSERT OR IGNORE INTO configuration_snapshots(fingerprint, values_json, created_at) VALUES(?, ?, ?);",
                bindings: [
                    configurationFingerprint,
                    try jsonString(configuration),
                    dateFormatter.string(from: target.startedAt)
                ]
            )
            if let afterConfiguration, let afterFingerprint {
                try execute(
                    "INSERT OR IGNORE INTO configuration_snapshots(fingerprint, values_json, created_at) VALUES(?, ?, ?);",
                    bindings: [
                        afterFingerprint,
                        try jsonString(afterConfiguration),
                        dateFormatter.string(from: Date())
                    ]
                )
            }
            engineFingerprint = try persistEngineSnapshot(
                configuration: configuration,
                backend: target.backend,
                providerVersion: target.providerVersion,
                observedAt: target.startedAt
            )
            try execute(
                "UPDATE runs SET configuration_fingerprint=?, after_configuration_fingerprint=? WHERE id=?;",
                bindings: [
                    configurationFingerprint,
                    afterFingerprint ?? NSNull(),
                    runID.uuidString
                ]
            )
            try execute(
                """
                INSERT INTO run_engine_snapshots(run_id, engine_fingerprint) VALUES(?, ?)
                ON CONFLICT(run_id) DO UPDATE SET engine_fingerprint=excluded.engine_fingerprint;
                """,
                bindings: [runID.uuidString, engineFingerprint]
            )
            try execute(
                """
                UPDATE research_experiments
                SET candidate_engine_fingerprint=?, updated_at=?
                WHERE run_id=? AND state!='passed';
                """,
                bindings: [
                    engineFingerprint,
                    dateFormatter.string(from: Date()),
                    runID.uuidString
                ]
            )
            try synchronizeLocalCertification(forRunID: runID)
            try recordEvent(
                runID: runID,
                phase: "compiled-profile-reconciled",
                value: profileValues["profile.id"] ?? "perfil compilado"
            )
        }
        return (configurationFingerprint, engineFingerprint)
    }

    public func recordObservation(_ observation: CompatibilityObservation) throws {
        try ensurePrepared()
        guard observation.hasCompletePerfectEvidence else {
            throw RegressionCoreError.invalidEvidence(
                "una observación perfecta exige render, entrada, opciones gráficas y gameplay aprobados"
            )
        }
        let notes = PrivacySanitizer.redactedLogExcerpt(observation.notes, limit: 2_000)
        try transaction {
            try upsertGame(
                appID: observation.appID,
                name: observation.gameName,
                at: observation.observedAt
            )
            let engineFingerprint = try persistEngineSnapshot(
                configuration: observation.configuration,
                backend: observation.backend,
                providerVersion: observation.providerVersion,
                observedAt: observation.observedAt
            )
            try execute(
                "INSERT OR IGNORE INTO configuration_snapshots(fingerprint, values_json, created_at) VALUES(?, ?, ?);",
                bindings: [
                    observation.configurationFingerprint,
                    try jsonString(observation.configuration),
                    dateFormatter.string(from: observation.observedAt)
                ]
            )
            try execute(
                """
                INSERT INTO compatibility_observations(
                    id, app_id, backend, provider_version, verdict, rendering,
                    input_precision, graphics_settings, gameplay, configuration_fingerprint,
                    source, notes, observed_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    observation.id.uuidString,
                    observation.appID,
                    observation.backend.rawValue,
                    observation.providerVersion,
                    observation.verdict.rawValue,
                    observation.rendering.rawValue,
                    observation.inputPrecision.rawValue,
                    observation.graphicsSettings.rawValue,
                    observation.gameplay.rawValue,
                    observation.configurationFingerprint,
                    observation.source.rawValue,
                    notes,
                    dateFormatter.string(from: observation.observedAt)
                ]
            )
            try execute(
                "INSERT INTO observation_engine_snapshots(observation_id, engine_fingerprint) VALUES(?, ?);",
                bindings: [observation.id.uuidString, engineFingerprint]
            )
            if observation.verdict == .perfect {
                try synchronizeLocalCertification(
                    appID: observation.appID,
                    gameName: observation.gameName,
                    backend: observation.backend
                )
            }
        }
    }

    public func observations(limit: Int = 10_000) throws -> [CompatibilityObservation] {
        try ensurePrepared()
        let sql = """
            SELECT o.id, o.app_id, g.name, o.backend, o.provider_version,
                   o.verdict, o.rendering, o.input_precision, o.graphics_settings,
                   o.gameplay, o.configuration_fingerprint, c.values_json,
                   o.source, o.notes, o.observed_at
            FROM compatibility_observations o
            JOIN games g ON g.app_id = o.app_id
            JOIN configuration_snapshots c ON c.fingerprint = o.configuration_fingerprint
            ORDER BY o.observed_at DESC LIMIT ?;
            """
        return try query(sql, bindings: [max(1, limit)]) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let backend = BackendKind(rawValue: Self.text(statement, 3)),
                let verdict = VerificationVerdict(rawValue: Self.text(statement, 5)),
                let rendering = VerificationDimension(rawValue: Self.text(statement, 6)),
                let input = VerificationDimension(rawValue: Self.text(statement, 7)),
                let settings = VerificationDimension(rawValue: Self.text(statement, 8)),
                let gameplay = VerificationDimension(rawValue: Self.text(statement, 9)),
                let data = Self.text(statement, 11).data(using: .utf8),
                let configuration = try? decoder.decode([String: String].self, from: data),
                let source = VerificationSource(rawValue: Self.text(statement, 12)),
                let observedAt = dateFormatter.date(from: Self.text(statement, 14))
            else { return nil }
            return CompatibilityObservation(
                id: id,
                appID: Self.text(statement, 1),
                gameName: Self.text(statement, 2),
                backend: backend,
                providerVersion: Self.text(statement, 4),
                verdict: verdict,
                rendering: rendering,
                inputPrecision: input,
                graphicsSettings: settings,
                gameplay: gameplay,
                configurationFingerprint: Self.text(statement, 10),
                configuration: configuration,
                source: source,
                notes: Self.text(statement, 13),
                observedAt: observedAt
            )
        }
    }

    public func recentRuns(limit: Int = 30) throws -> [RunSummary] {
        try ensurePrepared()
        let sql = """
            SELECT r.id, r.app_id, g.name, r.backend, r.started_at, r.ended_at,
                   r.result, r.exit_code, r.process_id, r.launch_ms, r.configuration_fingerprint,
                   v.verdict, v.rendering, v.input_precision, v.graphics_settings,
                   v.gameplay, v.source, v.notes, v.verified_at
            FROM runs r
            JOIN games g ON g.app_id = r.app_id
            LEFT JOIN run_verifications v ON v.run_id = r.id
            ORDER BY r.started_at DESC LIMIT ?;
            """
        return try query(sql, bindings: [max(1, limit)]) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let backend = BackendKind(rawValue: Self.text(statement, 3)),
                let startedAt = dateFormatter.date(from: Self.text(statement, 4)),
                let result = RunResult(rawValue: Self.text(statement, 6))
            else { return nil }
            let endedText = Self.optionalText(statement, 5)
            return RunSummary(
                id: id,
                appID: Self.text(statement, 1),
                gameName: Self.text(statement, 2),
                backend: backend,
                startedAt: startedAt,
                endedAt: endedText.flatMap(dateFormatter.date(from:)),
                result: result,
                exitCode: Self.optionalInt32(statement, 7),
                processID: Self.optionalInt32(statement, 8),
                launchDurationMilliseconds: Self.optionalInt(statement, 9),
                configurationFingerprint: Self.text(statement, 10),
                verification: verification(statement, startingAt: 11, runID: id)
            )
        }
    }

    public func compatibilityProfiles() throws -> [CompatibilityProfile] {
        try ensurePrepared()
        let sql = """
            WITH evidence AS (
                SELECT r.app_id, r.backend, r.configuration_fingerprint,
                       CASE WHEN v.verdict = 'perfect' AND r.process_id IS NOT NULL
                                  AND r.result!='preparing' THEN 1 ELSE 0 END AS perfect,
                       CASE WHEN v.verdict = 'playableWithIssues' THEN 1 ELSE 0 END AS playable,
                       CASE WHEN v.verdict = 'failed'
                                  OR ((v.run_id IS NULL OR v.verdict='invalidated')
                                      AND r.result IN ('failed','crashed'))
                            THEN 1 ELSE 0 END AS failed,
                       CASE WHEN (v.run_id IS NULL OR v.verdict='invalidated')
                                  AND r.result NOT IN ('failed','crashed')
                            THEN 1 ELSE 0 END AS unverified,
                       r.launch_ms,
                       CASE WHEN v.verdict='playableWithIssues'
                                  OR (v.verdict='perfect' AND r.process_id IS NOT NULL
                                      AND r.result!='preparing')
                            THEN v.verified_at END AS successful_at
                FROM runs r
                LEFT JOIN run_verifications v ON v.run_id = r.id
                UNION ALL
                SELECT o.app_id, o.backend, o.configuration_fingerprint,
                       CASE WHEN o.verdict = 'perfect' THEN 1 ELSE 0 END,
                       CASE WHEN o.verdict = 'playableWithIssues' THEN 1 ELSE 0 END,
                       CASE WHEN o.verdict = 'failed' THEN 1 ELSE 0 END,
                       0, NULL,
                       CASE WHEN o.verdict IN ('perfect','playableWithIssues') THEN o.observed_at END
                FROM compatibility_observations o
            )
            SELECT e.app_id, g.name, e.backend, e.configuration_fingerprint,
                   SUM(e.perfect + e.playable), SUM(e.failed),
                   SUM(e.perfect), SUM(e.playable), SUM(e.unverified),
                   CAST(AVG(e.launch_ms) AS INTEGER), MAX(e.successful_at)
            FROM evidence e
            JOIN games g ON g.app_id = e.app_id
            GROUP BY e.app_id, e.backend, e.configuration_fingerprint
            ORDER BY g.name COLLATE NOCASE, 7 DESC, 5 DESC, 6 ASC;
            """
        return try query(sql) { statement in
            guard let backend = BackendKind(rawValue: Self.text(statement, 2)) else { return nil }
            return CompatibilityProfile(
                appID: Self.text(statement, 0),
                gameName: Self.text(statement, 1),
                backend: backend,
                configurationFingerprint: Self.text(statement, 3),
                successfulRuns: Self.optionalInt(statement, 4) ?? 0,
                failedRuns: Self.optionalInt(statement, 5) ?? 0,
                perfectRuns: Self.optionalInt(statement, 6) ?? 0,
                playableRuns: Self.optionalInt(statement, 7) ?? 0,
                unverifiedRuns: Self.optionalInt(statement, 8) ?? 0,
                averageLaunchMilliseconds: Self.optionalInt(statement, 9),
                lastSuccessfulAt: Self.optionalText(statement, 10).flatMap(dateFormatter.date(from:))
            )
        }
    }

    public func engineProfiles() throws -> [EngineProfile] {
        try ensurePrepared()
        let sql = """
            WITH evidence AS (
                SELECT re.engine_fingerprint, r.app_id, r.started_at AS observed_at,
                       CASE WHEN v.verdict='perfect' AND r.process_id IS NOT NULL
                                  AND r.result!='preparing' THEN 1 ELSE 0 END AS perfect,
                       CASE WHEN v.verdict='playableWithIssues' THEN 1 ELSE 0 END AS playable,
                       CASE WHEN v.verdict='failed'
                                  OR ((v.run_id IS NULL OR v.verdict='invalidated')
                                      AND r.result IN ('failed','crashed'))
                            THEN 1 ELSE 0 END AS failed,
                       CASE WHEN (v.run_id IS NULL OR v.verdict='invalidated')
                                  AND r.result NOT IN ('failed','crashed')
                            THEN 1 ELSE 0 END AS unverified
                FROM run_engine_snapshots re
                JOIN runs r ON r.id=re.run_id
                LEFT JOIN run_verifications v ON v.run_id=r.id
                UNION ALL
                SELECT oe.engine_fingerprint, o.app_id, o.observed_at,
                       CASE WHEN o.verdict='perfect' THEN 1 ELSE 0 END,
                       CASE WHEN o.verdict='playableWithIssues' THEN 1 ELSE 0 END,
                       CASE WHEN o.verdict='failed' THEN 1 ELSE 0 END,
                       0
                FROM observation_engine_snapshots oe
                JOIN compatibility_observations o ON o.id=oe.observation_id
            )
            SELECT s.fingerprint, s.backend, s.provider_version, s.values_json,
                   COUNT(DISTINCT e.app_id),
                   COALESCE(SUM(e.perfect), 0), COALESCE(SUM(e.playable), 0),
                   COALESCE(SUM(e.failed), 0), COALESCE(SUM(e.unverified), 0),
                   MAX(e.observed_at)
            FROM engine_snapshots s
            LEFT JOIN evidence e ON e.engine_fingerprint=s.fingerprint
            GROUP BY s.fingerprint
            ORDER BY 6 DESC, 7 DESC, 8 ASC, 10 DESC;
            """
        return try query(sql) { statement in
            guard
                let backend = BackendKind(rawValue: Self.text(statement, 1)),
                let valuesData = Self.text(statement, 3).data(using: .utf8),
                let values = try? decoder.decode([String: String].self, from: valuesData)
            else { return nil }
            return EngineProfile(
                fingerprint: Self.text(statement, 0),
                backend: backend,
                providerVersion: Self.text(statement, 2),
                values: values,
                gameCount: Self.optionalInt(statement, 4) ?? 0,
                perfectRuns: Self.optionalInt(statement, 5) ?? 0,
                playableRuns: Self.optionalInt(statement, 6) ?? 0,
                failedRuns: Self.optionalInt(statement, 7) ?? 0,
                unverifiedRuns: Self.optionalInt(statement, 8) ?? 0,
                lastObservedAt: Self.optionalText(statement, 9).flatMap(dateFormatter.date(from:))
            )
        }
    }

    public func runDetails(limit: Int = 100_000) throws -> [RunDetail] {
        try ensurePrepared()
        let sql = """
            SELECT r.id, r.app_id, g.name, r.backend, r.bottle_name, r.provider_version,
                   r.started_at, r.ended_at, r.result, r.exit_code, r.process_id,
                   r.executable, r.launch_ms, r.command, r.arguments_json, r.system_json,
                   r.configuration_fingerprint, c.values_json,
                   r.after_configuration_fingerprint, r.configuration_delta_json,
                   v.verdict, v.rendering, v.input_precision, v.graphics_settings,
                   v.gameplay, v.source, v.notes, v.verified_at
            FROM runs r
            JOIN games g ON g.app_id = r.app_id
            JOIN configuration_snapshots c ON c.fingerprint = r.configuration_fingerprint
            LEFT JOIN run_verifications v ON v.run_id = r.id
            ORDER BY r.started_at DESC LIMIT ?;
            """
        return try query(sql, bindings: [max(1, limit)]) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let backend = BackendKind(rawValue: Self.text(statement, 3)),
                let startedAt = dateFormatter.date(from: Self.text(statement, 6)),
                let result = RunResult(rawValue: Self.text(statement, 8)),
                let argumentsData = Self.text(statement, 14).data(using: .utf8),
                let arguments = try? decoder.decode([String].self, from: argumentsData),
                let systemData = Self.text(statement, 15).data(using: .utf8),
                let system = try? decoder.decode(SystemSnapshot.self, from: systemData),
                let configurationData = Self.text(statement, 17).data(using: .utf8),
                let configuration = try? decoder.decode([String: String].self, from: configurationData)
            else { return nil }

            let delta: ConfigurationDelta?
            if let text = Self.optionalText(statement, 19), let data = text.data(using: .utf8) {
                delta = try? decoder.decode(ConfigurationDelta.self, from: data)
            } else {
                delta = nil
            }
            return RunDetail(
                id: id,
                appID: Self.text(statement, 1),
                gameName: Self.text(statement, 2),
                backend: backend,
                bottleName: Self.text(statement, 4),
                providerVersion: Self.text(statement, 5),
                startedAt: startedAt,
                endedAt: Self.optionalText(statement, 7).flatMap { dateFormatter.date(from: $0) },
                result: result,
                exitCode: Self.optionalInt32(statement, 9),
                processID: Self.optionalInt32(statement, 10),
                executable: Self.optionalText(statement, 11),
                launchDurationMilliseconds: Self.optionalInt(statement, 12),
                command: Self.text(statement, 13),
                arguments: arguments,
                system: system,
                configurationFingerprint: Self.text(statement, 16),
                configuration: configuration,
                afterConfigurationFingerprint: Self.optionalText(statement, 18),
                configurationDelta: delta,
                verification: verification(statement, startingAt: 20, runID: id)
            )
        }
    }

    public func runProcesses(
        runID: UUID? = nil,
        limit: Int = 100_000
    ) throws -> [RunProcessRecord] {
        try ensurePrepared()
        let runFilter = runID == nil ? "" : "WHERE run_id=?"
        var bindings: [Any] = []
        if let runID {
            bindings.append(runID.uuidString)
        }
        bindings.append(max(1, limit))
        return try query(
            """
            SELECT run_id, process_id, executable, started_at, ended_at, exit_code,
                   is_representative
            FROM run_processes
            \(runFilter)
            ORDER BY started_at DESC, process_id DESC
            LIMIT ?;
            """,
            bindings: bindings
        ) { statement in
            guard
                let runID = UUID(uuidString: Self.text(statement, 0)),
                let processID = Self.optionalInt32(statement, 1),
                let startedAt = dateFormatter.date(from: Self.text(statement, 3))
            else { return nil }
            return RunProcessRecord(
                runID: runID,
                processID: processID,
                executable: Self.text(statement, 2),
                startedAt: startedAt,
                endedAt: Self.optionalText(statement, 4).flatMap(dateFormatter.date(from:)),
                exitCode: Self.optionalInt32(statement, 5),
                isRepresentative: Self.optionalInt(statement, 6) == 1
            )
        }
    }

    public func certifications(activeOnly: Bool = true) throws -> [VerifiedGameCertification] {
        try ensurePrepared()
        let activeClause = activeOnly ? "WHERE c.is_active=1" : ""
        return try query(
            """
            SELECT c.app_id, g.name, c.backend, c.verified_at, c.evidence, c.criteria_version,
                   c.origin, c.source_run_id, c.source_observation_id,
                   c.configuration_fingerprint, c.engine_fingerprint,
                   c.catalog_revision, c.is_active, c.synced_at
            FROM verified_game_certifications c
            JOIN games g ON g.app_id=c.app_id
            \(activeClause)
            ORDER BY g.name COLLATE NOCASE, c.backend;
            """
        ) { statement in
            guard let backend = BackendKind(rawValue: Self.text(statement, 2)) else { return nil }
            return VerifiedGameCertification(
                appID: Self.text(statement, 0),
                gameName: Self.text(statement, 1),
                backend: backend,
                verifiedAt: Self.text(statement, 3),
                evidence: Self.text(statement, 4),
                criteriaVersion: Self.optionalInt(statement, 5) ?? 1,
                origin: CertificationOrigin(rawValue: Self.text(statement, 6)) ?? .embeddedCatalog,
                sourceRunID: Self.optionalText(statement, 7).flatMap(UUID.init(uuidString:)),
                sourceObservationID: Self.optionalText(statement, 8).flatMap(UUID.init(uuidString:)),
                configurationFingerprint: Self.optionalText(statement, 9),
                engineFingerprint: Self.optionalText(statement, 10),
                catalogRevision: Self.text(statement, 11),
                isActive: Self.optionalInt(statement, 12) == 1,
                syncedAt: Self.optionalText(statement, 13).flatMap(dateFormatter.date(from:))
            )
        }
    }

    public func registerExternalSource(_ source: ExternalCatalogSource) throws {
        try ensurePrepared()
        let now = dateFormatter.string(from: Date())
        try execute(
            """
            INSERT INTO external_catalog_sources(
                id, display_name, base_url, information_url,
                minimum_request_interval_seconds, cache_lifetime_seconds,
                created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name=excluded.display_name,
                base_url=excluded.base_url,
                information_url=excluded.information_url,
                minimum_request_interval_seconds=excluded.minimum_request_interval_seconds,
                cache_lifetime_seconds=excluded.cache_lifetime_seconds,
                updated_at=excluded.updated_at;
            """,
            bindings: [
                source.id, source.displayName, source.baseURL.absoluteString,
                source.informationURL.absoluteString, source.minimumRequestInterval,
                source.cacheLifetime, now, now
            ]
        )
        try execute(
            "INSERT OR IGNORE INTO external_catalog_sync_state(source_id) VALUES(?);",
            bindings: [source.id]
        )
    }

    /// Reserva de forma persistente el siguiente turno de red de una fuente pública.
    /// Si devuelve una fecha futura, el llamador debe esperar y volver a reservar.
    public func reserveExternalRequest(
        source: ExternalCatalogSource,
        now: Date = Date()
    ) throws -> Date {
        try registerExternalSource(source)
        let state = try externalSyncState(sourceID: source.id)
        if let next = state.nextRequestAt, next > now { return next }

        let next = now.addingTimeInterval(source.minimumRequestInterval)
        try execute(
            """
            UPDATE external_catalog_sync_state
            SET last_attempt_at=?, next_request_at=?, last_error=NULL
            WHERE source_id=?;
            """,
            bindings: [dateFormatter.string(from: now), dateFormatter.string(from: next), source.id]
        )
        return now
    }

    public func externalSyncState(sourceID: String) throws -> ExternalCatalogSyncState {
        try ensurePrepared()
        let rows: [ExternalCatalogSyncState] = try query(
            """
            SELECT source_id, last_attempt_at, last_success_at, next_request_at, last_error
            FROM external_catalog_sync_state WHERE source_id=? LIMIT 1;
            """,
            bindings: [sourceID]
        ) { statement in
            ExternalCatalogSyncState(
                sourceID: Self.text(statement, 0),
                lastAttemptAt: Self.optionalText(statement, 1).flatMap(dateFormatter.date(from:)),
                lastSuccessAt: Self.optionalText(statement, 2).flatMap(dateFormatter.date(from:)),
                nextRequestAt: Self.optionalText(statement, 3).flatMap(dateFormatter.date(from:)),
                lastError: Self.optionalText(statement, 4)
            )
        }
        return rows.first ?? ExternalCatalogSyncState(sourceID: sourceID)
    }

    public func recordExternalSyncSuccess(sourceID: String, at date: Date = Date()) throws {
        try ensurePrepared()
        try execute(
            "UPDATE external_catalog_sync_state SET last_success_at=?, last_error=NULL WHERE source_id=?;",
            bindings: [dateFormatter.string(from: date), sourceID]
        )
    }

    public func recordExternalSyncFailure(sourceID: String, message: String) throws {
        try ensurePrepared()
        try execute(
            "UPDATE external_catalog_sync_state SET last_error=? WHERE source_id=?;",
            bindings: [PrivacySanitizer.redactedLogExcerpt(message, limit: 500), sourceID]
        )
    }

    public func upsertExternalRecord(
        _ record: ExternalGameRecord,
        for game: SteamGame,
        matchMethod: ExternalCatalogMatchMethod,
        confidence: Double
    ) throws {
        try ensurePrepared()
        let safeConfidence = min(1, max(0, confidence))
        try transaction {
            try upsertGame(appID: game.appID, name: game.name, at: record.fetchedAt)
            try execute(
                """
                INSERT INTO external_game_records(
                    source_id, external_app_id, canonical_url, name, company, category,
                    steam_app_id, mac_rating, mac_tested_version, mac_tested_at,
                    linux_rating, linux_tested_version, linux_tested_at,
                    fetched_at, content_fingerprint, entity_tag, last_modified
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(source_id, external_app_id) DO UPDATE SET
                    canonical_url=excluded.canonical_url,
                    name=excluded.name,
                    company=excluded.company,
                    category=excluded.category,
                    steam_app_id=excluded.steam_app_id,
                    mac_rating=excluded.mac_rating,
                    mac_tested_version=excluded.mac_tested_version,
                    mac_tested_at=excluded.mac_tested_at,
                    linux_rating=excluded.linux_rating,
                    linux_tested_version=excluded.linux_tested_version,
                    linux_tested_at=excluded.linux_tested_at,
                    fetched_at=excluded.fetched_at,
                    content_fingerprint=excluded.content_fingerprint,
                    entity_tag=excluded.entity_tag,
                    last_modified=excluded.last_modified;
                """,
                bindings: [
                    record.sourceID, record.externalAppID, record.canonicalURL.absoluteString,
                    record.name, record.company ?? NSNull(), record.category ?? NSNull(),
                    record.steamAppID ?? NSNull(), record.macOSRating.value ?? NSNull(),
                    record.macOSRating.testedCrossOverVersion ?? NSNull(),
                    record.macOSRating.testedAt.map(dateFormatter.string(from:)) ?? NSNull(),
                    record.linuxRating.value ?? NSNull(),
                    record.linuxRating.testedCrossOverVersion ?? NSNull(),
                    record.linuxRating.testedAt.map(dateFormatter.string(from:)) ?? NSNull(),
                    dateFormatter.string(from: record.fetchedAt), record.contentFingerprint,
                    record.entityTag ?? NSNull(), record.lastModified ?? NSNull()
                ]
            )
            try execute(
                """
                INSERT INTO external_game_links(
                    source_id, app_id, external_app_id, status, match_method,
                    confidence, query_name, last_attempt_at, error_message, linked_at
                ) VALUES(?, ?, ?, 'linked', ?, ?, ?, ?, NULL, ?)
                ON CONFLICT(source_id, app_id) DO UPDATE SET
                    external_app_id=excluded.external_app_id,
                    status='linked',
                    match_method=excluded.match_method,
                    confidence=excluded.confidence,
                    query_name=excluded.query_name,
                    last_attempt_at=excluded.last_attempt_at,
                    error_message=NULL,
                    linked_at=excluded.linked_at;
                """,
                bindings: [
                    record.sourceID, game.appID, record.externalAppID, matchMethod.rawValue,
                    safeConfidence, game.name, dateFormatter.string(from: record.fetchedAt),
                    dateFormatter.string(from: record.fetchedAt)
                ]
            )
        }
    }

    public func recordExternalLookupStatus(
        sourceID: String,
        game: SteamGame,
        status: ExternalCatalogLinkStatus,
        message: String? = nil,
        at date: Date = Date()
    ) throws {
        try ensurePrepared()
        guard status != .linked else {
            throw RegressionCoreError.externalCatalog(
                "Un vínculo confirmado debe guardar también su ficha pública"
            )
        }
        try transaction {
            try upsertGame(appID: game.appID, name: game.name, at: date)
            let safeMessage = message.map {
                PrivacySanitizer.redactedLogExcerpt($0, limit: 500)
            }
            try execute(
                """
                INSERT INTO external_game_links(
                    source_id, app_id, external_app_id, status, match_method,
                    confidence, query_name, last_attempt_at, error_message, linked_at
                ) VALUES(?, ?, NULL, ?, NULL, NULL, ?, ?, ?, NULL)
                ON CONFLICT(source_id, app_id) DO UPDATE SET
                    status=CASE
                        WHEN external_game_links.external_app_id IS NULL THEN excluded.status
                        ELSE external_game_links.status
                    END,
                    query_name=excluded.query_name,
                    last_attempt_at=excluded.last_attempt_at,
                    error_message=excluded.error_message;
                """,
                bindings: [
                    sourceID, game.appID, status.rawValue, game.name,
                    dateFormatter.string(from: date), safeMessage ?? NSNull()
                ]
            )
        }
    }

    public func externalEntries(sourceID: String? = nil) throws -> [ExternalCompatibilityEntry] {
        try ensurePrepared()
        let filter = sourceID == nil ? "" : "WHERE l.source_id=?"
        let bindings: [Any] = sourceID.map { [$0] } ?? []
        let sql = """
            SELECT l.source_id, l.app_id, g.name, l.status, l.match_method, l.confidence,
                   l.last_attempt_at, l.error_message,
                   r.external_app_id, r.canonical_url, r.name, r.company, r.category,
                   r.steam_app_id, r.mac_rating, r.mac_tested_version, r.mac_tested_at,
                   r.linux_rating, r.linux_tested_version, r.linux_tested_at,
                   r.fetched_at, r.content_fingerprint, r.entity_tag, r.last_modified
            FROM external_game_links l
            JOIN games g ON g.app_id=l.app_id
            LEFT JOIN external_game_records r
              ON r.source_id=l.source_id AND r.external_app_id=l.external_app_id
            \(filter)
            ORDER BY g.name COLLATE NOCASE, l.source_id;
            """
        return try query(sql, bindings: bindings, transform: decodeExternalEntry)
    }

    public func externalEntry(sourceID: String, appID: String) throws -> ExternalCompatibilityEntry? {
        try ensurePrepared()
        let normalizedAppID = SteamAppID.normalized(appID) ?? appID
        let sql = """
            SELECT l.source_id, l.app_id, g.name, l.status, l.match_method, l.confidence,
                   l.last_attempt_at, l.error_message,
                   r.external_app_id, r.canonical_url, r.name, r.company, r.category,
                   r.steam_app_id, r.mac_rating, r.mac_tested_version, r.mac_tested_at,
                   r.linux_rating, r.linux_tested_version, r.linux_tested_at,
                   r.fetched_at, r.content_fingerprint, r.entity_tag, r.last_modified
            FROM external_game_links l
            JOIN games g ON g.app_id=l.app_id
            LEFT JOIN external_game_records r
              ON r.source_id=l.source_id AND r.external_app_id=l.external_app_id
            WHERE l.source_id=? AND l.app_id=?
            LIMIT 1;
            """
        return try query(
            sql,
            bindings: [sourceID, normalizedAppID],
            transform: decodeExternalEntry
        ).first
    }

    public func compatibilityComparisons() throws -> [CompatibilityComparison] {
        try ensurePrepared()
        let storedProfiles = try compatibilityProfiles()
        let activeCertifications = try certifications()
        let profilesByAppID = Dictionary(grouping: storedProfiles, by: \.appID)
        let certificationsByAppID = Dictionary(grouping: activeCertifications, by: \.appID)
        // La comparación pública actual tiene una fuente semántica concreta.
        // Filtrarla evita colisiones cuando se incorporen otros catálogos en el futuro.
        let externalByAppID = Dictionary(
            uniqueKeysWithValues: try externalEntries(
                sourceID: CodeWeaversCompatibilityProvider.codeWeaversSource.id
            ).map { ($0.appID, $0) }
        )
        let games = try storedGames()

        return games.map { appID, name in
            let certification = certificationsByAppID[appID]?.first
            let candidates = profilesByAppID[appID] ?? []
            let best = candidates.sorted(by: Self.isProfileBetter).first
            let localState: LocalCompatibilityState
            let localBackend: BackendKind?
            if let certification {
                localState = .verifiedPerfect
                localBackend = certification.backend
            } else if let best, best.perfectRuns > 0 {
                localState = .verifiedPerfect
                localBackend = best.backend
            } else if let best, best.playableRuns > 0 {
                localState = .playableWithIssues
                localBackend = best.backend
            } else if !candidates.isEmpty, candidates.reduce(0, { $0 + $1.failedRuns }) > 0 {
                localState = .failed
                localBackend = best?.backend
            } else {
                localState = .unverified
                localBackend = best?.backend
            }

            let external = externalByAppID[appID]?.record
            return CompatibilityComparison(
                appID: appID,
                gameName: name,
                localState: localState,
                localBackend: localBackend,
                publicMacRating: external?.macOSRating.value,
                publicTestedVersion: external?.macOSRating.testedCrossOverVersion,
                alignment: Self.alignment(
                    localState: localState,
                    publicRating: external?.macOSRating.value
                ),
                comparedAt: Date()
            )
        }
        .sorted { $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending }
    }

    private func decodeExternalEntry(
        _ statement: OpaquePointer
    ) throws -> ExternalCompatibilityEntry? {
        guard let status = ExternalCatalogLinkStatus(rawValue: Self.text(statement, 3)) else {
            return nil
        }
        let record: ExternalGameRecord?
        if let externalAppID = Self.optionalText(statement, 8),
           let canonicalURL = Self.optionalText(statement, 9).flatMap(URL.init(string:)),
           let fetchedAt = Self.optionalText(statement, 20).flatMap(dateFormatter.date(from:)) {
            record = ExternalGameRecord(
                sourceID: Self.text(statement, 0),
                externalAppID: externalAppID,
                canonicalURL: canonicalURL,
                name: Self.text(statement, 10),
                company: Self.optionalText(statement, 11),
                category: Self.optionalText(statement, 12),
                steamAppID: Self.optionalText(statement, 13),
                macOSRating: ExternalCompatibilityRating(
                    platform: .macOS,
                    value: Self.optionalInt(statement, 14),
                    testedCrossOverVersion: Self.optionalText(statement, 15),
                    testedAt: Self.optionalText(statement, 16).flatMap(dateFormatter.date(from:))
                ),
                linuxRating: ExternalCompatibilityRating(
                    platform: .linux,
                    value: Self.optionalInt(statement, 17),
                    testedCrossOverVersion: Self.optionalText(statement, 18),
                    testedAt: Self.optionalText(statement, 19).flatMap(dateFormatter.date(from:))
                ),
                fetchedAt: fetchedAt,
                contentFingerprint: Self.text(statement, 21),
                entityTag: Self.optionalText(statement, 22),
                lastModified: Self.optionalText(statement, 23)
            )
        } else {
            record = nil
        }
        return ExternalCompatibilityEntry(
            sourceID: Self.text(statement, 0),
            appID: Self.text(statement, 1),
            gameName: Self.text(statement, 2),
            status: status,
            matchMethod: Self.optionalText(statement, 4).flatMap(ExternalCatalogMatchMethod.init(rawValue:)),
            confidence: Self.optionalDouble(statement, 5),
            record: record,
            lastAttemptAt: Self.optionalText(statement, 6).flatMap(dateFormatter.date(from:)),
            errorMessage: Self.optionalText(statement, 7)
        )
    }

    public func databaseHealth() throws -> CompatibilityDatabaseHealth {
        try ensurePrepared()
        let integrity = try scalarText("PRAGMA quick_check;") ?? "unknown"
        let violations = try countRows("PRAGMA foreign_key_check;")
        return CompatibilityDatabaseHealth(
            schemaVersion: try schemaVersion(),
            integrity: integrity,
            foreignKeyViolations: violations,
            gameCount: try scalarInt("SELECT COUNT(*) FROM games;"),
            runCount: try scalarInt("SELECT COUNT(*) FROM runs;"),
            processCount: try scalarInt("SELECT COUNT(*) FROM run_processes;"),
            verifiedRunCount: try scalarInt("SELECT COUNT(*) FROM run_verifications;"),
            observationCount: try scalarInt("SELECT COUNT(*) FROM compatibility_observations;"),
            certificationCount: try scalarInt(
                "SELECT COUNT(*) FROM verified_game_certifications WHERE is_active=1;"
            ),
            externalRecordCount: try scalarInt("SELECT COUNT(*) FROM external_game_records;"),
            engineSnapshotCount: try scalarInt("SELECT COUNT(*) FROM engine_snapshots;"),
            runtimeTechnologyCount: try scalarInt("SELECT COUNT(*) FROM runtime_technologies;"),
            runtimeCandidateCount: try scalarInt("SELECT COUNT(*) FROM runtime_candidates;"),
            optimizationAssessmentCount: try scalarInt("SELECT COUNT(*) FROM optimization_assessments;"),
            runtimeRequirementCount: try scalarInt("SELECT COUNT(*) FROM game_runtime_requirements;"),
            repairReceiptCount: try scalarInt("SELECT COUNT(*) FROM repair_receipts;"),
            researchCaseCount: try scalarInt("SELECT COUNT(*) FROM compatibility_research_cases;"),
            researchHypothesisCount: try scalarInt("SELECT COUNT(*) FROM research_hypotheses;"),
            researchExperimentCount: try scalarInt("SELECT COUNT(*) FROM research_experiments;"),
            researchGateCount: try scalarInt("SELECT COUNT(*) FROM research_gate_results;"),
            researchArtifactCount: try scalarInt("SELECT COUNT(*) FROM research_artifacts;"),
            preflightReportCount: try scalarInt("SELECT COUNT(*) FROM run_preflight_reports;")
        )
    }

    public func exportJSON(to destinationURL: URL) throws {
        let payload = CompatibilityExport(
            schemaVersion: Self.currentSchemaVersion,
            exportedAt: Date(),
            runs: try runDetails(),
            processes: try runProcesses(),
            observations: try observations(),
            profiles: try compatibilityProfiles(),
            engines: try engineProfiles(),
            certifications: try certifications(activeOnly: false),
            externalCatalog: try externalEntries(),
            comparisons: try compatibilityComparisons(),
            runtimeTechnologies: try runtimeTechnologies(),
            runtimeCandidates: try runtimeCandidates(),
            optimizationAssessments: try optimizationAssessments(),
            runtimeRequirements: try runtimeRequirements(),
            repairReceipts: try repairReceipts(),
            researchCases: try researchCases(),
            researchHypotheses: try researchHypotheses(),
            researchExperiments: try researchExperiments(),
            researchGates: try researchGates(),
            researchArtifacts: try researchArtifacts(),
            preflightSnapshots: try preflightSnapshots(),
            databaseHealth: try databaseHealth()
        )
        let exportEncoder = JSONEncoder()
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        exportEncoder.dateEncodingStrategy = .iso8601
        try PrivateStorage.write(exportEncoder.encode(payload), atomicallyTo: destinationURL)
    }

    public func lastMigrationBackup() -> URL? {
        migrationBackupURL
    }

    private func migrateSchema(from startingVersion: Int) throws {
        guard startingVersion < Self.currentSchemaVersion else { return }
        try transaction {
            // También repara de forma idempotente índices/tablas base ausentes en
            // snapshots antiguos que ya declaraban una versión parcial.
            try executeScript(Self.legacySchema)
            if startingVersion < 1 {
                try recordMigration(version: 1, name: "telemetría local inicial")
                try execute("PRAGMA user_version=1;")
            }
            if startingVersion < 2 {
                // Un exit code 0 nunca demuestra que el juego renderizó o pudo jugarse.
                try execute(
                    "UPDATE runs SET result='unknown' WHERE result='succeeded' " +
                    "AND NOT EXISTS (SELECT 1 FROM run_verifications v WHERE v.run_id=runs.id);"
                )
                try recordMigration(version: 2, name: "verificación visual explícita")
                try execute("PRAGMA user_version=2;")
            }
            if startingVersion < 3 {
                if try !columnExists(table: "run_verifications", column: "gameplay") {
                    try execute(
                        "ALTER TABLE run_verifications " +
                        "ADD COLUMN gameplay TEXT NOT NULL DEFAULT 'notTested';"
                    )
                }
                if try !columnExists(table: "compatibility_observations", column: "gameplay") {
                    try execute(
                        "ALTER TABLE compatibility_observations " +
                        "ADD COLUMN gameplay TEXT NOT NULL DEFAULT 'notTested';"
                    )
                }
                // El diálogo histórico de «perfecto» ya exigía gameplay; esta migración
                // conserva ese contrato, ahora como dimensión consultable por separado.
                try execute("UPDATE run_verifications SET gameplay='passed' WHERE verdict='perfect';")
                try execute(
                    "UPDATE compatibility_observations SET gameplay='passed' WHERE verdict='perfect';"
                )
                try executeScript(Self.certificationSchema)
                try recordMigration(version: 3, name: "gameplay y catálogo blindado")
                try execute("PRAGMA user_version=3;")
            }
            if startingVersion < 4 {
                try executeScript(Self.externalCatalogSchema)
                try recordMigration(version: 4, name: "fuentes públicas y comparación")
                try execute("PRAGMA user_version=4;")
            }
            if startingVersion < 5 {
                try executeScript(Self.engineSnapshotSchema)
                try backfillEngineSnapshots()
                try recordMigration(version: 5, name: "identidad normalizada de motores")
                try execute("PRAGMA user_version=5;")
            }
            if startingVersion < 6 {
                try execute(
                    """
                    UPDATE run_verifications
                    SET verdict='invalidated', rendering='notTested', input_precision='notTested',
                        graphics_settings='notTested', gameplay='notTested',
                        notes='Verificación anulada: la ejecución nunca llegó a iniciarse. ' || notes
                    WHERE verdict='perfect' AND run_id IN (
                        SELECT id FROM runs WHERE process_id IS NULL OR result='preparing'
                    );
                    """
                )
                try addCertificationProvenanceColumns()
                try executeScript(Self.certificationProvenanceIndexes)
                try recordMigration(version: 6, name: "procedencia exacta de blindados")
                try execute("PRAGMA user_version=6;")
            }
            if startingVersion < 7 {
                try executeScript(RuntimeEvolutionSchema.sql)
                try recordMigration(version: 7, name: "evolución segura de runtimes y rendimiento")
                try execute("PRAGMA user_version=7;")
            }
            if startingVersion < 8 {
                try executeScript(RuntimeEvolutionSchema.promotionGuardsSQL)
                try recordMigration(version: 8, name: "comparación obligatoria de rendimiento")
                try execute("PRAGMA user_version=8;")
            }
            if startingVersion < 9 {
                try executeScript(RuntimeEvolutionSchema.metricIntegritySQL)
                try executeScript(RuntimeEvolutionSchema.promotionGuardsSQL)
                try recordMigration(version: 9, name: "integridad y cobertura de métricas")
                try execute("PRAGMA user_version=9;")
            }
            if startingVersion < 10 {
                try executeScript(ResearchSchema.sql)
                try recordMigration(version: 10, name: "expedientes reproducibles de I+D")
                try execute("PRAGMA user_version=10;")
            }
            if startingVersion < 11 {
                try executeScript(Self.preflightSchema)
                try recordMigration(
                    version: 11,
                    name: "preparación reproducible y diagnóstico previo"
                )
                try execute("PRAGMA user_version=11;")
            }
            if startingVersion < 12 {
                try executeScript(Self.processTrackingSchema)
                try backfillRunProcesses()
                try addPreflightCaptureColumns()
                try recordMigration(
                    version: 12,
                    name: "sesiones multiproceso y procedencia temporal del diagnóstico"
                )
                try execute("PRAGMA user_version=12;")
            }
        }
    }

    private func backfillRunProcesses() throws {
        try execute(
            """
            INSERT OR IGNORE INTO run_processes(
                run_id, process_id, executable, started_at, ended_at, exit_code,
                is_representative
            )
            SELECT id, process_id, COALESCE(executable, 'desconocido'), started_at,
                   ended_at, exit_code, 1
            FROM runs
            WHERE process_id IS NOT NULL;
            """
        )
    }

    private func addPreflightCaptureColumns() throws {
        if try !columnExists(table: "run_preflight_reports", column: "capture_phase") {
            try execute(
                """
                ALTER TABLE run_preflight_reports
                ADD COLUMN capture_phase TEXT NOT NULL DEFAULT 'preLaunch'
                    CHECK(capture_phase IN ('preLaunch','processStartBoundary'));
                """
            )
        }
        if try !columnExists(table: "run_preflight_reports", column: "capture_delay_ms") {
            try execute(
                """
                ALTER TABLE run_preflight_reports
                ADD COLUMN capture_delay_ms INTEGER
                    CHECK(capture_delay_ms IS NULL OR capture_delay_ms BETWEEN 0 AND 60000);
                """
            )
        }
    }

    private func recordMigration(version: Int, name: String) throws {
        try execute(
            """
            INSERT OR IGNORE INTO schema_migrations(version, name, applied_at)
            VALUES(?, ?, ?);
            """,
            bindings: [version, name, dateFormatter.string(from: Date())]
        )
    }

    private func synchronizeEmbeddedCertifications() throws {
        try transaction {
            let now = Date()
            for certification in VerifiedGameCatalog.all {
                try upsertGame(
                    appID: certification.appID,
                    name: certification.gameName,
                    at: now
                )
                try execute(
                    """
                    INSERT INTO verified_game_certifications(
                        app_id, backend, game_name, verified_at, evidence,
                        criteria_version, rendering, input_precision, graphics_settings,
                        gameplay, catalog_revision, is_active, synced_at, origin
                    ) VALUES(?, ?, ?, ?, ?, ?, 'passed', 'passed', 'passed', 'passed', ?, 1, ?, 'embeddedCatalog')
                    ON CONFLICT(app_id, backend) DO UPDATE SET
                        game_name=excluded.game_name,
                        verified_at=excluded.verified_at,
                        evidence=excluded.evidence,
                        criteria_version=excluded.criteria_version,
                        rendering=excluded.rendering,
                        input_precision=excluded.input_precision,
                        graphics_settings=excluded.graphics_settings,
                        gameplay=excluded.gameplay,
                        catalog_revision=excluded.catalog_revision,
                        origin='embeddedCatalog',
                        is_active=1,
                        synced_at=excluded.synced_at;
                    """,
                    bindings: [
                        certification.appID, certification.backend.rawValue,
                        certification.gameName, certification.verifiedAt,
                        certification.evidence, certification.criteriaVersion,
                        VerifiedGameCatalog.revision, dateFormatter.string(from: now)
                    ]
                )
                try refreshCertificationEvidenceLink(
                    appID: certification.appID,
                    backend: certification.backend
                )
            }

            let activeKeys = Set(
                VerifiedGameCatalog.all.map { "\($0.appID)|\($0.backend.rawValue)" }
            )
            let stored: [(String, String)] = try query(
                "SELECT app_id, backend FROM verified_game_certifications " +
                    "WHERE is_active=1 AND origin='embeddedCatalog';"
            ) { statement in
                (Self.text(statement, 0), Self.text(statement, 1))
            }
            for (appID, backend) in stored where !activeKeys.contains("\(appID)|\(backend)") {
                try execute(
                    "UPDATE verified_game_certifications SET is_active=0, synced_at=? " +
                    "WHERE app_id=? AND backend=?;",
                    bindings: [dateFormatter.string(from: now), appID, backend]
                )
            }

            let locallyPerfect: [(String, String, BackendKind)] = try query(
                """
                SELECT e.app_id, g.name, e.backend
                FROM (
                    SELECT r.app_id, r.backend
                    FROM runs r JOIN run_verifications v ON v.run_id=r.id
                    WHERE v.verdict='perfect' AND r.process_id IS NOT NULL
                      AND r.result!='preparing'
                    UNION
                    SELECT o.app_id, o.backend
                    FROM compatibility_observations o
                    WHERE o.verdict='perfect'
                ) e
                JOIN games g ON g.app_id=e.app_id;
                """
            ) { statement in
                guard let backend = BackendKind(rawValue: Self.text(statement, 2)) else { return nil }
                return (Self.text(statement, 0), Self.text(statement, 1), backend)
            }
            for (appID, gameName, backend) in locallyPerfect {
                try synchronizeLocalCertification(
                    appID: appID,
                    gameName: gameName,
                    backend: backend
                )
            }
        }
    }

    private func synchronizeLocalCertification(forRunID runID: UUID) throws {
        let runs: [(String, String, BackendKind)] = try query(
            """
            SELECT r.app_id, g.name, r.backend
            FROM runs r JOIN games g ON g.app_id=r.app_id
            WHERE r.id=? LIMIT 1;
            """,
            bindings: [runID.uuidString]
        ) { statement in
            guard let backend = BackendKind(rawValue: Self.text(statement, 2)) else { return nil }
            return (Self.text(statement, 0), Self.text(statement, 1), backend)
        }
        guard let run = runs.first else {
            throw RegressionCoreError.database("No existe la ejecución que se intenta certificar")
        }
        try synchronizeLocalCertification(
            appID: run.0,
            gameName: run.1,
            backend: run.2
        )
    }

    private func synchronizeLocalCertification(
        appID: String,
        gameName: String,
        backend: BackendKind
    ) throws {
        let now = dateFormatter.string(from: Date())
        guard let evidence = try latestPerfectEvidence(appID: appID, backend: backend) else {
            try execute(
                """
                UPDATE verified_game_certifications
                SET is_active=0, source_run_id=NULL, source_observation_id=NULL,
                    configuration_fingerprint=NULL, engine_fingerprint=NULL, synced_at=?
                WHERE app_id=? AND backend=? AND origin='localVerification';
                """,
                bindings: [now, appID, backend.rawValue]
            )
            return
        }

        let sourceRunID: Any = evidence.kind == "run" ? evidence.id.uuidString : NSNull()
        let sourceObservationID: Any = evidence.kind == "observation"
            ? evidence.id.uuidString
            : NSNull()
        let localEvidence = "Evidencia local \(evidence.kind) \(evidence.id.uuidString)"
        try execute(
            """
            INSERT INTO verified_game_certifications(
                app_id, backend, game_name, verified_at, evidence,
                criteria_version, rendering, input_precision, graphics_settings,
                gameplay, catalog_revision, is_active, synced_at, origin,
                source_run_id, source_observation_id,
                configuration_fingerprint, engine_fingerprint
            ) VALUES(
                ?, ?, ?, ?, ?, 2, 'passed', 'passed', 'passed', 'passed',
                'local', 1, ?, 'localVerification', ?, ?, ?, ?
            )
            ON CONFLICT(app_id, backend) DO UPDATE SET
                game_name=excluded.game_name,
                verified_at=CASE
                    WHEN verified_game_certifications.origin='embeddedCatalog'
                    THEN verified_game_certifications.verified_at
                    ELSE excluded.verified_at
                END,
                evidence=CASE
                    WHEN verified_game_certifications.origin='embeddedCatalog'
                    THEN verified_game_certifications.evidence
                    ELSE excluded.evidence
                END,
                criteria_version=CASE
                    WHEN verified_game_certifications.origin='embeddedCatalog'
                    THEN verified_game_certifications.criteria_version
                    ELSE excluded.criteria_version
                END,
                rendering='passed', input_precision='passed',
                graphics_settings='passed', gameplay='passed',
                catalog_revision=CASE
                    WHEN verified_game_certifications.origin='embeddedCatalog'
                    THEN verified_game_certifications.catalog_revision
                    ELSE 'local'
                END,
                origin=CASE
                    WHEN verified_game_certifications.origin='embeddedCatalog'
                    THEN 'embeddedCatalog'
                    ELSE 'localVerification'
                END,
                source_run_id=excluded.source_run_id,
                source_observation_id=excluded.source_observation_id,
                configuration_fingerprint=excluded.configuration_fingerprint,
                engine_fingerprint=excluded.engine_fingerprint,
                is_active=1,
                synced_at=excluded.synced_at;
            """,
            bindings: [
                appID, backend.rawValue, gameName, evidence.verifiedAt, localEvidence,
                now, sourceRunID, sourceObservationID,
                evidence.configurationFingerprint, evidence.engineFingerprint
            ]
        )
    }

    private func refreshCertificationEvidenceLink(
        appID: String,
        backend: BackendKind
    ) throws {
        let evidence = try latestPerfectEvidence(appID: appID, backend: backend)
        let sourceRunID: Any = evidence?.kind == "run"
            ? evidence?.id.uuidString ?? NSNull()
            : NSNull()
        let sourceObservationID: Any = evidence?.kind == "observation"
            ? evidence?.id.uuidString ?? NSNull()
            : NSNull()
        try execute(
            """
            UPDATE verified_game_certifications
            SET source_run_id=?, source_observation_id=?, configuration_fingerprint=?,
                engine_fingerprint=?, synced_at=?
            WHERE app_id=? AND backend=?;
            """,
            bindings: [
                sourceRunID, sourceObservationID,
                evidence?.configurationFingerprint ?? NSNull(),
                evidence?.engineFingerprint ?? NSNull(),
                dateFormatter.string(from: Date()), appID, backend.rawValue
            ]
        )
    }

    private func latestPerfectEvidence(
        appID: String,
        backend: BackendKind
    ) throws -> CertificationEvidenceRecord? {
        let records: [CertificationEvidenceRecord] = try query(
            """
            SELECT evidence_kind, evidence_id, configuration_fingerprint,
                   engine_fingerprint, verified_at
            FROM (
                SELECT 'run' AS evidence_kind, r.id AS evidence_id,
                       r.configuration_fingerprint, e.engine_fingerprint,
                       v.verified_at
                FROM runs r
                JOIN run_verifications v ON v.run_id=r.id AND v.verdict='perfect'
                JOIN run_engine_snapshots e ON e.run_id=r.id
                WHERE r.app_id=? AND r.backend=? AND r.process_id IS NOT NULL
                  AND r.result!='preparing'
                UNION ALL
                SELECT 'observation', o.id, o.configuration_fingerprint,
                       e.engine_fingerprint, o.observed_at
                FROM compatibility_observations o
                JOIN observation_engine_snapshots e ON e.observation_id=o.id
                WHERE o.app_id=? AND o.backend=? AND o.verdict='perfect'
            )
            ORDER BY verified_at DESC LIMIT 1;
            """,
            bindings: [appID, backend.rawValue, appID, backend.rawValue]
        ) { statement in
            guard let id = UUID(uuidString: Self.text(statement, 1)) else { return nil }
            return CertificationEvidenceRecord(
                kind: Self.text(statement, 0),
                id: id,
                configurationFingerprint: Self.text(statement, 2),
                engineFingerprint: Self.text(statement, 3),
                verifiedAt: Self.text(statement, 4)
            )
        }
        return records.first
    }

    private func addCertificationProvenanceColumns() throws {
        let additions = [
            ("origin", "TEXT NOT NULL DEFAULT 'embeddedCatalog'"),
            ("source_run_id", "TEXT REFERENCES runs(id) ON DELETE SET NULL"),
            ("source_observation_id", "TEXT REFERENCES compatibility_observations(id) ON DELETE SET NULL"),
            ("configuration_fingerprint", "TEXT REFERENCES configuration_snapshots(fingerprint)"),
            ("engine_fingerprint", "TEXT REFERENCES engine_snapshots(fingerprint)")
        ]
        for (column, definition) in additions where try !columnExists(
            table: "verified_game_certifications",
            column: column
        ) {
            try execute(
                "ALTER TABLE verified_game_certifications ADD COLUMN \(column) \(definition);"
            )
        }
    }

    func upsertGame(appID: String, name: String, at date: Date) throws {
        guard let normalized = SteamAppID.normalized(appID) else {
            throw RegressionCoreError.database("Steam App ID no válido: \(appID)")
        }
        let provisionalName = SteamGameName.placeholder(for: normalized)
        let normalizedName = SteamGameName.normalized(name, appID: normalized)
        let cleanName = SteamGameName.isPlaceholder(normalizedName, appID: normalized)
            ? provisionalName
            : normalizedName
        try execute(
            "INSERT INTO games(app_id, name, updated_at) VALUES(?, ?, ?) " +
            """
            ON CONFLICT(app_id) DO UPDATE SET
                name=excluded.name,
                updated_at=excluded.updated_at
            WHERE games.name<>excluded.name
              AND (
                   excluded.name<>?
                   OR trim(games.name)=''
                   OR lower(trim(games.name))=lower(?)
              );
            """,
            bindings: [
                normalized,
                cleanName,
                dateFormatter.string(from: date),
                provisionalName,
                provisionalName
            ]
        )
    }

    private func persistEngineSnapshot(
        configuration: [String: String],
        backend: BackendKind,
        providerVersion: String,
        observedAt: Date
    ) throws -> String {
        var values = ConfigurationCollector.engineValues(from: configuration)
        values["backend"] = backend.rawValue
        values["provider.version"] = providerVersion
        let fingerprint = ConfigurationCollector.fingerprint(values)
        try execute(
            """
            INSERT OR IGNORE INTO engine_snapshots(
                fingerprint, backend, provider_version, values_json, created_at
            ) VALUES(?, ?, ?, ?, ?);
            """,
            bindings: [
                fingerprint, backend.rawValue, providerVersion,
                try jsonString(values), dateFormatter.string(from: observedAt)
            ]
        )
        for (key, value) in values {
            try execute(
                """
                INSERT OR IGNORE INTO engine_facts(engine_fingerprint, category, key, value)
                VALUES(?, ?, ?, ?);
                """,
                bindings: [fingerprint, Self.engineFactCategory(for: key), key, value]
            )
        }
        return fingerprint
    }

    private func backfillEngineSnapshots() throws {
        let runRecords: [EngineBackfillRecord] = try query(
            """
            SELECT r.id, r.backend, r.provider_version, c.values_json, r.started_at
            FROM runs r
            JOIN configuration_snapshots c ON c.fingerprint=r.configuration_fingerprint;
            """
        ) { statement in
            guard
                let backend = BackendKind(rawValue: Self.text(statement, 1)),
                let data = Self.text(statement, 3).data(using: .utf8),
                let configuration = try? decoder.decode([String: String].self, from: data)
            else { return nil }
            return EngineBackfillRecord(
                id: Self.text(statement, 0),
                backend: backend,
                providerVersion: Self.text(statement, 2),
                configuration: configuration,
                observedAt: dateFormatter.date(from: Self.text(statement, 4)) ?? Date()
            )
        }
        for record in runRecords {
            let fingerprint = try persistEngineSnapshot(
                configuration: record.configuration,
                backend: record.backend,
                providerVersion: record.providerVersion,
                observedAt: record.observedAt
            )
            try execute(
                "INSERT OR IGNORE INTO run_engine_snapshots(run_id, engine_fingerprint) VALUES(?, ?);",
                bindings: [record.id, fingerprint]
            )
        }

        let observationRecords: [EngineBackfillRecord] = try query(
            """
            SELECT o.id, o.backend, o.provider_version, c.values_json, o.observed_at
            FROM compatibility_observations o
            JOIN configuration_snapshots c ON c.fingerprint=o.configuration_fingerprint;
            """
        ) { statement in
            guard
                let backend = BackendKind(rawValue: Self.text(statement, 1)),
                let data = Self.text(statement, 3).data(using: .utf8),
                let configuration = try? decoder.decode([String: String].self, from: data)
            else { return nil }
            return EngineBackfillRecord(
                id: Self.text(statement, 0),
                backend: backend,
                providerVersion: Self.text(statement, 2),
                configuration: configuration,
                observedAt: dateFormatter.date(from: Self.text(statement, 4)) ?? Date()
            )
        }
        for record in observationRecords {
            let fingerprint = try persistEngineSnapshot(
                configuration: record.configuration,
                backend: record.backend,
                providerVersion: record.providerVersion,
                observedAt: record.observedAt
            )
            try execute(
                """
                INSERT OR IGNORE INTO observation_engine_snapshots(
                    observation_id, engine_fingerprint
                ) VALUES(?, ?);
                """,
                bindings: [record.id, fingerprint]
            )
        }
    }

    private func storedGames() throws -> [(String, String)] {
        try query("SELECT app_id, name FROM games ORDER BY name COLLATE NOCASE;") { statement in
            (Self.text(statement, 0), Self.text(statement, 1))
        }
    }

    private func validateDatabase() throws {
        let version = try schemaVersion()
        guard version == Self.currentSchemaVersion else {
            throw RegressionCoreError.database(
                "La migración terminó en el esquema \(version), se esperaba \(Self.currentSchemaVersion)"
            )
        }
        guard try scalarText("PRAGMA quick_check;") == "ok" else {
            throw RegressionCoreError.database("SQLite detectó daños durante quick_check")
        }
        guard try countRows("PRAGMA foreign_key_check;") == 0 else {
            throw RegressionCoreError.database("La base contiene referencias huérfanas")
        }
        let incompletePerfectRuns = try scalarInt(
            """
            SELECT COUNT(*) FROM run_verifications
            WHERE verdict='perfect' AND (
                rendering!='passed' OR input_precision!='passed'
                OR graphics_settings!='passed' OR gameplay!='passed'
            );
            """
        )
        let incompletePerfectObservations = try scalarInt(
            """
            SELECT COUNT(*) FROM compatibility_observations
            WHERE verdict='perfect' AND (
                rendering!='passed' OR input_precision!='passed'
                OR graphics_settings!='passed' OR gameplay!='passed'
            );
            """
        )
        guard incompletePerfectRuns == 0, incompletePerfectObservations == 0 else {
            throw RegressionCoreError.database(
                "Hay perfiles perfectos sin todas las dimensiones confirmadas"
            )
        }
        let perfectRunsWithoutLaunch = try scalarInt(
            """
            SELECT COUNT(*) FROM run_verifications v
            JOIN runs r ON r.id=v.run_id
            WHERE v.verdict='perfect' AND (r.process_id IS NULL OR r.result='preparing');
            """
        )
        guard perfectRunsWithoutLaunch == 0 else {
            throw RegressionCoreError.database(
                "Hay verificaciones perfectas sobre ejecuciones que nunca llegaron a iniciarse"
            )
        }
        let invalidCertificationOrigins = try scalarInt(
            """
            SELECT COUNT(*) FROM verified_game_certifications
            WHERE origin NOT IN ('embeddedCatalog','localVerification')
               OR (source_run_id IS NOT NULL AND source_observation_id IS NOT NULL);
            """
        )
        let invalidLocalCertifications = try scalarInt(
            """
            SELECT COUNT(*) FROM verified_game_certifications c
            WHERE c.is_active=1 AND c.origin='localVerification' AND NOT (
                (
                    c.source_run_id IS NOT NULL AND c.source_observation_id IS NULL
                    AND EXISTS (
                        SELECT 1 FROM runs r
                        JOIN run_verifications v ON v.run_id=r.id AND v.verdict='perfect'
                        JOIN run_engine_snapshots e ON e.run_id=r.id
                        WHERE r.id=c.source_run_id
                          AND r.app_id=c.app_id AND r.backend=c.backend
                          AND r.configuration_fingerprint=c.configuration_fingerprint
                          AND e.engine_fingerprint=c.engine_fingerprint
                    )
                ) OR (
                    c.source_observation_id IS NOT NULL AND c.source_run_id IS NULL
                    AND EXISTS (
                        SELECT 1 FROM compatibility_observations o
                        JOIN observation_engine_snapshots e ON e.observation_id=o.id
                        WHERE o.id=c.source_observation_id AND o.verdict='perfect'
                          AND o.app_id=c.app_id AND o.backend=c.backend
                          AND o.configuration_fingerprint=c.configuration_fingerprint
                          AND e.engine_fingerprint=c.engine_fingerprint
                    )
                )
            );
            """
        )
        guard invalidCertificationOrigins == 0, invalidLocalCertifications == 0 else {
            throw RegressionCoreError.database(
                "Hay blindados locales sin una evidencia perfecta y reproducible"
            )
        }
        let runsWithoutEngine = try scalarInt(
            """
            SELECT COUNT(*) FROM runs r
            LEFT JOIN run_engine_snapshots e ON e.run_id=r.id
            WHERE e.run_id IS NULL;
            """
        )
        let observationsWithoutEngine = try scalarInt(
            """
            SELECT COUNT(*) FROM compatibility_observations o
            LEFT JOIN observation_engine_snapshots e ON e.observation_id=o.id
            WHERE e.observation_id IS NULL;
            """
        )
        guard runsWithoutEngine == 0, observationsWithoutEngine == 0 else {
            throw RegressionCoreError.database(
                "Hay evidencias sin una identidad de motor normalizada"
            )
        }
        let invalidRepresentativeProcesses = try scalarInt(
            """
            SELECT COUNT(*) FROM runs r
            WHERE r.process_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM run_processes p
                WHERE p.run_id=r.id AND p.process_id=r.process_id
                  AND p.is_representative=1
            );
            """
        )
        guard invalidRepresentativeProcesses == 0 else {
            throw RegressionCoreError.database(
                "Hay ejecuciones cuyo proceso representativo no está normalizado"
            )
        }
        try validateRuntimeEvolutionData()
        try validateResearchData()
        try validatePreflightData()
    }

    private func schemaVersion() throws -> Int {
        try scalarInt("PRAGMA user_version;")
    }

    private func containsUserDataTables() throws -> Bool {
        try scalarInt(
            """
            SELECT COUNT(*) FROM sqlite_master
            WHERE type='table' AND name NOT LIKE 'sqlite_%';
            """
        ) > 0
    }

    private func columnExists(table: String, column: String) throws -> Bool {
        let safeTable = table.replacingOccurrences(of: "'", with: "''")
        return try query("PRAGMA table_info('\(safeTable)');") { statement in
            Self.text(statement, 1)
        }
        .contains(column)
    }

    private func createMigrationBackup(fromVersion: Int) throws -> URL {
        guard let database else { throw RegressionCoreError.database("Base no inicializada") }
        let backupDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        try PrivateStorage.ensureDirectory(at: backupDirectory)
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime]
        let stamp = timestampFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let destinationURL = backupDirectory.appendingPathComponent(
            "compatibility-pre-v\(fromVersion)-to-v\(Self.currentSchemaVersion)-\(stamp)-\(UUID().uuidString.prefix(8)).sqlite"
        )

        var destination: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_EXRESCODE
        guard sqlite3_open_v2(destinationURL.path, &destination, flags, nil) == SQLITE_OK,
              let destination else {
            if let destination { sqlite3_close_v2(destination) }
            throw RegressionCoreError.database("No se pudo crear el backup previo a la migración")
        }
        defer { sqlite3_close_v2(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", database, "main") else {
            throw databaseError(destination)
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw databaseError(destination)
        }
        try PrivateStorage.secureFile(at: destinationURL)
        return destinationURL
    }

    func scalarInt(_ sql: String, bindings: [Any] = []) throws -> Int {
        let values: [Int] = try query(sql, bindings: bindings) { statement in
            Int(sqlite3_column_int64(statement, 0))
        }
        return values.first ?? 0
    }

    private func scalarText(_ sql: String, bindings: [Any] = []) throws -> String? {
        let values: [String] = try query(sql, bindings: bindings) { statement in
            Self.optionalText(statement, 0)
        }
        return values.first
    }

    private func countRows(_ sql: String, bindings: [Any] = []) throws -> Int {
        try query(sql, bindings: bindings) { _ in true }.count
    }

    private func secureDatabaseFiles() throws {
        try PrivateStorage.secureFile(at: databaseURL)
        try PrivateStorage.secureFile(
            at: URL(fileURLWithPath: databaseURL.path + "-wal")
        )
        try PrivateStorage.secureFile(
            at: URL(fileURLWithPath: databaseURL.path + "-shm")
        )
    }

    func ensurePrepared() throws {
        if database == nil { try prepare() }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func execute(_ sql: String, bindings: [Any] = []) throws {
        guard let database else { throw RegressionCoreError.database("Base no inicializada") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result == SQLITE_ROW { continue }
            throw databaseError(database)
        }
    }

    func executeScript(_ sql: String) throws {
        guard let database else { throw RegressionCoreError.database("Base no inicializada") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "Error SQLite desconocido"
            throw RegressionCoreError.database(detail)
        }
    }

    func query<T>(
        _ sql: String,
        bindings: [Any] = [],
        transform: (OpaquePointer) throws -> T?
    ) throws -> [T] {
        guard let database else { throw RegressionCoreError.database("Base no inicializada") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError(database)
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var values: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw databaseError(database) }
            if let value = try transform(statement) { values.append(value) }
        }
    }

    private func bind(_ bindings: [Any], to statement: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            if value is NSNull {
                result = sqlite3_bind_null(statement, index)
            } else if let value = value as? String {
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            } else if let value = value as? Int {
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            } else if let value = value as? Int32 {
                result = sqlite3_bind_int(statement, index, value)
            } else if let value = value as? Int64 {
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            } else if let value = value as? Double {
                result = sqlite3_bind_double(statement, index, value)
            } else if let value = value as? Bool {
                result = sqlite3_bind_int(statement, index, value ? 1 : 0)
            } else {
                result = sqlite3_bind_text(statement, index, String(describing: value), -1, sqliteTransient)
            }
            guard result == SQLITE_OK else {
                throw RegressionCoreError.database("No se pudo enlazar un valor SQL")
            }
        }
    }

    private func jsonString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func verification(
        _ statement: OpaquePointer,
        startingAt column: Int32,
        runID: UUID
    ) -> RunVerification? {
        guard
            let verdictText = Self.optionalText(statement, column),
            let verdict = VerificationVerdict(rawValue: verdictText),
            let rendering = VerificationDimension(rawValue: Self.text(statement, column + 1)),
            let input = VerificationDimension(rawValue: Self.text(statement, column + 2)),
            let settings = VerificationDimension(rawValue: Self.text(statement, column + 3)),
            let gameplay = VerificationDimension(rawValue: Self.text(statement, column + 4)),
            let source = VerificationSource(rawValue: Self.text(statement, column + 5)),
            let verifiedAt = dateFormatter.date(from: Self.text(statement, column + 7))
        else { return nil }
        return RunVerification(
            runID: runID,
            verdict: verdict,
            rendering: rendering,
            inputPrecision: input,
            graphicsSettings: settings,
            gameplay: gameplay,
            source: source,
            notes: Self.optionalText(statement, column + 6) ?? "",
            verifiedAt: verifiedAt
        )
    }

    private func databaseError(_ database: OpaquePointer) -> RegressionCoreError {
        let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "Error SQLite desconocido"
        return .database(message)
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column)
    }

    static func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    private static func optionalInt32(_ statement: OpaquePointer, _ column: Int32) -> Int32? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int(statement, column)
    }

    static func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    private static func isProfileBetter(_ left: CompatibilityProfile, _ right: CompatibilityProfile) -> Bool {
        if left.perfectRuns != right.perfectRuns { return left.perfectRuns > right.perfectRuns }
        if left.playableRuns != right.playableRuns { return left.playableRuns > right.playableRuns }
        if left.failedRuns != right.failedRuns { return left.failedRuns < right.failedRuns }
        return left.unverifiedRuns < right.unverifiedRuns
    }

    private static func alignment(
        localState: LocalCompatibilityState,
        publicRating: Int?
    ) -> CompatibilityAlignment {
        guard let publicRating else { return .insufficientEvidence }
        switch localState {
        case .verifiedPerfect:
            return publicRating >= 4 ? .agrees : .localOutperformsPublicRating
        case .playableWithIssues:
            return publicRating >= 3 ? .agrees : .localOutperformsPublicRating
        case .failed:
            return publicRating >= 4 ? .publicRatingOutperformsLocal : .agrees
        case .unverified:
            return .insufficientEvidence
        }
    }

    private static func engineFactCategory(for key: String) -> String {
        if key.hasPrefix("component.graphics.") { return "graphics-component" }
        if key.hasPrefix("component.runtime.") { return "runtime-component" }
        if key.hasPrefix("registry.") { return "registry" }
        if key.hasPrefix("bottle.") { return "bottle" }
        if key.hasPrefix("graphics.") { return "graphics" }
        if key.hasPrefix("runtime.") { return "runtime" }
        return "identity"
    }

    private static let legacySchema = """
        CREATE TABLE IF NOT EXISTS schema_migrations(
            version INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            applied_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS games(
            app_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS configuration_snapshots(
            fingerprint TEXT PRIMARY KEY,
            values_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS runs(
            id TEXT PRIMARY KEY,
            app_id TEXT NOT NULL REFERENCES games(app_id),
            backend TEXT NOT NULL,
            bottle_name TEXT NOT NULL,
            provider_version TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            result TEXT NOT NULL,
            exit_code INTEGER,
            process_id INTEGER,
            executable TEXT,
            launch_ms INTEGER,
            command TEXT NOT NULL,
            arguments_json TEXT NOT NULL,
            system_json TEXT NOT NULL,
            configuration_fingerprint TEXT NOT NULL REFERENCES configuration_snapshots(fingerprint),
            after_configuration_fingerprint TEXT REFERENCES configuration_snapshots(fingerprint),
            configuration_delta_json TEXT
        );
        CREATE INDEX IF NOT EXISTS runs_game_started_idx ON runs(app_id, started_at DESC);
        CREATE INDEX IF NOT EXISTS runs_backend_result_idx ON runs(backend, result, started_at DESC);
        CREATE TABLE IF NOT EXISTS run_verifications(
            run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
            verdict TEXT NOT NULL,
            rendering TEXT NOT NULL,
            input_precision TEXT NOT NULL,
            graphics_settings TEXT NOT NULL,
            source TEXT NOT NULL,
            notes TEXT NOT NULL,
            verified_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS run_verifications_verdict_idx
            ON run_verifications(verdict, verified_at DESC);
        CREATE TABLE IF NOT EXISTS compatibility_observations(
            id TEXT PRIMARY KEY,
            app_id TEXT NOT NULL REFERENCES games(app_id),
            backend TEXT NOT NULL,
            provider_version TEXT NOT NULL,
            verdict TEXT NOT NULL,
            rendering TEXT NOT NULL,
            input_precision TEXT NOT NULL,
            graphics_settings TEXT NOT NULL,
            configuration_fingerprint TEXT NOT NULL REFERENCES configuration_snapshots(fingerprint),
            source TEXT NOT NULL,
            notes TEXT NOT NULL,
            observed_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS compatibility_observations_game_idx
            ON compatibility_observations(app_id, observed_at DESC);
        CREATE TABLE IF NOT EXISTS run_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            occurred_at TEXT NOT NULL,
            phase TEXT NOT NULL,
            value TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS run_events_run_time_idx
            ON run_events(run_id, occurred_at);
        """

    private static let certificationSchema = """
        CREATE TABLE IF NOT EXISTS verified_game_certifications(
            app_id TEXT NOT NULL REFERENCES games(app_id),
            backend TEXT NOT NULL CHECK(backend IN ('crossOver','regression')),
            game_name TEXT NOT NULL,
            verified_at TEXT NOT NULL,
            evidence TEXT NOT NULL,
            criteria_version INTEGER NOT NULL CHECK(criteria_version >= 1),
            rendering TEXT NOT NULL CHECK(rendering='passed'),
            input_precision TEXT NOT NULL CHECK(input_precision='passed'),
            graphics_settings TEXT NOT NULL CHECK(graphics_settings='passed'),
            gameplay TEXT NOT NULL CHECK(gameplay='passed'),
            catalog_revision TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1 CHECK(is_active IN (0,1)),
            synced_at TEXT NOT NULL,
            PRIMARY KEY(app_id, backend)
        );
        CREATE INDEX IF NOT EXISTS verified_game_certifications_active_idx
            ON verified_game_certifications(is_active, verified_at DESC);

        CREATE TRIGGER IF NOT EXISTS run_verifications_complete_perfect_insert
        BEFORE INSERT ON run_verifications
        WHEN NEW.verdict='perfect' AND (
            NEW.rendering!='passed' OR NEW.input_precision!='passed'
            OR NEW.graphics_settings!='passed' OR NEW.gameplay!='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'perfect verification requires all dimensions');
        END;
        CREATE TRIGGER IF NOT EXISTS run_verifications_complete_perfect_update
        BEFORE UPDATE ON run_verifications
        WHEN NEW.verdict='perfect' AND (
            NEW.rendering!='passed' OR NEW.input_precision!='passed'
            OR NEW.graphics_settings!='passed' OR NEW.gameplay!='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'perfect verification requires all dimensions');
        END;
        CREATE TRIGGER IF NOT EXISTS observations_complete_perfect_insert
        BEFORE INSERT ON compatibility_observations
        WHEN NEW.verdict='perfect' AND (
            NEW.rendering!='passed' OR NEW.input_precision!='passed'
            OR NEW.graphics_settings!='passed' OR NEW.gameplay!='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'perfect observation requires all dimensions');
        END;
        CREATE TRIGGER IF NOT EXISTS observations_complete_perfect_update
        BEFORE UPDATE ON compatibility_observations
        WHEN NEW.verdict='perfect' AND (
            NEW.rendering!='passed' OR NEW.input_precision!='passed'
            OR NEW.graphics_settings!='passed' OR NEW.gameplay!='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'perfect observation requires all dimensions');
        END;
        """

    private static let externalCatalogSchema = """
        CREATE TABLE IF NOT EXISTS external_catalog_sources(
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            base_url TEXT NOT NULL,
            information_url TEXT NOT NULL,
            minimum_request_interval_seconds REAL NOT NULL
                CHECK(minimum_request_interval_seconds >= 0),
            cache_lifetime_seconds REAL NOT NULL CHECK(cache_lifetime_seconds >= 0),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS external_catalog_sync_state(
            source_id TEXT PRIMARY KEY REFERENCES external_catalog_sources(id) ON DELETE CASCADE,
            last_attempt_at TEXT,
            last_success_at TEXT,
            next_request_at TEXT,
            last_error TEXT
        );
        CREATE TABLE IF NOT EXISTS external_game_records(
            source_id TEXT NOT NULL REFERENCES external_catalog_sources(id) ON DELETE CASCADE,
            external_app_id TEXT NOT NULL,
            canonical_url TEXT NOT NULL,
            name TEXT NOT NULL,
            company TEXT,
            category TEXT,
            steam_app_id TEXT,
            mac_rating INTEGER CHECK(mac_rating BETWEEN 0 AND 5),
            mac_tested_version TEXT,
            mac_tested_at TEXT,
            linux_rating INTEGER CHECK(linux_rating BETWEEN 0 AND 5),
            linux_tested_version TEXT,
            linux_tested_at TEXT,
            fetched_at TEXT NOT NULL,
            content_fingerprint TEXT NOT NULL,
            entity_tag TEXT,
            last_modified TEXT,
            PRIMARY KEY(source_id, external_app_id),
            UNIQUE(source_id, canonical_url)
        );
        CREATE INDEX IF NOT EXISTS external_game_records_steam_idx
            ON external_game_records(source_id, steam_app_id);
        CREATE INDEX IF NOT EXISTS external_game_records_fetched_idx
            ON external_game_records(source_id, fetched_at DESC);
        CREATE TABLE IF NOT EXISTS external_game_links(
            source_id TEXT NOT NULL REFERENCES external_catalog_sources(id) ON DELETE CASCADE,
            app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE CASCADE,
            external_app_id TEXT,
            status TEXT NOT NULL CHECK(status IN ('pending','linked','noMatch','unavailable','failed')),
            match_method TEXT CHECK(match_method IN ('steamAppID','exactTitle','knownMapping','manual')),
            confidence REAL CHECK(confidence BETWEEN 0 AND 1),
            query_name TEXT NOT NULL,
            last_attempt_at TEXT,
            error_message TEXT,
            linked_at TEXT,
            PRIMARY KEY(source_id, app_id),
            FOREIGN KEY(source_id, external_app_id)
                REFERENCES external_game_records(source_id, external_app_id)
        );
        CREATE INDEX IF NOT EXISTS external_game_links_status_idx
            ON external_game_links(source_id, status, last_attempt_at);
        """

    private static let engineSnapshotSchema = """
        CREATE TABLE IF NOT EXISTS engine_snapshots(
            fingerprint TEXT PRIMARY KEY,
            backend TEXT NOT NULL CHECK(backend IN ('crossOver','regression')),
            provider_version TEXT NOT NULL,
            values_json TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS engine_snapshots_backend_idx
            ON engine_snapshots(backend, provider_version);
        CREATE TABLE IF NOT EXISTS engine_facts(
            engine_fingerprint TEXT NOT NULL
                REFERENCES engine_snapshots(fingerprint) ON DELETE CASCADE,
            category TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY(engine_fingerprint, key)
        );
        CREATE INDEX IF NOT EXISTS engine_facts_category_idx
            ON engine_facts(category, key);
        CREATE TABLE IF NOT EXISTS run_engine_snapshots(
            run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
            engine_fingerprint TEXT NOT NULL
                REFERENCES engine_snapshots(fingerprint)
        );
        CREATE INDEX IF NOT EXISTS run_engine_snapshots_engine_idx
            ON run_engine_snapshots(engine_fingerprint);
        CREATE TABLE IF NOT EXISTS observation_engine_snapshots(
            observation_id TEXT PRIMARY KEY
                REFERENCES compatibility_observations(id) ON DELETE CASCADE,
            engine_fingerprint TEXT NOT NULL
                REFERENCES engine_snapshots(fingerprint)
        );
        CREATE INDEX IF NOT EXISTS observation_engine_snapshots_engine_idx
            ON observation_engine_snapshots(engine_fingerprint);
        """

    private static let preflightSchema = """
        CREATE TABLE IF NOT EXISTS run_preflight_reports(
            run_id TEXT PRIMARY KEY REFERENCES runs(id) ON DELETE CASCADE,
            protocol_version INTEGER NOT NULL CHECK(protocol_version >= 1),
            status TEXT NOT NULL CHECK(status IN ('ready','warning','blocked')),
            blocker_count INTEGER NOT NULL CHECK(blocker_count >= 0),
            warning_count INTEGER NOT NULL CHECK(warning_count >= 0),
            capture_phase TEXT NOT NULL DEFAULT 'preLaunch'
                CHECK(capture_phase IN ('preLaunch','processStartBoundary')),
            capture_delay_ms INTEGER
                CHECK(capture_delay_ms IS NULL OR capture_delay_ms BETWEEN 0 AND 60000),
            report_json TEXT NOT NULL CHECK(json_valid(report_json)),
            report_fingerprint TEXT NOT NULL CHECK(
                length(report_fingerprint)=64
                AND report_fingerprint NOT GLOB '*[^0-9a-f]*'
            ),
            created_at TEXT NOT NULL,
            CHECK(
                (capture_phase='preLaunch' AND capture_delay_ms IS NULL)
                OR (capture_phase='processStartBoundary' AND capture_delay_ms IS NOT NULL)
            ),
            CHECK(
                (status='ready' AND blocker_count=0 AND warning_count=0)
                OR (status='warning' AND blocker_count=0 AND warning_count>0)
                OR (status='blocked' AND blocker_count>0)
            )
        );
        CREATE INDEX IF NOT EXISTS run_preflight_reports_status_idx
            ON run_preflight_reports(status, created_at DESC);
        """

    private static let processTrackingSchema = """
        CREATE TABLE IF NOT EXISTS run_processes(
            run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
            process_id INTEGER NOT NULL CHECK(process_id > 0),
            executable TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            exit_code INTEGER,
            is_representative INTEGER NOT NULL DEFAULT 0 CHECK(is_representative IN (0,1)),
            PRIMARY KEY(run_id, process_id),
            CHECK(ended_at IS NOT NULL OR exit_code IS NULL)
        );
        CREATE INDEX IF NOT EXISTS run_processes_run_time_idx
            ON run_processes(run_id, started_at);
        CREATE UNIQUE INDEX IF NOT EXISTS run_processes_one_representative_idx
            ON run_processes(run_id) WHERE is_representative=1;
        """

    private static let certificationProvenanceIndexes = """
        CREATE INDEX IF NOT EXISTS verified_certifications_origin_idx
            ON verified_game_certifications(origin, is_active, verified_at DESC);
        CREATE INDEX IF NOT EXISTS verified_certifications_run_idx
            ON verified_game_certifications(source_run_id);
        CREATE INDEX IF NOT EXISTS verified_certifications_observation_idx
            ON verified_game_certifications(source_observation_id);
        CREATE INDEX IF NOT EXISTS verified_certifications_engine_idx
            ON verified_game_certifications(engine_fingerprint);
        CREATE TRIGGER IF NOT EXISTS run_verifications_perfect_requires_launch_insert
        BEFORE INSERT ON run_verifications
        WHEN NEW.verdict='perfect' AND NOT EXISTS (
            SELECT 1 FROM runs r
            WHERE r.id=NEW.run_id AND r.process_id IS NOT NULL AND r.result!='preparing'
        )
        BEGIN
            SELECT RAISE(ABORT, 'perfect verification requires a launched run');
        END;
        CREATE TRIGGER IF NOT EXISTS run_verifications_perfect_requires_launch_update
        BEFORE UPDATE ON run_verifications
        WHEN NEW.verdict='perfect' AND NOT EXISTS (
            SELECT 1 FROM runs r
            WHERE r.id=NEW.run_id AND r.process_id IS NOT NULL AND r.result!='preparing'
        )
        BEGIN
            SELECT RAISE(ABORT, 'perfect verification requires a launched run');
        END;
        """
}

public struct CompatibilityExport: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let runs: [RunDetail]
    public let processes: [RunProcessRecord]
    public let observations: [CompatibilityObservation]
    public let profiles: [CompatibilityProfile]
    public let engines: [EngineProfile]
    public let certifications: [VerifiedGameCertification]
    public let externalCatalog: [ExternalCompatibilityEntry]
    public let comparisons: [CompatibilityComparison]
    public let runtimeTechnologies: [RuntimeTechnology]
    public let runtimeCandidates: [RuntimeCandidate]
    public let optimizationAssessments: [OptimizationAssessment]
    public let runtimeRequirements: [GameRuntimeRequirement]
    public let repairReceipts: [RepairReceipt]
    public let researchCases: [CompatibilityResearchCase]
    public let researchHypotheses: [ResearchHypothesis]
    public let researchExperiments: [ResearchExperiment]
    public let researchGates: [ResearchGateResult]
    public let researchArtifacts: [ResearchArtifact]
    public let preflightSnapshots: [RunPreflightSnapshot]
    public let databaseHealth: CompatibilityDatabaseHealth
}
