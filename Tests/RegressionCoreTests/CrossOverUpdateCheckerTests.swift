import Foundation
@testable import RegressionCore
import XCTest

final class CrossOverUpdateCheckerTests: XCTestCase {
    func testLegacyCheckerIsFailClosedWithoutPreferencesOrNetwork() async {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let checker = CrossOverUpdateChecker(now: { checkedAt })
        let installation = CrossOverInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/LegacyReference.app"),
            version: "26.3",
            build: "test",
            bottleName: "Steam",
            bottleURL: URL(fileURLWithPath: "/tmp/Bottles/Steam"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/Bottles/Steam/steam.exe"),
            wineCLIURL: URL(fileURLWithPath: "/usr/bin/true"),
            bottleCLIURL: URL(fileURLWithPath: "/usr/bin/true"),
            feedURL: URL(string: "https://network-must-not-be-used.invalid/feed.xml"),
            health: .ready,
            healthDetail: "histórico"
        )

        let status = await checker.check(installation)

        XCTAssertEqual(status.installedVersion, "26.3")
        XCTAssertNil(status.availableVersion)
        XCTAssertFalse(status.updateAvailable)
        XCTAssertFalse(status.automaticChecksEnabled)
        XCTAssertFalse(status.automaticInstallationEnabled)
        XCTAssertEqual(status.checkedAt, checkedAt)
    }
}
