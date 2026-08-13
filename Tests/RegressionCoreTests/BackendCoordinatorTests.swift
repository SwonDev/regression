import Foundation
@testable import RegressionCore
import XCTest

final class BackendCoordinatorTests: XCTestCase {
    func testCustodyInterlockPreventsLaunchingEitherBackend() async throws {
        for backend in BackendKind.allCases {
            let inspector = StubProcessInspector(states: [RunningBackendState()])
            let launcher = StubProcessLauncher()
            let coordinator = coordinator(
                inspector: inspector,
                launcher: launcher,
                custodyInterlock: StubCustodyInterlock(
                    snapshot: PhysicalLibraryCustodyInterlockSnapshot(
                        status: .preCutover,
                        mutationPolicy: .blocked
                    )
                )
            )

            do {
                _ = try await coordinator.launchSteam(
                    backend: backend,
                    installations: installations()
                )
                XCTFail("La custodia debía bloquear el lanzamiento de \(backend.displayName)")
            } catch RegressionCoreError.unsafeLibraryState {
                let commands = await launcher.commands()
                XCTAssertTrue(commands.isEmpty)
            } catch {
                XCTFail("Error inesperado: \(error)")
            }
        }
    }

    func testCrossOverCannotBeSelectedAfterPhysicalCutover() async throws {
        let inspector = StubProcessInspector(states: [
            RunningBackendState(),
            RunningBackendState(),
            RunningBackendState(regressionPIDs: [999]),
        ])
        let launcher = StubProcessLauncher()
        let coordinator = coordinator(
            inspector: inspector,
            launcher: launcher,
            custodyInterlock: StubCustodyInterlock(
                snapshot: PhysicalLibraryCustodyInterlockSnapshot(
                    status: .independent,
                    mutationPolicy: .unrestricted
                )
            )
        )

        do {
            _ = try await coordinator.launchSteam(
                backend: .crossOver,
                installations: installations()
            )
            XCTFail("CrossOver no debe seguir siendo seleccionable tras el cutover")
        } catch RegressionCoreError.unsafeLibraryState {
            let commands = await launcher.commands()
            XCTAssertTrue(commands.isEmpty)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testIndependentCustodyStillAllowsRegressionLaunch() async throws {
        let inspector = StubProcessInspector(states: [RunningBackendState()])
        let launcher = StubProcessLauncher()
        let coordinator = coordinator(
            inspector: inspector,
            launcher: launcher,
            custodyInterlock: StubCustodyInterlock(
                snapshot: PhysicalLibraryCustodyInterlockSnapshot(
                    status: .independent,
                    mutationPolicy: .unrestricted
                )
            )
        )

        _ = try await coordinator.launchSteam(
            backend: .regression,
            installations: installations()
        )

        let commands = await launcher.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.backend, .regression)
    }

    func testLaunchPermitIsHeldUntilDelayedBackendClassificationBecomesObservable() async throws {
        let tracker = PermitObservationTracker()
        let inspector = StubProcessInspector(states: [
            RunningBackendState(),
            RunningBackendState(),
            RunningBackendState(),
            RunningBackendState(regressionPIDs: [999]),
        ], onObservation: { tracker.observe() })
        let launcher = StubProcessLauncher()
        let interlock = TrackingCustodyInterlock(tracker: tracker)
        let coordinator = coordinator(
            inspector: inspector,
            launcher: launcher,
            custodyInterlock: interlock
        )

        _ = try await coordinator.launchSteam(
            backend: .regression,
            installations: installations()
        )

        XCTAssertTrue(tracker.observedWhilePermitHeld)
        XCTAssertTrue(tracker.wasReleased)
    }

    func testCrossOverIsRejectedOperationallyBeforeCutoverToo() async throws {
        let coordinator = coordinator(
            inspector: StubProcessInspector(states: [.init()]),
            launcher: StubProcessLauncher(),
            custodyInterlock: StubCustodyInterlock(
                snapshot: .init(status: .eligibleForTransfer, mutationPolicy: .unrestricted)
            )
        )
        do {
            _ = try await coordinator.launchSteam(
                backend: .crossOver,
                installations: self.installations()
            )
            XCTFail("CrossOver nunca debe ser seleccionable")
        } catch RegressionCoreError.unsafeLibraryState {
            // esperado
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testCustodyInterlockPreventsShutdownMutation() async throws {
        let runner = StubProcessRunner()
        let coordinator = BackendCoordinator(
            processRunner: runner,
            processLauncher: StubProcessLauncher(),
            inspector: StubProcessInspector(states: [
                RunningBackendState(regressionPIDs: [20]),
            ]),
            logDirectoryURL: FileManager.default.temporaryDirectory,
            custodyInterlock: StubCustodyInterlock(
                snapshot: PhysicalLibraryCustodyInterlockSnapshot(
                    status: .verifying,
                    mutationPolicy: .blocked
                )
            )
        )

        do {
            try await coordinator.requestShutdown(
                backend: .regression,
                installations: installations()
            )
            XCTFail("La custodia debía bloquear también el apagado mutante")
        } catch RegressionCoreError.unsafeLibraryState {
            let commands = await runner.commands()
            XCTAssertTrue(commands.isEmpty)
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testCLIBackendSelectionDefaultsToRegressionEvenWhenCrossOverIsRunning() throws {
        XCTAssertEqual(
            try BackendLaunchPolicy.cliSelection(
                requestedRawValue: nil,
                activeBackend: .crossOver
            ),
            .regression
        )
        XCTAssertThrowsError(
            try BackendLaunchPolicy.cliSelection(
                requestedRawValue: BackendKind.crossOver.rawValue,
                activeBackend: nil
            )
        )
    }

    func testCustodyMigrationRequiresBothDestructiveFactsToBeAcknowledged() throws {
        XCTAssertThrowsError(
            try PhysicalLibraryCustodyCommandPolicy.authorizeMigration(
                arguments: ["--confirm-single-library"]
            )
        )
        XCTAssertNoThrow(
            try PhysicalLibraryCustodyCommandPolicy.authorizeMigration(
                arguments: [
                    "--confirm-single-library",
                    "--confirm-crossover-games-removed",
                ]
            )
        )
    }

    func testCustodyFinalizationRequiresValidationAndNonEmptyEvidence() throws {
        XCTAssertThrowsError(
            try PhysicalLibraryCustodyCommandPolicy.authorizeFinalization(
                arguments: ["--validated"]
            )
        )
        XCTAssertThrowsError(
            try PhysicalLibraryCustodyCommandPolicy.authorizeFinalization(
                arguments: ["--validated", "--evidence", "  "]
            )
        )
        XCTAssertEqual(
            try PhysicalLibraryCustodyCommandPolicy.authorizeFinalization(
                arguments: ["--validated", "--evidence", "captura://steam-regression"]
            ),
            "captura://steam-regression"
        )
    }

    func testCustodyRollbackRequiresExplicitConfirmation() throws {
        XCTAssertThrowsError(
            try PhysicalLibraryCustodyCommandPolicy.authorizeRollback(arguments: [])
        )
        XCTAssertNoThrow(
            try PhysicalLibraryCustodyCommandPolicy.authorizeRollback(
                arguments: ["--confirm-rollback"]
            )
        )
    }

    func testValidateLibraryAcceptsOnlyAnOptionalNormalizedAppID() throws {
        XCTAssertNil(
            try PhysicalLibraryCustodyCommandPolicy.validationAppID(
                arguments: ["validate-library"]
            )
        )
        XCTAssertEqual(
            try PhysicalLibraryCustodyCommandPolicy.validationAppID(
                arguments: ["validate-library", "000219990"]
            ),
            "219990"
        )
        XCTAssertThrowsError(
            try PhysicalLibraryCustodyCommandPolicy.validationAppID(
                arguments: ["validate-library", "no-es-app-id"]
            )
        )
        XCTAssertThrowsError(
            try PhysicalLibraryCustodyCommandPolicy.validationAppID(
                arguments: ["validate-library", "219990", "otro"]
            )
        )
    }

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

    func testTitanQuest2StartsSteamBeforeItsUnifiedAppLaunchRoute() async throws {
        let inspector = StubProcessInspector(states: [
            RunningBackendState(),
            RunningBackendState(regressionPIDs: [20]),
        ])
        let launcher = StubProcessLauncher()
        let coordinator = coordinator(inspector: inspector, launcher: launcher)

        _ = try await coordinator.launchSteam(
            backend: .regression,
            installations: installations(),
            appID: "1154030"
        )

        let commands = await launcher.commands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments, [])
        XCTAssertEqual(commands[1].arguments, ["-applaunch", "1154030"])
    }

    func testTitanQuest2WaitsForSteamReadinessBeforeLaunchingGame() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-steam-readiness-\(UUID().uuidString)")
        let connectionLog = temporaryRoot
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/logs/connection_log.txt")
        try FileManager.default.createDirectory(
            at: connectionLog.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("previous session\n".utf8).write(to: connectionLog)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let inspector = StubProcessInspector(states: [
            RunningBackendState(),
            RunningBackendState(regressionPIDs: [20]),
        ])
        let launcher = StubProcessLauncher()
        let coordinator = coordinator(inspector: inspector, launcher: launcher)
        let snapshot = installations(regressionBottleURL: temporaryRoot)
        let launchTask = Task {
            try await coordinator.launchSteam(
                backend: .regression,
                installations: snapshot,
                appID: "1154030"
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        let commandsBeforeReadiness = await launcher.commands()
        XCTAssertEqual(commandsBeforeReadiness.count, 1)

        let handle = try FileHandle(forWritingTo: connectionLog)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            "[Logged On] RecvMsgClientLogOnResponse() : processing complete\n".utf8
        ))
        try handle.close()

        _ = try await launchTask.value
        let commands = await launcher.commands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[1].arguments, ["-applaunch", "1154030"])
    }

    func testUnrelatedGameDoesNotInheritTitanQuest2SteamPrelaunch() async throws {
        let inspector = StubProcessInspector(states: [RunningBackendState()])
        let launcher = StubProcessLauncher()
        let coordinator = coordinator(inspector: inspector, launcher: launcher)

        _ = try await coordinator.launchSteam(
            backend: .regression,
            installations: installations(),
            appID: "219990"
        )

        let commands = await launcher.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].arguments, ["-applaunch", "219990"])
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
        launcher: StubProcessLauncher,
        custodyInterlock: (any PhysicalLibraryCustodyInterlocking)? = nil
    ) -> BackendCoordinator {
        BackendCoordinator(
            processRunner: StubProcessRunner(),
            processLauncher: launcher,
            inspector: inspector,
            logDirectoryURL: FileManager.default.temporaryDirectory,
            custodyInterlock: custodyInterlock
        )
    }

    private func installations(
        crossOverHealth: InstallationHealth = .ready,
        regressionBottleURL: URL = URL(fileURLWithPath: "/tmp/RegressionBottle")
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
            bottleURL: regressionBottleURL,
            steamExecutableURL: regressionBottleURL.appendingPathComponent("Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/usr/bin/true"),
            health: .ready,
            healthDetail: "ok"
        )
        return InstallationSnapshot(crossOver: crossOver, regression: regression)
    }
}

