import Foundation

public struct TelemetryObservedRunStart: Codable, Equatable, Sendable {
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

public enum TelemetryIssueCode: Codable, Equatable, Sendable {
    case steamLog(SteamLogMonitorIssueCode)
    case staleProcessEvent
    case repositoryOperation
    case artifactCleanup
}

public struct TelemetryIssue: Codable, Equatable, Sendable, CustomStringConvertible {
    public let code: TelemetryIssueCode
    public let message: String
    public let isNew: Bool

    public init(code: TelemetryIssueCode, message: String, isNew: Bool = true) {
        self.code = code
        self.message = message
        self.isNew = isNew
    }

    public var description: String { message }
}

public struct TelemetryPollOutcome: Codable, Equatable, Sendable {
    public var changed: Bool
    public var unpreparedRunStarts: [TelemetryObservedRunStart]
    public var issues: [TelemetryIssue]
    public var resolvedIssues: [TelemetryIssueCode]

    public init(
        changed: Bool = false,
        unpreparedRunStarts: [TelemetryObservedRunStart] = [],
        issues: [TelemetryIssue] = [],
        resolvedIssues: [TelemetryIssueCode] = []
    ) {
        self.changed = changed
        self.unpreparedRunStarts = unpreparedRunStarts
        self.issues = issues
        self.resolvedIssues = resolvedIssues
    }

