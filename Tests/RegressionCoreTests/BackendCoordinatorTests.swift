import Foundation
@testable import RegressionCore
import XCTest

final class BackendCoordinatorTests: XCTestCase {
    func testConflictPreventsLaunchingAnotherSteam() async throws {
        let inspector = StubProcessInspector(states: [
            RunningBackendState(crossOverPIDs: [10], regressionPIDs: [20]),
        ])
        let launcher = StubProcessLauncher()
        let coordinator = coordinator(inspector: inspector, launcher: launcher)

        do {
            _ = try await coordinator.launchSteam(
                backend: .regression,
                installations: installations()
            )
            XCTFail("El conflicto debía bloquear el lanzamiento")
        } catch RegressionCoreError.backendConflict {
            let commands = await launcher.commands()
            XCTAssertTrue(commands.isEmpty)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testGameRequestReusesRunningBackendWithoutLaunchingSecondSteamClient() async throws {
        let inspector = StubProcessInspector(states: [
            RunningBackendState(regressionPIDs: [20]),
        ])
        let launcher = StubProcessLauncher()
        let coordinator = coordinator(inspector: inspector, launcher: launcher)

        _ = try await coordinator.launchSteam(
            backend: .regression,
            installations: installations(),
            appID: "000219990"
        )

        let commands = await launcher.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.arguments, ["-applaunch", "219990"])
    }

    func testShutdownUsesOfficialCommandAndWaitsUntilBackendDisappears() async throws {
        let runner = StubProcessRunner(result: ProcessResult(
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        ))
        let inspector = StubProcessInspector(states: [
            RunningBackendState(crossOverPIDs: [10]),
            RunningBackendState(),
        ])
        let coordinator = BackendCoordinator(
            processRunner: runner,
            processLauncher: StubProcessLauncher(),
            inspector: inspector,
            logDirectoryURL: FileManager.default.temporaryDirectory
        )

        try await coordinator.requestShutdown(
            backend: .crossOver,
            installations: installations(),
            timeoutSeconds: 1
        )

        let commands = await runner.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(
            commands.first?.arguments,
            [
                "--bottle", "Steam",
                "--cx-app", #"C:\Program Files (x86)\Steam\steam.exe"#,
                "-shutdown",
            ]
        )
    }

    func testDamagedBottleIsRejectedBeforeLauncherRuns() async throws {
        let inspector = StubProcessInspector(states: [RunningBackendState()])
        let launcher = StubProcessLauncher()
        let coordinator = coordinator(inspector: inspector, launcher: launcher)
        let damaged = installations(crossOverHealth: .damaged)

        do {
            _ = try await coordinator.launchSteam(
                backend: .crossOver,
                installations: damaged
            )
            XCTFail("Una botella dañada no debe iniciarse")
        } catch RegressionCoreError.bottleDamaged {
            let commands = await launcher.commands()
            XCTAssertTrue(commands.isEmpty)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    private func coordinator(
        inspector: StubProcessInspector,
        launcher: StubProcessLauncher
    ) -> BackendCoordinator {
        BackendCoordinator(
            processRunner: StubProcessRunner(),
            processLauncher: launcher,
            inspector: inspector,
            logDirectoryURL: FileManager.default.temporaryDirectory
        )
    }

    private func installations(
        crossOverHealth: InstallationHealth = .ready
    ) -> InstallationSnapshot {
        let crossOver = CrossOverInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/CrossOver.app"),
            version: "26.3",
            build: "test",
            bottleName: "Steam",
            bottleURL: URL(fileURLWithPath: "/tmp/CrossOver/Steam"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/CrossOver/Steam/steam.exe"),
            wineCLIURL: URL(fileURLWithPath: "/usr/bin/true"),
            bottleCLIURL: URL(fileURLWithPath: "/usr/bin/true"),
            feedURL: nil,
            health: crossOverHealth,
            healthDetail: crossOverHealth == .ready ? "ok" : "dañada"
        )
        let regression = RegressionInstallation(
            applicationURL: URL(fileURLWithPath: "/tmp/Regression.app"),
            bottleURL: URL(fileURLWithPath: "/tmp/RegressionBottle"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/RegressionBottle/Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/usr/bin/true"),
            health: .ready,
            healthDetail: "ok"
        )
        return InstallationSnapshot(crossOver: crossOver, regression: regression)
    }
}

private actor StubProcessRunner: ProcessRunning {
    struct Command: Sendable {
        let executableURL: URL
        let arguments: [String]
        let environment: [String: String]?
    }

    private let result: ProcessResult
    private var recordedCommands: [Command] = []

    init(result: ProcessResult = ProcessResult(
        exitCode: 0,
        standardOutput: "",
        standardError: ""
    )) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> ProcessResult {
        recordedCommands.append(Command(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment
        ))
        return result
    }

    func commands() -> [Command] {
        recordedCommands
    }
}

private actor StubProcessLauncher: ProcessLaunching {
    struct Command: Sendable {
        let backend: BackendKind
        let executableURL: URL
        let arguments: [String]
        let logDirectoryURL: URL
    }

    private var recordedCommands: [Command] = []

    func launch(
        backend: BackendKind,
        executableURL: URL,
        arguments: [String],
        logDirectoryURL: URL
    ) async throws -> BackendLaunch {
        recordedCommands.append(Command(
            backend: backend,
            executableURL: executableURL,
            arguments: arguments,
            logDirectoryURL: logDirectoryURL
        ))
        return BackendLaunch(
            backend: backend,
            processID: 999,
            command: executableURL.path,
            arguments: arguments,
            logURL: logDirectoryURL.appendingPathComponent("test.log")
        )
    }

    func reapFinishedProcesses() async {}

    func commands() -> [Command] {
        recordedCommands
    }
}

private actor StubProcessInspector: ProcessInspecting {
    private var states: [RunningBackendState]

    init(states: [RunningBackendState]) {
        self.states = states
    }

    func runningBackends() async -> RunningBackendState {
        guard states.count > 1 else { return states.first ?? RunningBackendState() }
        return states.removeFirst()
    }
}
