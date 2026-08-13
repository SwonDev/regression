import Foundation
import XCTest
@testable import RegressionCore

final class GameTechnologyEvidenceScannerTests: XCTestCase {
    func testResolverOnlyReturnsSealedComponentsCompiledProfilesOrInformation() throws {
        let observedAt = Date(timeIntervalSince1970: 50)
        let sealed = GameRuntimeRequirement(
            appID: "123",
            kind: .runtimeComponent,
            identifier: "microsoft-vc-runtime-x64",
            source: .automatic,
            observedAt: observedAt
        )
        let profile = GameRuntimeRequirement(
            appID: "1619520",
            kind: .dependency,
            identifier: "unity-player",
            source: .automatic,
            observedAt: observedAt
        )
        let unknown = GameRuntimeRequirement(
            appID: "123",
            kind: .runtimeComponent,
            identifier: "installer-at-/tmp/untrusted.exe",
            source: .automatic,
            observedAt: observedAt
        )
        let unrelatedKnownMarker = GameRuntimeRequirement(
            appID: "1619520",
            kind: .dependency,
            identifier: "gamemaker-runner",
            source: .automatic,
            observedAt: observedAt
        )

        XCTAssertEqual(
            GameRuntimeRequirementResolver.resolve(sealed).resolution,
            .sealedComponent(
                componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
                componentVersion: TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion
            )
        )
        XCTAssertEqual(
            GameRuntimeRequirementResolver.resolve(profile).resolution,
            .compiledProfile(
                identifier: "unity-intro-media-borderless-stability",
                revision: 2
            )
        )
        XCTAssertEqual(
            GameRuntimeRequirementResolver.resolve(unknown).resolution,
            .informational
        )
        XCTAssertEqual(
            GameRuntimeRequirementResolver.resolve(unrelatedKnownMarker).resolution,
            .informational,
            "Un ID conocido no puede seleccionar un perfil compilado de otra tecnología."
        )
        XCTAssertFalse(GameRuntimeRequirementResolver.resolve(sealed).automaticRetryEligible)
        XCTAssertFalse(GameRuntimeRequirementResolver.resolve(profile).automaticRetryEligible)
        XCTAssertFalse(GameRuntimeRequirementResolver.resolve(unknown).automaticRetryEligible)
    }

    func testSuccessfulScanReplacesAutomaticProjectionAndAdvancesCurrentGeneration() async throws {
        let root = try temporaryRoot("successful-generation")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let appID = "219990"
        try await repository.recordRuntimeRequirement(GameRuntimeRequirement(
            appID: appID,
            kind: .permission,
            identifier: "human-note",
            source: .user
        ))
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        try await repository.recordSuccessfulGameTechnologyScan(
            appID: appID,
            requirements: [GameRuntimeRequirement(
                appID: appID,
                kind: .runtimeComponent,
                identifier: "microsoft-vc-runtime-x64",
                source: .automatic,
                observedAt: firstDate
            )],
            scannedAt: firstDate
        )
        try await repository.recordSuccessfulGameTechnologyScan(
            appID: appID,
            requirements: [GameRuntimeRequirement(
                appID: appID,
                kind: .dependency,
                identifier: "unity-player",
                source: .automatic,
                observedAt: secondDate
            )],
            scannedAt: secondDate
        )

        let projection = try await repository.gameTechnologyRequirementProjection(appID: appID)
        XCTAssertEqual(projection.scanState?.freshness, .current)
        XCTAssertEqual(projection.scanState?.generation, 2)
        XCTAssertEqual(projection.scanState?.lastSuccessfulGeneration, 2)
        XCTAssertEqual(projection.scanState?.lastSuccessfulAt, secondDate)
        XCTAssertNil(projection.scanState?.error)
        XCTAssertEqual(
            Set(projection.currentRequirements.map(\.requirement.identifier)),
            ["human-note", "unity-player"]
        )
        XCTAssertTrue(projection.staleAutomaticRequirements.isEmpty)
    }

