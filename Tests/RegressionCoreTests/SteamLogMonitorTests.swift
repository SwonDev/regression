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
        let partialEvents = await monitor.readNewEvents(from: logURL)
        XCTAssertTrue(partialEvents.isEmpty)

        let secondHalf = #" process ""C:\Program Files (x86)\Steam\steamapps\common\Cube World\cubeworld.exe"""# + "\n"
        try handle.write(contentsOf: Data(secondHalf.utf8))
        try handle.synchronize()

        let events = await monitor.readNewEvents(from: logURL)
        guard case let .started(_, appID, processID, executable) = events.first else {
            return XCTFail("La línea completa no se recuperó después del segundo fragmento")
        }
        XCTAssertEqual(events.count, 1)
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

        let events = await monitor.readNewEvents(from: logURL)
        guard case let .ended(_, appID, processID, exitCode) = events.first else {
            return XCTFail("No se detectó el evento del archivo reemplazado")
        }
        XCTAssertEqual(appID, "1128000")
        XCTAssertEqual(processID, 2196)
        XCTAssertEqual(exitCode, 0)
    }
}
