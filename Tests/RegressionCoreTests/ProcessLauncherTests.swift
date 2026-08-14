import CryptoKit
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

    func testDurableSpawnMarkerCompletesBeforeRegressionProcessRuns() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("regression-durable-spawn-\(UUID().uuidString)", isDirectory: true)
        let bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        let logDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        let durableMarker = root.appendingPathComponent("durable-marker")
        let spawnedMarker = root.appendingPathComponent("spawned")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app", isDirectory: true),
            bottleURL: bottle,
            steamExecutableURL: bottle.appendingPathComponent("Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/bin/sh"),
            health: .ready,
            healthDetail: "ok"
        )
        let authority = ProcessLaunchAuthority(
            regressionInstallation: installation,
            custodyPermit: nil,
            normalizedAppID: "219990",
            regressionComponentHealthProvider: { _ in
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
            },
            rendererLaunchValidator: { _, _ in },
            gameLaunchAuthority: .testing(appID: "219990") {
                try Data("durable".utf8).write(to: durableMarker, options: .atomic)
            }
        )

        _ = try await ProcessLauncher().launch(
            backend: .regression,
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test -f \(durableMarker.path) && touch \(spawnedMarker.path)"],
            logDirectoryURL: logDirectory,
            authority: authority
        )

        // `Process.run()` has returned, but the shell itself proves that the durable marker was
        // committed before it received control. No post-spawn actor hop can satisfy this test.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(FileManager.default.fileExists(atPath: durableMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: spawnedMarker.path))
    }

    func testAuthorityForOneAppIDRejectsAnotherBeforeAnyProcessSpawns() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("regression-appid-authority-\(UUID().uuidString)", isDirectory: true)
        let bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        let spawnedMarker = root.appendingPathComponent("spawned")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
            normalizedAppID: "1154030",
            regressionComponentHealthProvider: { _ in
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
            },
            rendererLaunchValidator: { _, _ in },
            gameLaunchAuthority: .testing(appID: "219990")
        )

        do {
            _ = try await ProcessLauncher().launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: root.appendingPathComponent("Logs", isDirectory: true),
                authority: authority
            )
            XCTFail("La autoridad de 219990 no puede lanzar 1154030")
        } catch {
            // esperado: el App ID sellado y el App ID del proceso no coinciden.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: spawnedMarker.path))
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
            normalizedAppID: nil,
            regressionComponentHealthProvider: { _ in
                ComponentHealthReport(
                    identity: ComponentIdentity(
                        componentID: TrustedComponentCatalog
                            .steamRuntimePrerequisitesComponentID,
                        componentVersion: TrustedComponentCatalog
                            .steamRuntimePrerequisitesComponentVersion,
                        variant: .publicInstalled,
                        buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
                    ),
                    status: .ready,
                    recovery: .none
                )
            },
            rendererLaunchValidator: { _, _ in }
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
            normalizedAppID: nil,
            regressionComponentHealthProvider: { _ in health.report() },
            rendererLaunchValidator: { _, _ in }
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

    func testAuthorityRevalidatesRendererForNormalizedAppIDAtLastSpawnBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("regression-renderer-boundary-\(UUID().uuidString)", isDirectory: true)
        let bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        let logDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        let spawnedMarker = root.appendingPathComponent("spawned")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app", isDirectory: true),
            bottleURL: bottle,
            steamExecutableURL: bottle.appendingPathComponent("Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/usr/bin/touch"),
            health: .ready,
            healthDetail: "ok"
        )
        let componentHealth = LastBoundaryComponentHealth()
        let authority = ProcessLaunchAuthority(
            regressionInstallation: installation,
            custodyPermit: nil,
            normalizedAppID: "219990",
            regressionComponentHealthProvider: { _ in componentHealth.report() },
            rendererLaunchValidator: { observedInstallation, appID in
                guard observedInstallation.applicationURL == installation.applicationURL,
                      appID == "219990" else {
                    throw RegressionCoreError.launchFailed(
                        "El boundary no conservó la instalación y el App ID normalizado"
                    )
                }
                throw RegressionCoreError.unsafeLibraryState(
                    "El renderer dejó de ser elegible inmediatamente antes del spawn"
                )
            },
            gameLaunchAuthority: .testing(appID: "1154030")
        )

        do {
            _ = try await ProcessLauncher().launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: logDirectory,
                authority: authority
            )
            XCTFail("La inelegibilidad del renderer debía bloquear el spawn")
        } catch RegressionCoreError.unsafeLibraryState {
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawnedMarker.path))
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testRendererAnchoredRevalidationRejectsIdentitySubstitutionBeforeSpawn() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("regression-renderer-identity-\(UUID().uuidString)", isDirectory: true)
        let application = root.appendingPathComponent("Regression.app", isDirectory: true)
        let bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        let bottleSystem32 = bottle.appendingPathComponent(
            "drive_c/windows/system32",
            isDirectory: true
        )
        let wineWindows64 = application.appendingPathComponent(
            "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows",
            isDirectory: true
        )
        let logDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        let spawnedMarker = root.appendingPathComponent("spawned")
        for directory in [bottleSystem32, wineWindows64] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for fileName in ["d3d10core.dll", "d3d11.dll", "dxgi.dll"] {
                try Data("sealed-renderer".utf8).write(
                    to: directory.appendingPathComponent(fileName)
                )
            }
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = RegressionInstallation(
            applicationURL: application,
            bottleURL: bottle,
            steamExecutableURL: bottle.appendingPathComponent("Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/usr/bin/touch"),
            health: .ready,
            healthDetail: "ok"
        )
        let substitution = LastBoundaryRendererIdentitySubstitution()
        let expectedHash = SHA256.hash(data: Data("sealed-renderer".utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let inspector = RendererCapabilityInspector(
            applicationSupportURL: root.appendingPathComponent("Application Support"),
            moduleHealth: { descriptor, _, anchored in
                guard let digest = try? anchored.hashRegularFile(
                    relativePath: descriptor.fileName,
                    maximumBytes: 1_024
                ) else { return false }
                return digest.sha256 == expectedHash
            },
            afterSnapshotRootOpened: { moduleRoot in
                substitution.replaceOnce(root: moduleRoot)
            }
        )
        let health = LastBoundaryComponentHealth()
        let authority = ProcessLaunchAuthority(
            regressionInstallation: installation,
            custodyPermit: nil,
            normalizedAppID: nil,
            regressionComponentHealthProvider: { _ in health.report() },
            rendererLaunchValidator: { observedInstallation, appID in
                try RendererLaunchGate.validate(
                    installation: observedInstallation,
                    appID: appID,
                    inspector: inspector
                )
            }
        )

        do {
            _ = try await ProcessLauncher().launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: logDirectory,
                authority: authority
            )
            XCTFail("La sustitución de identidad debía bloquear el spawn")
        } catch RegressionCoreError.rendererIneligible(let reasons) {
            XCTAssertTrue(reasons.contains { reason in
                if case .incompleteRoute(.dxmt, _) = reason { return true }
                return false
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawnedMarker.path))
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testRendererRejectsGPTKDLLInPlaceABABeforeSpawn() async throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: true)
        let mutation = RendererInPlaceABAMutation(
            file: fixture.gptkComponentURL(.version4Beta2).appendingPathComponent(
                "wine/x86_64-windows/d3d11.dll"
            ),
            restoredData: Data("module".utf8)
        )
        let inspector = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in
                mutation.mutateOnce()
                return true
            },
            moduleHealth: trustedFixtureModule
        )
        let health = LastBoundaryComponentHealth()
        let authority = ProcessLaunchAuthority(
            regressionInstallation: fixture.installation,
            custodyPermit: nil,
            normalizedAppID: "1154030",
            regressionComponentHealthProvider: { _ in health.report() },
            rendererLaunchValidator: { installation, appID in
                try RendererLaunchGate.validate(
                    installation: installation,
                    appID: appID,
                    inspector: inspector
                )
            },
            gameLaunchAuthority: .testing(appID: "1154030")
        )
        let spawnedMarker = fixture.root.appendingPathComponent("spawned")

        do {
            _ = try await ProcessLauncher().launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: fixture.root.appendingPathComponent("Logs", isDirectory: true),
                authority: authority
            )
            XCTFail("El ABA in-place de la DLL GPTK debía bloquear el spawn")
        } catch RegressionCoreError.rendererIneligible(let reasons) {
            XCTAssertTrue(mutation.preservedInode)
            XCTAssertTrue(reasons.contains(
                .appleGPTKAuthorityUnavailable(
                    requiredVersion: .version4Beta2,
                    observedVersion: nil
                )
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawnedMarker.path))
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testRendererRejectsGPTKWindowsSubdirectorySubstitutionBeforeSpawn() async throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: true)
        let substitution = RendererComponentIdentitySubstitution(
            root: fixture.gptkComponentURL(.version4Beta2).appendingPathComponent(
                "wine/x86_64-windows",
                isDirectory: true
            )
        )
        let inspector = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in
                substitution.replaceOnce()
                return true
            },
            moduleHealth: trustedFixtureModule
        )
        let health = LastBoundaryComponentHealth()
        let authority = ProcessLaunchAuthority(
            regressionInstallation: fixture.installation,
            custodyPermit: nil,
            normalizedAppID: "1154030",
            regressionComponentHealthProvider: { _ in health.report() },
            rendererLaunchValidator: { installation, appID in
                try RendererLaunchGate.validate(
                    installation: installation,
                    appID: appID,
                    inspector: inspector
                )
            },
            gameLaunchAuthority: .testing(appID: "1154030")
        )
        let spawnedMarker = fixture.root.appendingPathComponent("spawned")

        do {
            _ = try await ProcessLauncher().launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: fixture.root.appendingPathComponent("Logs", isDirectory: true),
                authority: authority
            )
            XCTFail("La sustitución de x86_64-windows GPTK debía bloquear el spawn")
        } catch RegressionCoreError.rendererIneligible(let reasons) {
            XCTAssertTrue(reasons.contains(
                .appleGPTKAuthorityUnavailable(
                    requiredVersion: .version4Beta2,
                    observedVersion: nil
                )
            ))
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawnedMarker.path))
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testRendererRejectsDXMTDLLInPlaceABABeforeSpawn() async throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        let mutation = RendererInPlaceABAMutation(
            file: fixture.bottleSystem32.appendingPathComponent("d3d11.dll"),
            restoredData: Data("observed".utf8)
        )
        let inspector = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            moduleHealth: { descriptor, location, root in
                let accepted = trustedFixtureModule(
                    descriptor: descriptor,
                    location: location,
                    root: root
                )
                if descriptor.id == "dxmt.dxgi", location == .wineRootWindows64 {
                    mutation.mutateOnce()
                }
                return accepted
            }
        )
        let health = LastBoundaryComponentHealth()
        let authority = ProcessLaunchAuthority(
            regressionInstallation: fixture.installation,
            custodyPermit: nil,
            normalizedAppID: nil,
            regressionComponentHealthProvider: { _ in health.report() },
            rendererLaunchValidator: { installation, appID in
                try RendererLaunchGate.validate(
                    installation: installation,
                    appID: appID,
                    inspector: inspector
                )
            }
        )
        let spawnedMarker = fixture.root.appendingPathComponent("spawned")

        do {
            _ = try await ProcessLauncher().launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: fixture.root.appendingPathComponent("Logs", isDirectory: true),
                authority: authority
            )
            XCTFail("El ABA in-place de la DLL DXMT debía bloquear el spawn")
        } catch RegressionCoreError.rendererIneligible(let reasons) {
            XCTAssertTrue(mutation.preservedInode)
            XCTAssertTrue(reasons.contains { reason in
                if case .incompleteRoute(.dxmt, _) = reason { return true }
                return false
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: spawnedMarker.path))
        } catch {
            XCTFail("Error inesperado: \(error)")
        }
    }

    func testAuthorityRejectsExecutableModeDriftAtLastSpawnBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("regression-mode-boundary-\(UUID().uuidString)", isDirectory: true)
        let bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        let runtimeRoot = root.appendingPathComponent("wine-root", isDirectory: true)
        let loader = runtimeRoot.appendingPathComponent(
            "lib/wine/x86_64-unix/wine"
        )
        let logDirectory = root.appendingPathComponent("Logs", isDirectory: true)
        let spawnedMarker = root.appendingPathComponent("spawned")
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: loader.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let loaderData = Data("sealed-loader".utf8)
        try loaderData.write(to: loader)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: loader.path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = ProcessLauncher(immediatelyBeforeProcessRun: {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: loader.path
            )
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
            normalizedAppID: nil,
            regressionComponentHealthProvider: { _ in
                ComponentHealthService.evaluate(
                    TrustedComponentFileSetDescriptor(
                        identity: ComponentIdentity(
                            componentID: TrustedComponentCatalog
                                .steamRuntimePrerequisitesComponentID,
                            componentVersion: TrustedComponentCatalog
                                .steamRuntimePrerequisitesComponentVersion,
                            variant: .publicInstalled,
                            buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
                        ),
                        payloadRootURL: runtimeRoot,
                        files: [
                            TrustedComponentFile(
                                relativePath: "lib/wine/x86_64-unix/wine",
                                expectedSHA256: SHA256.hash(data: loaderData).map {
                                    String(format: "%02x", $0)
                                }.joined(),
                                expectedPOSIXMode: 0o755
                            )
                        ],
                        maximumFileBytes: 1_024,
                        maximumPayloadBytes: 1_024
                    )
                )
            },
            rendererLaunchValidator: { _, _ in }
        )

        do {
            _ = try await launcher.launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
                arguments: [spawnedMarker.path],
                logDirectoryURL: logDirectory,
                authority: authority
            )
            XCTFail("El chmod hostil aparecido en el último boundary debía bloquear el spawn")
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

    func testIdenticalActiveGameLaunchRejectsBeforeConsumingSecondAuthority() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-game-dedup-\(UUID().uuidString)", isDirectory: true)
        let bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let installation = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app", isDirectory: true),
            bottleURL: bottle,
            steamExecutableURL: bottle.appendingPathComponent("Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/bin/sh"),
            health: .ready,
            healthDetail: "ok"
        )
        let health = LastBoundaryComponentHealth()
        func authority(_ marker: @escaping @Sendable () async throws -> Void) -> ProcessLaunchAuthority {
            ProcessLaunchAuthority(
                regressionInstallation: installation,
                custodyPermit: nil,
                normalizedAppID: "219990",
                regressionComponentHealthProvider: { _ in health.report() },
                rendererLaunchValidator: { _, _ in },
            gameLaunchAuthority: .testing(appID: "219990", markImmediatelyBeforeSpawn: marker)
            )
        }
        let launcher = ProcessLauncher()
        let executable = URL(fileURLWithPath: "/bin/sh")
        let arguments = ["-c", "sleep 0.4"]
        _ = try await launcher.launch(
            backend: .regression, executableURL: executable, arguments: arguments,
            logDirectoryURL: root, authority: authority({})
        )
        let secondMarker = root.appendingPathComponent("second-marker")
        do {
            _ = try await launcher.launch(
                backend: .regression, executableURL: executable, arguments: arguments,
                logDirectoryURL: root,
                authority: authority { try Data("used".utf8).write(to: secondMarker) }
            )
            XCTFail("Un juego no puede deduplicarse contra un proceso activo")
        } catch {
            // esperado
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondMarker.path))
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
    private var issue: ComponentHealthIssue?

    func markDrifted() {
        markDrifted(issue: nil)
    }

    func markDrifted(issue: ComponentHealthIssue?) {
        lock.lock()
        status = .drifted
        self.issue = issue
        lock.unlock()
    }

    func report() -> ComponentHealthReport {
        lock.lock()
        defer { lock.unlock() }
        return ComponentHealthReport(
            identity: ComponentIdentity(
                componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
                componentVersion: TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion,
                variant: .publicInstalled,
                buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
            ),
            status: status,
            recovery: status == .ready ? .none : .reinstallTrustedArtifact,
            issue: issue
        )
    }
}

private final class LastBoundaryRendererIdentitySubstitution: @unchecked Sendable {
    private let lock = NSLock()
    private var replaced = false

    func replaceOnce(root: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !replaced else { return }
        replaced = true
        let previous = root.deletingLastPathComponent().appendingPathComponent(
            "\(root.lastPathComponent)-before-identity-substitution",
            isDirectory: true
        )
        do {
            try FileManager.default.moveItem(at: root, to: previous)
            try FileManager.default.copyItem(at: previous, to: root)
        } catch {
            XCTFail("No se pudo sustituir la identidad anclada: \(error)")
        }
    }
}
