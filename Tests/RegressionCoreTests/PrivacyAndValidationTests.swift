import Foundation
@testable import RegressionCore
import XCTest

final class PrivacyAndValidationTests: XCTestCase {
    func testSteamAppIDRejectsMixedOrEmptyValues() {
        XCTAssertEqual(SteamAppID.normalized(" 219990 "), "219990")
        XCTAssertNil(SteamAppID.normalized(""))
        XCTAssertNil(SteamAppID.normalized("abc219990"))
        XCTAssertNil(SteamAppID.normalized("219990-extra"))
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
