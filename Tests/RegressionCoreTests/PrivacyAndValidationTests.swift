import Foundation
@testable import RegressionCore
import XCTest

final class PrivacyAndValidationTests: XCTestCase {
    func testDXMTModulesRequireTheirProtectedBuiltinPairWithoutNativeOverrides() throws {
        for id in ["dxmt.d3d10core", "dxmt.d3d11", "dxmt.dxgi"] {
            let module = try XCTUnwrap(RuntimeModuleCatalog.module(id: id))
            XCTAssertEqual(module.binaryClass, .builtinWine)
            XCTAssertEqual(module.expectedLocations, [.bottleSystem32, .wineRootWindows64])
            XCTAssertEqual(
                module.requiredPair,
                RuntimeModuleRequiredPair(
                    first: .bottleSystem32,
                    second: .wineRootWindows64
                )
            )
            XCTAssertEqual(module.overridePolicy, .forbidden)
            XCTAssertEqual(module.scope, .global)
            XCTAssertEqual(module.architecture, .x86_64)
            XCTAssertEqual(module.variant, "0.72-regression-cross-process")
            XCTAssertEqual(module.provenance.project, "DXMT")
            XCTAssertEqual(module.provenance.license, "LGPL-2.1+")
            XCTAssertEqual(module.provenance.sourceURL.host, "github.com")
        }
    }

    func testDXVKD3D9IsTheOnlyProtectedNativePEWithNativeOverrideAllowed() throws {
        let d3d9 = try XCTUnwrap(RuntimeModuleCatalog.module(id: "dxvk.d3d9"))

        XCTAssertEqual(d3d9.fileName, "d3d9.dll")
        XCTAssertEqual(d3d9.binaryClass, .nativePE)
        XCTAssertEqual(d3d9.expectedLocations, [.bottleSystem32])
        XCTAssertNil(d3d9.requiredPair)
        XCTAssertEqual(d3d9.overridePolicy, .allowed)
        XCTAssertEqual(d3d9.scope, .global)
        XCTAssertEqual(d3d9.architecture, .x86_64)
        XCTAssertEqual(d3d9.variant, "1.10.3")
        XCTAssertEqual(d3d9.provenance.project, "DXVK")
        XCTAssertEqual(d3d9.provenance.license, "Zlib")
        XCTAssertEqual(
            RuntimeModuleCatalog.protectedModules.filter { $0.binaryClass == .nativePE }.map(\.id),
            ["dxvk.d3d9"]
        )
    }

    func testGPTKModulesRemainLocalUserProvidedAndPerProcess() throws {
        let modules = RuntimeModuleCatalog.protectedModules.filter { $0.id.hasPrefix("apple-gptk.") }

        XCTAssertFalse(modules.isEmpty)
        XCTAssertTrue(modules.allSatisfy { $0.binaryClass == .localUserProvided })
        XCTAssertTrue(modules.allSatisfy { $0.scope == .perProcess })
        XCTAssertTrue(modules.allSatisfy { $0.overridePolicy == .forbidden })
        XCTAssertTrue(modules.allSatisfy { $0.architecture == .x86_64 })
        XCTAssertTrue(modules.allSatisfy { $0.variant == "4.0b2" })
        XCTAssertTrue(modules.allSatisfy { $0.provenance.project == "Apple Game Porting Toolkit" })
        XCTAssertTrue(modules.allSatisfy { $0.provenance.license.contains("not redistributed") })
        XCTAssertEqual(
            RuntimeModuleCatalog.module(id: "apple-gptk.d3dmetal")?.expectedLocations,
            [
                .localUserComponent(
                    relativePath: "AppleGPTK/4.0b2/external/D3DMetal.framework/Versions/A/D3DMetal"
                )
            ]
        )
    }

