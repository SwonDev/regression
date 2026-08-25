import Foundation
import XCTest
@testable import RegressionCore

final class LauncherConfigurationRouteDetectorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-launcher-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var commonURL: URL {
        root.appendingPathComponent("steamapps/common", isDirectory: true)
    }

    /// Construye un juego con el formato real del prelanzador de REDengine.
    @discardableResult
    private func makeGame(
        named name: String,
        entries: [(description: String, directory: String, fileName: String)],
        existing: Set<String>,
        includeLauncher: Bool = true,
        launcherMachine: UInt16 = 0x8664,
        targetMachine: UInt16 = 0x8664
    ) throws -> URL {
        let gameURL = commonURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: gameURL, withIntermediateDirectories: true)
        if includeLauncher {
            try MinimalPortableExecutable.data(linked: [], delayed: [], machine: launcherMachine)
                .write(to: gameURL.appendingPathComponent("REDprelauncher.exe"))
        }
        for entry in entries where existing.contains(entry.directory) {
            let directory = entry.directory
                .split(separator: "\\")
                .reduce(gameURL) { $0.appendingPathComponent(String($1), isDirectory: true) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try MinimalPortableExecutable.data(linked: [], delayed: [], machine: targetMachine)
                .write(to: directory.appendingPathComponent(entry.fileName))
        }
        let payload: [String: Any] = [
            "revision": 3,
            "gameId": name,
            "executables": entries.map { entry in
                [
                    "description": entry.description,
                    "executable": ["directoryPath": entry.directory, "fileName": entry.fileName]
                ]
            }
        ]
        try JSONSerialization.data(withJSONObject: payload)
            .write(to: gameURL.appendingPathComponent("launcher-configuration.json"))
        return gameURL
    }

    private let witcherEntries = [
        (description: "DirectX 12", directory: "bin\\x64_dx12", fileName: "witcher3.exe"),
        (description: "DirectX 11", directory: "bin\\x64", fileName: "witcher3.exe")
    ]

    /// El caso reproducido: la configuración lista D3D12 primero y este runtime sirve D3D11.
    func testPrefersTheEntryThatIsNotDirect3D12() throws {
        try makeGame(named: "The Witcher 3", entries: witcherEntries,
                     existing: ["bin\\x64_dx12", "bin\\x64"])

        let routes = try LauncherConfigurationRouteDetector.routes(in: root)
        XCTAssertEqual(routes.count, 1)
        let route = try XCTUnwrap(routes.first)
        XCTAssertEqual(route.launcherExecutable, "REDprelauncher.exe")
        XCTAssertEqual(route.targetExecutable, "witcher3.exe")
        XCTAssertTrue(route.targetURL.path.hasSuffix("bin/x64/witcher3.exe"))
        XCTAssertFalse(route.targetURL.path.contains("dx12"))
    }

    /// Sin prelanzador no hay a quién redirigir: la configuración sola no basta.
    func testIgnoresAGameWithoutTheLauncher() throws {
        try makeGame(named: "Sin prelanzador", entries: witcherEntries,
                     existing: ["bin\\x64"], includeLauncher: false)
        XCTAssertTrue(try LauncherConfigurationRouteDetector.routes(in: root).isEmpty)
    }

    /// Una entrada cuyo binario no está en disco no puede elegirse.
    func testSkipsEntriesWhoseExecutableIsMissing() throws {
        try makeGame(named: "Solo D3D12", entries: witcherEntries, existing: ["bin\\x64_dx12"])
        XCTAssertTrue(
            try LauncherConfigurationRouteDetector.routes(in: root).isEmpty,
            "si la única entrada presente es D3D12 no se redirige nada"
        )
    }

    /// Una ruta declarada no puede escaparse de la carpeta del juego.
    func testRejectsATraversingDirectoryPath() throws {
        try makeGame(
            named: "Traviesa",
            entries: [(description: "DirectX 11", directory: "..\\..\\windows", fileName: "witcher3.exe")],
            existing: []
        )
        XCTAssertTrue(try LauncherConfigurationRouteDetector.routes(in: root).isEmpty)
    }

    /// Un nombre de ejecutable con separadores o extensión ajena no se acepta.
    func testRejectsAnUnsafeExecutableName() throws {
        try makeGame(
            named: "Nombre raro",
            entries: [(description: "DirectX 11", directory: "bin", fileName: "witcher3.exe.sh")],
            existing: ["bin"]
        )
        XCTAssertTrue(try LauncherConfigurationRouteDetector.routes(in: root).isEmpty)
    }

    /// Un JSON que no es del formato esperado se ignora en silencio, no rompe el arranque.
    func testIgnoresAnUnrelatedConfigurationFile() throws {
        let gameURL = commonURL.appendingPathComponent("Otro", isDirectory: true)
        try FileManager.default.createDirectory(at: gameURL, withIntermediateDirectories: true)
        try MinimalPortableExecutable.data(linked: [], delayed: [])
            .write(to: gameURL.appendingPathComponent("REDprelauncher.exe"))
        try Data(#"{"algo":"distinto"}"#.utf8)
            .write(to: gameURL.appendingPathComponent("launcher-configuration.json"))
        XCTAssertTrue(try LauncherConfigurationRouteDetector.routes(in: root).isEmpty)
    }

    /// Una biblioteca sin `steamapps/common` no es un error.
    func testAnEmptyLibraryProducesNoRoutes() throws {
        XCTAssertTrue(try LauncherConfigurationRouteDetector.routes(in: root).isEmpty)
    }

    /// El caso real de REDengine: prelanzador de 32 bits y juego de 64. Redirigir la imagen ahí
    /// hace que Steam falle con `AppError_46`, así que no se propone ruta ninguna.
    func testDoesNotRouteAcrossArchitectures() throws {
        try makeGame(named: "Cruce de arquitecturas", entries: witcherEntries,
                     existing: ["bin\\x64_dx12", "bin\\x64"],
                     launcherMachine: 0x014c, targetMachine: 0x8664)
        XCTAssertTrue(try LauncherConfigurationRouteDetector.routes(in: root).isEmpty)
    }
}
