import Foundation
@testable import RegressionCore
import XCTest

final class InstallationDiscoveryTests: XCTestCase {
    func testDiscoveryIgnoresCrossOverApplicationsBottlesAndExecutables() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        _ = try fixture.createCrossOver(named: "CrossOver 25.app", version: "25.1")
        _ = try fixture.createCrossOver(named: "CrossOver.app", version: "26.3")
        try fixture.createSteamBottle()
        let regressionApp = try fixture.createRegressionApp()
        let runner = StubDiscoveryRunner(result: ProcessResult(
            exitCode: 0,
            standardOutput: "status=uptodate",
            standardError: ""
        ))
        let discovery = InstallationDiscovery(
            runner: runner,
            homeDirectoryURL: fixture.home,
            applicationRoots: [fixture.applications],
            regressionComponentHealthProvider: { _ in readyRuntimeReport() }
        )

        let snapshot = await discovery.discover(regressionApplicationURL: regressionApp)

        XCTAssertNil(snapshot.crossOver)
        XCTAssertNil(snapshot.crossOverIssue)
        XCTAssertEqual(snapshot.regression.health, .ready)
        let invocationCount = await runner.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testDiscoveryFailsClosedWhenSealedRuntimeAuthorityIsUnavailable() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let regressionApp = try fixture.createRegressionApp()
        let discovery = InstallationDiscovery(
            runner: StubDiscoveryRunner(),
            homeDirectoryURL: fixture.home
        )

        let snapshot = await discovery.discover(regressionApplicationURL: regressionApp)

        XCTAssertEqual(snapshot.regression.health, .damaged)
        XCTAssertTrue(snapshot.regression.healthDetail.contains("runtime sellado"))
    }

    func testDiscoveryRejectsReadyReportFromStaleRuntimeContract() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let regressionApp = try fixture.createRegressionApp()
        let discovery = InstallationDiscovery(
            runner: StubDiscoveryRunner(),
            homeDirectoryURL: fixture.home,
            regressionComponentHealthProvider: { _ in staleReadyRuntimeReport() }
        )

        let snapshot = await discovery.discover(regressionApplicationURL: regressionApp)

        XCTAssertEqual(snapshot.regression.health, .damaged)
    }

    func testDiscoveryExplainsMissingCrossOverAndKeepsRegressionHealth() async throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        let regressionApp = try fixture.createRegressionApp(includeSteam: false)
        let discovery = InstallationDiscovery(
            runner: StubDiscoveryRunner(),
            homeDirectoryURL: fixture.home,
            applicationRoots: [fixture.applications]
        )

        let snapshot = await discovery.discover(regressionApplicationURL: regressionApp)

        XCTAssertNil(snapshot.crossOver)
        XCTAssertNil(snapshot.crossOverIssue)
        XCTAssertEqual(snapshot.regression.health, .missing)
    }
}

private func readyRuntimeReport() -> ComponentHealthReport {
    ComponentHealthReport(
        identity: ComponentIdentity(
            componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
            componentVersion: TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion,
            variant: .publicInstalled,
            buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
        ),
        status: .ready,
        recovery: .none
    )
}

private func staleReadyRuntimeReport() -> ComponentHealthReport {
    ComponentHealthReport(
        identity: ComponentIdentity(
            componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
            componentVersion: "1",
            variant: .publicInstalled,
            buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
        ),
        status: .ready,
        recovery: .none
    )
}

private actor StubDiscoveryRunner: ProcessRunning {
    private let result: ProcessResult
    private var count = 0

    init(result: ProcessResult = ProcessResult(
        exitCode: 0,
        standardOutput: "",
        standardError: ""
    )) {
        self.result = result
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?
    ) async throws -> ProcessResult {
        count += 1
        return result
    }

    func invocationCount() -> Int {
        count
    }
}

private final class DiscoveryFixture {
    let root: URL
    let home: URL
    let applications: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-discovery-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("Home", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    }

    func createCrossOver(named name: String, version: String) throws -> URL {
        let application = applications.appendingPathComponent(name, isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        let tools = contents.appendingPathComponent(
            "SharedSupport/CrossOver/bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        try writeExecutable(to: tools.appendingPathComponent("wine"))
        try writeExecutable(to: tools.appendingPathComponent("cxbottle"))
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.codeweavers.CrossOver",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "test",
            "SUFeedURL": "https://www.codeweavers.com/xml/versions/cxmac.xml",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return application
    }

    func createSteamBottle() throws {
        let bottle = home.appendingPathComponent(
            "Library/Application Support/CrossOver/Bottles/Steam",
            isDirectory: true
        )
        let steam = bottle.appendingPathComponent(
            "drive_c/Program Files (x86)/Steam/steam.exe"
        )
        try FileManager.default.createDirectory(
            at: steam.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: steam.path, contents: Data()))
        try Data(#"""
        "CX_GRAPHICS_BACKEND" = "d3dmetal"
        """#.utf8).write(to: bottle.appendingPathComponent("cxbottle.conf"))
    }

    func createRegressionApp(includeSteam: Bool = true) throws -> URL {
        let application = root.appendingPathComponent("Regression.app", isDirectory: true)
        let launcher = application.appendingPathComponent("Contents/MacOS/regression-engine")
        try FileManager.default.createDirectory(
            at: launcher.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeExecutable(to: launcher)
        if includeSteam {
            let steam = home.appendingPathComponent(
                "Library/Application Support/Regression/Bottles/Steam/drive_c/Program Files (x86)/Steam/Steam.exe"
            )
            try FileManager.default.createDirectory(
                at: steam.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: steam.path, contents: Data()))
        }
        return application
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeExecutable(to url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8)
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
