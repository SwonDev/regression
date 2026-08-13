import CryptoKit
import Foundation
@testable import RegressionCore
import XCTest

final class RegressionReleaseUpdateTests: XCTestCase {
    func testRepairNeverDowngradesAndOnlySpawnsForTheInstalledRelease() async {
        var spawnCount = 0
        let downgrade = await RegressionManualRepairPolicy.runIfAuthorized(
            installedVersion: "1.11.0",
            releaseVersion: "1.10.1"
        ) {
            spawnCount += 1
        }
        XCTAssertEqual(downgrade, .rejectDowngrade)
        XCTAssertEqual(spawnCount, 0)
        XCTAssertFalse(downgrade.permitsInstallerSpawn)

        let sameVersion = await RegressionManualRepairPolicy.runIfAuthorized(
            installedVersion: "1.11.0",
            releaseVersion: "1.11.0"
        ) {
            spawnCount += 1
        }
        XCTAssertEqual(sameVersion, .repairNow)
        XCTAssertEqual(spawnCount, 1)
        XCTAssertTrue(sameVersion.permitsInstallerSpawn)
    }

    func testRepairExposesANewerReleaseForExplicitUpdateWithoutSpawning() async {
        var spawnCount = 0
        let decision = await RegressionManualRepairPolicy.runIfAuthorized(
            installedVersion: "1.11.0",
            releaseVersion: "1.12.0"
        ) {
            spawnCount += 1
        }

        XCTAssertEqual(decision, .newerUpdateAvailable)
        XCTAssertEqual(spawnCount, 0)
        XCTAssertFalse(decision.permitsInstallerSpawn)
    }

    func testInvalidRepairVersionsFailClosedWithoutSpawning() async {
        var spawnCount = 0
        let decision = await RegressionManualRepairPolicy.runIfAuthorized(
            installedVersion: "desconocida",
            releaseVersion: "1.11.0"
        ) {
            spawnCount += 1
        }

        XCTAssertEqual(decision, .rejectDowngrade)
        XCTAssertEqual(spawnCount, 0)
    }

    func testRepairDecisionRemainsAClosedThreeWayContract() {
        XCTAssertEqual(
            RegressionManualRepairPolicy.decision(
                installedVersion: "1.11.0",
                releaseVersion: "1.10.1"
            ),
            .rejectDowngrade
        )
        XCTAssertFalse(
            RegressionManualRepairPolicy.decision(
                installedVersion: "1.11.0",
                releaseVersion: "1.10.1"
            ).permitsInstallerSpawn
        )
        XCTAssertEqual(
            RegressionManualRepairPolicy.decision(
                installedVersion: "1.11.0",
                releaseVersion: "1.11.0"
            ),
            .repairNow
        )
        XCTAssertTrue(
            RegressionManualRepairPolicy.decision(
                installedVersion: "1.11.0",
                releaseVersion: "1.11.0"
            ).permitsInstallerSpawn
        )
    }

    func testAutomaticUpdateInstallsOnlyFromCanonicalIdleApplication() {
        let status = RegressionReleaseUpdateStatus.available(
            installedVersion: "1.9.0",
            release: Self.release(version: "1.9.1")
        )

        XCTAssertEqual(
            RegressionAutomaticUpdatePolicy.decision(
                enabled: true,
                canonicalInstallation: true,
                regressionIsRunning: false,
                applicationIsBusy: false,
                status: status
            ),
            .installNow
        )
        XCTAssertEqual(
            RegressionAutomaticUpdatePolicy.decision(
                enabled: true,
                canonicalInstallation: false,
                regressionIsRunning: false,
                applicationIsBusy: false,
                status: status
            ),
            .requiresCanonicalInstallation
        )
        XCTAssertEqual(
            RegressionAutomaticUpdatePolicy.decision(
                enabled: false,
                canonicalInstallation: true,
                regressionIsRunning: false,
                applicationIsBusy: false,
                status: status
            ),
            .disabled
        )
    }

