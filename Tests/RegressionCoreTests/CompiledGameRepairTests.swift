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

    func testTinkerlandsRepairCreatesRollbackAndIsIdempotent() async throws {
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

        let firstOutcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: root,
            prepareLedger: {},
            recordReceipt: { _ in }
        )
        guard case let .committed(first) = firstOutcome else {
            return XCTFail("la reparación debía comprometerse")
        }
        XCTAssertEqual(first.repairedFiles.count, 1)
        XCTAssertEqual(first.rollbackFiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.rollbackFiles[0].path))
        let rollback = try Data(contentsOf: first.rollbackFiles[0])
        XCTAssertEqual(
            try XCTUnwrap(JSONSerialization.jsonObject(with: rollback) as? [String: NSNumber])["fullscreen"],
            0
        )

        let second = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("un no-op no registra recibo") }
        )
        XCTAssertEqual(second, .noOp)
    }

    func testTinkerlandsRepairDoesNotFollowAParentDirectorySymlink() async throws {
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

        let outcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("un symlink no registra recibo") }
        )
        XCTAssertEqual(outcome, .noOp)
        XCTAssertEqual(try Data(contentsOf: outsideOptions), original)
    }

    func testTinkerlandsTransactionPreparesLedgerBeforeInspectingOrMutating() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var receiptWasAttempted = false

        let outcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {
                throw RegressionCoreError.database("fallo prepare inyectado")
            },
            recordReceipt: { _ in receiptWasAttempted = true }
        )

        guard case let .unsafe(failure) = outcome else {
            return XCTFail("un prepare fallido debe producir un resultado inseguro estructurado")
        }
        XCTAssertFalse(failure.mutationOccurred)
        XCTAssertFalse(receiptWasAttempted)
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)
        let journalDirectory = fixture.root.appendingPathComponent(".regression/repair-transactions")
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: journalDirectory.path)
                .contains { $0.hasSuffix(".json") }
        )
    }

    func testTinkerlandsTransactionRollsBackExactBytesWhenReceiptFailsAfterMutation() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var receiptResults: [RepairReceiptResult] = []

        let outcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { receiptResults.append($0.result) },
            faultInjection: .receipt
        )

        guard case let .rolledBack(report) = outcome else {
            return XCTFail("un fallo de ledger posterior a la mutación debe restaurar")
        }
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)
        XCTAssertEqual(try Data(contentsOf: report.entries[0].rollbackURL), fixture.original)
        XCTAssertEqual(receiptResults, [.rolledBack])
    }

    func testTargetRenameFollowedByDirectorySyncFailureRollsBackExactBytes() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in },
            faultInjection: .targetAfterRename
        )
        guard case .rolledBack = outcome else {
            return XCTFail("un fallo post-rename debe tratarse como mutación y restaurarse")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)
    }

    func testTinkerlandsTransactionFailsClosedWhenRollbackCannotBeVerified() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let outcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in
                throw RegressionCoreError.database("fallo receipt inyectado")
            },
            faultInjection: .rollback
        )

        guard case let .unsafe(failure) = outcome else {
            return XCTFail("un rollback no verificable debe bloquear el lanzamiento")
        }
        XCTAssertTrue(failure.mutationOccurred)
        XCTAssertNotEqual(try Data(contentsOf: fixture.options), fixture.original)
    }

    func testTinkerlandsTransactionCommitsOneReceiptWithAggregateFingerprintsAndThenIsNoOp() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var recordedContexts: [GameDisplayStateRepairReceiptContext] = []

        let first = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { recordedContexts.append($0) }
        )
        guard case let .committed(report) = first else {
            return XCTFail("la reparación válida debía quedar comprometida")
        }
        XCTAssertEqual(report.entries.count, 1)
        XCTAssertEqual(recordedContexts.count, 1)
        XCTAssertEqual(recordedContexts[0].beforeFingerprint, report.aggregateBeforeFingerprint)
        XCTAssertEqual(recordedContexts[0].afterFingerprint, report.aggregateAfterFingerprint)
        XCTAssertEqual(recordedContexts[0].result, .succeeded)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recordedContexts[0].intentURL.path),
            "el journal debe desaparecer únicamente después de persistir el recibo"
        )

        let second = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("un no-op no debe generar otro recibo") }
        )
        XCTAssertEqual(second, .noOp)
    }

    func testTinkerlandsTransactionRecoversCrashAfterIntentAsVerifiedRollback() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let interrupted = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("no hay mutación ni recibo antes del crash") },
            faultInjection: .crashAfterIntent
        )
        guard case let .unsafe(failure) = interrupted else {
            return XCTFail("la interrupción debía quedar pendiente")
        }
        XCTAssertFalse(failure.mutationOccurred)
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)

        var recoveryReceipts: [GameDisplayStateRepairReceiptContext] = []
        let recovered = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { recoveryReceipts.append($0) }
        )
        guard case .rolledBack = recovered else {
            return XCTFail("un intent pendiente debía reconciliarse como rollback")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)
        XCTAssertEqual(recoveryReceipts.map(\.result), [.rolledBack])
    }

    func testTinkerlandsTransactionRecoversCrashAfterMutationBeforeReceiptByExactRollback() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let interrupted = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("el crash precede al recibo") },
            faultInjection: .crashAfterMutation
        )
        guard case let .unsafe(failure) = interrupted else {
            return XCTFail("la interrupción debía conservar un journal")
        }
        XCTAssertTrue(failure.mutationOccurred)
        XCTAssertNotEqual(try Data(contentsOf: fixture.options), fixture.original)

        let recovered = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in }
        )
        guard case .rolledBack = recovered else {
            return XCTFail("un journal pending con bytes mutados debía restaurarse")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)
    }

    func testPendingCrashJournalAndLedgerPrepareFailureBlocksUntilRecoverySucceeds() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        _ = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("el crash precede al recibo") },
            faultInjection: .crashAfterMutation
        )
        let mutated = try Data(contentsOf: fixture.options)
        XCTAssertNotEqual(mutated, fixture.original)

        let blocked = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: { throw RegressionCoreError.database("SQLite no disponible") },
            recordReceipt: { _ in XCTFail("sin ledger no se registra recibo") }
        )
        guard case let .unsafe(failure) = blocked else {
            return XCTFail("un journal pendiente más fallo del ledger debe bloquear")
        }
        XCTAssertTrue(failure.mutationOccurred)
        XCTAssertFalse(blocked.allowsLaunch)
        XCTAssertEqual(try Data(contentsOf: fixture.options), mutated)

        let recovered = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in }
        )
        guard case .rolledBack = recovered else {
            return XCTFail("al recuperar el ledger debe reconciliarse el crash")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)
    }

    func testTinkerlandsTransactionRecoversPartialMultiUserMutationWithoutTouchingTheSecondUser() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let secondOptions = fixture.root.appendingPathComponent(
            "drive_c/users/second/AppData/Local/Tinkerlands/useroptions.conf"
        )
        try FileManager.default.createDirectory(
            at: secondOptions.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let secondOriginal = Data("{\"fullscreen\":0,\"resolution\":7,\"volume\":0.25}".utf8)
        try secondOriginal.write(to: secondOptions)

        let interrupted = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("un crash parcial no registra éxito") },
            faultInjection: .crashAfterFirstMutation
        )
        guard case let .unsafe(failure) = interrupted else {
            return XCTFail("la interrupción parcial debía conservar el journal")
        }
        XCTAssertTrue(failure.mutationOccurred)
        XCTAssertNotEqual(try Data(contentsOf: fixture.options), fixture.original)
        XCTAssertEqual(try Data(contentsOf: secondOptions), secondOriginal)

        let recovered = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in }
        )
        guard case .rolledBack = recovered else {
            return XCTFail("el reinicio debía restaurar la mutación parcial")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)
        XCTAssertEqual(try Data(contentsOf: secondOptions), secondOriginal)
    }

    func testTinkerlandsTransactionFailsClosedWhenParentBecomesSymlinkAfterIntent() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-tinkerlands-swap-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outside)
        }
        let appData = fixture.root.appendingPathComponent("drive_c/users/crossover/AppData")
        let anchoredOriginal = appData.deletingLastPathComponent()
            .appendingPathComponent("AppData-anchored-original")
        let outsideOptions = outside.appendingPathComponent("Local/Tinkerlands/useroptions.conf")
        try FileManager.default.createDirectory(
            at: outsideOptions.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outsideOriginal = Data("{\"fullscreen\":0,\"resolution\":6,\"outside\":true}".utf8)
        try outsideOriginal.write(to: outsideOptions)

        let outcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("un swap de symlink no puede registrar éxito") },
            faultInjection: .none,
            beforeMutation: {
                try FileManager.default.moveItem(at: appData, to: anchoredOriginal)
                try FileManager.default.createSymbolicLink(at: appData, withDestinationURL: outside)
            }
        )
        guard case let .unsafe(failure) = outcome else {
            return XCTFail("el swap posterior a la intención debe fallar cerrado")
        }
        XCTAssertFalse(failure.mutationOccurred)
        let originalOptions = anchoredOriginal.appendingPathComponent(
            "Local/Tinkerlands/useroptions.conf"
        )
        XCTAssertEqual(try Data(contentsOf: originalOptions), fixture.original)
        XCTAssertEqual(try Data(contentsOf: outsideOptions), outsideOriginal)
    }

    func testTinkerlandsTransactionLockPreventsConcurrentMutation() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let enteredMutation = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)

        let first = Task {
            await GameDisplayStateRepair.prepareTinkerlandsTransaction(
                in: fixture.root,
                prepareLedger: {},
                recordReceipt: { _ in },
                faultInjection: .none,
                beforeMutation: {
                    enteredMutation.signal()
                    releaseMutation.wait()
                }
            )
        }
        XCTAssertEqual(enteredMutation.wait(timeout: .now() + 2), .success)

        let concurrent = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("la segunda transacción no debe adquirir el lock") }
        )
        guard case let .unsafe(failure) = concurrent else {
            releaseMutation.signal()
            _ = await first.value
            return XCTFail("una reparación concurrente debe fallar cerrada")
        }
        XCTAssertTrue(failure.mutationOccurred)
        XCTAssertFalse(concurrent.allowsLaunch)

        releaseMutation.signal()
        guard case .committed = await first.value else {
            return XCTFail("la transacción que posee el lock debe completar")
        }
    }

    func testTinkerlandsTransactionRecoversCrashAfterReceiptIdempotently() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var receiptIDs = Set<UUID>()
        var receiptCalls = 0
        let recorder: (GameDisplayStateRepairReceiptContext) async throws -> Void = { context in
            receiptCalls += 1
            receiptIDs.insert(context.receiptID)
        }

        let interrupted = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: recorder,
            faultInjection: .crashAfterReceipt
        )
        guard case let .unsafe(failure) = interrupted else {
            return XCTFail("la interrupción posterior al recibo debía conservar el journal")
        }
        XCTAssertTrue(failure.mutationOccurred)
        XCTAssertEqual(receiptCalls, 1)

        let recovered = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: recorder
        )
        guard case .committed = recovered else {
            return XCTFail("el journal mutated debía completar el mismo commit")
        }
        XCTAssertEqual(receiptCalls, 2)
        XCTAssertEqual(receiptIDs.count, 1, "el retry del recibo debe conservar identidad")
    }

    func testCleanupFailureAfterSucceededReceiptNeverRollsBackCommittedBytes() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var receipts: [UUID: RepairReceiptResult] = [:]
        let recorder: (GameDisplayStateRepairReceiptContext) async throws -> Void = { context in
            if let existing = receipts[context.receiptID] {
                XCTAssertEqual(existing, context.result)
                return
            }
            receipts[context.receiptID] = context.result
        }

        let interrupted = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: recorder,
            faultInjection: .cleanupAfterReceipt
        )
        guard case let .unsafe(failure) = interrupted else {
            return XCTFail("el cleanup fallido debe conservar el journal y bloquear")
        }
        XCTAssertTrue(failure.mutationOccurred)
        XCTAssertFalse(interrupted.allowsLaunch)
        XCTAssertEqual(Array(receipts.values), [.succeeded])
        XCTAssertNotEqual(try Data(contentsOf: fixture.options), fixture.original)

        let recovered = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: recorder
        )
        guard case .committed = recovered else {
            return XCTFail("el reinicio debe cerrar el mismo commit")
        }
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(Array(receipts.values), [.succeeded])
        XCTAssertNotEqual(try Data(contentsOf: fixture.options), fixture.original)
    }

    func testTinkerlandsTransactionRejectsJournalDirectorySymlink() async throws {
        let fixture = try makeTinkerlandsTransactionFixture()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-journal-outside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let regression = fixture.root.appendingPathComponent(".regression")
        try FileManager.default.createDirectory(at: regression, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: regression.appendingPathComponent("repair-transactions"),
            withDestinationURL: outside
        )

        let outcome = await GameDisplayStateRepair.prepareTinkerlandsTransaction(
            in: fixture.root,
            prepareLedger: {},
            recordReceipt: { _ in XCTFail("un journal enlazado no registra recibos") }
        )
        guard case let .unsafe(failure) = outcome else {
            return XCTFail("un journal enlazado debe fallar cerrado")
        }
        XCTAssertTrue(failure.mutationOccurred, "un journal no inspeccionable mantiene el estado indeterminado")
        XCTAssertEqual(try Data(contentsOf: fixture.options), fixture.original)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testCompiledActivationWritesAnIsolatedV2Record() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let report = try XCTUnwrap(CompiledRepairActivationStore.activate(
            appID: "424242",
            executable: #"C:\Games\Future\Future-Win64-Shipping.exe"#,
            recipe: .unrealD3D11DualOverlayIsolation,
            in: root
        ))
        XCTAssertEqual(report.activation.appID, "424242")
        XCTAssertEqual(report.activation.executable, "future-win64-shipping.exe")
        XCTAssertNotEqual(report.beforeFingerprint, report.afterFingerprint)

        // El registro nombra App ID, basename y receta: nada más puede viajar hasta Wine.
        let written = try String(
            contentsOf: CompiledRepairActivationStore.activationURL(in: root),
            encoding: .utf8
        )
        XCTAssertEqual(
            written,
            "REGRESSION-COMPILED-REPAIRS\t2\n424242\tfuture-win64-shipping.exe\tunreal-d3d11-dual-overlay-isolation-v1\n"
        )

        let attributes = try FileManager.default.attributesOfItem(
            atPath: CompiledRepairActivationStore.activationURL(in: root).path
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)

        // Repetir el aprendizaje no reescribe la botella ni duplica registros.
        XCTAssertNil(try CompiledRepairActivationStore.activate(
            appID: "424242",
            executable: "Future-Win64-Shipping.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            in: root
        ))
        XCTAssertEqual(try CompiledRepairActivationStore.activations(in: root).count, 1)
    }

    /// El formato v1 no identifica el App ID, así que no puede ampliarse ni convivir: mientras
    /// exista un fichero heredado vivo, ninguna activación nueva entra en la botella.
    func testCompiledActivationRefusesLegacyFormats() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".regression", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try CompiledRepairActivationStore.activate(
            executable: "Future-Win64-Shipping.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            in: root
        ))

        try Data("REGRESSION-COMPILED-REPAIRS\t1\nfuture-win64-shipping.exe\tunreal-d3d11-dual-overlay-isolation-v1\n".utf8)
            .write(to: CompiledRepairActivationStore.legacyActivationURL(in: root))
        XCTAssertThrowsError(try CompiledRepairActivationStore.activate(
            appID: "424242",
            executable: "Future-Win64-Shipping.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            in: root
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CompiledRepairActivationStore.activationURL(in: root).path
        ))
    }

    func testCompiledActivationRejectsAnInvalidAppID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-activation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertThrowsError(try CompiledRepairActivationStore.activate(
            appID: "no-es-un-app-id",
            executable: "Future-Win64-Shipping.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            in: root
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CompiledRepairActivationStore.activationURL(in: root).path
        ))
    }

    func testLegacyActivationReaderQuarantinesAmbiguousBasenames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-activation-app-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".regression")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        REGRESSION-COMPILED-REPAIRS\t1
        shared.exe\tunreal-d3d11-dual-overlay-isolation-v1
        shared.exe\tunity-intro-winegstreamer-isolation-v1
        """.utf8).write(to: CompiledRepairActivationStore.legacyActivationURL(in: root))

        XCTAssertThrowsError(try CompiledRepairActivationStore.activations(in: root))
    }

    private func makeTinkerlandsTransactionFixture() throws -> (
        root: URL,
        options: URL,
        original: Data
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-tinkerlands-transaction-\(UUID().uuidString)")
        let options = root.appendingPathComponent(
            "drive_c/users/crossover/AppData/Local/Tinkerlands/useroptions.conf"
        )
        try FileManager.default.createDirectory(
            at: options.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let original = Data("{\"fullscreen\":0,\"resolution\":6,\"volume\":0.5}\n".utf8)
        try original.write(to: options)
        return (root, options, original)
    }

    func testLegacyActivationReaderRejectsSymlinkAndHardlink() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-activation-link-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-activation-outside-\(UUID().uuidString).tsv")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let directory = root.appendingPathComponent(".regression")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data("""
        REGRESSION-COMPILED-REPAIRS\t1
        future.exe\tunreal-d3d11-dual-overlay-isolation-v1
        """.utf8)
        try data.write(to: outside)
        let legacyURL = CompiledRepairActivationStore.legacyActivationURL(in: root)
        try FileManager.default.createSymbolicLink(at: legacyURL, withDestinationURL: outside)
        XCTAssertThrowsError(try CompiledRepairActivationStore.activations(in: root))
        try FileManager.default.removeItem(at: legacyURL)
        try FileManager.default.linkItem(at: outside, to: legacyURL)
        XCTAssertThrowsError(try CompiledRepairActivationStore.activations(in: root))
    }

    func testCrashDetectionIsPureUntilActivationIsExplicit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-crash-pure-detection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(
            "drive_c/users/test/AppData/Local/Future/Saved/Crashes/UECC-1",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let crashURL = logs.appendingPathComponent("Future.log")
        try Data("""
        Unhandled Exception: EXCEPTION_ACCESS_VIOLATION reading address 0x1
        d3d11.dll
        gameoverlayrenderer64.dll
        EOSOVH-Win64-Shipping.dll
        EOSSDK-Win64-Shipping.dll
        Future.exe
        """.utf8).write(to: crashURL)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: crashURL.path)

        let detection = try XCTUnwrap(CompiledCrashRepairLearner.detect(
            appID: "424242",
            executable: "Future.exe",
            bottleURL: root,
            startedAt: now.addingTimeInterval(-10),
            endedAt: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(detection.recipe, .unrealD3D11DualOverlayIsolation)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CompiledRepairActivationStore.activationURL(in: root).path
        ))
    }

    func testCrashLearnerActivatesTheRecognisedRecipe() throws {
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
        XCTAssertEqual(report.appID, "424242")
        XCTAssertEqual(report.activation.activation.executable, "future-win64-shipping.exe")

        let activations = try CompiledRepairActivationStore.activations(in: root)
        XCTAssertEqual(activations.count, 1)
        XCTAssertEqual(activations[0].appID, "424242")

        // Volver a aprender el mismo fallo no vuelve a mutar la botella.
        XCTAssertNil(try CompiledCrashRepairLearner.learn(
            appID: "424242",
            executable: #"C:\Games\Future\Future-Win64-Shipping.exe"#,
            bottleURL: root,
            startedAt: now.addingTimeInterval(-10),
            endedAt: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(try CompiledRepairActivationStore.activations(in: root).count, 1)
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
