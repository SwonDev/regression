import Foundation
@testable import RegressionCore
import XCTest

final class PrivacyAndValidationTests: XCTestCase {
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
        "CX_GRAPHICS_BACKEND" = "d3dmetal"
        "UNSAFE_ACCOUNT_TOKEN" = "secreto"
        """#.utf8).write(to: root.appendingPathComponent("cxbottle.conf"))
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
        XCTAssertEqual(values["bottle.CX_GRAPHICS_BACKEND"], "d3dmetal")
        XCTAssertEqual(values["registry.RetinaMode"], "n")
        XCTAssertNotNil(values["component.graphics.d3d11.dll"])
        XCTAssertNotNil(values["component.runtime.vcruntime140.dll"])
        XCTAssertEqual(values["component.runtime.dotnet-frameworks"], "v4.0.30319")
        XCTAssertFalse(values.keys.contains { $0.localizedCaseInsensitiveContains("token") })
        XCTAssertFalse(values.values.contains("secreto"))
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
