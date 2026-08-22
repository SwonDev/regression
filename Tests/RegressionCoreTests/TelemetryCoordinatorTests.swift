import Foundation
@testable import RegressionCore
import XCTest

final class TelemetryCoordinatorTests: XCTestCase {
    func testMissingSteamProcessLogIsReturnedAsTelemetryIssue() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let missingLogURL = fixture.root.appendingPathComponent("missing-gameprocess_log.txt")

        let outcome = await fixture.telemetry.poll(
            backend: .regression,
            logURL: missingLogURL,
            games: [fixture.game],
            system: fixture.context().system,
            steamRootURL: fixture.root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: fixture.bottleURL,
            bottleName: "Steam",
            providerVersion: "1.12"
        )

        XCTAssertFalse(outcome.changed)
        XCTAssertEqual(outcome.issues.count, 1)
        XCTAssertEqual(outcome.issues[0].code, .steamLog(.logUnavailable))
        XCTAssertTrue(outcome.issues[0].message.contains("no está disponible"))
        XCTAssertTrue(outcome.issues[0].isNew)
    }

    func testPersistentLogFailureRemainsVisibleButIsDeduplicated() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let missingLogURL = fixture.root.appendingPathComponent("persistent-missing.txt")

        _ = await fixture.poll(logURL: missingLogURL)
        let repeated = await fixture.poll(logURL: missingLogURL)

        XCTAssertEqual(repeated.issues.map(\.code), [.steamLog(.logUnavailable)])
        XCTAssertFalse(try XCTUnwrap(repeated.issues.first).isNew)
    }

    func testDiscontinuousBatchDoesNotConsumePendingLaunchIntent() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("discontinuous-pending.txt")
        try Data(repeating: 0x61, count: 256).write(to: logURL)
        await fixture.telemetry.beginMonitoring(logURL: logURL)
        let intentDate = try XCTUnwrap(Self.steamLogDate("2026-07-28 12:00:00"))
        let context = fixture.context(startedAt: intentDate)
        try await fixture.telemetry.registerLaunchIntent(context: context, bottleURL: fixture.bottleURL)
        let event = #"[2026-07-28 12:00:01] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe""# + "\n"
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((event + String(repeating: "rewrite-padding\n", count: 40_000)).utf8))
        try handle.close()

        let discontinuous = await fixture.poll(logURL: logURL)
        let historicalRemainder = await fixture.poll(logURL: logURL)
        let runsAfterDiscontinuity = try await fixture.repository.recentRuns()
        let preparingRun = try XCTUnwrap(runsAfterDiscontinuity.first)
        XCTAssertEqual(discontinuous.issues.first?.code, .steamLog(.logTruncated))
        XCTAssertFalse(historicalRemainder.changed)
        XCTAssertEqual(preparingRun.result, .preparing)

        let appendHandle = try FileHandle(forWritingTo: logURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data(event.utf8))
        try appendHandle.close()
        _ = await fixture.poll(logURL: logURL)

        let runsAfterValidEvent = try await fixture.repository.recentRuns()
        XCTAssertEqual(runsAfterValidEvent.first?.result, .launched)
    }

    func testDiscontinuousEndEventDoesNotCloseActiveRun() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("discontinuous-active.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)
        let started = #"[2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe""# + "\n"
        try Data(started.utf8).write(to: logURL)
        _ = await fixture.poll(logURL: logURL)
        let ended = "[2026-07-28 12:00:02] AppID 219990 no longer tracking PID 4242, exit code 0\n"
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((ended + String(repeating: "rewrite-padding\n", count: 24)).utf8))
        try handle.close()

        _ = await fixture.poll(logURL: logURL)
        let runsAfterDiscontinuity = try await fixture.repository.recentRuns()
        XCTAssertEqual(runsAfterDiscontinuity.first?.result, .launched)

        let appendHandle = try FileHandle(forWritingTo: logURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data(ended.utf8))
        try appendHandle.close()
        _ = await fixture.poll(logURL: logURL)
        let runsAfterValidEnd = try await fixture.repository.recentRuns()
        XCTAssertEqual(runsAfterValidEnd.first?.result, .unknown)
    }

    func testReplacementPartialEndCannotCloseActiveRunOnFollowingPoll() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("partial-discontinuous-active.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)
        let started = #"[2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe""# + "\n"
        try Data(started.utf8).write(to: logURL)
        _ = await fixture.poll(logURL: logURL)

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("[2026-07-28 12:00:02] AppID 219990 no longer tracking PID".utf8))
        try handle.close()
        _ = await fixture.poll(logURL: logURL)
        let continuation = try FileHandle(forWritingTo: logURL)
        try continuation.seekToEnd()
        try continuation.write(contentsOf: Data(" 4242, exit code 0\n".utf8))
        try continuation.close()
        _ = await fixture.poll(logURL: logURL)

        let runsAfterContinuation = try await fixture.repository.recentRuns()
        XCTAssertEqual(runsAfterContinuation.first?.result, .launched)

        let validEnd = "[2026-07-28 12:00:03] AppID 219990 no longer tracking PID 4242, exit code 0\n"
        let appendHandle = try FileHandle(forWritingTo: logURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data(validEnd.utf8))
        try appendHandle.close()
        _ = await fixture.poll(logURL: logURL)

        let finalRuns = try await fixture.repository.recentRuns()
        XCTAssertEqual(finalRuns.first?.result, .unknown)
    }

    func testProcessStartOlderThanIntentIsIgnored() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("stale-start.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)
        let context = fixture.context(startedAt: try XCTUnwrap(Self.steamLogDate("2026-07-28 12:00:02")))
        try await fixture.telemetry.registerLaunchIntent(context: context, bottleURL: fixture.bottleURL)
        let stale = #"[2026-07-28 12:00:01] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe""# + "\n"
        try Data(stale.utf8).write(to: logURL)

        let outcome = await fixture.poll(logURL: logURL)

        XCTAssertEqual(outcome.issues.map(\.code), [.staleProcessEvent])
        let runs = try await fixture.repository.recentRuns()
        XCTAssertEqual(runs.first?.result, .preparing)
    }

    func testGraceFinalizationStillRunsWhileLogIsUnavailable() async throws {
        let fixture = try TelemetryFixture(sessionJoinGrace: 0.01)
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("grace-missing.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: logURL)
        let batch = #"""
        [2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe"
        [2026-07-28 12:00:01] AppID 219990 no longer tracking PID 4242, exit code 0

        """#
        try Data(batch.utf8).write(to: logURL)
        _ = await fixture.poll(logURL: logURL)
        try FileManager.default.removeItem(at: logURL)
        try await Task.sleep(for: .milliseconds(20))

        let outcome = await fixture.poll(logURL: logURL)

        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.issues.first?.code, .steamLog(.logUnavailable))
        let runs = try await fixture.repository.recentRuns()
        XCTAssertEqual(runs.first?.result, .unknown)
    }

    func testBacklogDefersGraceFinalizationUntilChildProcessChunkArrives() async throws {
        let started = #"[2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Launcher.exe""# + "\n"
        let ended = "[2026-07-28 12:00:01] AppID 219990 no longer tracking PID 4242, exit code 0\n"
        let firstChunk = started + ended
        let fixture = try TelemetryFixture(
            sessionJoinGrace: 0,
            maximumReadBytes: Data(firstChunk.utf8).count
        )
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("backlog-child.txt")
        let childStarted = #"[2026-07-28 12:00:02] AppID 219990 adding PID 4343 as a tracked process "C:\Games\Grim Dawn\Grim Dawn.exe""# + "\n"
        try Data((firstChunk + childStarted).utf8).write(to: logURL)

        let firstPoll = await fixture.poll(logURL: logURL)
        let afterFirstPoll = try await fixture.repository.recentRuns()
        XCTAssertTrue(firstPoll.issues.contains { $0.code == .steamLog(.readLimitReached) })
        XCTAssertEqual(afterFirstPoll.count, 1)
        XCTAssertEqual(afterFirstPoll.first?.result, .launched)

        _ = await fixture.poll(logURL: logURL)
        let afterChild = try await fixture.repository.runDetails()
        let processes = try await fixture.repository.runProcesses()

        XCTAssertEqual(afterChild.count, 1)
        XCTAssertEqual(afterChild.first?.processID, 4343)
        XCTAssertEqual(afterChild.first?.result, .launched)
        XCTAssertEqual(Set(processes.map(\.processID)), Set([4242, 4343]))
    }

    func testPartialChildLineDefersGraceAndJoinsContinuationIntoOneRun() async throws {
        let fixture = try TelemetryFixture(sessionJoinGrace: 0)
        defer { fixture.remove() }
        let logURL = fixture.root.appendingPathComponent("partial-child.txt")
        let start = #"[2026-07-28 12:00:00] AppID 219990 adding PID 4242 as a tracked process "C:\Games\Grim Dawn\Launcher.exe""# + "\n"
        let end = "[2026-07-28 12:00:01] AppID 219990 no longer tracking PID 4242, exit code 0\n"
        let partialChild = #"[2026-07-28 12:00:02] AppID 219990 adding PID 4343 as a tracked process "C:\Games\Grim"#
        let batch = start + end + partialChild
        try Data(batch.utf8).write(to: logURL)

        _ = await fixture.poll(logURL: logURL)
        let beforeContinuation = try await fixture.repository.recentRuns()
        XCTAssertEqual(beforeContinuation.count, 1)
        XCTAssertEqual(beforeContinuation.first?.result, .launched)

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" Dawn\\Grim Dawn.exe\"\n".utf8))
        try handle.close()
        _ = await fixture.poll(logURL: logURL)

        let runs = try await fixture.repository.runDetails()
        let processes = try await fixture.repository.runProcesses()
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.processID, 4343)
        XCTAssertEqual(runs.first?.result, .launched)
        XCTAssertEqual(Set(processes.map(\.processID)), Set([4242, 4343]))
    }

    func testTelemetryOutcomeRoundTripsThroughCodableContract() throws {
        let outcome = TelemetryPollOutcome(
            changed: true,
            issues: [TelemetryIssue(
                code: .steamLog(.logUnavailable),
                message: "missing",
                isNew: false
            )],
            resolvedIssues: [.steamLog(.logUnreadable)]
        )

        let decoded = try JSONDecoder().decode(
            TelemetryPollOutcome.self,
            from: JSONEncoder().encode(outcome)
        )

        XCTAssertEqual(decoded, outcome)
    }

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

    func testCrashedRunActivatesTheRecognisedRecipeForTheExactProcess() async throws {
        let fixture = try TelemetryFixture()
        defer { fixture.remove() }
        let processLogURL = fixture.root.appendingPathComponent("learned-gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: processLogURL.path, contents: nil))
        await fixture.telemetry.beginMonitoring(logURL: processLogURL)
        let sourceStartedAt = try XCTUnwrap(Self.steamLogDate("2026-07-28 11:59:59"))
        let sourceContext = fixture.context(startedAt: sourceStartedAt)
        try await fixture.telemetry.registerLaunchIntent(
            context: sourceContext,
            bottleURL: fixture.bottleURL
        )

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
        XCTAssertTrue(
            outcome.issues.isEmpty,
            "incidencias inesperadas: \(outcome.issues.map(\.message))"
        )
        // El loader acredita el App ID contra el appmanifest de Steam, así que la
        // activación puede escribirse y se aplicará en el siguiente arranque.
        let activations = try CompiledRepairActivationStore.activations(in: fixture.bottleURL)
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations[0].appID, "219990")
        XCTAssertEqual(activations[0].executable, "future-win64-shipping.exe")
        XCTAssertEqual(activations[0].recipe, .unrealD3D11DualOverlayIsolation)
        let receipts = try await fixture.repository.repairReceipts(appID: "219990")
        XCTAssertTrue(receipts.isEmpty)
        let attempts = try await fixture.repository.repairAttempts(appID: "219990")
        let attempt = try XCTUnwrap(attempts.first)
        let sourceRunID = try await fixture.repository.recentRuns().first?.id
        XCTAssertEqual(attempt.sourceRunID, sourceRunID)
        XCTAssertEqual(attempt.executable, "future-win64-shipping.exe")
        XCTAssertEqual(attempt.recipe, .unrealD3D11DualOverlayIsolation)
        XCTAssertEqual(attempt.state, .appliedAwaitingRelaunch)
        XCTAssertEqual(attempt.recipeVersion, 2)
        XCTAssertEqual(attempt.launchOrigin, .regression)
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

    init(
        sessionJoinGrace: TimeInterval = 0,
        maximumReadBytes: Int? = nil
    ) throws {
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
            monitor: maximumReadBytes.map {
                SteamLogMonitor(
                    maximumPendingBytes: 256 * 1_024,
                    unrecognizedCandidateLineThreshold: 32,
                    maximumReadBytes: $0
                )
            } ?? SteamLogMonitor(),
            sessionJoinGrace: sessionJoinGrace,
            artifactCleaner: artifactCleaner
        )
    }

    func context(startedAt: Date = Date(timeIntervalSince1970: 1_767_225_600)) -> RunContext {
        let configuration = ["backend": "regression"]
        return RunContext(
            appID: "219990",
            gameName: "Grim Dawn",
            backend: .regression,
            bottleName: "Steam",
            providerVersion: "1.2",
            startedAt: startedAt,
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

    func poll(logURL: URL) async -> TelemetryPollOutcome {
        await telemetry.poll(
            backend: .regression,
            logURL: logURL,
            games: [game],
            system: context().system,
            steamRootURL: root.appendingPathComponent("Steam", isDirectory: true),
            bottleURL: bottleURL,
            bottleName: "Steam",
            providerVersion: "1.12"
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
