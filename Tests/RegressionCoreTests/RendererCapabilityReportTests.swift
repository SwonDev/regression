import CryptoKit
@testable import RegressionCore
import XCTest

final class RendererCapabilityReportTests: XCTestCase {
    func testInspectorRejectsDXMTFilesWithUntrustedBytes() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport
        ).inspect(installation: fixture.installation, appID: nil)

        XCTAssertTrue(report.ineligibilityReasons.contains { reason in
            if case .incompleteRoute(.dxmt, _) = reason { return true }
            return false
        })
    }

    func testInspectorRejectsDXMTDLLInPlaceABAAfterHashing() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        let mutation = RendererInPlaceABAMutation(
            file: fixture.bottleSystem32.appendingPathComponent("d3d11.dll"),
            restoredData: Data("observed".utf8)
        )

        let report = RendererCapabilityInspector(
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
        ).inspect(installation: fixture.installation, appID: nil)

        XCTAssertTrue(mutation.preservedInode)
        XCTAssertTrue(report.ineligibilityReasons.contains { reason in
            if case .incompleteRoute(.dxmt, _) = reason { return true }
            return false
        })
    }

    func testInspectorAcceptsDXMTFilesMatchingCompiledAuthority() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            moduleHealth: { descriptor, location, root in
                RuntimeModuleCatalog.expectedSHA256(moduleID: descriptor.id, location: location) != nil
                    && (try? root.readRegularFile(
                        relativePath: descriptor.fileName,
                        maximumBytes: 1_024
                    )) == Data("observed".utf8)
            }
        ).inspect(installation: fixture.installation, appID: nil)

        XCTAssertEqual(report.resolution, .effective(.dxmt))
    }

    func testInspectorRejectsDXVKFileWithUntrustedBytes() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installDXVK()

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport
        ).inspect(installation: fixture.installation, appID: nil)

        XCTAssertTrue(report.ineligibilityReasons.contains { reason in
            if case .incompleteRoute(.dxmt, _) = reason { return true }
            return false
        })
    }

    func testInspectorAcceptsDXVKFileMatchingCompiledAuthority() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installDXVK()

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            moduleHealth: { descriptor, location, root in
                RuntimeModuleCatalog.expectedSHA256(moduleID: descriptor.id, location: location) != nil
                    && (try? root.readRegularFile(
                        relativePath: descriptor.fileName,
                        maximumBytes: 1_024
                    )) == Data("observed".utf8)
            }
        ).inspect(installation: fixture.installation, appID: nil)

        XCTAssertTrue(report.ineligibilityReasons.contains { reason in
            if case .incompleteRoute(.dxmt, _) = reason { return true }
            return false
        })
    }

    func testInspectorRejectsInvalidGPTKReceipt() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: false)

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in true },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertEqual(
            report.resolution,
            .ineligible(
                reasons: [
                    .appleGPTKAuthorityUnavailable(
                        requiredVersion: .version4Beta2,
                        observedVersion: nil
                    )
                ]
            )
        )
    }

    func testInspectorAcceptsValidGPTK3ForLegacyProfile() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version3, validReceipt: true)

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { version, _ in version == .version3 },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "219990")

        XCTAssertEqual(report.resolution, .effective(.d3dmetal))
    }

    func testInspectorAcceptsValidGPTK4ForDeclaredProfile() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: true)

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { version, _ in version == .version4Beta2 },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertEqual(report.resolution, .effective(.d3dmetal))
    }

    func testInspectorRejectsGPTK4UnixSymlinkEscapingComponent() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(
            version: .version4Beta2,
            validReceipt: true,
            hostileUnixLink: true
        )

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in true },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertEqual(
            report.resolution,
            .ineligible(reasons: [.appleGPTKAuthorityUnavailable(
                requiredVersion: .version4Beta2,
                observedVersion: nil
            )])
        )
    }

    func testInspectorRejectsGPTK4WithSeventhUnixEntry() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: true)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.gptkUnixURL.appendingPathComponent("extra.so").path,
            withDestinationPath: "../../external/libd3dshared.dylib"
        )

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in true },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertEqual(
            report.resolution,
            .ineligible(reasons: [.appleGPTKAuthorityUnavailable(
                requiredVersion: .version4Beta2,
                observedVersion: nil
            )])
        )
    }

    func testInspectorRejectsExactGPTKComponentIdentitySubstitutionAfterModuleHashing() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: true)
        let substitution = RendererComponentIdentitySubstitution(
            root: fixture.gptkComponentURL(.version4Beta2)
        )

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in
                substitution.replaceOnce()
                return true
            },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertTrue(report.ineligibilityReasons.contains { reason in
            if case .incompleteRoute(.d3dmetal, _) = reason { return true }
            return false
        })
        XCTAssertTrue(report.ineligibilityReasons.contains(
            .appleGPTKAuthorityUnavailable(
                requiredVersion: .version4Beta2,
                observedVersion: nil
            )
        ))
    }

    func testInspectorRejectsGPTKWindowsSubdirectoryIdentitySubstitutionAfterHashing() throws {
        try assertGPTKSubdirectoryIdentitySubstitutionIsRejected(
            relativePath: "wine/x86_64-windows"
        )
    }

    func testInspectorRejectsGPTKDLLInPlaceABAAfterHashing() throws {
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

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in
                mutation.mutateOnce()
                return true
            },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertTrue(mutation.preservedInode)
        XCTAssertNil(report.effectiveRoute)
        XCTAssertTrue(report.ineligibilityReasons.contains(
            .appleGPTKAuthorityUnavailable(
                requiredVersion: .version4Beta2,
                observedVersion: nil
            )
        ))
    }

    func testInspectorRejectsGPTKUnixSubdirectoryIdentitySubstitutionAfterHashing() throws {
        try assertGPTKSubdirectoryIdentitySubstitutionIsRejected(
            relativePath: "wine/x86_64-unix"
        )
    }

    func testInspectorRejectsGPTKUnixEntryIdentitySubstitutionAfterTopology() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: true)
        let substitution = RendererComponentIdentitySubstitution(
            root: fixture.gptkUnixURL.appendingPathComponent("d3d11.so")
        )

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in true },
            moduleHealth: trustedFixtureModule,
            afterGPTKTopologyCaptured: {
                substitution.replaceOnce()
            }
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertNil(report.effectiveRoute)
        XCTAssertTrue(report.ineligibilityReasons.contains(
            .appleGPTKAuthorityUnavailable(
                requiredVersion: .version4Beta2,
                observedVersion: nil
            )
        ))
    }

    func testInspectorRejectsExactReceiptRootIdentitySubstitution() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: true)
        let substitution = RendererComponentIdentitySubstitution(
            root: fixture.gptkReceiptRoot
        )

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in
                substitution.replaceOnce()
                return true
            },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertEqual(
            report.resolution,
            .ineligible(reasons: [.appleGPTKAuthorityUnavailable(
                requiredVersion: .version4Beta2,
                observedVersion: nil
            )])
        )
    }

    func testInspectorRejectsRendererBelowHostileSymlinkAncestor() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installDXVK()
        let physicalBottle = fixture.root.appendingPathComponent("PhysicalBottle", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.bottle, to: physicalBottle)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.bottle.path,
            withDestinationPath: physicalBottle.path
        )

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            moduleHealth: { descriptor, location, root in
                RuntimeModuleCatalog.expectedSHA256(moduleID: descriptor.id, location: location) != nil
                    && (try? root.readRegularFile(
                        relativePath: descriptor.fileName,
                        maximumBytes: 1_024
                    )) == Data("observed".utf8)
            }
        ).inspect(installation: fixture.installation, appID: nil)

        XCTAssertTrue(report.ineligibilityReasons.contains { reason in
            if case .incompleteRoute(.dxmt, _) = reason { return true }
            return false
        })
    }

    func testRendererLaunchGateFailsClosedForIncompleteFilesystemObservation() throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try RendererLaunchGate.validate(
                installation: fixture.installation,
                appID: nil,
                inspector: RendererCapabilityInspector(
                    applicationSupportURL: fixture.applicationSupport
                )
            )
        ) { error in
            guard case RegressionCoreError.rendererIneligible(let reasons) = error,
                  reasons.count == 1,
                  case .incompleteRoute(.dxmt, let missing) = reasons[0],
                  missing.count == 6 else {
                return XCTFail("Se esperaba rendererIneligible tipado y se recibió \(error)")
            }
        }
    }

    func testActiveRoutesAreDerivedFromModulesInsteadOfCallerDeclaration() {
        let observation = RendererCapabilityObservation(
            modules: completeDXMTModules
        )

        XCTAssertEqual(observation.activeRoutes, [.dxmt])
        XCTAssertEqual(
            RendererCapabilityReport.evaluate(observation).resolution,
            .effective(.dxmt)
        )
    }

    func testCompleteDXMTPairResolvesExactlyOneEffectiveRoute() {
        let report = RendererCapabilityReport.evaluate(
            RendererCapabilityObservation(
                modules: completeDXMTModules
            )
        )

        XCTAssertEqual(report.resolution, .effective(.dxmt))
        XCTAssertEqual(report.effectiveRoute, .dxmt)
        XCTAssertTrue(report.ineligibilityReasons.isEmpty)
    }

    func testIncompleteDXMTPairIsIneligibleWithTypedMissingRequirement() {
        let report = RendererCapabilityReport.evaluate(
            RendererCapabilityObservation(
                modules: [
                    .init(moduleID: "dxmt.d3d10core", location: .bottleSystem32),
                    .init(moduleID: "dxmt.d3d10core", location: .wineRootWindows64),
                    .init(moduleID: "dxmt.d3d11", location: .bottleSystem32),
                    .init(moduleID: "dxmt.d3d11", location: .wineRootWindows64),
                    .init(moduleID: "dxmt.dxgi", location: .bottleSystem32),
                ]
            )
        )

        XCTAssertEqual(
            report.resolution,
            .ineligible(
                reasons: [
                    .incompleteRoute(
                        .dxmt,
                        missing: [
                            .init(moduleID: "dxmt.dxgi", location: .wineRootWindows64)
                        ]
                    )
                ]
            )
        )
        XCTAssertNil(report.effectiveRoute)
    }

    func testInstalledDXVKDoesNotConflictWithAuthorizedD3DMetalProfile() {
        let observation = RendererCapabilityObservation(
            modules: completeDXMTModules.union([
                    .init(moduleID: "dxvk.d3d9", location: .bottleSystem32),
                    .init(
                        moduleID: "apple-gptk.d3dmetal",
                        location: .localUserComponent(
                            relativePath: "AppleGPTK/4.0b2/external/D3DMetal.framework/Versions/A/D3DMetal"
                        )
                    ),
                    .init(
                        moduleID: "apple-gptk.libd3dshared",
                        location: .localUserComponent(
                            relativePath: "AppleGPTK/4.0b2/external/libd3dshared.dylib"
                        )
                    ),
                    .init(moduleID: "apple-gptk.d3d10", location: gptkWine("d3d10.dll")),
                    .init(moduleID: "apple-gptk.d3d11", location: gptkWine("d3d11.dll")),
                    .init(moduleID: "apple-gptk.d3d12", location: gptkWine("d3d12.dll")),
                    .init(moduleID: "apple-gptk.dxgi", location: gptkWine("dxgi.dll")),
                    .init(moduleID: "apple-gptk.nvapi64", location: gptkWine("nvapi64.dll")),
                    .init(moduleID: "apple-gptk.nvngx", location: gptkWine("nvngx.dll")),
                ]),
                profileGraphicsBackend: .d3dmetal,
                requiredAppleGPTKVersion: .version4Beta2,
            authorizedAppleGPTKVersion: .version4Beta2
        )
        let report = RendererCapabilityReport.evaluate(observation)

        XCTAssertEqual(observation.activeRoutes, [.d3dmetal])
        XCTAssertEqual(report.resolution, .effective(.d3dmetal))
    }

    func testDXVKProfileRequiresAndPreservesCompleteSteamDXMTBaseline() {
        let report = RendererCapabilityReport.evaluate(
            RendererCapabilityObservation(
                modules: completeDXMTModules.union([
                    .init(moduleID: "dxvk.d3d9", location: .bottleSystem32),
                ]),
                profileGraphicsBackend: .dxvk
            )
        )

        XCTAssertEqual(report.resolution, .effective(.dxvk))
        XCTAssertEqual(report.effectiveRoute, .dxvk)
    }

    func testD3DMetalProfileWithoutGPTKAuthorityIsIneligible() {
        let report = RendererCapabilityReport.evaluate(
            RendererCapabilityObservation(
                modules: completeGPTKModules,
                profileGraphicsBackend: .d3dmetal,
                requiredAppleGPTKVersion: .version4Beta2
            )
        )

        XCTAssertEqual(
            report.resolution,
            .ineligible(
                reasons: [
                    .appleGPTKAuthorityUnavailable(
                        requiredVersion: .version4Beta2,
                        observedVersion: nil
                    )
                ]
            )
        )
        XCTAssertNil(report.effectiveRoute)
    }

    func testD3DMetalProfileCannotReplaceMissingSteamDXMTBaseline() {
        let report = RendererCapabilityReport.evaluate(
            RendererCapabilityObservation(
                modules: completeGPTKModules.filter { observation in
                    if case .localUserComponent = observation.location { return true }
                    return false
                },
                profileGraphicsBackend: .d3dmetal,
                requiredAppleGPTKVersion: .version4Beta2,
                authorizedAppleGPTKVersion: .version4Beta2
            )
        )

        XCTAssertTrue(report.ineligibilityReasons.contains { reason in
            if case .incompleteRoute(.dxmt, _) = reason { return true }
            return false
        })
        XCTAssertNil(report.effectiveRoute)
    }

    func testValidD3DMetalProfileResolvesExactlyOneEffectiveRoute() {
        let report = RendererCapabilityReport.evaluate(
            RendererCapabilityObservation(
                modules: completeGPTKModules,
                profileGraphicsBackend: .d3dmetal,
                requiredAppleGPTKVersion: .version4Beta2,
                authorizedAppleGPTKVersion: .version4Beta2
            )
        )

        XCTAssertEqual(report.resolution, .effective(.d3dmetal))
        XCTAssertEqual(report.effectiveRoute, .d3dmetal)
        XCTAssertTrue(report.ineligibilityReasons.isEmpty)
    }

    private func assertGPTKSubdirectoryIdentitySubstitutionIsRejected(
        relativePath: String
    ) throws {
        let fixture = try RendererInspectorFixture()
        defer { fixture.remove() }
        try fixture.installCompleteDXMT()
        try fixture.installGPTK(version: .version4Beta2, validReceipt: true)
        let substitution = RendererComponentIdentitySubstitution(
            root: fixture.gptkComponentURL(.version4Beta2).appendingPathComponent(
                relativePath,
                isDirectory: true
            )
        )

        let report = RendererCapabilityInspector(
            applicationSupportURL: fixture.applicationSupport,
            componentHealth: { _, _ in
                substitution.replaceOnce()
                return true
            },
            moduleHealth: trustedFixtureModule
        ).inspect(installation: fixture.installation, appID: "1154030")

        XCTAssertNil(report.effectiveRoute)
        XCTAssertTrue(report.ineligibilityReasons.contains(
            .appleGPTKAuthorityUnavailable(
                requiredVersion: .version4Beta2,
                observedVersion: nil
            )
        ))
    }

    func testEngineProfilePrefersAuthoritativeProfileGraphicsBackend() throws {
        let encoded = Data(
            #"{"fingerprint":"engine-1","backend":"regression","providerVersion":"26.3","values":{"profile.graphics.backend":"d3dmetal","bottle.CX_GRAPHICS_BACKEND":"dxmt"},"gameCount":1,"perfectRuns":0,"playableRuns":0,"failedRuns":0,"unverifiedRuns":1,"lastObservedAt":null}"#.utf8
        )

        let profile = try JSONDecoder().decode(EngineProfile.self, from: encoded)

        XCTAssertEqual(profile.graphicsBackend, "d3dmetal")
    }

    private func gptkWine(_ fileName: String) -> RendererModuleLocation {
        .localUserComponent(
            relativePath: "AppleGPTK/4.0b2/wine/x86_64-windows/\(fileName)"
        )
    }

    private var completeDXMTModules: Set<RendererModuleObservation> {
        [
            .init(moduleID: "dxmt.d3d10core", location: .bottleSystem32),
            .init(moduleID: "dxmt.d3d10core", location: .wineRootWindows64),
            .init(moduleID: "dxmt.d3d11", location: .bottleSystem32),
            .init(moduleID: "dxmt.d3d11", location: .wineRootWindows64),
            .init(moduleID: "dxmt.dxgi", location: .bottleSystem32),
            .init(moduleID: "dxmt.dxgi", location: .wineRootWindows64),
        ]
    }

    private var completeGPTKModules: Set<RendererModuleObservation> {
        completeDXMTModules.union([
            .init(
                moduleID: "apple-gptk.d3dmetal",
                location: .localUserComponent(
                    relativePath: "AppleGPTK/4.0b2/external/D3DMetal.framework/Versions/A/D3DMetal"
                )
            ),
            .init(
                moduleID: "apple-gptk.libd3dshared",
                location: .localUserComponent(
                    relativePath: "AppleGPTK/4.0b2/external/libd3dshared.dylib"
                )
            ),
            .init(moduleID: "apple-gptk.d3d10", location: gptkWine("d3d10.dll")),
            .init(moduleID: "apple-gptk.d3d11", location: gptkWine("d3d11.dll")),
            .init(moduleID: "apple-gptk.d3d12", location: gptkWine("d3d12.dll")),
            .init(moduleID: "apple-gptk.dxgi", location: gptkWine("dxgi.dll")),
            .init(moduleID: "apple-gptk.nvapi64", location: gptkWine("nvapi64.dll")),
            .init(moduleID: "apple-gptk.nvngx", location: gptkWine("nvngx.dll")),
        ])
    }
}

