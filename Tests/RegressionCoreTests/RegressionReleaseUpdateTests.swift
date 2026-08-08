import CryptoKit
import Foundation
@testable import RegressionCore
import XCTest

final class RegressionReleaseUpdateTests: XCTestCase {
    func testStableNewerReleaseIsOfferedWithVerifiedInstallerMetadata() async throws {
        let installer = Data("#!/bin/bash\nexit 0\n".utf8)
        let digest = SHA256.hash(data: installer).map { String(format: "%02x", $0) }.joined()
        let service = RegressionReleaseUpdateService(fetch: { request in
            if request.url == RegressionReleaseUpdateService.latestReleaseURL {
                let data = Self.releaseJSON(version: "v1.7.4", digest: digest, size: installer.count)
                return (data, Self.response(url: request.url!))
            }
            return (installer, Self.response(url: request.url!))
        })

        let status = try await service.check(installedVersion: "1.7.3")
        guard case let .available(installedVersion, release) = status else {
            return XCTFail("La versión posterior debía ofrecerse como actualización.")
        }
        XCTAssertEqual(installedVersion, "1.7.3")
        XCTAssertEqual(release.version, "1.7.4")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-update-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloaded = try await service.downloadInstaller(for: release, to: directory)
        XCTAssertEqual(try Data(contentsOf: downloaded), installer)
        let permissions = try FileManager.default.attributesOfItem(atPath: downloaded.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o700)
    }

    func testDraftPrereleaseAndMalformedVersionsAreRejected() async throws {
        for payload in [
            Self.releaseJSON(version: "v1.8.0", draft: true),
            Self.releaseJSON(version: "v1.8.0", prerelease: true),
            Self.releaseJSON(version: "latest"),
        ] {
            let service = RegressionReleaseUpdateService(fetch: { request in
                (payload, Self.response(url: request.url!))
            })
            await XCTAssertThrowsErrorAsync {
                _ = try await service.check(installedVersion: "1.7.3")
            }
        }
    }

    func testInstallerWithDifferentDigestIsNeverWritten() async throws {
        let service = RegressionReleaseUpdateService(fetch: { request in
            if request.url == RegressionReleaseUpdateService.latestReleaseURL {
                return (
                    Self.releaseJSON(version: "1.7.4", digest: String(repeating: "a", count: 64), size: 4),
                    Self.response(url: request.url!)
                )
            }
            return (Data("malo".utf8), Self.response(url: request.url!))
        })
        let status = try await service.check(installedVersion: "1.7.3")
        guard case let .available(_, release) = status else {
            return XCTFail("Faltó la actualización de prueba.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-update-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await service.downloadInstaller(for: release, to: directory)
            XCTFail("Un instalador con hash distinto debía rechazarse.")
        } catch {
            XCTAssertEqual(error as? RegressionReleaseUpdateError, .integrityMismatch)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testCurrentOrOlderReleaseLeavesInstallationUpToDate() async throws {
        for candidate in ["1.7.3", "1.6.9"] {
            let service = RegressionReleaseUpdateService(fetch: { request in
                (
                    Self.releaseJSON(version: candidate),
                    Self.response(url: request.url!)
                )
            })
            let status = try await service.check(installedVersion: "1.7.3")
            guard case let .upToDate(installed, _) = status else {
                return XCTFail("Una release igual o anterior no debía ofrecerse.")
            }
            XCTAssertEqual(installed, "1.7.3")
        }
    }

    private static func releaseJSON(
        version: String,
        draft: Bool = false,
        prerelease: Bool = false,
        digest: String = String(repeating: "b", count: 64),
        size: Int = 22
    ) -> Data {
        Data(#"""
        {
          "tag_name": "\#(version)",
          "html_url": "https://github.com/SwonDev/regression/releases/tag/\#(version)",
          "draft": \#(draft),
          "prerelease": \#(prerelease),
          "assets": [{
            "name": "install_regression.sh",
            "browser_download_url": "https://github.com/SwonDev/regression/releases/download/\#(version)/install_regression.sh",
            "digest": "sha256:\#(digest)",
            "size": \#(size)
          }]
        }
        """#.utf8)
    }

    private static func response(url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Se esperaba un error.", file: file, line: line)
    } catch {
        // Éxito: el error es el resultado esperado.
    }
}
