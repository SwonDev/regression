import Foundation
@testable import RegressionCore
import XCTest

final class TelemetryCoordinatorTests: XCTestCase {
    func testCancelledIntentBecomesFailedEvidenceInsteadOfStalePreparingRun() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let context = fixture.context()

        try await fixture.telemetry.registerLaunchIntent(
            context: context,
            bottleURL: fixture.bottleURL
        )
        try await fixture.telemetry.cancelLaunchIntent(
            context: context,
            reason: "El lanzador no pudo ejecutarse"
        )

        let runs = try await fixture.repository.recentRuns()
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.result, .failed)
        let profiles = try await fixture.repository.compatibilityProfiles()
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.failedRuns, 1)
        XCTAssertEqual(profile.unverifiedRuns, 0)
    }

    func testNewIntentClosesOlderPendingIntentForSameGame() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let first = fixture.context()
        let second = fixture.context()

        try await fixture.telemetry.registerLaunchIntent(context: first, bottleURL: fixture.bottleURL)
        try await fixture.telemetry.registerLaunchIntent(context: second, bottleURL: fixture.bottleURL)

        let runs = try await fixture.repository.recentRuns()
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs.first(where: { $0.id == first.id })?.result, .failed)
        XCTAssertEqual(runs.first(where: { $0.id == second.id })?.result, .preparing)
    }

    func testPrimaryProcessLifecycleFinishesAsUnverifiedInsteadOfInferringSuccess() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)

        let context = fixture.context()
        try await fixture.telemetry.registerLaunchIntent(
            context: context,
            bottleURL: fixture.bottleURL
        )
        let log = #"""
        [2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe"
        [2026-07-28 12:05:00] AppID 219990 no longer tracking PID 4242, exit code 0

        """#
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(log.utf8))
        try handle.close()

        let changed = await fixture.telemetry.poll(
            backend: .regression,
            logURL: logURL,
            games: [fixture.game],
            system: fixture.context().system,
            steamRootURL: fixture.root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: fixture.bottleURL,
            bottleName: "Steam",
            providerVersion: "1.5"
        )

        XCTAssertTrue(changed.changed)
        let runs = try await fixture.repository.recentRuns()
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.processID, 4242)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertEqual(run.result, .unknown)
        XCTAssertNil(run.verification)
        let profiles = try await fixture.repository.compatibilityProfiles()
        let profile = try XCTUnwrap(profiles.first)
        XCTAssertEqual(profile.unverifiedRuns, 1)
        XCTAssertEqual(profile.perfectRuns, 0)
    }

    func testCrashedRunLearnsOnlyTheCompiledRecipeFromItsRecentLog() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let processLogURL = fixture.root.appendingPathComponent("learned-gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: processLogURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: processLogURL)

        let crashDirectory = fixture.bottleURL.appendingPathComponent(
            "drive_c/users/test/AppData/Local/Future/Saved/Crashes/UECC-1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
        let crashURL = crashDirectory.appendingPathComponent("Future.log")
        try Data("""
        Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x1
        d3d11.dll
        gameoverlayrenderer64.dll
        EOSOVH-Win64-Shipping.dll
        EOSSDK-Win64-Shipping.dll
        Future-Win64-Shipping.exe
        """.utf8).write(to: crashURL)
        let timestamp = try XCTUnwrap(Self.steamLogDate("2026-07-28 12:00:02"))
        try FileManager.default.setAttributes(
            [.modificationDate: timestamp],
            ofItemAtPath: crashURL.path
        )

        try Data(#"""
        [2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Future\Future-Win64-Shipping.exe"
        [2026-07-28 12:00:02] AppID 219990 no longer tracking PID 4242, exit code 1

        """#.utf8).write(to: processLogURL)

        let outcome = await fixture.telemetry.poll(
            backend: .regression,
            logURL: processLogURL,
            games: [fixture.game],
            system: fixture.context().system,
            steamRootURL: fixture.root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: fixture.bottleURL,
            bottleName: "Steam",
            providerVersion: "1.9"
        )

        XCTAssertTrue(outcome.changed)
        XCTAssertTrue(outcome.issues.isEmpty)
        XCTAssertEqual(
            try CompiledRepairActivationStore.activations(in: fixture.bottleURL),
            [CompiledRepairActivation(
                executable: "future-win64-shipping.exe",
                recipe: .unrealD3D11DualOverlayIsolation
            )]
        )
        let receipts = try await fixture.repository.repairReceipts(appID: "219990")
        XCTAssertEqual(receipts.first?.recipeID, CompiledRepairRecipe.unrealD3D11DualOverlayIsolation.rawValue)
        XCTAssertEqual(receipts.first?.result, .succeeded)
    }

    func testLauncherAndShippingExecutableRemainOneLogicalRun() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("multiprocess-gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)

        let log = #"""
        [2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Launcher.exe"
        [2026-07-28 12:00:01] AppID 219990 adding PID 4343 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe"
        [2026-07-28 12:00:02] AppID 219990 no longer tracking PID 4242, exit code 0
        [2026-07-28 12:05:00] AppID 219990 no longer tracking PID 4343, exit code 0

        """#
        try Data(log.utf8).write(to: logURL)

        let outcome = await fixture.telemetry.poll(
            backend: .regression,
            logURL: logURL,
            games: [fixture.game],
            system: fixture.context().system,
            steamRootURL: fixture.root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: fixture.bottleURL,
            bottleName: "Steam",
            providerVersion: "1.6"
        )

        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.unpreparedRunStarts.count, 1)
        XCTAssertTrue(outcome.issues.isEmpty)
        let runs = try await fixture.repository.runDetails()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].processID, 4343)
        XCTAssertEqual(runs[0].executable, "C:\\Games\\Grim Dawn\\Grim Dawn.exe")
        XCTAssertEqual(runs[0].result, .unknown)

        let processes = try await fixture.repository.runProcesses()
        XCTAssertEqual(processes.count, 2)
        XCTAssertEqual(Set(processes.map(\.processID)), Set([4242, 4343]))
        XCTAssertEqual(processes.first { $0.isRepresentative }?.processID, 4343)
        XCTAssertTrue(processes.allSatisfy { $0.endedAt != nil && $0.exitCode == 0 })
        let cleanups = await fixture.artifactCleaner.recordedCleanups()
        XCTAssertEqual(
            cleanups,
            [
                RecordedArtifactCleanup(
                    appID: "219990",
                    backend: .regression,
                    endedWindowsProcessIDs: [4242, 4343]
                )
            ]
        )
    }

    private static func steamLogDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    func testRegisteredLaunchIntentDoesNotRequestPassivePreflight() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("intent-gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)
        let context = fixture.context()
        try await fixture.telemetry.registerLaunchIntent(
            context: context,
            bottleURL: fixture.bottleURL
        )
        let log = #"""
        [2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe"

        """#
        try Data(log.utf8).write(to: logURL)

        let outcome = await fixture.telemetry.poll(
            backend: .regression,
            logURL: logURL,
            games: [fixture.game],
            system: context.system,
            steamRootURL: fixture.root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: fixture.bottleURL,
            bottleName: "Steam",
            providerVersion: "1.6"
        )

        XCTAssertTrue(outcome.changed)
        XCTAssertTrue(outcome.unpreparedRunStarts.isEmpty)
        XCTAssertTrue(outcome.issues.isEmpty)
    }

    func testChildProcessCanJoinAfterLauncherEndsWithoutCreatingAnotherRun() async throws {
        let fixture = try TelemetryFixture(sessionJoinGrace: 60)
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("delayed-child-gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)
        let firstBatch = #"""
        [2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Launcher.exe"
        [2026-07-28 12:00:01] AppID 219990 no longer tracking PID 4242, exit code 0

        """#
        try Data(firstBatch.utf8).write(to: logURL)

        _ = await fixture.telemetry.poll(
            backend: .regression,
            logURL: logURL,
            games: [fixture.game],
            system: fixture.context().system,
            steamRootURL: fixture.root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: fixture.bottleURL,
            bottleName: "Steam",
            providerVersion: "1.6"
        )
        let runsAfterLauncher = try await fixture.repository.recentRuns()
        XCTAssertEqual(runsAfterLauncher.first?.result, .launched)

        let secondBatch = #"""
        [2026-07-28 12:00:02] AppID 219990 adding PID 4343 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe"

        """#
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secondBatch.utf8))
        try handle.close()

        _ = await fixture.telemetry.poll(
            backend: .regression,
            logURL: logURL,
            games: [fixture.game],
            system: fixture.context().system,
            steamRootURL: fixture.root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: fixture.bottleURL,
            bottleName: "Steam",
            providerVersion: "1.6"
        )

        let runs = try await fixture.repository.runDetails()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].processID, 4343)
        let processes = try await fixture.repository.runProcesses()
        XCTAssertEqual(processes.count, 2)
    }

    func testEarlyTelemetryWithoutManifestCannotReplacePreviouslyDiscoveredGameName() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        try await fixture.repository.reconcileDiscoveredGames([fixture.game])

        let logURL = fixture.root.appendingPathComponent("early-gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)
        let log = #"""
        [2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe"

        """#
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.write(contentsOf: Data(log.utf8))
        try handle.close()

        _ = await fixture.telemetry.poll(
            backend: .regression,
            logURL: logURL,
            games: [],
            system: fixture.context().system,
            steamRootURL: fixture.root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: fixture.bottleURL,
            bottleName: "Steam",
            providerVersion: "1.5"
        )

        let runs = try await fixture.repository.recentRuns()
        XCTAssertEqual(runs.first?.gameName, "Grim Dawn")
    }
}

private final class TelemetryFixture {
    let root: URL
    let bottleURL: URL
    let repository: CompatibilityRepository
    let telemetry: TelemetryCoordinator
    let artifactCleaner: RecordingArtifactCleaner

    var game: SteamGame {
        SteamGame(
            appID: "219990",
            name: "Grim Dawn",
            installDirectory: "Grim Dawn",
            manifestURL: root.appendingPathComponent("Steam/steamapps/appmanifest_219990.acf"),
            sourceBackend: .regression
        )
    }

    init(sessionJoinGrace: TimeInterval = 0) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-telemetry-\(UUID().uuidString)", isDirectory: true)
        bottleURL = root.appendingPathComponent("Bottle", isDirectory: true)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        artifactCleaner = RecordingArtifactCleaner()
        telemetry = TelemetryCoordinator(
            repository: repository,
            monitor: SteamLogMonitor(),
            sessionJoinGrace: sessionJoinGrace,
            artifactCleaner: artifactCleaner
        )
    }

    func context() -> RunContext {
        let configuration = ["backend": "regression"]
        return RunContext(
            appID: "219990",
            gameName: "Grim Dawn",
            backend: .regression,
            bottleName: "Steam",
            providerVersion: "1.2",
            command: "$HOME/Regression/regression-engine",
            arguments: ["-applaunch", "219990"],
            system: SystemSnapshot(
                macOSVersion: "26.0",
                architecture: "arm64",
                deviceModel: "MacTest",
                displayWidth: 3024,
                displayHeight: 1964,
                displayScale: 2
            ),
            configuration: configuration,
            configurationFingerprint: ConfigurationCollector.fingerprint(configuration)
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct RecordedArtifactCleanup: Equatable, Sendable {
    let appID: String
    let backend: BackendKind
    let endedWindowsProcessIDs: Set<Int32>
}

private actor RecordingArtifactCleaner: GameSessionArtifactCleaning {
    private var cleanups: [RecordedArtifactCleanup] = []

    func clean(
        appID: String,
        backend: BackendKind,
        endedWindowsProcessIDs: Set<Int32>
    ) async -> [String] {
        cleanups.append(RecordedArtifactCleanup(
            appID: appID,
            backend: backend,
            endedWindowsProcessIDs: endedWindowsProcessIDs
        ))
        return []
    }

    func recordedCleanups() -> [RecordedArtifactCleanup] {
        cleanups
    }
}
