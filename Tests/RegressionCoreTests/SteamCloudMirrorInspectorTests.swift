import Foundation
import XCTest
@testable import RegressionCore

final class SteamCloudMirrorInspectorTests: XCTestCase {
    private func makeSteamRoot(
        accountID: String = "121123806",
        appID: String = "1621690",
        cache: String,
        remoteFiles: [String: Int]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-cloud-\(UUID().uuidString)", isDirectory: true)
        let base = root
            .appendingPathComponent("userdata", isDirectory: true)
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent(appID, isDirectory: true)
        let remote = base.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Data(cache.utf8).write(to: base.appendingPathComponent("remotecache.vdf"))
        for (path, size) in remoteFiles {
            let url = remote.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: size).write(to: url)
        }
        return root
    }

    /// Formato real de `remotecache.vdf`: bloques anidados por ruta relativa.
    private func cacheDocument(_ entries: [(String, Int)]) -> String {
        var text = "\"1621690\"\n{\n\t\"ChangeNumber\"\t\t\"44\"\n\t\"OSType\"\t\t\"0\"\n"
        for (path, size) in entries {
            text += """
            \t"\(path)"
            \t{
            \t\t"root"\t\t"0"
            \t\t"size"\t\t"\(size)"
            \t\t"syncstate"\t\t"1"
            \t}

            """
        }
        return text + "}\n"
    }

    /// Éste es el estado que dejó a Core Keeper cerrándose solo: la caché declara los archivos
    /// como sincronizados y el espejo local no los tiene, así que Steam nunca los rebaja.
    func testDeclaredButAbsentFilesAreReportedAsMissing() throws {
        let root = try makeSteamRoot(
            cache: cacheDocument([
                ("Admins.json", 251),
                ("saves/0.json", 43862),
                ("worlds/0.world.gzip", 4_208_490)
            ]),
            remoteFiles: [:]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try XCTUnwrap(
            SteamCloudMirrorInspector.reports(appID: "1621690", in: root).first
        )
        XCTAssertEqual(report.accountID, "121123806")
        XCTAssertEqual(report.files.count, 3)
        XCTAssertFalse(report.isCoherent)
        XCTAssertEqual(report.incoherentFiles.count, 3)
        XCTAssertTrue(report.files.allSatisfy { $0.state == .missing })
        XCTAssertEqual(report.files.first { $0.path == "saves/0.json" }?.declaredSize, 43862)
        XCTAssertNil(report.files.first { $0.path == "saves/0.json" }?.actualSize)
    }

    func testCoherentMirrorReportsNoIncidence() throws {
        let root = try makeSteamRoot(
            cache: cacheDocument([("Admins.json", 251), ("saves/0.json", 128)]),
            remoteFiles: ["Admins.json": 251, "saves/0.json": 128]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try XCTUnwrap(
            SteamCloudMirrorInspector.reports(appID: "1621690", in: root).first
        )
        XCTAssertTrue(report.isCoherent)
        XCTAssertTrue(report.incoherentFiles.isEmpty)
    }

    /// Un archivo presente pero truncado es tan inservible como uno ausente, y Steam tampoco lo
    /// corrige solo: se distingue para que el diagnóstico no lo dé por bueno.
    func testTruncatedFileIsReportedAsSizeMismatch() throws {
        let root = try makeSteamRoot(
            cache: cacheDocument([("worlds/0.world.gzip", 4_208_490)]),
            remoteFiles: ["worlds/0.world.gzip": 64]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let file = try XCTUnwrap(
            SteamCloudMirrorInspector.reports(appID: "1621690", in: root).first?.files.first
        )
        XCTAssertEqual(file.state, .sizeMismatch)
        XCTAssertEqual(file.actualSize, 64)
        XCTAssertEqual(file.declaredSize, 4_208_490)
    }

    /// `ChangeNumber` y `OSType` son metadatos del bloque, no archivos: colarlos como rutas
    /// produciría incidencias fantasma en todos los juegos.
    func testCacheMetadataIsNeverTreatedAsAFile() throws {
        let root = try makeSteamRoot(
            cache: cacheDocument([("Admins.json", 251)]),
            remoteFiles: ["Admins.json": 251]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try XCTUnwrap(
            SteamCloudMirrorInspector.reports(appID: "1621690", in: root).first
        )
        XCTAssertEqual(report.files.map(\.path), ["Admins.json"])
    }

    func testGameWithoutCloudCacheYieldsNoReport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(try SteamCloudMirrorInspector.reports(appID: "1621690", in: root).isEmpty)
    }

    func testInspectorRejectsAnInvalidAppID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-cloud-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try SteamCloudMirrorInspector.reports(appID: "no-es-un-appid", in: root)
        )
    }
}