    func testFailedScanPreservesPreviousAutomaticEvidenceButMarksItStale() async throws {
        let root = try temporaryRoot("failed-generation")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let appID = "219990"
        let successDate = Date(timeIntervalSince1970: 100)
        let failureDate = Date(timeIntervalSince1970: 200)
        try await repository.recordSuccessfulGameTechnologyScan(
            appID: appID,
            requirements: [GameRuntimeRequirement(
                appID: appID,
                kind: .runtimeComponent,
                identifier: "microsoft-vc-runtime-x86",
                source: .automatic,
                observedAt: successDate
            )],
            scannedAt: successDate
        )

        try await repository.recordFailedGameTechnologyScan(
            appID: appID,
            error: "No se pudo leer "
                + FileManager.default.homeDirectoryForCurrentUser.path
                + "/private/token=secret/game",
            attemptedAt: failureDate
        )

        let projection = try await repository.gameTechnologyRequirementProjection(appID: appID)
        XCTAssertEqual(projection.scanState?.freshness, .stale)
        XCTAssertEqual(projection.scanState?.generation, 2)
        XCTAssertEqual(projection.scanState?.lastSuccessfulGeneration, 1)
        XCTAssertEqual(projection.scanState?.lastSuccessfulAt, successDate)
        XCTAssertEqual(projection.scanState?.attemptedAt, failureDate)
        XCTAssertNotNil(projection.scanState?.error)
        XCTAssertFalse(
            projection.scanState?.error?.contains(
                FileManager.default.homeDirectoryForCurrentUser.path
            ) == true
        )
        XCTAssertTrue(projection.currentRequirements.isEmpty)
        XCTAssertEqual(
            projection.staleAutomaticRequirements.map(\.requirement.identifier),
            ["microsoft-vc-runtime-x86"]
        )
        let currentRequirements = try await repository.runtimeRequirements(appID: appID)
        XCTAssertTrue(
            currentRequirements.isEmpty,
            "La evidencia anterior permanece archivada en la proyección stale, no como actual."
        )
    }

