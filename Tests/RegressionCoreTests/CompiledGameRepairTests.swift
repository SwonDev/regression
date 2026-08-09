import Foundation
import XCTest
@testable import RegressionCore

final class CompiledGameRepairTests: XCTestCase {
    private func modernSplitVCBootstrapData() -> Data {
        var data = Data("MZ\u{0}BootstrapPackagedGame-Win64-Shipping.pdb\u{0}".utf8)
        for value in [
            "Microsoft Visual C++ 2015-2022 Redistributable ",
            #"Engine\Extras\Redist\en-us\vc_redist.arm64.exe"#,
            #"Engine\Extras\Redist\en-us\vc_redist.x64.exe"#
        ] {
            data.append(value.data(using: .utf16LittleEndian)!)
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    func testUnrealBootstrapDetectorFindsOnlyAnExactPackagedGamePair() throws {
        let steamRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-unreal-bootstrap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: steamRoot) }
        let game = steamRoot.appendingPathComponent(
            "steamapps/common/Future Game",
            isDirectory: true
        )
        let shipping = game.appendingPathComponent(
            "InternalProject/Binaries/Win64/FutureGame-Win64-Shipping.exe"
        )
        try FileManager.default.createDirectory(
            at: shipping.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try modernSplitVCBootstrapData()
            .write(to: game.appendingPathComponent("FutureGame.exe"))
        try Data(repeating: 0x41, count: 4_096).write(to: shipping)

        let routes = try UnrealBootstrapRouteDetector.routes(in: steamRoot)

        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].bootstrapExecutable, "FutureGame.exe")
        XCTAssertEqual(routes[0].shippingExecutable, "FutureGame-Win64-Shipping.exe")
        XCTAssertEqual(
            routes[0].shippingURL.resolvingSymlinksInPath(),
            shipping.resolvingSymlinksInPath()
        )
    }

    func testUnrealBootstrapDetectorRejectsNearMatchesAndSymlinkedGames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-unreal-bootstrap-reject-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-unreal-bootstrap-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let common = root.appendingPathComponent("steamapps/common", isDirectory: true)
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)

        let wrongMarker = common.appendingPathComponent("WrongMarker", isDirectory: true)
        let wrongMarkerShipping = wrongMarker.appendingPathComponent(
            "WrongMarker/Binaries/Win64/WrongMarker-Win64-Shipping.exe"
        )
        try FileManager.default.createDirectory(
            at: wrongMarkerShipping.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("MZ ordinary launcher".utf8)
            .write(to: wrongMarker.appendingPathComponent("WrongMarker.exe"))
        try Data(repeating: 0x42, count: 4_096).write(to: wrongMarkerShipping)

        let mismatched = common.appendingPathComponent("Mismatched", isDirectory: true)
        let mismatchedShipping = mismatched.appendingPathComponent(
            "Other/Binaries/Win64/Other-Win64-Shipping.exe"
        )
        try FileManager.default.createDirectory(
            at: mismatchedShipping.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try modernSplitVCBootstrapData()
            .write(to: mismatched.appendingPathComponent("Mismatched.exe"))
        try Data(repeating: 0x43, count: 4_096).write(to: mismatchedShipping)

        let linkedGame = outside.appendingPathComponent("Linked", isDirectory: true)
        let linkedShipping = linkedGame.appendingPathComponent(
            "Linked/Binaries/Win64/Linked-Win64-Shipping.exe"
        )
        try FileManager.default.createDirectory(
            at: linkedShipping.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try modernSplitVCBootstrapData()
            .write(to: linkedGame.appendingPathComponent("Linked.exe"))
        try Data(repeating: 0x44, count: 4_096).write(to: linkedShipping)
        try FileManager.default.createSymbolicLink(
            at: common.appendingPathComponent("Linked"),
            withDestinationURL: linkedGame
        )

        XCTAssertTrue(try UnrealBootstrapRouteDetector.routes(in: root).isEmpty)
    }

    func testUnrealBootstrapDetectorRejectsLegacyAndIncompletePrerequisiteFamilies() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-unreal-bootstrap-family-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let common = root.appendingPathComponent("steamapps/common", isDirectory: true)

        for (gameName, bootstrapData) in [
            (
                "Legacy",
                Data("MZ BootstrapPackagedGame-Win64-Shipping.pdb Engine\\Extras\\Redist\\en-us\\UEPrereqSetup_x64.exe".utf8)
            ),
            (
                "Incomplete",
                Data("MZ BootstrapPackagedGame-Win64-Shipping.pdb Microsoft Visual C++ 2015-2022 Redistributable".utf8)
            )
        ] {
            let game = common.appendingPathComponent(gameName, isDirectory: true)
            let shipping = game.appendingPathComponent(
                "\(gameName)/Binaries/Win64/\(gameName)-Win64-Shipping.exe"
            )
            try FileManager.default.createDirectory(
                at: shipping.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try bootstrapData.write(to: game.appendingPathComponent("\(gameName).exe"))
            try Data(repeating: 0x46, count: 4_096).write(to: shipping)
        }

        XCTAssertTrue(try UnrealBootstrapRouteDetector.routes(in: root).isEmpty)
    }

    func testUnrealBootstrapDetectorRejectsAmbiguousExecutableNames() throws {
        let steamRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-unreal-bootstrap-ambiguous-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: steamRoot) }
        let common = steamRoot.appendingPathComponent("steamapps/common", isDirectory: true)

        for gameName in ["First", "Second"] {
            let game = common.appendingPathComponent(gameName, isDirectory: true)
            let shipping = game.appendingPathComponent(
                "Shared/Binaries/Win64/Shared-Win64-Shipping.exe"
            )
            try FileManager.default.createDirectory(
                at: shipping.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try modernSplitVCBootstrapData()
                .write(to: game.appendingPathComponent("Shared.exe"))
            try Data(repeating: 0x45, count: 4_096).write(to: shipping)
        }

        XCTAssertTrue(try UnrealBootstrapRouteDetector.routes(in: steamRoot).isEmpty)
    }

    func testDragonwildsCrashStackSelectsOnlyTheDualOverlayRecipe() {
        let crash = """
        Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x5320747375725420
        d3d11.dll
        gameoverlayrenderer64.dll
        EOSOVH-Win64-Shipping.dll
        EOSSDK-Win64-Shipping.dll
        RSDragonwilds-Win64-Shipping.exe
        """

        XCTAssertEqual(
            CompiledRepairClassifier.recipe(forCrashLog: crash),
            .unrealD3D11DualOverlayIsolation
        )
        XCTAssertNil(
            CompiledRepairClassifier.recipe(
                forCrashLog: "Unhandled Exception: EXCEPTION_ACCESS_VIOLATION\nd3d11.dll"
            )
        )
    }

    func testDragonwildsRuntimeProfileIsProcessScopedAndRegressionOnly() throws {
        let profile = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "1374490", backend: .regression)
        )

        XCTAssertEqual(profile.identifier, "unreal-d3d11-dual-overlay-isolation")
        XCTAssertEqual(profile.executable, "rsdragonwilds-win64-shipping.exe")
        XCTAssertEqual(profile.configurationValues["profile.scope"], "exact-process")
        XCTAssertEqual(
            profile.configurationValues["profile.repair.id"],
            CompiledRepairRecipe.unrealD3D11DualOverlayIsolation.rawValue
        )
        XCTAssertEqual(profile.configurationValues["profile.dll.disabled"], "eosovh-win64-shipping")
        XCTAssertNil(GameRuntimeProfileCatalog.profile(for: "1374490", backend: .crossOver))

        let unrelated = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "619820", backend: .regression)
        )
        XCTAssertNil(unrelated.configurationValues["profile.dll.disabled"])
    }

    func testUnityIntroWineGStreamerCrashSelectsOnlyTheMediaIsolationRecipe() {
        let crash = """
        Cross Blitz.exe
        UnityPlayer.dll
        rtworkq.dll
        winegstreamer.dll
        Media Foundation VideoPlayer failed while decoding intro video
        """

        XCTAssertEqual(
            CompiledRepairClassifier.recipe(forCrashLog: crash),
            .unityIntroWineGStreamerIsolation
        )
        XCTAssertNil(
            CompiledRepairClassifier.recipe(
                forCrashLog: "UnityPlayer.dll\nwinegstreamer.dll"
            )
        )
    }

    func testUnityExclusiveFullscreenFocusFailureSelectsOnlyBorderlessRecipe() {
        let playerLog = """
        Initialize engine version: 2021.3.45f2
        Failed to apply requested ExclusiveFullScreen resolution (1512x945)...will try again
        Unable to apply requested ExclusiveFullScreen resolution again (1512x945)...reverting to current display resolution: 1512x982
        """

        XCTAssertEqual(
            CompiledRepairClassifier.recipe(forCrashLog: playerLog),
            .unityExclusiveFullscreenBorderless
        )
        XCTAssertNil(
            CompiledRepairClassifier.recipe(
                forCrashLog: "UnityPlayer.dll\nExclusiveFullScreen"
            )
        )
    }

    func testCrossBlitzRuntimeProfileDisablesOnlyWineGStreamerInItsExactProcess() throws {
        let profile = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "1619520", backend: .regression)
        )

        XCTAssertEqual(profile.identifier, "unity-intro-media-borderless-stability")
        XCTAssertEqual(profile.revision, 2)
        XCTAssertEqual(profile.executable, "cross blitz.exe")
        XCTAssertTrue(profile.requiresActiveSteamClient)
        XCTAssertEqual(profile.configurationValues["profile.scope"], "exact-process")
        XCTAssertEqual(
            profile.configurationValues["profile.repair.id"],
            CompiledRepairRecipe.unityIntroWineGStreamerIsolation.rawValue
        )
        XCTAssertEqual(profile.configurationValues["profile.dll.disabled"], "winegstreamer")
        XCTAssertEqual(profile.configurationValues["profile.media.preserved"], "mfplat,mf,mfreadwrite")
        XCTAssertEqual(
            profile.configurationValues["profile.repair.secondary.id"],
            CompiledRepairRecipe.unityExclusiveFullscreenBorderless.rawValue
        )
        XCTAssertEqual(
            profile.configurationValues["profile.launch.arguments"],
            "-window-mode borderless"
        )
        XCTAssertEqual(profile.configurationValues["profile.window.scope"], "exact-process")
        XCTAssertNil(GameRuntimeProfileCatalog.profile(for: "1619520", backend: .crossOver))

        let unrelated = try XCTUnwrap(
            GameRuntimeProfileCatalog.profile(for: "619820", backend: .regression)
        )
        XCTAssertNil(unrelated.configurationValues["profile.dll.disabled"])
    }

    func testTinkerlandsRepairsOnlyTheKnownRetinaWindowMismatch() throws {
        let broken = try XCTUnwrap("""
        {"hardwareMouse":false,"fullscreen":0.0,"resolution":6.0,"volume":0.75}
        """.data(using: .utf8))
        let validWindow = try XCTUnwrap("""
        {"hardwareMouse":false,"fullscreen":0.0,"resolution":4.0,"volume":0.75}
        """.data(using: .utf8))
        let alreadyFullscreen = try XCTUnwrap("""
        {"hardwareMouse":false,"fullscreen":1.0,"resolution":6.0,"volume":0.75}
        """.data(using: .utf8))

        let repaired = try XCTUnwrap(GameDisplayStateRepair.repairedTinkerlandsOptions(broken))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: repaired) as? [String: Any]
        )
        XCTAssertEqual((object["fullscreen"] as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual((object["resolution"] as? NSNumber)?.doubleValue, 6)
        XCTAssertEqual((object["volume"] as? NSNumber)?.doubleValue, 0.75)
        XCTAssertNil(GameDisplayStateRepair.repairedTinkerlandsOptions(validWindow))
        XCTAssertNil(GameDisplayStateRepair.repairedTinkerlandsOptions(alreadyFullscreen))
        XCTAssertNil(GameDisplayStateRepair.repairedTinkerlandsOptions(Data("[]".utf8)))
    }

    func testTinkerlandsRepairCreatesRollbackAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-tinkerlands-repair-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let options = root
            .appendingPathComponent("drive_c/users/crossover/AppData/Local/Tinkerlands/useroptions.conf")
        try FileManager.default.createDirectory(
            at: options.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{\"fullscreen\":0,\"resolution\":6,\"volume\":0.5}".utf8)
            .write(to: options)

        let first = try GameDisplayStateRepair.repairTinkerlands(in: root)
        XCTAssertEqual(first.repairedFiles.count, 1)
        XCTAssertEqual(first.rollbackFiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.rollbackFiles[0].path))
        let rollback = try Data(contentsOf: first.rollbackFiles[0])
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: rollback) as? [String: NSNumber])["fullscreen"],
            0
        )

        let second = try GameDisplayStateRepair.repairTinkerlands(in: root)
        XCTAssertTrue(second.repairedFiles.isEmpty)
        XCTAssertTrue(second.rollbackFiles.isEmpty)
    }

    func testTinkerlandsRepairDoesNotFollowAParentDirectorySymlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-tinkerlands-symlink-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-tinkerlands-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let user = root.appendingPathComponent("drive_c/users/crossover", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let outsideOptions = outside.appendingPathComponent("Local/Tinkerlands/useroptions.conf")
        try FileManager.default.createDirectory(
            at: outsideOptions.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("{\"fullscreen\":0,\"resolution\":6}".utf8)
        try original.write(to: outsideOptions)
        try FileManager.default.createSymbolicLink(
            at: user.appendingPathComponent("AppData"),
            withDestinationURL: outside
        )

        XCTAssertTrue(try GameDisplayStateRepair.repairTinkerlands(in: root).entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: outsideOptions), original)
    }

    func testCompiledActivationStoresOnlyKnownRecipeForExactExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let report = try XCTUnwrap(CompiledRepairActivationStore.activate(
            executable: #"C:\Games\Future\Future-Win64-Shipping.exe"#,
            recipe: .unrealD3D11DualOverlayIsolation,
            in: root
        ))
        XCTAssertNotEqual(report.beforeFingerprint, report.afterFingerprint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.rollbackURL.path))
        XCTAssertEqual(
            try CompiledRepairActivationStore.activations(in: root),
            [CompiledRepairActivation(
                executable: "future-win64-shipping.exe",
                recipe: .unrealD3D11DualOverlayIsolation
            )]
        )
        XCTAssertNil(try CompiledRepairActivationStore.activate(
            executable: "Future-Win64-Shipping.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            in: root
        ))
        XCTAssertThrowsError(try CompiledRepairActivationStore.activate(
            executable: "../Future-Win64-Shipping.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            in: root
        ))
    }

    func testCrashLearnerActivatesKnownRecipeFromBoundedRecentLog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-crash-learning-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(
            "drive_c/users/test/AppData/Local/Future/Saved/Crashes/UECC-1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let crashURL = logs.appendingPathComponent("Future.log")
        let crash = """
        Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x1
        d3d11.dll
        gameoverlayrenderer64.dll
        EOSOVH-Win64-Shipping.dll
        EOSSDK-Win64-Shipping.dll
        Future-Win64-Shipping.exe
        """
        try Data(crash.utf8).write(to: crashURL)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: crashURL.path
        )

        let report = try XCTUnwrap(CompiledCrashRepairLearner.learn(
            appID: "424242",
            executable: #"C:\Games\Future\Future-Win64-Shipping.exe"#,
            bottleURL: root,
            startedAt: now.addingTimeInterval(-10),
            endedAt: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(report.recipe, .unrealD3D11DualOverlayIsolation)
        XCTAssertEqual(report.executable, "future-win64-shipping.exe")
        XCTAssertEqual(report.appID, "424242")
    }

    func testCrashLearnerRejectsAConcurrentCrashFromAnotherExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-crash-misattribution-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(
            "drive_c/users/test/AppData/Local/Other/Saved/Crashes/UECC-1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let crashURL = logs.appendingPathComponent("Other.log")
        try Data("""
        Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x1
        d3d11.dll
        gameoverlayrenderer64.dll
        EOSOVH-Win64-Shipping.dll
        EOSSDK-Win64-Shipping.dll
        Other-Win64-Shipping.exe
        """.utf8).write(to: crashURL)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: crashURL.path)

        XCTAssertNil(try CompiledCrashRepairLearner.learn(
            appID: "424242",
            executable: #"C:\Games\Future\Future-Win64-Shipping.exe"#,
            bottleURL: root,
            startedAt: now.addingTimeInterval(-10),
            endedAt: now.addingTimeInterval(1)
        ))
        XCTAssertTrue(try CompiledRepairActivationStore.activations(in: root).isEmpty)
    }
}