final class RendererInspectorFixture {
    let root: URL
    let application: URL
    let bottle: URL
    let applicationSupport: URL

    var gptkUnixURL: URL {
        gptkComponentURL(.version4Beta2).appendingPathComponent(
            "wine/x86_64-unix",
            isDirectory: true
        )
    }

    var gptkReceiptRoot: URL {
        applicationSupport.appendingPathComponent(
            "Receipts/AppleGPTK",
            isDirectory: true
        )
    }

    var bottleSystem32: URL {
        bottle.appendingPathComponent(
            "drive_c/windows/system32",
            isDirectory: true
        )
    }

    var installation: RegressionInstallation {
        RegressionInstallation(
            applicationURL: application,
            bottleURL: bottle,
            steamExecutableURL: bottle.appendingPathComponent("drive_c/Steam/Steam.exe"),
            engineLauncherURL: application.appendingPathComponent(
                "Contents/SharedSupport/bin/regression-engine"
            ),
            health: .ready,
            healthDetail: "fixture"
        )
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "renderer-inspector-\(UUID().uuidString)",
            isDirectory: true
        )
        application = root.appendingPathComponent("Regression.app", isDirectory: true)
        bottle = root.appendingPathComponent("Bottle", isDirectory: true)
        applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(
            at: application,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bottle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
    }