    func testRuntimeModuleCatalogHasNoDuplicateIdentitiesOrSnapshotKeys() {
        let identities = RuntimeModuleCatalog.protectedModules.map(\.id)
        let snapshotKeys = RuntimeModuleCatalog.observedInventory.map(\.snapshotKey)

        XCTAssertEqual(Set(identities).count, identities.count)
        XCTAssertEqual(Set(snapshotKeys).count, snapshotKeys.count)
        XCTAssertEqual(
            Set(snapshotKeys),
            [
                "component.graphics.d3d9.dll",
                "component.graphics.d3d10core.dll",
                "component.graphics.d3d11.dll",
                "component.graphics.d3d12.dll",
                "component.graphics.d3d12core.dll",
                "component.graphics.dxgi.dll",
                "component.graphics.winevulkan.dll",
                "component.graphics.vulkan-1.dll",
                "component.runtime.ucrtbase.dll",
                "component.runtime.vcruntime140.dll",
                "component.runtime.vcruntime140_1.dll",
                "component.runtime.msvcp140.dll",
                "component.runtime.msvcp140_1.dll",
                "component.runtime.msvcp140_2.dll",
                "component.runtime.d3dcompiler_43.dll",
                "component.runtime.d3dcompiler_47.dll",
                "component.runtime.xinput1_3.dll",
                "component.runtime.xinput1_4.dll",
                "component.runtime.xaudio2_7.dll",
                "component.runtime.openal32.dll",
                "component.runtime.mf.dll",
                "component.runtime.mfplat.dll",
                "component.runtime.mscoree.dll",
                "component.runtime.winegstreamer.dll",
            ]
        )
    }

    func testSnapshotInventoryDoesNotClaimRepairAuthorityForInstallationDependentModules() {
        let installationDependentFiles = [
            "vcruntime140.dll", "vcruntime140_1.dll",
            "msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
            "d3dcompiler_43.dll", "d3dcompiler_47.dll",
            "xinput1_3.dll", "xinput1_4.dll", "xaudio2_7.dll",
            "openal32.dll", "ucrtbase.dll", "mf.dll", "mfplat.dll",
            "mscoree.dll", "winegstreamer.dll",
        ]

        for fileName in installationDependentFiles {
            XCTAssertTrue(RuntimeModuleCatalog.observedInventory.contains { $0.fileName == fileName })
            XCTAssertFalse(RuntimeModuleCatalog.protectedModules.contains { $0.fileName == fileName })
        }
    }

    func testSteamAppIDRejectsMixedOrEmptyValues() {
        XCTAssertEqual(SteamAppID.normalized(" 219990 "), "219990")
        XCTAssertEqual(SteamAppID.normalized("000219990"), "219990")
        XCTAssertEqual(SteamAppID.normalized("4294967295"), "4294967295")
        XCTAssertNil(SteamAppID.normalized(""))
        XCTAssertNil(SteamAppID.normalized("0"))
        XCTAssertNil(SteamAppID.normalized("abc219990"))
        XCTAssertNil(SteamAppID.normalized("219990-extra"))
        XCTAssertNil(SteamAppID.normalized("4294967296"))
        XCTAssertNil(SteamAppID.normalized("٢١٩٩٩٠"))
    }

