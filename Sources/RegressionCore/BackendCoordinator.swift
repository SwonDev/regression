import Foundation

public struct SteamCommand: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]

    public init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}

public enum BackendCommandFactory {
    private static let crossOverSteamPath = #"C:\Program Files (x86)\Steam\steam.exe"#

    public static func crossOver(
        installation: CrossOverInstallation,
        steamArguments: [String]
    ) -> SteamCommand {
        SteamCommand(
            executableURL: installation.wineCLIURL,
            arguments: [
                "--bottle", installation.bottleName,
                "--cx-app", crossOverSteamPath
            ] + steamArguments
        )
    }

    public static func regression(
        installation: RegressionInstallation,
        steamArguments: [String]
    ) -> SteamCommand {
        SteamCommand(
            executableURL: installation.engineLauncherURL,
            arguments: steamArguments
        )
    }
}

public actor BackendCoordinator {
    private let processRunner: ProcessRunner
    private let processLauncher: ProcessLauncher
    private let inspector: ProcessInspector
    private let logDirectoryURL: URL

    public init(
        processRunner: ProcessRunner,
        processLauncher: ProcessLauncher,
        inspector: ProcessInspector,
        logDirectoryURL: URL
    ) {
        self.processRunner = processRunner
        self.processLauncher = processLauncher
        self.inspector = inspector
        self.logDirectoryURL = logDirectoryURL
    }

    public func runningState() async -> RunningBackendState {
        await inspector.runningBackends()
    }

    public func launchSteam(
        backend: BackendKind,
        installations: InstallationSnapshot,
        appID: String? = nil
    ) async throws -> BackendLaunch {
        let running = await inspector.runningBackends()
        if running.hasConflict {
            throw RegressionCoreError.backendConflict
        }
        if let active = running.activeBackend, active != backend {
            throw RegressionCoreError.backendAlreadyRunning(active)
        }
        if appID == nil, running.activeBackend == backend {
            throw RegressionCoreError.backendAlreadyRunning(backend)
        }

        let steamArguments: [String]
        if let appID {
            guard let normalized = SteamAppID.normalized(appID) else {
                throw RegressionCoreError.launchFailed("El Steam App ID no es válido")
            }
            steamArguments = ["-applaunch", normalized]
        } else {
            steamArguments = []
        }

        let command = try command(
            backend: backend,
            installations: installations,
            steamArguments: steamArguments
        )
        guard FileManager.default.isExecutableFile(atPath: command.executableURL.path) else {
            throw RegressionCoreError.launcherMissing(command.executableURL)
        }
        return try await processLauncher.launch(
            backend: backend,
            executableURL: command.executableURL,
            arguments: command.arguments,
            logDirectoryURL: logDirectoryURL
        )
    }

    public func requestShutdown(
        backend: BackendKind,
        installations: InstallationSnapshot,
        timeoutSeconds: Double = 30
    ) async throws {
        let command = try command(
            backend: backend,
            installations: installations,
            steamArguments: ["-shutdown"]
        )
        let result = try await processRunner.run(
            executableURL: command.executableURL,
            arguments: command.arguments
        )
        if result.exitCode != 0 {
            let detail = PrivacySanitizer.redactedLogExcerpt(
                result.standardError.isEmpty ? result.standardOutput : result.standardError
            )
            throw RegressionCoreError.launchFailed(detail)
        }

        let attempts = max(1, Int(timeoutSeconds * 2))
        for _ in 0..<attempts {
            let running = await inspector.runningBackends()
            let stillRunning = backend == .crossOver ? running.crossOverIsRunning : running.regressionIsRunning
            if !stillRunning { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw RegressionCoreError.shutdownTimedOut(backend)
    }

    public func switchBackend(
        from current: BackendKind?,
        to target: BackendKind,
        installations: InstallationSnapshot
    ) async throws -> BackendLaunch {
        if let current, current != target {
            try await requestShutdown(backend: current, installations: installations)
        }
        return try await launchSteam(backend: target, installations: installations)
    }

    private func command(
        backend: BackendKind,
        installations: InstallationSnapshot,
        steamArguments: [String]
    ) throws -> SteamCommand {
        switch backend {
        case .crossOver:
            guard let crossOver = installations.crossOver else {
                switch installations.crossOverIssue?.code {
                case .crossOverNotInstalled:
                    throw RegressionCoreError.crossOverNotInstalled
                case .steamBottleNotFound:
                    throw RegressionCoreError.bottleNotFound
                case .steamNotInstalled:
                    throw RegressionCoreError.steamNotInstalled
                case .bottleDamaged:
                    throw RegressionCoreError.bottleDamaged(installations.crossOverIssue?.message ?? "Estado desconocido")
                case nil:
                    throw RegressionCoreError.crossOverNotInstalled
                }
            }
            if crossOver.health == .damaged {
                throw RegressionCoreError.bottleDamaged(crossOver.healthDetail)
            }
            return BackendCommandFactory.crossOver(
                installation: crossOver,
                steamArguments: steamArguments
            )
        case .regression:
            guard installations.regression.health == .ready else {
                throw RegressionCoreError.launcherMissing(installations.regression.engineLauncherURL)
            }
            return BackendCommandFactory.regression(
                installation: installations.regression,
                steamArguments: steamArguments
            )
        }
    }
}
