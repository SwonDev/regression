import Foundation
import XCTest
@testable import RegressionCore

final class D3D12MetalRouteDetectorTests: XCTestCase {
    private func makeSteamRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-d3d12-route-\(UUID().uuidString)")
    }

    private func makeUnrealGame(
        in steamRoot: URL,
        game: String,
        project: String,
        shipping: String,
        withAgilitySDK: Bool
    ) throws -> URL {
        let win64 = steamRoot.appendingPathComponent(
            "steamapps/common/\(game)/\(project)/Binaries/Win64",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: win64, withIntermediateDirectories: true)
        let shippingURL = win64.appendingPathComponent(shipping)
        try Data(repeating: 0x41, count: 4_096).write(to: shippingURL)
        if withAgilitySDK {
            let agility = win64.appendingPathComponent("D3D12", isDirectory: true)
            try FileManager.default.createDirectory(at: agility, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 512)
                .write(to: agility.appendingPathComponent("D3D12Core.dll"))
        }
        return shippingURL
    }

    func testDetectorFindsUnrealGameShippingTheAgilitySDK() throws {
        let steamRoot = makeSteamRoot()
        defer { try? FileManager.default.removeItem(at: steamRoot) }
        let shipping = try makeUnrealGame(
            in: steamRoot,
            game: "Future Game",
            project: "FutureProject",
            shipping: "FutureGame-Win64-Shipping.exe",
            withAgilitySDK: true
        )

        let routes = try D3D12MetalRouteDetector.routes(in: steamRoot)

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].shippingExecutable, "FutureGame-Win64-Shipping.exe")
        XCTAssertEqual(
            routes[0].shippingURL.resolvingSymlinksInPath(),
            shipping.resolvingSymlinksInPath()
        )
    }

    /// Un juego Unity empaqueta el Agility SDK en la raíz y arranca en D3D11. Enrutarlo a
    /// D3DMetal cambiaría el camino gráfico de un título que ya funciona, que es exactamente
    /// la regresión que este detector no puede provocar. Core Keeper es el caso real.
    func testDetectorIgnoresUnityLayoutThatMerelyShipsTheAgilitySDK() throws {
        let steamRoot = makeSteamRoot()
        defer { try? FileManager.default.removeItem(at: steamRoot) }
        let game = steamRoot.appendingPathComponent(
            "steamapps/common/Unity Game",
            isDirectory: true
        )
        let agility = game.appendingPathComponent("D3D12", isDirectory: true)
        try FileManager.default.createDirectory(at: agility, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 512)
            .write(to: agility.appendingPathComponent("D3D12Core.dll"))
        try Data(repeating: 0x41, count: 4_096)
            .write(to: game.appendingPathComponent("UnityGame.exe"))

        XCTAssertTrue(try D3D12MetalRouteDetector.routes(in: steamRoot).isEmpty)
    }

    func testDetectorRequiresTheAgilitySDKAsEvidence() throws {
        let steamRoot = makeSteamRoot()
        defer { try? FileManager.default.removeItem(at: steamRoot) }
        _ = try makeUnrealGame(
            in: steamRoot,
            game: "Plain Game",
            project: "PlainProject",
            shipping: "PlainGame-Win64-Shipping.exe",
            withAgilitySDK: false
        )

        XCTAssertTrue(try D3D12MetalRouteDetector.routes(in: steamRoot).isEmpty)
    }

    func testDetectorRejectsAmbiguousShippingBasenames() throws {
        let steamRoot = makeSteamRoot()
        defer { try? FileManager.default.removeItem(at: steamRoot) }
        for game in ["Alpha Game", "Beta Game"] {
            _ = try makeUnrealGame(
                in: steamRoot,
                game: game,
                project: "SharedProject",
                shipping: "SharedGame-Win64-Shipping.exe",
                withAgilitySDK: true
            )
        }

        XCTAssertTrue(try D3D12MetalRouteDetector.routes(in: steamRoot).isEmpty)
    }

    func testDetectorRejectsMoreThanOneShippingPerProject() throws {
        let steamRoot = makeSteamRoot()
        defer { try? FileManager.default.removeItem(at: steamRoot) }
        let shipping = try makeUnrealGame(
            in: steamRoot,
            game: "Twin Game",
            project: "TwinProject",
            shipping: "TwinGame-Win64-Shipping.exe",
            withAgilitySDK: true
        )
        try Data(repeating: 0x41, count: 4_096).write(
            to: shipping.deletingLastPathComponent()
                .appendingPathComponent("TwinServer-Win64-Shipping.exe")
        )

        XCTAssertTrue(try D3D12MetalRouteDetector.routes(in: steamRoot).isEmpty)
    }

    func testDetectorRejectsSymlinkedShippingExecutable() throws {
        let steamRoot = makeSteamRoot()
        defer { try? FileManager.default.removeItem(at: steamRoot) }
        let shipping = try makeUnrealGame(
            in: steamRoot,
            game: "Linked Game",
            project: "LinkedProject",
            shipping: "LinkedGame-Win64-Shipping.exe",
            withAgilitySDK: true
        )
        let outside = steamRoot.appendingPathComponent("outside.exe")
        try Data(repeating: 0x41, count: 4_096).write(to: outside)
        try FileManager.default.removeItem(at: shipping)
        try FileManager.default.createSymbolicLink(at: shipping, withDestinationURL: outside)

        XCTAssertTrue(try D3D12MetalRouteDetector.routes(in: steamRoot).isEmpty)
    }

    func testDetectorReturnsNothingWithoutASteamLibrary() throws {
        let steamRoot = makeSteamRoot()
        XCTAssertTrue(try D3D12MetalRouteDetector.routes(in: steamRoot).isEmpty)
    }
}
