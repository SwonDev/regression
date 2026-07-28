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

        XCTAssertTrue(changed)
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

    var game: SteamGame {
        SteamGame(
            appID: "219990",
            name: "Grim Dawn",
            installDirectory: "Grim Dawn",
            manifestURL: root.appendingPathComponent("Steam/steamapps/appmanifest_219990.acf"),
            sourceBackend: .regression
        )
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-telemetry-\(UUID().uuidString)", isDirectory: true)
        bottleURL = root.appendingPathComponent("Bottle", isDirectory: true)
        try FileManager.default.createDirectory(at: bottleURL, withIntermediateDirectories: true)
        repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        telemetry = TelemetryCoordinator(repository: repository, monitor: SteamLogMonitor())
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
