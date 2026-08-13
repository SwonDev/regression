import Foundation
@testable import RegressionCore
import XCTest

final class ProcessLauncherTests: XCTestCase {
    func testRegressionLaunchWithoutSealedAuthorityFailsClosed() async throws {
        let launcher = ProcessLauncher()
        do {
            _ = try await launcher.launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                logDirectoryURL: FileManager.default.temporaryDirectory
            )
            XCTFail("ProcessLauncher no debe aceptar Regression sin autoridad sellada")
        } catch RegressionCoreError.unsafeLibraryState {
            // esperado
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testAuthorityRevalidatesLegacyActivationInLastBoundaryBeforeProcessRun() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("regression-launch-boundary-\(UUID().uuidString)", isDirectory: true)
        let bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        let activationDirectory = bottle.appendingPathComponent(".regression", isDirectory: true)
        let logDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        let spawnedMarker = root.appendingPathComponent("spawned")
        try FileManager.default.createDirectory(
            at: activationDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyActivation = activationDirectory
            .appendingPathComponent("compiled-repair-activations-v1.tsv")
        let injector = LastBoundaryLegacyActivationInjector(url: legacyActivation)
        let launcher = ProcessLauncher(immediatelyBeforeProcessRun: {
            injector.install()
        })
        let installation = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app", isDirectory: true),
            bottleURL: bottle,
            steamExecutableURL: bottle.appendingPathComponent("Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/usr/bin/touch"),
            health: .ready,
            healthDetail: "ok"
        )
        let authority = ProcessLaunchAuthority(
            regressionInstallation: installation,
            custodyPermit: nil,
            regressionComponentHealthProvider: { _ in
                ComponentHealthReport(
                    identity: ComponentIdentity(
                        componentID: TrustedComponentCatalog
                            .steamRuntimePrerequisitesComponentID,
                        componentVersion: TrustedComponentCatalog
                            .steamRuntimePrerequisitesComponentVersion,
                        variant: .development,
                        buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
                    ),
                    status: .ready,
                    recovery: .none
                )
            }
        )

        do {
            _ = try await launcher.launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: logDirectory,
                authority: authority
            )
            XCTFail("La activación v1 creada en el último boundary debía bloquear el spawn")
        } catch RegressionCoreError.unsafeLibraryState {
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyActivation.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawnedMarker.path))
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testAuthorityRevalidatesComponentHealthInLastBoundaryBeforeProcessRun() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("regression-component-boundary-\(UUID().uuidString)", isDirectory: true)
        let bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        let logDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        let spawnedMarker = root.appendingPathComponent("spawned")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let health = LastBoundaryComponentHealth()
        let launcher = ProcessLauncher(immediatelyBeforeProcessRun: {
            health.markDrifted()
        })
        let installation = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app", isDirectory: true),
            bottleURL: bottle,
            steamExecutableURL: bottle.appendingPathComponent("Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/usr/bin/touch"),
            health: .ready,
            healthDetail: "ok"
        )
        let authority = ProcessLaunchAuthority(
            regressionInstallation: installation,
            custodyPermit: nil,
            regressionComponentHealthProvider: { _ in health.report() }
        )

        do {
            _ = try await launcher.launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: logDirectory,
                authority: authority
            )
            XCTFail("El drift de ComponentHealth en el último boundary debía bloquear el spawn")
        } catch RegressionCoreError.unsafeLibraryState {
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawnedMarker.path))
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

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
            backend: .crossOver,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            logDirectoryURL: directory
        )
        try await Task.sleep(for: .milliseconds(50))
        await launcher.reapFinishedProcesses()
        let second = try await launcher.launch(
            backend: .crossOver,
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
            backend: .crossOver,
            executableURL: executable,
            arguments: arguments,
            logDirectoryURL: directory
        )
        let second = try await launcher.launch(
            backend: .crossOver,
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
            backend: .crossOver,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            logDirectoryURL: directory
        )

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.filter { $0.lastPathComponent.hasPrefix("regression-") }.count, 19)
        XCTAssertEqual(files.filter { $0.lastPathComponent.hasPrefix("crossOver-") }.count, 1)
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

private final class LastBoundaryLegacyActivationInjector: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var installed = false

    init(url: URL) {
        self.url = url
    }

    func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !installed else { return }
        installed = true
        try? Data("REGRESSION-COMPILED-REPAIRS\t1\n".utf8).write(to: url)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private final class LastBoundaryComponentHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var status = ComponentHealthStatus.ready

    func markDrifted() {
        lock.lock()
        status = .drifted
        lock.unlock()
    }

    func report() -> ComponentHealthReport {
        lock.lock()
        defer { lock.unlock() }
        return ComponentHealthReport(
            identity: ComponentIdentity(
                componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
                componentVersion: TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion,
                variant: .development,
                buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
            ),
            status: status,
            recovery: status == .ready ? .none : .reinstallTrustedArtifact
        )
    }
}
