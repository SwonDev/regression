import CSQLite
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor CompatibilityRepository {
    private let databaseURL: URL
    private var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let dateFormatter: ISO8601DateFormatter

    public init(databaseURL: URL) {
        self.databaseURL = databaseURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public func prepare() throws {
        guard database == nil else { return }
        try PrivateStorage.ensureDirectory(at: databaseURL.deletingLastPathComponent())
        try secureDatabaseFiles()
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw RegressionCoreError.database("No se pudo abrir \(databaseURL.lastPathComponent)")
        }
        database = handle
        sqlite3_busy_timeout(handle, 3_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try executeScript(Self.schema)
        // Version 1 inferred success from exit code 0. That is insufficient for
        // games that showed a black screen or an error dialog and then closed cleanly.
        try execute(
            "UPDATE runs SET result='unknown' WHERE result='succeeded' " +
            "AND NOT EXISTS (SELECT 1 FROM run_verifications v WHERE v.run_id=runs.id);"
        )
        try secureDatabaseFiles()
    }

    public func beginRun(_ context: RunContext) throws {
        try ensurePrepared()
        try transaction {
            try execute(
                "INSERT INTO games(app_id, name, updated_at) VALUES(?, ?, ?) " +
                "ON CONFLICT(app_id) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at;",
                bindings: [context.appID, context.gameName, dateFormatter.string(from: Date())]
            )
            let configurationJSON = try jsonString(context.configuration)
            try execute(
                "INSERT OR IGNORE INTO configuration_snapshots(fingerprint, values_json, created_at) VALUES(?, ?, ?);",
                bindings: [context.configurationFingerprint, configurationJSON, dateFormatter.string(from: context.startedAt)]
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
        }
    }

    public func markLaunched(id: UUID, processID: Int32, executable: String, launchMilliseconds: Int?) throws {
        try ensurePrepared()
        try execute(
            "UPDATE runs SET result=?, process_id=?, executable=?, launch_ms=? WHERE id=?;",
            bindings: [
                RunResult.launched.rawValue,
                String(processID),
                executable,
                launchMilliseconds.map(String.init) ?? NSNull(),
                id.uuidString
            ]
        )
        try recordEvent(runID: id, phase: "process-started", value: executable)
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
                    dateFormatter.string(from: endedAt), result.rawValue, String(exitCode),
                    afterFingerprint, try jsonString(delta), id.uuidString
                ]
            )
            try recordEvent(runID: id, phase: "process-ended", value: "exit=\(exitCode)")
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
        let notes = PrivacySanitizer.redactedLogExcerpt(verification.notes, limit: 2_000)
        try transaction {
            try execute(
                """
                INSERT INTO run_verifications(
                    run_id, verdict, rendering, input_precision, graphics_settings,
                    source, notes, verified_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(run_id) DO UPDATE SET
                    verdict=excluded.verdict,
                    rendering=excluded.rendering,
                    input_precision=excluded.input_precision,
                    graphics_settings=excluded.graphics_settings,
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
        }
    }

    public func recordObservation(_ observation: CompatibilityObservation) throws {
        try ensurePrepared()
        let notes = PrivacySanitizer.redactedLogExcerpt(observation.notes, limit: 2_000)
        try transaction {
            try execute(
                "INSERT INTO games(app_id, name, updated_at) VALUES(?, ?, ?) " +
                "ON CONFLICT(app_id) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at;",
                bindings: [
                    observation.appID,
                    observation.gameName,
                    dateFormatter.string(from: observation.observedAt)
                ]
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
                    input_precision, graphics_settings, configuration_fingerprint,
                    source, notes, observed_at
                ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                    observation.configurationFingerprint,
                    observation.source.rawValue,
                    notes,
                    dateFormatter.string(from: observation.observedAt)
                ]
            )
        }
    }

    public func observations(limit: Int = 10_000) throws -> [CompatibilityObservation] {
        try ensurePrepared()
        let sql = """
            SELECT o.id, o.app_id, g.name, o.backend, o.provider_version,
                   o.verdict, o.rendering, o.input_precision, o.graphics_settings,
                   o.configuration_fingerprint, c.values_json, o.source, o.notes, o.observed_at
            FROM compatibility_observations o
            JOIN games g ON g.app_id = o.app_id
            JOIN configuration_snapshots c ON c.fingerprint = o.configuration_fingerprint
            ORDER BY o.observed_at DESC LIMIT ?;
            """
        return try query(sql, bindings: [String(max(1, limit))]) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let backend = BackendKind(rawValue: Self.text(statement, 3)),
                let verdict = VerificationVerdict(rawValue: Self.text(statement, 5)),
                let rendering = VerificationDimension(rawValue: Self.text(statement, 6)),
                let input = VerificationDimension(rawValue: Self.text(statement, 7)),
                let settings = VerificationDimension(rawValue: Self.text(statement, 8)),
                let data = Self.text(statement, 10).data(using: .utf8),
                let configuration = try? decoder.decode([String: String].self, from: data),
                let source = VerificationSource(rawValue: Self.text(statement, 11)),
                let observedAt = dateFormatter.date(from: Self.text(statement, 13))
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
                configurationFingerprint: Self.text(statement, 9),
                configuration: configuration,
                source: source,
                notes: Self.text(statement, 12),
                observedAt: observedAt
            )
        }
    }

    public func recentRuns(limit: Int = 30) throws -> [RunSummary] {
        try ensurePrepared()
        let sql = """
            SELECT r.id, r.app_id, g.name, r.backend, r.started_at, r.ended_at,
                   r.result, r.exit_code, r.launch_ms, r.configuration_fingerprint,
                   v.verdict, v.rendering, v.input_precision, v.graphics_settings,
                   v.source, v.notes, v.verified_at
            FROM runs r
            JOIN games g ON g.app_id = r.app_id
            LEFT JOIN run_verifications v ON v.run_id = r.id
            ORDER BY r.started_at DESC LIMIT ?;
            """
        return try query(sql, bindings: [String(max(1, limit))]) { statement in
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
                launchDurationMilliseconds: Self.optionalInt(statement, 8),
                configurationFingerprint: Self.text(statement, 9),
                verification: verification(statement, startingAt: 10, runID: id)
            )
        }
    }

    public func compatibilityProfiles() throws -> [CompatibilityProfile] {
        try ensurePrepared()
        let sql = """
            WITH evidence AS (
                SELECT r.app_id, r.backend, r.configuration_fingerprint,
                       CASE WHEN v.verdict = 'perfect' THEN 1 ELSE 0 END AS perfect,
                       CASE WHEN v.verdict = 'playableWithIssues' THEN 1 ELSE 0 END AS playable,
                       CASE WHEN v.verdict = 'failed' OR r.result = 'crashed' THEN 1 ELSE 0 END AS failed,
                       CASE WHEN v.run_id IS NULL AND r.result != 'crashed' THEN 1 ELSE 0 END AS unverified,
                       r.launch_ms,
                       CASE WHEN v.verdict IN ('perfect','playableWithIssues') THEN v.verified_at END AS successful_at
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

    public func runDetails(limit: Int = 100_000) throws -> [RunDetail] {
        try ensurePrepared()
        let sql = """
            SELECT r.id, r.app_id, g.name, r.backend, r.bottle_name, r.provider_version,
                   r.started_at, r.ended_at, r.result, r.exit_code, r.process_id,
                   r.executable, r.launch_ms, r.command, r.arguments_json, r.system_json,
                   r.configuration_fingerprint, c.values_json,
                   r.after_configuration_fingerprint, r.configuration_delta_json,
                   v.verdict, v.rendering, v.input_precision, v.graphics_settings,
                   v.source, v.notes, v.verified_at
            FROM runs r
            JOIN games g ON g.app_id = r.app_id
            JOIN configuration_snapshots c ON c.fingerprint = r.configuration_fingerprint
            LEFT JOIN run_verifications v ON v.run_id = r.id
            ORDER BY r.started_at DESC LIMIT ?;
            """
        return try query(sql, bindings: [String(max(1, limit))]) { statement in
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

    public func exportJSON(to destinationURL: URL) throws {
        let payload = CompatibilityExport(
            schemaVersion: 2,
            exportedAt: Date(),
            runs: try runDetails(),
            observations: try observations(),
            profiles: try compatibilityProfiles()
        )
        let exportEncoder = JSONEncoder()
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        exportEncoder.dateEncodingStrategy = .iso8601
        try exportEncoder.encode(payload).write(to: destinationURL, options: .atomic)
        try PrivateStorage.secureFile(at: destinationURL)
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

    private func ensurePrepared() throws {
        if database == nil { try prepare() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func execute(_ sql: String, bindings: [Any] = []) throws {
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

    private func executeScript(_ sql: String) throws {
        guard let database else { throw RegressionCoreError.database("Base no inicializada") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "Error SQLite desconocido"
            throw RegressionCoreError.database(detail)
        }
    }

    private func query<T>(
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
            let source = VerificationSource(rawValue: Self.text(statement, column + 4)),
            let verifiedAt = dateFormatter.date(from: Self.text(statement, column + 6))
        else { return nil }
        return RunVerification(
            runID: runID,
            verdict: verdict,
            rendering: rendering,
            inputPrecision: input,
            graphicsSettings: settings,
            source: source,
            notes: Self.optionalText(statement, column + 5) ?? "",
            verifiedAt: verifiedAt
        )
    }

    private func databaseError(_ database: OpaquePointer) -> RegressionCoreError {
        let message = sqlite3_errmsg(database).map(String.init(cString:)) ?? "Error SQLite desconocido"
        return .database(message)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private static func optionalText(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column)
    }

    private static func optionalInt(_ statement: OpaquePointer, _ column: Int32) -> Int? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, column))
    }

    private static func optionalInt32(_ statement: OpaquePointer, _ column: Int32) -> Int32? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int(statement, column)
    }

    private static let schema = """
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
        """
}

public struct CompatibilityExport: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let runs: [RunDetail]
    public let observations: [CompatibilityObservation]
    public let profiles: [CompatibilityProfile]
}