    func testFirstFailedScanHasExplicitStaleGenerationWithoutCurrentRequirements() async throws {
        let root = try temporaryRoot("first-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let attemptedAt = Date(timeIntervalSince1970: 300)

        try await repository.recordFailedGameTechnologyScan(
            appID: "219990",
            error: "La instalación aún no está disponible",
            attemptedAt: attemptedAt
        )

        let projection = try await repository.gameTechnologyRequirementProjection(appID: "219990")
        XCTAssertEqual(projection.scanState?.freshness, .stale)
        XCTAssertEqual(projection.scanState?.generation, 1)
        XCTAssertNil(projection.scanState?.lastSuccessfulGeneration)
        XCTAssertNil(projection.scanState?.lastSuccessfulAt)
        XCTAssertEqual(projection.scanState?.attemptedAt, attemptedAt)
        XCTAssertTrue(projection.currentRequirements.isEmpty)
        XCTAssertTrue(projection.staleAutomaticRequirements.isEmpty)
    }

    func testAutomaticRequirementsAreReplacedWithoutDeletingHumanEvidence() async throws {
        let root = try temporaryRoot("repository")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let appID = "219990"
        try await repository.recordRuntimeRequirement(GameRuntimeRequirement(
            appID: appID,
            kind: .runtimeComponent,
            identifier: "stale-auto",
            source: .automatic
        ))
        try await repository.recordRuntimeRequirement(GameRuntimeRequirement(
            appID: appID,
            kind: .permission,
            identifier: "human-note",
            source: .user
        ))
        let current = GameRuntimeRequirement(
            appID: appID,
            kind: .graphicsBackend,
            identifier: "directx-11",
            source: .automatic
        )

        try await repository.replaceAutomaticRuntimeRequirements(
            appID: appID,
            with: [current]
        )

        let stored = try await repository.runtimeRequirements(appID: appID)
        XCTAssertEqual(Set(stored.map(\.identifier)), ["directx-11", "human-note"])
        XCTAssertEqual(stored.first { $0.identifier == "human-note" }?.source, .user)
    }

    func testAutomaticScanCannotOverwriteHumanEvidenceWithTheSameIdentity() async throws {
        let root = try temporaryRoot("repository-human-collision")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let appID = "219990"
        let human = GameRuntimeRequirement(
            appID: appID,
            kind: .dependency,
            identifier: "unity-player",
            source: .user,
            notes: "Confirmado por la persona"
        )
        try await repository.recordRuntimeRequirement(human)

        try await repository.recordSuccessfulGameTechnologyScan(
            appID: appID,
            requirements: [GameRuntimeRequirement(
                appID: appID,
                kind: .dependency,
                identifier: "unity-player",
                source: .automatic,
                notes: "Escáner"
            )]
        )

        let stored = try await repository.runtimeRequirements(appID: appID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.source, .user)
        XCTAssertEqual(stored.first?.notes, "Confirmado por la persona")
    }

    func testInvalidAutomaticProjectionDoesNotAdvanceGenerationOrReplaceEvidence() async throws {
        let root = try temporaryRoot("repository-invalid-projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let appID = "219990"
        let observedAt = Date(timeIntervalSince1970: 40)
        let current = GameRuntimeRequirement(
            appID: appID,
            kind: .dependency,
            identifier: "unity-player",
            source: .automatic,
            observedAt: observedAt
        )
        try await repository.recordSuccessfulGameTechnologyScan(
            appID: appID,
            requirements: [current],
            scannedAt: observedAt
        )

        do {
            try await repository.recordSuccessfulGameTechnologyScan(
                appID: appID,
                requirements: [GameRuntimeRequirement(
                    appID: "999",
                    kind: .dependency,
                    identifier: "unreal-engine",
                    source: .automatic
                )]
            )
            XCTFail("Una proyección no canónica debe fallar antes de iniciar la transacción")
        } catch {}

        let projection = try await repository.gameTechnologyRequirementProjection(appID: appID)
        XCTAssertEqual(projection.scanState?.generation, 1)
        XCTAssertEqual(projection.scanState?.freshness, .current)
        XCTAssertEqual(projection.requirements.map(\.requirement), [current])
        do {
            try await repository.recordRuntimeRequirement(GameRuntimeRequirement(
                appID: "../../bad",
                kind: .dependency,
                identifier: "unity-player",
                source: .user
            ))
            XCTFail("Se esperaba rechazar un App ID no canónico")
        } catch {}
    }

    private func temporaryRoot(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-technology-\(suffix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("marker".utf8).write(to: url)
    }

    func testUnityRequiresCorrelatedPlayerExecutableAndDataMarkers() throws {
        let root = try temporaryRoot("unity")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Moon.exe", in: root)
        try write("UnityPlayer.dll", in: root)
        try write("Moon_Data/globalgamemanagers", in: root)
        try write("Redist/vc_redist.x64.exe", in: root)

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertEqual(report.technologies.map(\.family), [.unity])
        XCTAssertEqual(report.technologies.first?.confidence, .high)
        XCTAssertEqual(
            report.technologies.first?.evidence.map(\.marker),
            [.unityDataManifest, .unityPlayerLibrary, .windowsExecutable]
        )
        XCTAssertEqual(report.packagedRedistributables.map(\.kind), [.visualCppX64])
        XCTAssertEqual(
            report.runtimeRequirements.map(\.identifier),
            ["microsoft-vc-runtime-x64", "unity-player"]
        )
        XCTAssertTrue(report.runtimeRequirements.allSatisfy { $0.appID.isEmpty })
        let boundRequirements = try report.requirements(
            forAppID: " 123 ",
            observedAt: Date(timeIntervalSince1970: 123)
        )
        XCTAssertTrue(boundRequirements.allSatisfy {
            $0.appID == "123" && $0.observedAt == Date(timeIntervalSince1970: 123)
        })
        XCTAssertThrowsError(try report.requirements(forAppID: "../../bad"))
        XCTAssertEqual(
            try report.resolvedRequirements(
                forAppID: "123",
                observedAt: Date(timeIntervalSince1970: 123)
            ).map(\.resolution),
            [
                .sealedComponent(
                    componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
                    componentVersion: TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion
                ),
                .informational
            ]
        )

        let partial = try temporaryRoot("unity-partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        try write("UnityPlayer.dll", in: partial)
        try write("NotTheSameGame.exe", in: partial)
        try write("Other_Data/globalgamemanagers", in: partial)

        XCTAssertTrue(
            try GameTechnologyEvidenceScanner.scan(gameRootURL: partial).technologies.isEmpty
        )
    }

    func testDetectsUnrealGameMakerXNAAndMonoGameOnlyFromCombinedMarkers() throws {
        let unreal = try temporaryRoot("unreal")
        defer { try? FileManager.default.removeItem(at: unreal) }
        try write("Project/Binaries/Win64/Project-Win64-Shipping.exe", in: unreal)
        try write("Engine/Binaries/Win64/CrashReportClient.exe", in: unreal)
        try write("Engine/Content/Slate/placeholder.uasset", in: unreal)
        XCTAssertEqual(
            try GameTechnologyEvidenceScanner.scan(gameRootURL: unreal)
                .technologies.map(\.family),
            [.unrealEngine]
        )

        let gameMaker = try temporaryRoot("gamemaker")
        defer { try? FileManager.default.removeItem(at: gameMaker) }
        try write("Tinker.exe", in: gameMaker)
        try write("data.win", in: gameMaker)
        XCTAssertEqual(
            try GameTechnologyEvidenceScanner.scan(gameRootURL: gameMaker)
                .technologies.map(\.family),
            [.gameMaker]
        )

        let xna = try temporaryRoot("xna")
        defer { try? FileManager.default.removeItem(at: xna) }
        try write("Forsaken.exe", in: xna)
        try write("Microsoft.Xna.Framework.dll", in: xna)
        try write("Microsoft.Xna.Framework.Game.dll", in: xna)
        XCTAssertEqual(
            try GameTechnologyEvidenceScanner.scan(gameRootURL: xna)
                .technologies.map(\.family),
            [.xna]
        )

        let monoGame = try temporaryRoot("monogame")
        defer { try? FileManager.default.removeItem(at: monoGame) }
        try write("Grindea.exe", in: monoGame)
        try write("MonoGame.Framework.dll", in: monoGame)
        XCTAssertEqual(
            try GameTechnologyEvidenceScanner.scan(gameRootURL: monoGame)
                .technologies.map(\.family),
            [.monoGame]
        )

        let partial = try temporaryRoot("partial-families")
        defer { try? FileManager.default.removeItem(at: partial) }
        try write("Project/Binaries/Win64/Project-Win64-Shipping.exe", in: partial)
        try write("data.win", in: partial)
        try write("Microsoft.Xna.Framework.dll", in: partial)
        try write("MonoGame.Framework.dll", in: partial)
        XCTAssertTrue(
            try GameTechnologyEvidenceScanner.scan(gameRootURL: partial).technologies.isEmpty
        )
    }

    func testSymlinkedMarkersAreNeverFollowed() throws {
        let root = try temporaryRoot("symlink-root")
        let outside = try temporaryRoot("symlink-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write("Moon.exe", in: root)
        try write("UnityPlayer.dll", in: outside)
        try write("Moon_Data/globalgamemanagers", in: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("UnityPlayer.dll"),
            withDestinationURL: outside.appendingPathComponent("UnityPlayer.dll")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Moon_Data"),
            withDestinationURL: outside.appendingPathComponent("Moon_Data")
        )

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertTrue(report.technologies.isEmpty)
        XCTAssertFalse(report.evidence.contains { $0.relativePath.contains(outside.path) })
    }

    func testBudgetsFailClosedAndDepthLimitDoesNotInspectDescendants() throws {
        let root = try temporaryRoot("budget")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one.bin", in: root)
        try write("two.bin", in: root)
        try write("three.bin", in: root)

        XCTAssertThrowsError(
            try GameTechnologyEvidenceScanner.scan(
                gameRootURL: root,
                limits: GameTechnologyScanLimits(
                    maximumDepth: 4,
                    maximumEntries: 2,
                    maximumMetadataBytes: 1_024
                )
            )
        )

        XCTAssertThrowsError(
            try GameTechnologyEvidenceScanner.scan(
                gameRootURL: root,
                limits: GameTechnologyScanLimits(
                    maximumDepth: 4,
                    maximumEntries: 10,
                    maximumMetadataBytes: 5
                )
            )
        )

        let deep = try temporaryRoot("depth")
        defer { try? FileManager.default.removeItem(at: deep) }
        try write("Moon.exe", in: deep)
        try write("UnityPlayer.dll", in: deep)
        try write("Moon_Data/deeper/globalgamemanagers", in: deep)
        let shallowReport = try GameTechnologyEvidenceScanner.scan(
            gameRootURL: deep,
            limits: GameTechnologyScanLimits(
                maximumDepth: 2,
                maximumEntries: 20,
                maximumMetadataBytes: 1_024
            )
        )
        XCTAssertTrue(shallowReport.technologies.isEmpty)
    }

    func testEvidenceIsSanitizedSortedAndDeterministic() throws {
        let root = try temporaryRoot("determinism")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Zed.exe", in: root)
        try write("data.win", in: root)
        try write("token=secret/vc_redist.x86.exe", in: root)
        try write("A/DirectX/DXSETUP.exe", in: root)
        try write("A/DirectX/DSETUP.dll", in: root)

        let first = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)
        let second = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.technologies.map(\.family), [.gameMaker])
        XCTAssertEqual(
            first.packagedRedistributables.map(\.kind),
            [.directXJune2010, .visualCppX86]
        )
        XCTAssertTrue(first.evidence.map(\.relativePath).allSatisfy { !$0.contains("token=secret") })
        XCTAssertTrue(first.evidence.map(\.relativePath).allSatisfy { !$0.hasPrefix("/") })
    }
}