    public mutating func merge(_ other: TelemetryPollOutcome) {
        changed = changed || other.changed
        unpreparedRunStarts.append(contentsOf: other.unpreparedRunStarts)
        issues.append(contentsOf: other.issues)
        resolvedIssues.append(contentsOf: other.resolvedIssues)
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
        let launchOrigin: RepairAttemptLaunchOrigin
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

    /// Descarta solamente la referencia en memoria después de que el repositorio ya haya
    /// persistido su cierre atómico. No vuelve a tocar el run ni puede añadir un evento fuera de
    /// la transacción del envelope.
    public func discardLaunchIntentAfterDurableFailure(context: RunContext) {
        let key = Self.sessionKey(backend: context.backend, appID: context.appID)
        guard pending[key]?.context.id == context.id else { return }
        pending.removeValue(forKey: key)
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
        let read = await monitor.readNewEvents(from: logURL)
        let newLogIssues = Set(read.newlyObservedIssues)
        let typedLogIssues = read.issues.map {
            TelemetryIssue(
                code: .steamLog($0.code),
                message: $0.message,
                isNew: newLogIssues.contains($0.code)
            )
        }
        let resolvedLogIssues = read.resolvedIssues.map(TelemetryIssueCode.steamLog)
        if read.events.isEmpty || read.discontinuity != nil {
            var outcome = read.hasMoreData || read.hasPendingLine
                ? TelemetryPollOutcome()
                : await finalizeExpiredSessions(backend: backend, now: Date())
            outcome.issues.append(contentsOf: typedLogIssues)
            outcome.resolvedIssues.append(contentsOf: resolvedLogIssues)
            return outcome
        }

        let gameNames = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0.name) })
        let gamesByID = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0) })
        var outcome = TelemetryPollOutcome(
            issues: typedLogIssues,
            resolvedIssues: resolvedLogIssues
        )

        for event in read.events {
            switch event {
            case let .started(timestamp, rawAppID, processID, executable):
                guard SteamGameProcessLogParser.isPrimaryExecutable(executable),
                      let appID = SteamAppID.normalized(rawAppID) else { continue }
                let key = Self.sessionKey(backend: backend, appID: appID)

                if var run = active[key] {
                    guard timestamp >= run.startedAt else {
                        outcome.issues.append(Self.staleEventIssue(appID: appID))
                        continue
                    }
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

                // El CLI no comparte memoria con la app. Antes de crear una sesión observada,
                // adopta la intención durable exacta (App ID + backend + run preparado) para no
                // duplicar evidencia ni perder su envelope/nonce.
                let pendingRun: PendingRun?
                if let inMemory = pending[key] {
                    pendingRun = inMemory
                } else if let durable = try? await repository.adoptableLaunchEnvelopeRun(
                    appID: appID,
                    backend: backend
                ) {
                    pendingRun = PendingRun(context: durable.context, bottleURL: bottleURL)
                } else {
                    pendingRun = nil
                }
                if let pendingRun, timestamp < pendingRun.context.startedAt {
                    outcome.issues.append(Self.staleEventIssue(appID: appID))
                    continue
                }
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
                        launchOrigin: pendingRun == nil ? .steamObserved : .regression,
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
                guard timestamp >= run.startedAt else {
                    outcome.issues.append(Self.staleEventIssue(appID: appID))
                    continue
                }
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

        if !read.hasMoreData && !read.hasPendingLine {
            outcome.merge(await finalizeExpiredSessions(backend: backend, now: Date()))
        }
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
                // El final de telemetría solo desbloquea la revisión humana. Nunca convierte un
                // exit code ni la presencia de un proceso en certificación funcional.
                _ = try await repository.reconcileLaunchEnvelopeAfterTelemetry(runID: run.id)
                outcome.issues.append(contentsOf: await artifactCleaner.clean(
                    appID: run.appID,
                    backend: run.backend,
                    endedWindowsProcessIDs: Set(run.exitCodes.keys)
                ).map {
                    TelemetryIssue(code: .artifactCleanup, message: $0)
                })
                if result == .crashed, run.backend == .regression {
                    do {
                        if let detection = try CompiledCrashRepairLearner.detect(
                            appID: run.appID,
                            executable: run.representativeExecutable,
                            bottleURL: run.bottleURL,
                            startedAt: run.startedAt,
                            endedAt: termination.endedAt
                        ) {
                            // El loader ya aísla App ID y basename: acredita contra el
                            // `appmanifest` de Steam que el proceso pertenece de verdad al
                            // App ID del registro. La activación puede escribirse, y surte
                            // efecto en el siguiente arranque de ese ejecutable exacto.
                            let origin = PrivacySanitizer.normalizedPath(
                                detection.crashLogURL.path
                            )
                            // La máquina de estados manda: primero se deja constancia de lo
                            // observado, después del plan y solo entonces se toca la botella.
                            // El repositorio no promueve a aplicado sin huellas antes/después
                            // ni manifiesto de rollback, así que nada queda sin poder deshacerse.
                            let attempt = RepairAttempt(
                                sourceRunID: run.id,
                                appID: detection.appID,
                                executable: detection.executable,
                                launchOrigin: run.launchOrigin,
                                recipe: detection.recipe,
                                recipeVersion: 2,
                                state: .detected,
                                notes: "Firma de crash estricta detectada en \(origin)."
                            )
                            try await repository.recordRepairAttempt(attempt)
                            try await repository.transitionRepairAttempt(
                                id: attempt.id,
                                to: .planned,
                                notes: "Receta compilada \(detection.recipe.rawValue) para el App ID y el ejecutable exactos.",
                                at: termination.endedAt
                            )
                            let activation = try CompiledRepairActivationStore.activate(
                                appID: detection.appID,
                                executable: detection.executable,
                                recipe: detection.recipe,
                                in: run.bottleURL
                            )
                            if let activation {
                                try await repository.transitionRepairAttempt(
                                    id: attempt.id,
                                    to: .appliedAwaitingRelaunch,
                                    beforeFingerprint: activation.beforeFingerprint,
                                    afterFingerprint: activation.afterFingerprint,
                                    rollbackReference: activation.rollbackURL.standardizedFileURL.path,
                                    rollbackManifest: activation.rollbackManifest(),
                                    notes: "Activación v2 escrita; surte efecto en el siguiente arranque de ese ejecutable exacto.",
                                    at: termination.endedAt
                                )
                            } else {
                                // Reincidir con la receta ya activa significa que no era la causa:
                                // se cierra como fallida en vez de reescribir la botella en bucle.
                                try await repository.transitionRepairAttempt(
                                    id: attempt.id,
                                    to: .failed,
                                    notes: "La activación ya estaba presente, así que la receta no resolvió este fallo.",
                                    at: termination.endedAt
                                )
                            }
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

    private static func issue(_ prefix: String, error: any Error) -> TelemetryIssue {
        TelemetryIssue(
            code: .repositoryOperation,
            message: PrivacySanitizer.redactedLogExcerpt(
                "\(prefix): \(error.localizedDescription)",
                limit: 500
            )
        )
    }

    private static func staleEventIssue(appID: String) -> TelemetryIssue {
        TelemetryIssue(
            code: .staleProcessEvent,
            message: "Se ignoró un evento anterior al inicio verificable del App ID \(appID)."
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
