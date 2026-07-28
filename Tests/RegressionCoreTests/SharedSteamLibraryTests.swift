import Foundation
@testable import RegressionCore
import XCTest

final class SharedSteamLibraryTests: XCTestCase {
    func testConfigureRollsBackOriginalSteamAppsWhenReceiptCannotBeWritten() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try Data("preservar".utf8).write(to: fixture.regressionSteamApps.appendingPathComponent("marker.txt"))
        try FileManager.default.createDirectory(
            at: fixture.backupRoot.appendingPathComponent("shared-library-receipt.json"),
            withIntermediateDirectories: true
        )

        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        do {
            _ = try await manager.configure(
                regression: fixture.regression,
                crossOver: fixture.crossOver,
                runningState: RunningBackendState()
            )
            XCTFail("La escritura del recibo debía fallar")
        } catch {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.regressionSteamApps.appendingPathComponent("marker.txt").path
                )
            )
            XCTAssertThrowsError(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: fixture.regressionSteamApps.path
                )
            )
        }
    }

    func testConfigureCreatesRecoverableSharedLibraryAndPrivateReceipt() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let link = try await manager.configure(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            runningState: RunningBackendState()
        )
        let assessment = await manager.assess(
            regression: fixture.regression,
            crossOver: fixture.crossOver
        )
        XCTAssertEqual(link, fixture.regressionSteamApps)
        XCTAssertEqual(assessment.status, .ready)

        let receipt = fixture.backupRoot.appendingPathComponent("shared-library-receipt.json")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: receipt.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
    }
}

private final class SharedLibraryFixture {
    let root: URL
    let backupRoot: URL
    let regressionSteamApps: URL
    let regression: RegressionInstallation
    let crossOver: CrossOverInstallation

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-shared-library-\(UUID().uuidString)", isDirectory: true)
        backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let regressionBottle = root.appendingPathComponent("regression-bottle", isDirectory: true)
        let crossOverBottle = root.appendingPathComponent("crossover-bottle", isDirectory: true)
        let relativeSteam = "drive_c/Program Files (x86)/Steam"
        let regressionSteam = regressionBottle.appendingPathComponent(relativeSteam, isDirectory: true)
        let crossOverSteam = crossOverBottle.appendingPathComponent(relativeSteam, isDirectory: true)
        regressionSteamApps = regressionSteam.appendingPathComponent("steamapps", isDirectory: true)
        try FileManager.default.createDirectory(at: regressionSteamApps, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: crossOverSteam.appendingPathComponent("steamapps", isDirectory: true),
            withIntermediateDirectories: true
        )

        regression = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app"),
            bottleURL: regressionBottle,
            steamExecutableURL: regressionSteam.appendingPathComponent("Steam.exe"),
            engineLauncherURL: root.appendingPathComponent("regression-engine"),
            health: .ready,
            healthDetail: "ok"
        )
        crossOver = CrossOverInstallation(
            applicationURL: root.appendingPathComponent("CrossOver.app"),
            version: "26.3",
            build: "1",
            bottleName: "Steam",
            bottleURL: crossOverBottle,
            steamExecutableURL: crossOverSteam.appendingPathComponent("steam.exe"),
            wineCLIURL: root.appendingPathComponent("wine"),
            bottleCLIURL: root.appendingPathComponent("cxbottle"),
            feedURL: nil,
            health: .ready,
            healthDetail: "ok"
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
