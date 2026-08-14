import Foundation
@testable import RegressionCore
import XCTest

final class SteamLogMonitorTests: XCTestCase {
    func testPartialLineIsRetainedUntilSteamFinishesWritingIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-monitor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))

        let monitor = SteamLogMonitor()
        await monitor.beginMonitoringAtEnd(of: logURL)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        let firstHalf = #"[2026-07-27 08:13:10] AppID 1128000 adding PID 2196 as a tracked"#
        try handle.write(contentsOf: Data(firstHalf.utf8))
        try handle.synchronize()
        let partialRead = await monitor.readNewEvents(from: logURL)
        XCTAssertTrue(partialRead.events.isEmpty)
        XCTAssertTrue(partialRead.issues.isEmpty)

        let secondHalf = #" process ""C:\Program Files (x86)\Steam\steamapps\common\Cube World\cubeworld.exe"""# + "\n"
        try handle.write(contentsOf: Data(secondHalf.utf8))
        try handle.synchronize()

        let read = await monitor.readNewEvents(from: logURL)
        guard case let .started(_, appID, processID, executable) = read.events.first else {
            return XCTFail("La línea completa no se recuperó después del segundo fragmento")
        }
        XCTAssertEqual(read.events.count, 1)
        XCTAssertTrue(read.issues.isEmpty)
        XCTAssertEqual(appID, "1128000")
        XCTAssertEqual(processID, 2196)
        XCTAssertTrue(executable.hasSuffix("cubeworld.exe"))
    }

    func testReplacingLogFileResetsOffsetAndPendingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        try Data("contenido anterior".utf8).write(to: logURL)

        let monitor = SteamLogMonitor()
        await monitor.beginMonitoringAtEnd(of: logURL)
        try FileManager.default.removeItem(at: logURL)
        let replacement = "[2026-07-27 08:13:19] AppID 1128000 no longer tracking PID 2196, exit code 0\n"
        try Data(replacement.utf8).write(to: logURL)

        let read = await monitor.readNewEvents(from: logURL)
        XCTAssertTrue(read.events.isEmpty)
        XCTAssertEqual(read.issues.map(\.code), [.logReplaced])

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(replacement.utf8))
        try handle.close()
        let appendedRead = await monitor.readNewEvents(from: logURL)
        XCTAssertEqual(appendedRead.events.count, 1)
    }

    func testMissingLogRemainsObservableButOnlyFirstPollMarksItNew() async {
        let monitor = SteamLogMonitor()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-gameprocess-\(UUID().uuidString).txt")

        let firstRead = await monitor.readNewEvents(from: logURL)
        let repeatedRead = await monitor.readNewEvents(from: logURL)

        XCTAssertTrue(firstRead.events.isEmpty)
        XCTAssertEqual(firstRead.issues.map(\.code), [.logUnavailable])
        XCTAssertEqual(firstRead.newlyObservedIssues, [.logUnavailable])
        XCTAssertTrue(repeatedRead.events.isEmpty)
        XCTAssertEqual(repeatedRead.issues.map(\.code), [.logUnavailable])
        XCTAssertTrue(repeatedRead.newlyObservedIssues.isEmpty)
    }

    func testUnreadableLogTargetIsDistinguishedFromMissingLog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-unreadable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = SteamLogMonitor()

        let read = await monitor.readNewEvents(from: directory)

        XCTAssertTrue(read.events.isEmpty)
        XCTAssertEqual(read.issues.map(\.code), [.logUnreadable])
    }

    func testTruncatedLogResetsOffsetAndReportsDataLossBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-truncation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        try Data(repeating: 0x78, count: 4_096).write(to: logURL)
        let monitor = SteamLogMonitor()
        await monitor.beginMonitoringAtEnd(of: logURL)
        let event = "[2026-07-27 08:13:19] AppID 1128000 no longer tracking PID 2196, exit code 0\n"
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(event.utf8))
        try handle.close()

        let read = await monitor.readNewEvents(from: logURL)

        XCTAssertTrue(read.events.isEmpty)
        XCTAssertEqual(read.issues.map(\.code), [.logTruncated])
    }

    func testOversizedPendingLineIsBoundedAndObservableOnceUntilBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-pending-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let monitor = SteamLogMonitor(maximumPendingBytes: 32, unrecognizedCandidateLineThreshold: 3)

        try Data(repeating: 0x78, count: 64).write(to: logURL)
        let firstRead = await monitor.readNewEvents(from: logURL)
        let repeatedRead = await monitor.readNewEvents(from: logURL)

        XCTAssertEqual(firstRead.issues.map(\.code), [.pendingLineLimitExceeded])
        XCTAssertEqual(firstRead.newlyObservedIssues, [.pendingLineLimitExceeded])
        XCTAssertEqual(repeatedRead.issues.map(\.code), [.pendingLineLimitExceeded])
        XCTAssertTrue(repeatedRead.newlyObservedIssues.isEmpty)
    }

    func testOversizedPendingSuffixCannotBecomeAProcessEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-discard-line-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let monitor = SteamLogMonitor(maximumPendingBytes: 96, unrecognizedCandidateLineThreshold: 3)
        let forgedSuffix = "[2026-07-27 08:13:19] AppID 1128000 adding PID 2196 as a tracked process \"C:\\Games\\forged.exe\""
        try Data((String(repeating: "x", count: 512) + forgedSuffix).utf8).write(to: logURL)

        let overflow = await monitor.readNewEvents(from: logURL)
        XCTAssertTrue(overflow.events.isEmpty)
        XCTAssertTrue(overflow.issues.map(\.code).contains(.pendingLineLimitExceeded))

        let valid = "[2026-07-27 08:13:20] AppID 1128000 adding PID 2197 as a tracked process \"C:\\Games\\valid.exe\"\n"
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + valid).utf8))
        try handle.close()
        let recovered = await monitor.readNewEvents(from: logURL)

        XCTAssertEqual(recovered.events.count, 1)
        guard case let .started(_, _, processID, executable) = recovered.events.first else {
            return XCTFail("No se recuperó el evento posterior completo")
        }
        XCTAssertEqual(processID, 2197)
        XCTAssertTrue(executable.hasSuffix("valid.exe"))
        XCTAssertTrue(recovered.resolvedIssues.contains(.pendingLineLimitExceeded))
    }

    func testUnavailableAndUnreadableTransitionsResolvePreviousFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-transition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let logURL = root.appendingPathComponent("gameprocess_log.txt", isDirectory: true)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        let monitor = SteamLogMonitor()

        let unreadable = await monitor.readNewEvents(from: logURL)
        try FileManager.default.removeItem(at: logURL)
        let unavailable = await monitor.readNewEvents(from: logURL)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        let unreadableAgain = await monitor.readNewEvents(from: logURL)

        XCTAssertEqual(unreadable.issues.map(\.code), [.logUnreadable])
        XCTAssertEqual(unavailable.issues.map(\.code), [.logUnavailable])
        XCTAssertEqual(unavailable.resolvedIssues, [.logUnreadable])
        XCTAssertEqual(unreadableAgain.issues.map(\.code), [.logUnreadable])
        XCTAssertEqual(unreadableAgain.resolvedIssues, [.logUnavailable])
    }

    func testPendingLineDefersOnlyForBoundedIdlePollBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-pending-budget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        try Data("partial".utf8).write(to: logURL)
        let monitor = SteamLogMonitor(
            maximumPendingBytes: 128,
            unrecognizedCandidateLineThreshold: 3,
            maximumPendingLineIdlePolls: 2
        )

        let initial = await monitor.readNewEvents(from: logURL)
        let firstIdle = await monitor.readNewEvents(from: logURL)
        let abandoned = await monitor.readNewEvents(from: logURL)

        XCTAssertTrue(initial.hasPendingLine)
        XCTAssertTrue(firstIdle.hasPendingLine)
        XCTAssertFalse(abandoned.hasPendingLine)
        XCTAssertEqual(abandoned.issues.map(\.code), [.pendingLineAbandoned])
        XCTAssertEqual(abandoned.newlyObservedIssues, [.pendingLineAbandoned])
    }

    func testOnlyProcessLikeUnrecognizedLinesCountTowardBoundedFormatDriftIssue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-format-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        let monitor = SteamLogMonitor(maximumPendingBytes: 128, unrecognizedCandidateLineThreshold: 3)
        let unrelated = (0..<100).map { "Steam maintenance line \($0)" }.joined(separator: "\n")
        let malformed = (0..<3).map {
            "[2026-07-27 08:13:1\($0)] AppID 1128000 adding PID nope as a tracked process"
        }.joined(separator: "\n")
        try Data("\(unrelated)\n\(malformed)\n".utf8).write(to: logURL)

        let read = await monitor.readNewEvents(from: logURL)

        XCTAssertTrue(read.events.isEmpty)
        XCTAssertEqual(read.issues.map(\.code), [.unrecognizedProcessLineVolume])
    }

    func testNormalCompletedBatchBreaksSparseMalformedLineAccumulation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-format-decay-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let monitor = SteamLogMonitor(maximumPendingBytes: 128, unrecognizedCandidateLineThreshold: 3)
        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        try handle.write(contentsOf: Data("AppID 1 adding PID nope\nAppID 1 adding PID nope\n".utf8))
        let firstRead = await monitor.readNewEvents(from: logURL)
        XCTAssertTrue(firstRead.issues.isEmpty)
        try handle.write(contentsOf: Data("Steam maintenance completed\n".utf8))
        let normalRead = await monitor.readNewEvents(from: logURL)
        XCTAssertTrue(normalRead.issues.isEmpty)
        try handle.write(contentsOf: Data("AppID 1 adding PID nope\n".utf8))

        let finalRead = await monitor.readNewEvents(from: logURL)
        XCTAssertTrue(finalRead.issues.isEmpty)
    }

    func testAvailabilityRecoveryIsExplicitAndClearsPersistentIssue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        let monitor = SteamLogMonitor()
        _ = await monitor.readNewEvents(from: logURL)
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))

        let recovered = await monitor.readNewEvents(from: logURL)

        XCTAssertEqual(recovered.issues.map(\.code), [.monitoringRecovered])
        XCTAssertEqual(recovered.newlyObservedIssues, [.monitoringRecovered])
        XCTAssertEqual(recovered.resolvedIssues, [.logUnavailable])
    }

    func testSameInodeRewriteWithRecoveredSizeCreatesNewEpoch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-rewrite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        try Data(repeating: 0x61, count: 256).write(to: logURL)
        let originalFileNumber = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: logURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        let monitor = SteamLogMonitor()
        await monitor.beginMonitoringAtEnd(of: logURL)
        let event = "[2026-07-27 08:13:19] AppID 1128000 no longer tracking PID 2196, exit code 0\n"
        let replacement = Data(event.utf8) + Data(repeating: 0x62, count: 256)
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: replacement)
        try handle.close()

        let read = await monitor.readNewEvents(from: logURL)
        let currentFileNumber = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: logURL.path)[.systemFileNumber] as? NSNumber)?.uint64Value
        )

        XCTAssertEqual(currentFileNumber, originalFileNumber)
        XCTAssertEqual(read.discontinuity, SteamLogDiscontinuity(epoch: 1, reason: .logTruncated))
        XCTAssertTrue(read.events.isEmpty)
    }

    func testLargeReplacementEstablishesEOFEpochBoundaryBeforeFutureAppend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-large-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        try Data("old".utf8).write(to: logURL)
        let monitor = SteamLogMonitor(
            maximumPendingBytes: 128,
            unrecognizedCandidateLineThreshold: 3,
            maximumReadBytes: 128
        )
        await monitor.beginMonitoringAtEnd(of: logURL)
        try FileManager.default.removeItem(at: logURL)
        let historical = "[2026-07-27 08:13:19] AppID 1128000 no longer tracking PID 2196, exit code 0\n"
        try Data((String(repeating: historical, count: 16)).utf8).write(to: logURL)

        let discontinuity = await monitor.readNewEvents(from: logURL)
        let nextPoll = await monitor.readNewEvents(from: logURL)
        XCTAssertEqual(discontinuity.discontinuity?.reason, .logReplaced)
        XCTAssertTrue(discontinuity.events.isEmpty)
        XCTAssertTrue(nextPoll.events.isEmpty)

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(historical.utf8))
        try handle.close()
        let appendedRead = await monitor.readNewEvents(from: logURL)
        XCTAssertEqual(appendedRead.events.count, 1, "\(appendedRead)")
    }

    func testReplacementPartialLineNeverJoinsWithFutureAppend() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-partial-replacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        try Data("old".utf8).write(to: logURL)
        let monitor = SteamLogMonitor()
        await monitor.beginMonitoringAtEnd(of: logURL)
        try FileManager.default.removeItem(at: logURL)
        try Data("[2026-07-27 08:13:19] AppID 1128000 adding PID".utf8).write(to: logURL)
        _ = await monitor.readNewEvents(from: logURL)

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" 2196 as a tracked process \"C:\\Games\\old.exe\"\n".utf8))
        try handle.close()
        let continuation = await monitor.readNewEvents(from: logURL)

        XCTAssertTrue(continuation.events.isEmpty)
        let valid = "[2026-07-27 08:13:20] AppID 1128000 adding PID 2197 as a tracked process \"C:\\Games\\new.exe\"\n"
        let appendHandle = try FileHandle(forWritingTo: logURL)
        try appendHandle.seekToEnd()
        try appendHandle.write(contentsOf: Data(valid.utf8))
        try appendHandle.close()
        let validRead = await monitor.readNewEvents(from: logURL)
        XCTAssertEqual(validRead.events.count, 1, "\(validRead)")
    }

    func testBoundedReadReturnsEventAndBacklogIssueWithoutReadingWholeFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-bounded-read-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("gameprocess_log.txt")
        let event = "[2026-07-27 08:13:19] AppID 1128000 no longer tracking PID 2196, exit code 0\n"
        try Data((event + String(repeating: "x", count: 4_096)).utf8).write(to: logURL)
        let monitor = SteamLogMonitor(
            maximumPendingBytes: 128,
            unrecognizedCandidateLineThreshold: 3,
            maximumReadBytes: 128
        )

        let read = await monitor.readNewEvents(from: logURL)

        XCTAssertEqual(read.events.count, 1)
        XCTAssertTrue(read.hasMoreData)
        XCTAssertTrue(read.issues.map(\.code).contains(.readLimitReached))
        XCTAssertTrue(read.newlyObservedIssues.contains(.readLimitReached))
    }

    func testMonitorBoundsAndCanForgetPerLogState() async {
        let monitor = SteamLogMonitor(
            maximumPendingBytes: 128,
            unrecognizedCandidateLineThreshold: 3,
            maximumMonitoredLogs: 2
        )
        let urls = (0..<3).map {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-state-\($0)-\(UUID().uuidString).txt")
        }

        for url in urls {
            _ = await monitor.readNewEvents(from: url)
        }
        let boundedCount = await monitor.monitoredLogCount()
        await monitor.forget(urls[2])
        let forgottenCount = await monitor.monitoredLogCount()

        XCTAssertEqual(boundedCount, 2)
        XCTAssertEqual(forgottenCount, 1)
    }

    func testEventAndOutcomeRoundTripThroughCodableContract() throws {
        let event = SteamGameProcessEvent.started(
            timestamp: Date(timeIntervalSince1970: 123),
            appID: "1128000",
            processID: 2196,
            executable: "C:\\Games\\game.exe"
        )
        let outcome = SteamLogReadOutcome(
            events: [event],
            issues: [SteamLogMonitorIssue(code: .readLimitReached, message: "backlog")],
            newlyObservedIssues: [.readLimitReached],
            epoch: 2,
            hasMoreData: true
        )

        let decoded = try JSONDecoder().decode(
            SteamLogReadOutcome.self,
            from: JSONEncoder().encode(outcome)
        )

        XCTAssertEqual(decoded, outcome)
    }
}