private struct StubCustodyInterlock: PhysicalLibraryCustodyInterlocking {
    let snapshot: PhysicalLibraryCustodyInterlockSnapshot

    func currentPhysicalLibraryCustodyInterlock() async -> PhysicalLibraryCustodyInterlockSnapshot {
        snapshot
    }

    func authorizePhysicalLibraryCustodyMutation(
        backend: BackendKind,
        validationLease _: PhysicalLibraryCustodyValidationLease?
    ) async -> Bool {
        if backend == .crossOver, snapshot.crossOverUnavailable { return false }
        return snapshot.mutationPolicy == .unrestricted
    }

    func acquirePhysicalLibraryCustodyMutationPermit(
        backend: BackendKind,
        validationLease: PhysicalLibraryCustodyValidationLease?
    ) async throws -> PhysicalLibraryCustodyMutationPermit {
        guard await authorizePhysicalLibraryCustodyMutation(
            backend: backend,
            validationLease: validationLease
        ) else {
            throw RegressionCoreError.unsafeLibraryState(
                "La custodia física de prueba bloquea la mutación"
            )
        }
        return PhysicalLibraryCustodyMutationPermit(descriptor: -1)
    }

    func registerPhysicalLibraryLaunchIntent(backend _: BackendKind) async throws
        -> PhysicalLibraryCustodyLaunchIntent { .init() }
    func attachPhysicalLibraryLaunch(
        _: BackendLaunch,
        to _: PhysicalLibraryCustodyLaunchIntent
    ) async throws {}
    func resolvePhysicalLibraryLaunchIntent(
        _: PhysicalLibraryCustodyLaunchIntent
    ) async throws {}
}