    func testLogRedactionRemovesSecretsAccountDataAndUserPaths() {
        let source = #"email=persona@example.com password="clave-muy-privada" token=abc123 Authorization: Bearer valor C:\Users\Adrian\save"#
        let redacted = PrivacySanitizer.redactedLogExcerpt(source)

        XCTAssertFalse(redacted.contains("persona@example.com"))
        XCTAssertFalse(redacted.contains("clave-muy-privada"))
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("Bearer valor"))
        XCTAssertFalse(redacted.contains("Adrian"))
        XCTAssertTrue(redacted.contains("<correo-redactado>"))
        XCTAssertTrue(redacted.contains("<secreto-redactado>"))
        XCTAssertTrue(redacted.contains("<ruta-de-usuario-redactada>"))
    }

    func testGameConfigurationCollectorRejectsIdentityLikeGraphicsKeys() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-private-game-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let gameRoot = steamRoot.appendingPathComponent("steamapps/common/Test", isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        try Data("displayMode=fullscreen\ndisplayName=Adrian\nresolution=1920x1080\n".utf8)
            .write(to: gameRoot.appendingPathComponent("graphics.ini"))
        let game = SteamGame(
            appID: "42",
            name: "Test",
            installDirectory: "Test",
            manifestURL: steamRoot.appendingPathComponent("steamapps/appmanifest_42.acf"),
            sourceBackend: .regression
        )

        let values = GameConfigurationCollector.snapshot(
            bottleURL: root,
            steamRootURL: steamRoot,
            game: game
        )
        XCTAssertTrue(values.values.contains("fullscreen"))
        XCTAssertTrue(values.values.contains("1920x1080"))
        XCTAssertFalse(values.values.contains("Adrian"))
    }

    func testGameConfigurationCollectorRejectsPathTraversalFromManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-path-traversal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let escapedRoot = steamRoot.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createDirectory(at: escapedRoot, withIntermediateDirectories: true)
        try Data("resolution=7680x4320".utf8)
            .write(to: escapedRoot.appendingPathComponent("graphics.ini"))
        let game = SteamGame(
            appID: "42",
            name: "../../escape",
            installDirectory: "../../escape",
            manifestURL: steamRoot.appendingPathComponent("steamapps/appmanifest_42.acf"),
            sourceBackend: .regression
        )

        let values = GameConfigurationCollector.snapshot(
            bottleURL: root.appendingPathComponent("Bottle", isDirectory: true),
            steamRootURL: steamRoot,
            game: game
        )

        XCTAssertTrue(values.isEmpty)
    }

    func testGameConfigurationCollectorRejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-symlink-escape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let common = steamRoot.appendingPathComponent("steamapps/common", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("resolution=7680x4320".utf8)
            .write(to: outside.appendingPathComponent("graphics.ini"))
        try FileManager.default.createSymbolicLink(
            at: common.appendingPathComponent("Test"),
            withDestinationURL: outside
        )
        let game = SteamGame(
            appID: "42",
            name: "Test",
            installDirectory: "Test",
            manifestURL: steamRoot.appendingPathComponent("steamapps/appmanifest_42.acf"),
            sourceBackend: .regression
        )

        let values = GameConfigurationCollector.snapshot(
            bottleURL: root.appendingPathComponent("Bottle", isDirectory: true),
            steamRootURL: steamRoot,
            game: game
        )

        XCTAssertTrue(values.isEmpty)
    }

    func testArgumentSanitizerUsesCanonicalSteamAppIDValidation() {
        XCTAssertEqual(
            PrivacySanitizer.safeArguments(["-applaunch", "000219990"]),
            ["-applaunch", "219990"]
        )
        XCTAssertEqual(
            PrivacySanitizer.safeArguments(["-applaunch", "٢١٩٩٩٠"]),
            ["-applaunch"]
        )
    }

    func testConfigurationSnapshotCollectorKeepsOnlyAllowlistedRuntimeFacts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-runtime-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let system32 = root.appendingPathComponent(
            "drive_c/windows/system32",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try Data("d3d11-test".utf8).write(to: system32.appendingPathComponent("d3d11.dll"))
        try Data("runtime-test".utf8).write(to: system32.appendingPathComponent("vcruntime140.dll"))
        try Data(#"""
        [Software\\Wine\\Mac Driver]
        "RetinaMode"="n"
        "SteamLoginSecure"="secreto"
        """#.utf8).write(to: root.appendingPathComponent("user.reg"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(
                "drive_c/windows/Microsoft.NET/Framework64/v4.0.30319",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let values = await ConfigurationSnapshotCollector().snapshot(
            bottleURL: root,
            backend: .regression,
            providerVersion: "1.5"
        )

        XCTAssertEqual(values["backend"], "regression")
        XCTAssertEqual(values["provider.version"], "1.5")
        XCTAssertNil(values["bottle.CX_GRAPHICS_BACKEND"])
        XCTAssertEqual(values["registry.RetinaMode"], "n")
        XCTAssertNotNil(values["component.graphics.d3d11.dll"])
        XCTAssertNotNil(values["component.runtime.vcruntime140.dll"])
        XCTAssertEqual(values["component.runtime.dotnet-frameworks"], "v4.0.30319")
        XCTAssertFalse(values.keys.contains { $0.localizedCaseInsensitiveContains("token") })
        XCTAssertFalse(values.values.contains("secreto"))

        XCTAssertEqual(
            Set(values.keys),
            [
                "backend",
                "provider.version",
                "bottle.name",
                "registry.RetinaMode",
                "component.graphics.d3d11.dll",
                "component.runtime.vcruntime140.dll",
                "component.runtime.dotnet-frameworks",
            ]
        )
    }

    func testPrivateAtomicWriteKeepsFilePrivateWithoutChangingExistingParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-private-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let destination = root.appendingPathComponent("export.json")

        try PrivateStorage.write(Data("primero".utf8), atomicallyTo: destination)
        try PrivateStorage.write(Data("segundo".utf8), atomicallyTo: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "segundo")
        let fileMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber
        ).intValue
        let parentMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(fileMode & 0o777, 0o600)
        XCTAssertEqual(parentMode & 0o777, 0o755)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .allSatisfy { !$0.hasSuffix(".tmp") }
        )
    }
}