    func testAutomaticUpdateWaitsForRegressionAndBusyOperationsToFinish() {
        let status = RegressionReleaseUpdateStatus.available(
            installedVersion: "1.9.0",
            release: Self.release(version: "1.9.1")
        )

        XCTAssertEqual(
            RegressionAutomaticUpdatePolicy.decision(
                enabled: true,
                canonicalInstallation: true,
                regressionIsRunning: true,
                applicationIsBusy: false,
                status: status
            ),
            .waitForIdle
        )
        XCTAssertEqual(
            RegressionAutomaticUpdatePolicy.decision(
                enabled: true,
                canonicalInstallation: true,
                regressionIsRunning: false,
                applicationIsBusy: true,
                status: status
            ),
            .waitForIdle
        )
    }

    func testAutomaticUpdateDoesNothingWithoutANewerRelease() {
        XCTAssertEqual(
            RegressionAutomaticUpdatePolicy.decision(
                enabled: true,
                canonicalInstallation: true,
                regressionIsRunning: false,
                applicationIsBusy: false,
                status: .upToDate(installedVersion: "1.9.0", checkedAt: Date())
            ),
            .noUpdate
        )
    }

    func testAutomaticUpdateDoesNotLoopAfterAttemptingTheSameRelease() {
        let status = RegressionReleaseUpdateStatus.available(
            installedVersion: "1.9.0",
            release: Self.release(version: "1.9.1")
        )

        XCTAssertEqual(
            RegressionAutomaticUpdatePolicy.decision(
                enabled: true,
                canonicalInstallation: true,
                regressionIsRunning: false,
                applicationIsBusy: false,
                lastAttemptedVersion: "1.9.1",
                status: status
            ),
            .manualRetryRequired
        )
        XCTAssertEqual(
            RegressionAutomaticUpdatePolicy.decision(
                enabled: true,
                canonicalInstallation: true,
                regressionIsRunning: false,
                applicationIsBusy: false,
                lastAttemptedVersion: "1.9.0",
                status: status
            ),
            .installNow
        )
    }

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

        let directory = Self.secureTemporaryRoot
            .appendingPathComponent("regression-update-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloaded = try await service.downloadInstaller(for: release, to: directory)
        XCTAssertEqual(try Data(contentsOf: downloaded), installer)
        let permissions = try FileManager.default.attributesOfItem(atPath: downloaded.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o700)
    }

    func testLatestReleaseCanRepairTheCurrentVersionWithoutWeakeningAssetValidation() async throws {
        let installer = Data("#!/bin/bash\nexit 0\n".utf8)
        let digest = SHA256.hash(data: installer).map { String(format: "%02x", $0) }.joined()
        let service = RegressionReleaseUpdateService(fetch: { request in
            (
                Self.releaseJSON(version: "v1.10.1", digest: digest, size: installer.count),
                Self.response(url: request.url!)
            )
        })

        let release = try await service.latestRelease(clientVersion: "1.10.1")

        XCTAssertEqual(release.version, "1.10.1")
        XCTAssertEqual(release.installerSHA256, digest)
        XCTAssertEqual(release.installerURL.lastPathComponent, "install_regression.sh")
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
        let directory = Self.secureTemporaryRoot
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

    func testInstallerFromAnotherGitHubRepositoryIsRejected() async {
        let service = RegressionReleaseUpdateService(fetch: { request in
            (
                Self.releaseJSON(
                    version: "1.9.1",
                    downloadURL: "https://github.com/otro/proyecto/releases/download/v1.9.1/install_regression.sh"
                ),
                Self.response(url: request.url!)
            )
        })

        do {
            _ = try await service.check(installedVersion: "1.9.0")
            XCTFail("Un asset de otro repositorio no debía aceptarse como actualizador oficial.")
        } catch {
            XCTAssertEqual(error as? RegressionReleaseUpdateError, .unsupportedDownloadURL)
        }
    }

    func testLookalikeOfficialReleasePathsAreRejected() async {
        for downloadURL in [
            "https://github.com/SwonDev/regression/releases/download-evil/v1.9.1/install_regression.sh",
            "https://github.com/SwonDev/regression/releases/download/v1.9.1/nested/install_regression.sh",
        ] {
            let service = RegressionReleaseUpdateService(fetch: { request in
                (
                    Self.releaseJSON(version: "1.9.1", downloadURL: downloadURL),
                    Self.response(url: request.url!)
                )
            })

            do {
                _ = try await service.check(installedVersion: "1.9.0")
                XCTFail("Una ruta parecida al canal oficial no debía aceptarse: \(downloadURL)")
            } catch {
                XCTAssertEqual(error as? RegressionReleaseUpdateError, .unsupportedDownloadURL)
            }
        }
    }

    func testInstallerStagingRejectsSymbolicLinkAndRepairsDirectoryPermissions() async throws {
        let installer = Data("#!/bin/bash\nexit 0\n".utf8)
        let digest = SHA256.hash(data: installer).map { String(format: "%02x", $0) }.joined()
        let release = Self.release(
            version: "1.9.1",
            digest: digest,
            size: installer.count
        )
        let service = RegressionReleaseUpdateService(fetch: { request in
            (installer, Self.response(url: request.url!))
        })
        let root = Self.secureTemporaryRoot
            .appendingPathComponent("regression-update-test-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let linked = root.appendingPathComponent("linked", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        do {
            _ = try await service.downloadInstaller(for: release, to: linked)
            XCTFail("El staging de una actualización no debe seguir enlaces simbólicos.")
        } catch {
            XCTAssertEqual(error as? RegressionReleaseUpdateError, .unsafeUpdateDirectory)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: target.appendingPathComponent("install_regression.sh").path
                )
            )
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        _ = try await service.downloadInstaller(for: release, to: target)
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual((permissions?.intValue ?? 0) & 0o777, 0o700)
        let ancestorPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual((ancestorPermissions?.intValue ?? 0) & 0o777, 0o755)
    }