    func installCompleteDXMT() throws {
        let system32 = bottleSystem32
        let wineWindows64 = application.appendingPathComponent(
            "Contents/SharedSupport/wine-root/lib/wine/x86_64-windows",
            isDirectory: true
        )
        for directory in [system32, wineWindows64] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for fileName in ["d3d10core.dll", "d3d11.dll", "dxgi.dll"] {
                XCTAssertTrue(FileManager.default.createFile(
                    atPath: directory.appendingPathComponent(fileName).path,
                    contents: Data("observed".utf8)
                ))
            }
        }
    }

    func installDXVK() throws {
        let system32 = bottle.appendingPathComponent(
            "drive_c/windows/system32",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: system32.appendingPathComponent("d3d9.dll").path,
            contents: Data("observed".utf8)
        ))
    }

    func installGPTK(
        version: AppleGPTKVersion,
        validReceipt: Bool,
        hostileUnixLink: Bool = false
    ) throws {
        let component = gptkComponentURL(version)
        let windows = component.appendingPathComponent("wine/x86_64-windows", isDirectory: true)
        let framework = component.appendingPathComponent(
            "external/D3DMetal.framework/Versions/A",
            isDirectory: true
        )
        let documentation = component.appendingPathComponent("Documentation", isDirectory: true)
        for directory in [windows, framework, documentation] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let moduleNames = version == .version3
            ? ["atidxx64.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll"]
            : ["d3d10.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll"]
        for fileName in moduleNames {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: windows.appendingPathComponent(fileName).path,
                contents: Data("module".utf8)
            ))
        }
        let unix = component.appendingPathComponent("wine/x86_64-unix", isDirectory: true)
        try FileManager.default.createDirectory(at: unix, withIntermediateDirectories: true)
        let unixModules = version == .version3
            ? ["atidxx64", "d3d11", "d3d12", "dxgi", "nvapi64", "nvngx"]
            : ["d3d10", "d3d11", "d3d12", "dxgi", "nvapi64", "nvngx"]
        for module in unixModules {
            try FileManager.default.createSymbolicLink(
                atPath: unix.appendingPathComponent("\(module).so").path,
                withDestinationPath: hostileUnixLink && module == "dxgi"
                    ? "../../../../outside/libd3dshared.dylib"
                    : "../../external/libd3dshared.dylib"
            )
        }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: framework.appendingPathComponent("D3DMetal").path,
            contents: Data("d3dmetal".utf8)
        ))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: component.appendingPathComponent("external/libd3dshared.dylib").path,
            contents: Data("shared".utf8)
        ))
        let license = Data("license-\(version.rawValue)".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: documentation.appendingPathComponent("License.rtf").path,
            contents: license
        ))
        let hash = SHA256.hash(data: license).map { String(format: "%02x", $0) }.joined()
        let receiptDirectory = applicationSupport.appendingPathComponent(
            "Receipts/AppleGPTK",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
        let receipt = receiptDirectory.appendingPathComponent(
            "\(version.rawValue)-license-receipt"
        )
        let lines: [String]
        if version == .version3 {
            lines = [
                "schema=1",
                "version=3.0",
                "source_kind=existing-protected-component",
                "catalog_id=apple-gptk-protected-profiles",
                "payload_fingerprint=fdc07beb364b2327896196e214996585fbcc1a10c71784d383218d2de9db57d7",
                "license_sha256=\(validReceipt ? hash : String(repeating: "0", count: 64))",
                "confirmation=ACEPTO LA LICENCIA DE APPLE GPTK 3.0",
                "confirmed_at=2026-08-13T12:00:00Z",
            ]
        } else {
            lines = [
                "schema=1",
                "version=4.0b2",
                "dmg_sha256=6248a0edc61553790753e5e9c060b8e53c940ed197f11409dcc34a35e05becc1",
                "license_sha256=\(validReceipt ? hash : String(repeating: "0", count: 64))",
                "confirmation=ACEPTO LA LICENCIA DE APPLE GPTK 4.0b2",
                "confirmed_at=2026-08-13T12:00:00Z",
            ]
        }
        XCTAssertTrue(FileManager.default.createFile(
            atPath: receipt.path,
            contents: Data((lines.joined(separator: "\n") + "\n").utf8),
            attributes: [.posixPermissions: 0o600]
        ))
    }

    func gptkComponentURL(_ version: AppleGPTKVersion) -> URL {
        switch version {
        case .version3:
            application.appendingPathComponent(
                "Contents/SharedSupport/wine-root/lib/apple_gptk",
                isDirectory: true
            )
        case .version4Beta2:
            applicationSupport.appendingPathComponent(
                "Components/AppleGPTK/4.0b2",
                isDirectory: true
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

func trustedFixtureModule(
    descriptor: RuntimeModuleDescriptor,
    location: RuntimeModuleExpectedLocation,
    root: AnchoredDirectory
) -> Bool {
    RuntimeModuleCatalog.expectedSHA256(moduleID: descriptor.id, location: location) != nil
        && (try? root.readRegularFile(
            relativePath: descriptor.fileName,
            maximumBytes: 1_024
        )) == Data("observed".utf8)
}

final class RendererComponentIdentitySubstitution: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private var replaced = false

    init(root: URL) {
        self.root = root
    }

    func replaceOnce() {
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
            XCTFail("No se pudo sustituir la identidad exacta del componente: \(error)")
        }
    }
}

final class RendererInPlaceABAMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL
    private let restoredData: Data
    private var mutated = false
    private var inodeBefore: UInt64?
    private var inodeAfter: UInt64?

    var preservedInode: Bool {
        lock.lock()
        defer { lock.unlock() }
        return inodeBefore != nil && inodeBefore == inodeAfter
    }

    init(file: URL, restoredData: Data) {
        self.file = file
        self.restoredData = restoredData
    }

    func mutateOnce() {
        lock.lock()
        defer { lock.unlock() }
        guard !mutated else { return }
        mutated = true
        do {
            inodeBefore = try inode(of: file)
            try Data("temporary-hostile-bytes".utf8).write(to: file)
            try restoredData.write(to: file)
            inodeAfter = try inode(of: file)
        } catch {
            XCTFail("No se pudo ejecutar el ciclo ABA in-place: \(error)")
        }
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return number.uint64Value
    }
}
