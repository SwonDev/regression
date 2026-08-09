import Foundation
import XCTest
@testable import RegressionCore

final class CompiledGameRepairTests: XCTestCase {
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
