import Foundation
@testable import RegressionCore
import XCTest

final class GameTestPreflightTests: XCTestCase {
    func testCrossOverPreflightFailsClosedEvenWhenItsInstallationLooksReady() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.cleanup() }
        let crossOverRoot = fixture.root.appendingPathComponent("CrossOver", isDirectory: true)
        let crossOver = CrossOverInstallation(
            applicationURL: fixture.root.appendingPathComponent("CrossOver.app", isDirectory: true),
            version: "26.3",
            build: "39832",
            bottleName: "Steam",
            bottleURL: crossOverRoot,
            steamExecutableURL: crossOverRoot.appendingPathComponent("Steam.exe"),
            wineCLIURL: crossOverRoot.appendingPathComponent("wine"),
            bottleCLIURL: crossOverRoot.appendingPathComponent("cxbottle"),
            feedURL: nil,
            health: .ready,
            healthDetail: "La instalación externa parece lista"
        )
        let installations = InstallationSnapshot(
            crossOver: crossOver,
            regression: fixture.installations.regression
        )

        let report = await GameTestPreflight(
            runner: PreflightProcessRunner(output: ""),
            applicationSupportURL: fixture.applicationSupportURL
        ).evaluate(
            backend: .crossOver,
            installations: installations,
            runningState: RunningBackendState(),
            databaseHealth: healthyDatabase(),
            sharedLibraryAssessment: nil
        )

        let availability = try XCTUnwrap(
            report.checks.first { $0.checkID == .backendAvailability }
        )
        XCTAssertEqual(availability.status, .blocked)
        XCTAssertEqual(availability.title, "Backend no operativo")
        XCTAssertFalse(availability.detail.contains(crossOver.bottleName))
        XCTAssertTrue(availability.recoveryAction?.contains("Regression") == true)
        XCTAssertEqual(report.status, .blocked)
    }

    func testIndependentCustodyIsReadyWithoutCrossOver() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.cleanup() }
        let destination = fixture.installations.regression.steamRootURL
            .appendingPathComponent("steamapps", isDirectory: true)

        let report = await GameTestPreflight(
            runner: PreflightProcessRunner(output: ""),
            applicationSupportURL: fixture.applicationSupportURL
        ).evaluate(
            backend: .regression,
            installations: fixture.installations,
            runningState: RunningBackendState(),
            databaseHealth: healthyDatabase(),
            sharedLibraryAssessment: nil,
            physicalCustodyAssessment: PhysicalLibraryCustodyAssessment(
                status: .independent,
                sourceSteamAppsURL: fixture.root.appendingPathComponent("Legacy/steamapps"),
                destinationSteamAppsURL: destination,
                inventory: emptyPhysicalLibraryInventory()
            ),
            game: fixture.game
        )

        let custody = try XCTUnwrap(report.checks.first { $0.checkID == .sharedLibrary })
        XCTAssertEqual(custody.status, .ready)
        XCTAssertEqual(custody.title, "Biblioteca propia")
        XCTAssertFalse(custody.detail.contains("CrossOver"))
    }

    func testPendingCustodyAllowsRegressionValidationWithExplicitWarning() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.cleanup() }

        let report = await GameTestPreflight(
            runner: PreflightProcessRunner(output: ""),
            applicationSupportURL: fixture.applicationSupportURL
        ).evaluate(
            backend: .regression,
            installations: fixture.installations,
            runningState: RunningBackendState(),
            databaseHealth: healthyDatabase(),
            sharedLibraryAssessment: nil,
            physicalCustodyAssessment: PhysicalLibraryCustodyAssessment(
                status: .pendingValidation,
                sourceSteamAppsURL: fixture.root.appendingPathComponent("Legacy/steamapps"),
                destinationSteamAppsURL: fixture.installations.regression.steamRootURL
                    .appendingPathComponent("steamapps", isDirectory: true),
                inventory: emptyPhysicalLibraryInventory()
            ),
            game: fixture.game
        )

        let custody = try XCTUnwrap(report.checks.first { $0.checkID == .sharedLibrary })
        XCTAssertEqual(custody.status, .warning)
        XCTAssertEqual(custody.title, "Biblioteca propia")
        XCTAssertNotEqual(report.status, .blocked)
    }

    func testProcessParserUsesCommAndPreservesExecutablePathsWithSpaces() {
        let output = #"""
          10     1 /tmp/Regression.app/Contents/SharedSupport/wine-root/bin/wineserver
          11     1 C:\windows\system32\services.exe
          12    99 /bin/zsh
          13    99 /Applications/Other Wine/bin/wineserver
        """#

        let records = GameTestPreflight.parseProcessList(output)

        XCTAssertEqual(records.count, 4)
        XCTAssertTrue(records[0].isKnownRegressionWineServer)
        XCTAssertTrue(records[1].isWineServicesProcess)
        XCTAssertFalse(records[2].isWineServer)
        XCTAssertTrue(records[3].isWineServer)
        XCTAssertEqual(records[3].executable, "/Applications/Other Wine/bin/wineserver")
    }

    func testKnownWineSessionAndInstalledGamePassWithoutFalseOrphan() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.cleanup() }
        let applicationPath = fixture.installations.regression.applicationURL.path
        let runner = PreflightProcessRunner(output: """
          10     1 \(applicationPath)/Contents/SharedSupport/wine-root/bin/wineserver
          11     1 C:\\windows\\system32\\services.exe
        """)

        let report = await GameTestPreflight(
            runner: runner,
            applicationSupportURL: fixture.applicationSupportURL
        ).evaluate(
            backend: .regression,
            installations: fixture.installations,
            runningState: RunningBackendState(regressionPIDs: [20]),
            databaseHealth: healthyDatabase(),
            sharedLibraryAssessment: nil,
            game: fixture.game
        )

        XCTAssertEqual(
            report.checks.first { $0.checkID == .wineRuntimeIsolation }?.status,
            .ready
        )
        XCTAssertEqual(
            report.checks.first { $0.checkID == .wineServiceLifecycle }?.status,
            .ready
        )
        XCTAssertFalse(report.checks.contains { $0.status == .blocked })
        XCTAssertFalse(
            String(describing: report).contains(FileManager.default.homeDirectoryForCurrentUser.path)
        )
    }

    func testForeignWineServerBlocksTestWithoutTerminatingIt() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.cleanup() }
        let runner = PreflightProcessRunner(
            output: "99 1 /Applications/OtroRuntime.app/Contents/bin/wineserver\n"
        )

        let report = await GameTestPreflight(
            runner: runner,
            applicationSupportURL: fixture.applicationSupportURL
        ).evaluate(
            backend: .regression,
            installations: fixture.installations,
            runningState: RunningBackendState(),
            databaseHealth: healthyDatabase(),
            sharedLibraryAssessment: nil,
            game: fixture.game
        )

        XCTAssertEqual(report.status, .blocked)
        XCTAssertEqual(
            report.checks.first { $0.checkID == .wineRuntimeIsolation }?.status,
            .blocked
        )
        XCTAssertTrue(
            report.checks.first { $0.checkID == .wineRuntimeIsolation }?.detail
                .contains("OtroRuntime") == true
        )
        XCTAssertFalse(
            report.checks.first { $0.checkID == .wineRuntimeIsolation }?.detail
                .contains("/Applications") == true
        )
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testWineServerUsesExactDiscoveredRegressionApplicationInsteadOfBundleSubstring() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.cleanup() }
        let exactApplication = fixture.root.appendingPathComponent(
            "Regression Candidate.app",
            isDirectory: true
        )
        let regression = RegressionInstallation(
            applicationURL: exactApplication,
            bottleURL: fixture.installations.regression.bottleURL,
            steamExecutableURL: fixture.installations.regression.steamExecutableURL,
            engineLauncherURL: fixture.installations.regression.engineLauncherURL,
            health: .ready,
            healthDetail: "fixture"
        )
        let installations = InstallationSnapshot(crossOver: nil, regression: regression)
        let runner = PreflightProcessRunner(
            output: "99 1 \(exactApplication.path)/Contents/SharedSupport/wine-root/bin/wineserver\n"
        )

        let report = await GameTestPreflight(
            runner: runner,
            applicationSupportURL: fixture.applicationSupportURL
        ).evaluate(
            backend: .regression,
            installations: installations,
            runningState: RunningBackendState(regressionPIDs: [20]),
            databaseHealth: healthyDatabase(),
            sharedLibraryAssessment: nil,
            game: fixture.game
        )

        XCTAssertEqual(
            report.checks.first { $0.checkID == .wineRuntimeIsolation }?.status,
            .ready
        )
    }

    func testDeceptiveRegressionSubstringDoesNotBypassExactApplicationAttribution() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.cleanup() }
        let runner = PreflightProcessRunner(
            output: "99 1 /Applications/FakeRegression.app/Contents/Regression.app/Contents/bin/wineserver\n"
        )

        let report = await GameTestPreflight(
            runner: runner,
            applicationSupportURL: fixture.applicationSupportURL
        ).evaluate(
            backend: .regression,
            installations: fixture.installations,
            runningState: RunningBackendState(),
            databaseHealth: healthyDatabase(),
            sharedLibraryAssessment: nil,
            game: fixture.game
        )

        XCTAssertEqual(
            report.checks.first { $0.checkID == .wineRuntimeIsolation }?.status,
            .blocked
        )
    }

    func testDownloadInProgressBlocksTheGameBeforeLaunch() async throws {
        let fixture = try PreflightFixture()
        defer { fixture.cleanup() }
        try Data(#"""
        "AppState"
        {
            "appid" "42"
            "name" "Test Game"
            "installdir" "Test Game"
            "StateFlags" "1026"
            "SizeOnDisk" "0"
            "BytesToDownload" "4096"
            "BytesDownloaded" "0"
        }
        """#.utf8).write(to: fixture.game.manifestURL, options: .atomic)

        let report = await GameTestPreflight(
            runner: PreflightProcessRunner(output: ""),
            applicationSupportURL: fixture.applicationSupportURL
        ).evaluate(
            backend: .regression,
            installations: fixture.installations,
            runningState: RunningBackendState(),
            databaseHealth: healthyDatabase(),
            sharedLibraryAssessment: nil,
            game: fixture.game
        )

        let installation = try XCTUnwrap(
            report.checks.first { $0.checkID == .gameInstallation }
        )
        XCTAssertEqual(installation.status, .blocked)
        XCTAssertTrue(installation.detail.contains("descargando"))
    }

    func testPreflightSnapshotIsHashedLinkedAndExported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "regression-preflight-db-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()

        let context = RunContext(
            appID: "219990",
            gameName: "Grim Dawn",
            backend: .regression,
            bottleName: "Steam",
            providerVersion: "1.6",
            command: "$APP/regression-engine",
            arguments: ["-applaunch", "219990"],
            system: SystemSnapshot(
                macOSVersion: "26.5",
                architecture: "arm64",
                deviceModel: "Mac",
                displayWidth: 3024,
                displayHeight: 1964,
                displayScale: 2
            ),
            configuration: ["backend": "regression"],
            configurationFingerprint: ConfigurationCollector.fingerprint([
                "backend": "regression",
            ])
        )
        try await repository.beginRun(context)
        let report = GameTestPreflightReport(
            appID: context.appID,
            gameName: context.gameName,
            backend: context.backend,
            checks: GameTestPreflightCheckID.allCases.map {
                GameTestPreflightCheck(
                    checkID: $0,
                    status: .ready,
                    title: $0.rawValue,
                    detail: "Comprobación superada"
                )
            }
        )

        try await repository.recordPreflight(report, forRunID: context.id)
        let stored = try await repository.preflightSnapshots()

        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].runID, context.id)
        XCTAssertEqual(stored[0].report, report)
        XCTAssertEqual(stored[0].reportFingerprint.count, 64)
        let health = try await repository.databaseHealth()
        XCTAssertEqual(health.preflightReportCount, 1)

        let exportURL = root.appendingPathComponent("export.json")
        try await repository.exportJSON(to: exportURL)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: exportURL)) as? [String: Any]
        )
        XCTAssertEqual((payload["preflightSnapshots"] as? [[String: Any]])?.count, 1)
    }

    func testPreflightCannotBeAttachedToAnotherGameOrBackend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "regression-preflight-link-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        let context = RunContext(
            appID: "219990",
            gameName: "Grim Dawn",
            backend: .regression,
            bottleName: "Steam",
            providerVersion: "1.6",
            command: "$APP/regression-engine",
            arguments: ["-applaunch", "219990"],
            system: SystemSnapshot(
                macOSVersion: "26.5",
                architecture: "arm64",
                deviceModel: "Mac",
                displayWidth: 3024,
                displayHeight: 1964,
                displayScale: 2
            ),
            configuration: [:],
            configurationFingerprint: ConfigurationCollector.fingerprint([:])
        )
        try await repository.beginRun(context)
        let mismatchedReport = GameTestPreflightReport(
            appID: "1128000",
            gameName: "Cube World",
            backend: .crossOver,
            checks: GameTestPreflightCheckID.allCases.map {
                GameTestPreflightCheck(
                    checkID: $0,
                    status: .ready,
                    title: $0.rawValue,
                    detail: "Comprobación superada"
                )
            }
        )

        do {
            try await repository.recordPreflight(mismatchedReport, forRunID: context.id)
            XCTFail("Una preparación ajena no debe vincularse a la ejecución")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }

        let incompleteReport = GameTestPreflightReport(
            appID: context.appID,
            gameName: context.gameName,
            backend: context.backend,
            checks: []
        )
        do {
            try await repository.recordPreflight(incompleteReport, forRunID: context.id)
            XCTFail("Una preparación incompleta no debe persistirse")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }

        let snapshots = try await repository.preflightSnapshots()
        let health = try await repository.databaseHealth()
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertEqual(health.preflightReportCount, 0)
    }

    func testCapturePhaseMustMatchTheExactRunLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "regression-preflight-phase-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = RunContext(
            appID: "219990",
            gameName: "Grim Dawn",
            backend: .regression,
            bottleName: "Steam",
            providerVersion: "1.6",
            command: "$APP/regression-engine",
            arguments: ["-applaunch", "219990"],
            system: SystemSnapshot(
                macOSVersion: "26.5",
                architecture: "arm64",
                deviceModel: "Mac",
                displayWidth: 3024,
                displayHeight: 1964,
                displayScale: 2
            ),
            configuration: [:],
            configurationFingerprint: ConfigurationCollector.fingerprint([:])
        )
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 990,
            executable: "C:\\Games\\Grim Dawn\\Grim Dawn.exe",
            launchMilliseconds: 500
        )
        let checks = GameTestPreflightCheckID.allCases.map {
            GameTestPreflightCheck(
                checkID: $0,
                status: .ready,
                title: $0.rawValue,
                detail: "Comprobación superada"
            )
        }
        let tooLatePreLaunch = GameTestPreflightReport(
            appID: context.appID,
            gameName: context.gameName,
            backend: context.backend,
            checks: checks
        )
        do {
            try await repository.recordPreflight(tooLatePreLaunch, forRunID: context.id)
            XCTFail("No debe fingirse una captura previa después de iniciar el proceso")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }

        let observedAtStart = GameTestPreflightReport(
            appID: context.appID,
            gameName: context.gameName,
            backend: context.backend,
            capturePhase: .processStartBoundary,
            captureDelayMilliseconds: 750,
            checks: checks
        )
        try await repository.recordPreflight(observedAtStart, forRunID: context.id)

        let stored = try await repository.preflightSnapshots()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].report.capturePhase, .processStartBoundary)
        XCTAssertEqual(stored[0].report.captureDelayMilliseconds, 750)
    }

    func testVersionOneReportDecodesAsAnExactPreLaunchCapture() throws {
        let report = GameTestPreflightReport(
            appID: "219990",
            gameName: "Grim Dawn",
            backend: .regression,
            checks: GameTestPreflightCheckID.allCases.map {
                GameTestPreflightCheck(
                    checkID: $0,
                    status: .ready,
                    title: $0.rawValue,
                    detail: "Comprobación superada"
                )
            }
        )
        let encoded = try JSONEncoder().encode(report)
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacy["protocolVersion"] = 1
        legacy.removeValue(forKey: "capturePhase")
        legacy.removeValue(forKey: "captureDelayMilliseconds")

        let decoded = try JSONDecoder().decode(
            GameTestPreflightReport.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(decoded.protocolVersion, 1)
        XCTAssertEqual(decoded.capturePhase, .preLaunch)
        XCTAssertNil(decoded.captureDelayMilliseconds)
    }

    private func healthyDatabase() -> CompatibilityDatabaseHealth {
        CompatibilityDatabaseHealth(
            schemaVersion: CompatibilityRepository.currentSchemaVersion,
            integrity: "ok",
            foreignKeyViolations: 0,
            gameCount: 0,
            runCount: 0,
            processCount: 0,
            verifiedRunCount: 0,
            observationCount: 0,
            certificationCount: 0,
            externalRecordCount: 0,
            engineSnapshotCount: 0,
            runtimeTechnologyCount: 0,
            runtimeCandidateCount: 0,
            optimizationAssessmentCount: 0,
            runtimeRequirementCount: 0,
            repairReceiptCount: 0,
            researchCaseCount: 0,
            researchHypothesisCount: 0,
            researchExperimentCount: 0,
            researchGateCount: 0,
            researchArtifactCount: 0,
            preflightReportCount: 0
        )
    }
}

private func emptyPhysicalLibraryInventory() -> PhysicalLibraryInventory {
    PhysicalLibraryInventory(
        manifestAppIDs: [],
        manifestSHA256ByAppID: [:],
        regularFileCount: 0,
        directoryCount: 0,
        totalRegularFileBytes: 0,
        structuralFingerprint: "fixture"
    )
}

private final class PreflightFixture: @unchecked Sendable {
    let root: URL
    let applicationSupportURL: URL
    let installations: InstallationSnapshot
    let game: SteamGame

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "regression-preflight-\(UUID().uuidString)",
            isDirectory: true
        )
        applicationSupportURL = root.appendingPathComponent("Support", isDirectory: true)
        let bottle = applicationSupportURL.appendingPathComponent(
            "Bottles/Steam",
            isDirectory: true
        )
        let steamRoot = bottle.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam",
            isDirectory: true
        )
        let steamApps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        let common = steamApps.appendingPathComponent("common/Test Game", isDirectory: true)
        let logs = steamRoot.appendingPathComponent("logs", isDirectory: true)
        let launcher = root.appendingPathComponent("Regression.app/Contents/MacOS/regression-engine")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: launcher.path, contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: launcher.path
        )
        let steamExecutable = steamRoot.appendingPathComponent("Steam.exe")
        FileManager.default.createFile(atPath: steamExecutable.path, contents: Data())
        let manifest = steamApps.appendingPathComponent("appmanifest_42.acf")
        try Data(#"""
        "AppState"
        {
            "appid" "42"
            "name" "Test Game"
            "installdir" "Test Game"
        }
        """#.utf8).write(to: manifest)
        game = SteamGame(
            appID: "42",
            name: "Test Game",
            installDirectory: "Test Game",
            manifestURL: manifest,
            sourceBackend: .regression
        )
        let regression = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app", isDirectory: true),
            bottleURL: bottle,
            steamExecutableURL: steamExecutable,
            engineLauncherURL: launcher,
            health: .ready,
            healthDetail: "Motor propio disponible"
        )
        installations = InstallationSnapshot(
            crossOver: nil,
            crossOverIssue: InstallationIssue(
                code: .crossOverNotInstalled,
                message: "CrossOver no está instalado",
                recoveryAction: "Instalar CrossOver"
            ),
            regression: regression
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor PreflightProcessRunner: ProcessRunning {
    private let output: String
    private var calls = 0

    init(output: String) {
        self.output = output
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> ProcessResult {
        calls += 1
        return ProcessResult(exitCode: 0, standardOutput: output, standardError: "")
    }

    func callCount() -> Int {
        calls
    }
}
