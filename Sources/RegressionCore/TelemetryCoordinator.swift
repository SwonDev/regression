import Foundation

public struct TelemetryObservedRunStart: Equatable, Sendable {
    public let runID: UUID
    public let appID: String
    public let gameName: String
    public let backend: BackendKind
    public let processStartedAt: Date

    public init(
        runID: UUID,
        appID: String,
        gameName: String,
        backend: BackendKind,
        processStartedAt: Date
    ) {
        self.runID = runID
        self.appID = appID
        self.gameName = gameName
        self.backend = backend
        self.processStartedAt = processStartedAt
    }
}

public struct TelemetryPollOutcome: Equatable, Sendable {
    public var changed: Bool
    public var unpreparedRunStarts: [TelemetryObservedRunStart]
    public var issues: [String]

    public init(
        changed: Bool = false,
        unpreparedRunStarts: [TelemetryObservedRunStart] = [],
        issues: [String] = []
    ) {
        self.changed = changed
        self.unpreparedRunStarts = unpreparedRunStarts
        self.issues = issues
    }

    public mutating func merge(_ other: TelemetryPollOutcome) {
        changed = changed || other.changed
        unpreparedRunStarts.append(contentsOf: other.unpreparedRunStarts)
        issues.append(contentsOf: other.issues)
    }
}

