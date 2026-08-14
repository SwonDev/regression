import Foundation

public actor InstallationDiscovery {
    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private let regressionComponentHealthProvider:
        @Sendable (RegressionInstallation) -> ComponentHealthReport

    public init(
        runner: any ProcessRunning,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil,
        applicationRoots: [URL]? = nil
    ) {
        // Se conserva el parámetro para mantener compatibilidad binaria con callers existentes,
        // pero el descubrimiento de instalaciones es deliberadamente pasivo y Regression-only.
        _ = runner
        _ = applicationRoots
        self.fileManager = fileManager
        let home = homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
        self.homeDirectoryURL = home
        self.regressionComponentHealthProvider = RegressionLaunchComponentGate.evaluate
    }

    init(
        runner: any ProcessRunning,
        fileManager: FileManager = .default,
        homeDirectoryURL: URL? = nil,
        applicationRoots: [URL]? = nil,
        regressionComponentHealthProvider: @escaping @Sendable (
            RegressionInstallation
        ) -> ComponentHealthReport
    ) {
        _ = runner
        _ = applicationRoots
        self.fileManager = fileManager
        let home = homeDirectoryURL ?? fileManager.homeDirectoryForCurrentUser
        self.homeDirectoryURL = home
        self.regressionComponentHealthProvider = regressionComponentHealthProvider
    }

    public func discover(regressionApplicationURL: URL? = nil) async -> InstallationSnapshot {
        let regression = discoverRegression(applicationURL: regressionApplicationURL)
        return InstallationSnapshot(
            crossOver: nil,
            crossOverIssue: nil,
            regression: regression
        )
    }

    private func discoverRegression(applicationURL: URL?) -> RegressionInstallation {
        let resolvedApplicationURL: URL
        if let applicationURL {
            resolvedApplicationURL = applicationURL
        } else {
            resolvedApplicationURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Regression.app", isDirectory: true)
        }

        let bottle = homeDirectoryURL
            .appendingPathComponent("Library/Application Support/Regression/Bottles/Steam", isDirectory: true)
        let steam = bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam/Steam.exe")
        let modernLauncher = resolvedApplicationURL.appendingPathComponent("Contents/MacOS/regression-engine")
        let legacyLauncher = resolvedApplicationURL.appendingPathComponent("Contents/MacOS/regression")
        let launcher = fileManager.fileExists(atPath: modernLauncher.path) ? modernLauncher : legacyLauncher

        let health: InstallationHealth
        let detail: String
        if !fileManager.fileExists(atPath: steam.path) {
            health = .missing
            detail = "Steam no está instalado en la botella propia"
        } else if !fileManager.isExecutableFile(atPath: launcher.path) {
            health = .damaged
            detail = "Falta el lanzador del motor propio"
        } else {
            health = .ready
            detail = "Motor propio disponible"
        }

        let installation = RegressionInstallation(
            applicationURL: resolvedApplicationURL,
            bottleURL: bottle,
            steamExecutableURL: steam,
            engineLauncherURL: launcher,
            health: health,
            healthDetail: detail
        )
        guard health == .ready else { return installation }

        let runtimeHealth = regressionComponentHealthProvider(installation)
        do {
            try RegressionLaunchComponentGate.requireReady(runtimeHealth)
        } catch {
            return RegressionInstallation(
                applicationURL: resolvedApplicationURL,
                bottleURL: bottle,
                steamExecutableURL: steam,
                engineLauncherURL: launcher,
                health: .damaged,
                healthDetail: "El runtime sellado no supera ComponentHealth "
                    + "(\(runtimeHealth.status.rawValue))"
            )
        }
        return installation
    }

}
