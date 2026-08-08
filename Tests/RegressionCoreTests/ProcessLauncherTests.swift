import Foundation
@testable import RegressionCore
import XCTest

final class ProcessLauncherTests: XCTestCase {
    func testRunnerCapturesOutputErrorExitCodeAndEnvironment() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf '%s' \"$REGRESSION_TEST_VALUE\"; printf 'diagnóstico' >&2; exit 7",
            ],
            environment: ["REGRESSION_TEST_VALUE": "correcto"]
        )

        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.standardOutput, "correcto")
        XCTAssertEqual(result.standardError, "diagnóstico")
    }

    func testRapidLaunchesReceiveDistinctPrivateLogFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-launcher-logs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = ProcessLauncher()

        let first = try await launcher.launch(
            backend: .regression,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            logDirectoryURL: directory
        )
        try await Task.sleep(for: .milliseconds(50))
        await launcher.reapFinishedProcesses()
        let second = try await launcher.launch(
            backend: .regression,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            logDirectoryURL: directory
        )

        XCTAssertNotEqual(first.logURL, second.logURL)
        for url in [first.logURL, second.logURL] {
            let mode = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            ).intValue
            XCTAssertEqual(mode & 0o777, 0o600)
        }
    }

    func testIdenticalActiveLaunchIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-launcher-dedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let launcher = ProcessLauncher()
        let executable = URL(fileURLWithPath: "/bin/sh")
        let arguments = ["-c", "sleep 0.2"]

        let first = try await launcher.launch(
            backend: .regression,
            executableURL: executable,
            arguments: arguments,
            logDirectoryURL: directory
        )
        let second = try await launcher.launch(
            backend: .regression,
            executableURL: executable,
            arguments: arguments,
            logDirectoryURL: directory
        )

        XCTAssertEqual(first.processID, second.processID)
        XCTAssertEqual(first.logURL, second.logURL)
        try await Task.sleep(for: .milliseconds(250))
        await launcher.reapFinishedProcesses()
    }

    func testLauncherRotatesOnlyItsOwnLogsAndKeepsPrivateLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<25 {
            let url = directory.appendingPathComponent("regression-old-\(index).log")
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index))],
                ofItemAtPath: url.path
            )
        }
        let unrelated = directory.appendingPathComponent("usuario.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: unrelated.path, contents: Data()))

        let launcher = ProcessLauncher()
        _ = try await launcher.launch(
            backend: .regression,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            logDirectoryURL: directory
        )

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.lastPathComponent.hasPrefix("regression-") }.count, 20)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testLogReaderUsesBoundedTailAndRedactsSecrets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-log-reader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let logURL = directory.appendingPathComponent("launcher.log")
        let prefix = "inicio reservado\n" + String(repeating: "x", count: 200_000) + "\n"
        try Data("\(prefix)password=secreto\nerror final".utf8).write(to: logURL)

        let excerpt = await ProcessLogReader().redactedExcerpt(
            at: logURL,
            maximumReadBytes: 4_096,
            maximumOutputCharacters: 500
        )

        XCTAssertFalse(excerpt.contains("inicio reservado"))
        XCTAssertFalse(excerpt.contains("password=secreto"))
        XCTAssertTrue(excerpt.contains("<secreto-redactado>"))
        XCTAssertTrue(excerpt.contains("error final"))
        XCTAssertLessThanOrEqual(excerpt.count, 500)
    }
}
