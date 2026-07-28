import Foundation
@testable import RegressionCore
import XCTest

final class ProcessLauncherTests: XCTestCase {
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
}
