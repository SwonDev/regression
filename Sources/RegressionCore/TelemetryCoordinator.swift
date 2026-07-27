import Foundation

public actor TelemetryCoordinator {
    private struct ActiveRun: Sendable {
        let id: UUID
        let appID: String
        let processID: Int32
        let backend: BackendKind
        let startedAt: Date
        let beforeConfiguration: [String: String]
        let bottleURL: URL
        let providerVersion: String
        let configurationOverrides: [String: String]
        let game: SteamGame?
        let steamRootURL: URL
    }

    private struct PendingRun: Sendable {
        let context: RunContext
        let bottleURL: URL
    }

    private let repository: CompatibilityRepository
    private let monitor: SteamLogMonitor
    private var active: [String: ActiveRun] = [:]
    private var pending: [String: PendingRun] = [:]

    public init(repository: CompatibilityRepository, monitor: SteamLogMonitor) {
        self.repository = repository
        self.monitor = monitor
    }

    public func beginMonitoring(logURL: URL) async {
        await monitor.beginMonitoringAtEnd(of: logURL)
    }

    public func registerLaunchIntent(context: RunContext, bottleURL: URL) async throws {
        try await repository.beginRun(context)
        pending[Self.pendingKey(backend: context.backend, appID: context.appID)] = PendingRun(
            context: context,
            bottleURL: bottleURL
        )
    }

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
    ) async {
        let events = await monitor.readNewEvents(from: logURL)
        let gameNames = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0.name) })
        let gamesByID = Dictionary(uniqueKeysWithValues: games.map { ($0.appID, $0) })

        for event in events {
            switch event {
            case let .started(timestamp, appID, processID, executable):
                guard SteamGameProcessLogParser.isPrimaryExecutable(executable) else { continue }
                let activeKey = Self.activeKey(backend: backend, appID: appID, processID: processID)
                guard active[activeKey] == nil else { continue }

                let pendingKey = Self.pendingKey(backend: backend, appID: appID)
                let pendingRun = pending.removeValue(forKey: pendingKey)
                let configuration = pendingRun?.context.configuration
                    ?? Self.configuration(
                        bottleURL: bottleURL,
                        backend: backend,
                        providerVersion: providerVersion,
                        game: gamesByID[appID],
                        steamRootURL: steamRootURL,
                        overrides: configurationOverrides
                    )
                let context = pendingRun?.context ?? RunContext(
                    appID: appID,
                    gameName: gameNames[appID] ?? "Steam App \(appID)",
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
                if pendingRun == nil {
                    try? await repository.beginRun(context)
                }
                let launchMilliseconds = max(0, Int(timestamp.timeIntervalSince(context.startedAt) * 1_000))
                try? await repository.markLaunched(
                    id: context.id,
                    processID: processID,
                    executable: executable,
                    launchMilliseconds: launchMilliseconds
                )
                active[activeKey] = ActiveRun(
                    id: context.id,
                    appID: appID,
                    processID: processID,
                    backend: backend,
                    startedAt: timestamp,
                    beforeConfiguration: configuration,
                    bottleURL: pendingRun?.bottleURL ?? bottleURL,
                    providerVersion: providerVersion,
                    configurationOverrides: configurationOverrides,
                    game: gamesByID[appID],
                    steamRootURL: steamRootURL
                )

            case let .ended(timestamp, appID, processID, exitCode):
                let activeKey = Self.activeKey(backend: backend, appID: appID, processID: processID)
                guard let run = active.removeValue(forKey: activeKey) else { continue }
                let after = Self.configuration(
                    bottleURL: run.bottleURL,
                    backend: run.backend,
                    providerVersion: run.providerVersion,
                    game: run.game,
                    steamRootURL: run.steamRootURL,
                    overrides: run.configurationOverrides
                )
                let delta = ConfigurationDiffer.difference(before: run.beforeConfiguration, after: after)
                // Un cierre limpio no demuestra que el juego haya renderizado ni que
                // el ratón o sus opciones funcionasen. El éxito solo lo establece una
                // verificación visual explícita almacenada aparte.
                let result: RunResult = exitCode == 0 ? .unknown : .crashed
                try? await repository.finishRun(
                    id: run.id,
                    endedAt: timestamp,
                    exitCode: exitCode,
                    result: result,
                    afterConfiguration: after,
                    delta: delta
                )
            }
        }
    }

    private static func pendingKey(backend: BackendKind, appID: String) -> String {
        "\(backend.rawValue):\(appID)"
    }

    private static func activeKey(backend: BackendKind, appID: String, processID: Int32) -> String {
        "\(backend.rawValue):\(appID):\(processID)"
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