private actor TrackingCustodyInterlock: PhysicalLibraryCustodyInterlocking {
    private let tracker: PermitObservationTracker

    init(tracker: PermitObservationTracker) { self.tracker = tracker }

    func currentPhysicalLibraryCustodyInterlock() -> PhysicalLibraryCustodyInterlockSnapshot {
        .init(status: .independent, mutationPolicy: .unrestricted)
    }

    func authorizePhysicalLibraryCustodyMutation(
        backend: BackendKind,
        validationLease _: PhysicalLibraryCustodyValidationLease?
    ) -> Bool { backend == .regression }

    func acquirePhysicalLibraryCustodyMutationPermit(
        backend: BackendKind,
        validationLease _: PhysicalLibraryCustodyValidationLease?
    ) throws -> PhysicalLibraryCustodyMutationPermit {
        guard backend == .regression else {
            throw RegressionCoreError.unsafeLibraryState("backend bloqueado")
        }
        return PhysicalLibraryCustodyMutationPermit(
            descriptor: -1,
            onRelease: { self.tracker.release() }
        )
    }

    func registerPhysicalLibraryLaunchIntent(backend _: BackendKind)
        -> PhysicalLibraryCustodyLaunchIntent { .init() }
    func attachPhysicalLibraryLaunch(
        _: BackendLaunch,
        to _: PhysicalLibraryCustodyLaunchIntent
    ) {}
    func resolvePhysicalLibraryLaunchIntent(_: PhysicalLibraryCustodyLaunchIntent) {}
}

private final class PermitObservationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var observedHeld = false

    func observe() {
        lock.lock()
        defer { lock.unlock() }
        if !released { observedHeld = true }
    }

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    var observedWhilePermitHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observedHeld
    }

    var wasReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
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
    private let onObservation: (@Sendable () -> Void)?

    init(
        states: [RunningBackendState],
        onObservation: (@Sendable () -> Void)? = nil
    ) {
        self.states = states
        self.onObservation = onObservation
    }

    func runningBackends() async -> RunningBackendState {
        onObservation?()
        guard states.count > 1 else { return states.first ?? RunningBackendState() }
        return states.removeFirst()
    }
}