    func testInstallerStagingRejectsASymbolicLinkInTheParentChainBeforeCreatingAChild() async throws {
        let installer = Data("#!/bin/bash\nexit 0\n".utf8)
        let digest = SHA256.hash(data: installer).map { String(format: "%02x", $0) }.joined()
        let release = Self.release(
            version: "1.9.1",
            digest: digest,
            size: installer.count
        )
        let service = RegressionReleaseUpdateService(fetch: { request in
            (installer, Self.response(url: request.url!))
        })
        let root = Self.secureTemporaryRoot
            .appendingPathComponent("regression-update-test-\(UUID().uuidString)", isDirectory: true)
        let physicalParent = root.appendingPathComponent("physical", isDirectory: true)
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        let child = linkedParent.appendingPathComponent("child", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: physicalParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: physicalParent)

        do {
            _ = try await service.downloadInstaller(for: release, to: child)
            XCTFail("El staging no debe atravesar un padre simbólico para crear el hijo.")
        } catch {
            XCTAssertEqual(error as? RegressionReleaseUpdateError, .unsafeUpdateDirectory)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: physicalParent.appendingPathComponent("child").path
                )
            )
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
        size: Int = 22,
        downloadURL: String? = nil
    ) -> Data {
        let resolvedDownloadURL = downloadURL
            ?? "https://github.com/SwonDev/regression/releases/download/\(version)/install_regression.sh"
        return Data(#"""
        {
          "tag_name": "\#(version)",
          "html_url": "https://github.com/SwonDev/regression/releases/tag/\#(version)",
          "draft": \#(draft),
          "prerelease": \#(prerelease),
          "assets": [{
            "name": "install_regression.sh",
            "browser_download_url": "\#(resolvedDownloadURL)",
            "digest": "sha256:\#(digest)",
            "size": \#(size)
          }]
        }
        """#.utf8)
    }

    private static let secureTemporaryRoot = URL(
        fileURLWithPath: "/private/tmp",
        isDirectory: true
    )

    private static func release(
        version: String,
        digest: String = String(repeating: "a", count: 64),
        size: Int = 22
    ) -> RegressionRelease {
        RegressionRelease(
            version: version,
            pageURL: URL(string: "https://github.com/SwonDev/regression/releases/tag/v\(version)")!,
            installerURL: URL(
                string: "https://github.com/SwonDev/regression/releases/download/v\(version)/install_regression.sh"
            )!,
            installerSHA256: digest,
            installerSize: size
        )
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