public actor TelemetryCoordinator {
    private struct PendingTermination: Sendable {
        let endedAt: Date
        let observedAt: Date
        let exitCode: Int32
    }

    private struct ActiveRun: Sendable {
        let id: UUID
        let appID: String
        let backend: BackendKind
        let startedAt: Date
        let beforeConfiguration: [String: String]
        let bottleURL: URL
        let providerVersion: String
        let configurationOverrides: [String: String]
        let game: SteamGame?
        let steamRootURL: URL
        var processes: [Int32: String]
        var exitCodes: [Int32: Int32]
        var representativeProcessID: Int32
        var representativeExecutable: String
        var pendingTermination: PendingTermination?
    }

    private struct PendingRun: Sendable {
        let context: RunContext
        let bottleURL: URL
    }

    private let repository: CompatibilityRepository
    private let monitor: SteamLogMonitor
    private let sessionJoinGrace: TimeInterval
    private let artifactCleaner: any GameSessionArtifactCleaning
    private var active: [String: ActiveRun] = [:]
    private var pending: [String: PendingRun] = [:]

    public init(
        repository: CompatibilityRepository,
        monitor: SteamLogMonitor,
        sessionJoinGrace: TimeInterval = 3,
        artifactCleaner: any GameSessionArtifactCleaning = NoOpGameSessionArtifactCleaner()
    ) {
        self.repository = repository
        self.monitor = monitor
        self.sessionJoinGrace = max(0, sessionJoinGrace)
        self.artifactCleaner = artifactCleaner
    }

    public func beginMonitoring(logURL: URL) async {
        await monitor.beginMonitoringAtEnd(of: logURL)
    }

    public func registerLaunchIntent(context: RunContext, bottleURL: URL) async throws {
        let key = Self.sessionKey(backend: context.backend, appID: context.appID)
        if let previous = pending[key] {
            try await repository.failRunBeforeLaunch(
                id: previous.context.id,
                reason: "La solicitud pendiente fue sustituida por un nuevo lanzamiento."
            )
            pending.removeValue(forKey: key)
        }
        try await repository.beginRun(context)
        pending[key] = PendingRun(
            context: context,
            bottleURL: bottleURL
        )
    }

    public func cancelLaunchIntent(context: RunContext, reason: String) async throws {
        let key = Self.sessionKey(backend: context.backend, appID: context.appID)
        guard pending[key]?.context.id == context.id else { return }
        pending.removeValue(forKey: key)
        try await repository.failRunBeforeLaunch(id: context.id, reason: reason)
    }

    /// Consume el log de Steam como sesiones lógicas por backend y App ID.
    ///
    /// Steam puede iniciar primero un launcher y después el binario real. Los PID se conservan
    /// individualmente en SQLite, pero solo existe una ejecución verificable y no se cierra hasta
    /// que todos sus procesos han terminado y ha vencido una breve ventana de unión.
    public func poll(
        backend: BackendKind,
        logURL: URL,
        games: [SteamGame],
        system: SystemSnapshot,
        steamRootURL: URL,
        bottleURL: URL,
        bottleName: String,
        providerVersion: String,
        configurationOverrides: [String: String] = [:]
    ) async -> TelemetryPollOutcome {
        let events = await monitor.readNewEvents(from: logURL)
        if events.isEmpty {
            return await finalizeExpiredSessions(backend: backend, now: Date())
        }

        let gameNames = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0.name) })
        let gamesByID = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0) })
        var outcome = TelemetryPollOutcome()

        for event in events {
            switch event {
            case let .started(timestamp, rawAppID, processID, executable):
                guard SteamGameProcessLogParser.isPrimaryExecutable(executable),
                      let appID = SteamAppID.normalized(rawAppID) else { continue }
                let key = Self.sessionKey(backend: backend, appID: appID)

                if var run = active[key] {
                    guard run.processes[processID] == nil else { continue }
                    do {
                        try await repository.markAdditionalProcessStarted(
                            id: run.id,
                            processID: processID,
                            executable: executable,
                            startedAt: timestamp
                        )
                        run.processes[processID] = executable
                        run.exitCodes.removeValue(forKey: processID)
                        run.representativeProcessID = processID
                        run.representativeExecutable = executable
                        run.pendingTermination = nil
                        active[key] = run
                        outcome.changed = true
                    } catch {
                        outcome.issues.append(Self.issue(
                            "No se pudo asociar un proceso adicional del App ID \(appID)",
                            error: error
                        ))
                    }
                    continue
                }

                let pendingRun = pending[key]
                let configuration = pendingRun?.context.configuration
                    ?? Self.configuration(
                        bottleURL: bottleURL,
                        backend: backend,
                        providerVersion: providerVersion,
                        game: gamesByID[appID],
                        steamRootURL: steamRootURL,
                        overrides: configurationOverrides
                    )
                let gameName = gameNames[appID] ?? SteamGameName.placeholder(for: appID)
                let context = pendingRun?.context ?? RunContext(
                    appID: appID,
                    gameName: gameName,
                    backend: backend,
                    bottleName: bottleName,
                    providerVersion: providerVersion,
                    startedAt: timestamp,
                    command: executable,
                    arguments: [],
                    system: system,
                    configuration: configuration,
                    configurationFingerprint: ConfigurationCollector.fingerprint(configuration)
                )

                do {
                    if pendingRun == nil {
                        try await repository.beginRun(context)
                    }
                    let launchMilliseconds = max(
                        0,
                        Int(timestamp.timeIntervalSince(context.startedAt) * 1_000)
                    )
                    try await repository.markLaunched(
                        id: context.id,
                        processID: processID,
                        executable: executable,
                        startedAt: timestamp,
                        launchMilliseconds: launchMilliseconds
                    )
                    pending.removeValue(forKey: key)
                    active[key] = ActiveRun(
                        id: context.id,
                        appID: appID,
                        backend: backend,
                        startedAt: context.startedAt,
                        beforeConfiguration: configuration,
                        bottleURL: pendingRun?.bottleURL ?? bottleURL,
                        providerVersion: providerVersion,
                        configurationOverrides: configurationOverrides,
                        game: gamesByID[appID],
                        steamRootURL: steamRootURL,
                        processes: [processID: executable],
                        exitCodes: [:],
                        representativeProcessID: processID,
                        representativeExecutable: executable,
                        pendingTermination: nil
                    )
                    if pendingRun == nil {
                        outcome.unpreparedRunStarts.append(TelemetryObservedRunStart(
                            runID: context.id,
                            appID: appID,
                            gameName: gameName,
                            backend: backend,
                            processStartedAt: timestamp
                        ))
                    }
                    outcome.changed = true
                } catch {
                    pending.removeValue(forKey: key)
                    try? await repository.failRunBeforeLaunch(
                        id: context.id,
                        reason: "No se pudo registrar el proceso observado por Steam."
                    )
                    outcome.issues.append(Self.issue(
                        "No se pudo abrir la sesión de telemetría del App ID \(appID)",
                        error: error
                    ))
                }

            case let .ended(timestamp, rawAppID, processID, exitCode):
                guard let appID = SteamAppID.normalized(rawAppID) else { continue }
                let key = Self.sessionKey(backend: backend, appID: appID)
                guard var run = active[key], run.processes[processID] != nil else { continue }
                do {
                    try await repository.markProcessEnded(
                        id: run.id,
                        processID: processID,
                        endedAt: timestamp,
                        exitCode: exitCode
                    )
                    run.processes.removeValue(forKey: processID)
                    run.exitCodes[processID] = exitCode
                    run.pendingTermination = run.processes.isEmpty
                        ? PendingTermination(
                            endedAt: timestamp,
                            observedAt: Date(),
                            exitCode: exitCode
                        )
                        : nil
                    active[key] = run
                    outcome.changed = true
                } catch {
                    outcome.issues.append(Self.issue(
                        "No se pudo cerrar un proceso del App ID \(appID)",
                        error: error
                    ))
                }
            }
        }

        outcome.merge(await finalizeExpiredSessions(backend: backend, now: Date()))
        return outcome
    }

    private func finalizeExpiredSessions(
        backend: BackendKind,
        now: Date
    ) async -> TelemetryPollOutcome {
        var outcome = TelemetryPollOutcome()
        let keys = active.compactMap { key, run -> String? in
            guard run.backend == backend,
                  run.processes.isEmpty,
                  let pendingTermination = run.pendingTermination,
                  now.timeIntervalSince(pendingTermination.observedAt) >= sessionJoinGrace
            else { return nil }
            return key
        }

        for key in keys {
            guard let run = active[key], let termination = run.pendingTermination else { continue }
            let after = Self.configuration(
                bottleURL: run.bottleURL,
                backend: run.backend,
                providerVersion: run.providerVersion,
                game: run.game,
                steamRootURL: run.steamRootURL,
                overrides: run.configurationOverrides
            )
            let delta = ConfigurationDiffer.difference(
                before: run.beforeConfiguration,
                after: after
            )
            let representativeExitCode = run.exitCodes[run.representativeProcessID]
                ?? termination.exitCode
            // Un cierre limpio no demuestra render, entrada, opciones ni gameplay.
            let result: RunResult = representativeExitCode == 0 ? .unknown : .crashed
            do {
                try await repository.finishRun(
                    id: run.id,
                    endedAt: termination.endedAt,
                    exitCode: representativeExitCode,
                    result: result,
                    afterConfiguration: after,
                    delta: delta
                )
                outcome.issues.append(contentsOf: await artifactCleaner.clean(
                    appID: run.appID,
                    backend: run.backend,
                    endedWindowsProcessIDs: Set(run.exitCodes.keys)
                ))
                if result == .crashed, run.backend == .regression {
                    do {
                        if let learned = try CompiledCrashRepairLearner.learn(
                            appID: run.appID,
                            executable: run.representativeExecutable,
                            bottleURL: run.bottleURL,
                            startedAt: run.startedAt,
                            endedAt: termination.endedAt
                        ) {
                            try await repository.recordRepairReceipt(RepairReceipt(
                                appID: learned.appID,
                                backend: .regression,
                                recipeID: learned.recipe.rawValue,
                                recipeVersion: 1,
                                beforeFingerprint: learned.activation.beforeFingerprint,
                                afterFingerprint: learned.activation.afterFingerprint,
                                rollbackReference: PrivacySanitizer.normalizedPath(
                                    learned.activation.rollbackURL.path
                                ),
                                result: .succeeded,
                                notes: "Activación tipada aprendida desde una firma de crash estricta en \(PrivacySanitizer.normalizedPath(learned.crashLogURL.path))."
                            ))
                        }
                    } catch {
                        outcome.issues.append(Self.issue(
                            "No se pudo registrar una autorreparación tipada para el App ID \(run.appID)",
                            error: error
                        ))
                    }
                }
                active.removeValue(forKey: key)
                outcome.changed = true
            } catch {
                outcome.issues.append(Self.issue(
                    "No se pudo consolidar la sesión del App ID \(run.appID)",
                    error: error
                ))
            }
        }
        return outcome
    }

    private static func sessionKey(backend: BackendKind, appID: String) -> String {
        "\(backend.rawValue):\(appID)"
    }

    private static func issue(_ prefix: String, error: any Error) -> String {
        PrivacySanitizer.redactedLogExcerpt(
            "\(prefix): \(error.localizedDescription)",
            limit: 500
        )
    }

    private static func configuration(
        bottleURL: URL,
        backend: BackendKind,
        providerVersion: String,
        game: SteamGame?,
        steamRootURL: URL,
        overrides: [String: String]
    ) -> [String: String] {
        var values = ConfigurationCollector.snapshot(
            bottleURL: bottleURL,
            backend: backend,
            providerVersion: providerVersion,
            game: game,
            steamRootURL: steamRootURL
        )
        values.merge(overrides) { _, override in override }
        return values
    }
}
