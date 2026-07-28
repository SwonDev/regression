import Foundation
@testable import RegressionCore
import XCTest

final class CrossOverUpdateCheckerTests: XCTestCase {
    func testAppcastSelectsLatestNumericVersion() throws {
        let data = Data(#"""
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <item sparkle:shortVersionString="26.9" />
            <item><sparkle:shortVersionString>26.10</sparkle:shortVersionString></item>
          </channel>
        </rss>
        """#.utf8)

        XCTAssertEqual(try CrossOverAppcast.latestVersion(in: data), "26.10")
        XCTAssertTrue(CrossOverAppcast.isNewer("26.10", than: "26.9"))
        XCTAssertFalse(CrossOverAppcast.isNewer("26.3", than: "26.3"))
    }

    func testCheckerCombinesFeedAndAutomaticUpdatePreferences() async throws {
        let feedURL = URL(string: "https://updates.example.test/crossover.xml")!
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data(#"""
        <rss xmlns:sparkle="https://sparkle-project.org/xml-namespaces/sparkle">
          <channel><item sparkle:shortVersionString="27.0" /></channel>
        </rss>
        """#.utf8)
        let checker = CrossOverUpdateChecker(
            fetch: { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                ))
                return (data, response)
            },
            preferenceValue: { key in
                [
                    "SUEnableAutomaticChecks": true,
                    "SUAutomaticallyUpdate": true,
                ][key]
            },
            now: { checkedAt }
        )

        let status = await checker.check(installation(feedURL: feedURL, version: "26.3"))

        XCTAssertEqual(status.availableVersion, "27.0")
        XCTAssertTrue(status.updateAvailable)
        XCTAssertTrue(status.automaticChecksEnabled)
        XCTAssertTrue(status.automaticInstallationEnabled)
        XCTAssertEqual(status.checkedAt, checkedAt)
    }

    func testCheckerTreatsMalformedFeedAsUnknownInsteadOfClaimingUpToDate() async {
        let feedURL = URL(string: "https://updates.example.test/crossover.xml")!
        let checker = CrossOverUpdateChecker(fetch: { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data("<rss>".utf8), response)
        })

        let status = await checker.check(installation(feedURL: feedURL, version: "26.3"))

        XCTAssertNil(status.availableVersion)
        XCTAssertFalse(status.updateAvailable)
    }

    func testCheckerRejectsOversizedAppcastWithoutClaimingUpToDate() async {
        let feedURL = URL(string: "https://updates.example.test/crossover.xml")!
        let feed = Data(String(repeating: "x", count: 1_024).utf8)
        let checker = CrossOverUpdateChecker(
            fetch: { request in
                (
                    feed,
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                )
            },
            preferenceValue: { _ in true },
            maximumResponseBytes: 128
        )

        let status = await checker.check(installation(feedURL: feedURL, version: "26.3"))

        XCTAssertNil(status.availableVersion)
        XCTAssertFalse(status.updateAvailable)
    }

    private func installation(feedURL: URL, version: String) -> CrossOverInstallation {
        CrossOverInstallation(
            applicationURL: URL(fileURLWithPath: "/Applications/CrossOver.app"),
            version: version,
            build: "test",
            bottleName: "Steam",
            bottleURL: URL(fileURLWithPath: "/tmp/Bottles/Steam"),
            steamExecutableURL: URL(fileURLWithPath: "/tmp/Bottles/Steam/steam.exe"),
            wineCLIURL: URL(fileURLWithPath: "/usr/bin/true"),
            bottleCLIURL: URL(fileURLWithPath: "/usr/bin/true"),
            feedURL: feedURL,
            health: .ready,
            healthDetail: "ok"
        )
    }
}
