import Foundation
import XCTest
@testable import RegressionCore

final class GameTechnologyEvidenceScannerTests: XCTestCase {
    func testLegacyPackagedRedistributablesPreserveExactVersionsButDoNotClaimTheyAreMissing() throws {
        let root = try temporaryRoot("legacy-components")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Redist/xnafx31_redist.msi", in: root)
        try write("Redist/xnafx31_redist.exe", in: root)
        try write("Redist/xnafx40_redist.msi", in: root)
        try write("Redist/xnafx40_redist.exe", in: root)
        try write("Redist/dotNetFx40_Full_x86_x64.exe", in: root)
        try write("Redist/dotNetFx45_Full_setup.exe", in: root)
        try write("Redist/NDP48-x86-x64-AllOS-ENU.exe", in: root)
        try write("Redist/vc_redist.arm64.exe", in: root)
        try write("Redist/DXSETUP.exe", in: root)
        try write("Redist/DSETUP.dll", in: root)
        try write("Redist/Jun2010_d3dx9_43_x64.cab", in: root)

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertEqual(
            report.packagedRedistributables.map(\.kind),
            [.directXJune2010, .dotNetFramework40, .dotNetFramework45, .dotNetFramework48, .visualCppARM64,
             .xnaFramework31, .xnaFramework40]
        )
        XCTAssertTrue(
            report.runtimeRequirements.isEmpty,
            "Un redistribuible empaquetado es inventario, no prueba de un prerequisito ausente."
        )
        XCTAssertTrue(try report.resolvedRequirements(forAppID: "123").isEmpty)
        XCTAssertEqual(
            report.packagedRedistributables.first(where: { $0.kind == .xnaFramework31 })?.evidence.count,
            2,
            "Los aliases MSI/EXE de la misma versión forman un único requisito."
        )
    }

    func testARM64RedistributableNeverBlocksWithoutACompiledMissingPrerequisiteAuthority() throws {
        let x64 = try temporaryRoot("vc-arm64-x64-game")
        defer { try? FileManager.default.removeItem(at: x64) }
        try write("vc_redist.x64.exe", in: x64)
        try write("vc_redist.arm64.exe", in: x64)

        XCTAssertTrue(try GameTechnologyEvidenceScanner.scan(gameRootURL: x64).runtimeRequirements.isEmpty)

        let arm64 = try temporaryRoot("vc-arm64-arm64-game")
        defer { try? FileManager.default.removeItem(at: arm64) }
        try write("vc_redist.arm64.exe", in: arm64)

        XCTAssertTrue(try GameTechnologyEvidenceScanner.scan(gameRootURL: arm64).runtimeRequirements.isEmpty)
    }

    func testAmbiguousXNAAndDotNetSignalsRemainInformationalWithoutMissingPrerequisiteEvidence() throws {
        let root = try temporaryRoot("legacy-ambiguous")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Game.exe", in: root)
        try write("Microsoft.Xna.Framework.dll", in: root)
        try write("Microsoft.Xna.Framework.Game.dll", in: root)
        try write("Redist/dotNetFx.exe", in: root)

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertEqual(report.technologies.map(\.family), [.xna])
        XCTAssertTrue(report.runtimeRequirements.isEmpty)
        XCTAssertTrue(try report.resolvedRequirements(forAppID: "123").isEmpty)
    }

    func testGenericDirectXSetupIsAmbiguousAndNeverClaimsJune2010() throws {
        let root = try temporaryRoot("directx-ambiguous")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Redist/DXSETUP.exe", in: root)
        try write("Redist/DSETUP.dll", in: root)

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertEqual(report.packagedRedistributables.map(\.kind), [.directXRuntimeUnknown])
        XCTAssertTrue(report.runtimeRequirements.isEmpty)
        XCTAssertTrue(try report.resolvedRequirements(forAppID: "123").isEmpty)
    }

    func testKnownPerfectSecretsOfGrindeaXNAEvidenceDoesNotBlockTheBaseline() throws {
        let root = try temporaryRoot("secrets-of-grindea-perfect-baseline")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Secrets Of Grindea.exe", in: root)
        try write("Microsoft.Xna.Framework.dll", in: root)
        try write("Microsoft.Xna.Framework.Game.dll", in: root)

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertEqual(report.technologies.map(\.family), [.xna])
        XCTAssertTrue(report.runtimeRequirements.isEmpty)
    }

    func testKnownPerfectForsakenIsleDotNetRedistributableDoesNotBlockTheBaseline() throws {
        let root = try temporaryRoot("forsaken-isle-perfect-baseline")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Forsaken Isle.exe", in: root)
        try write("MonoGame.Framework.dll", in: root)
        try write("Redist/dotNetFx45_Full_setup.exe", in: root)
        try write("Audio/theme.wma", in: root)

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertEqual(report.packagedRedistributables.map(\.kind), [.dotNetFramework45])
        XCTAssertEqual(report.runtimeRequirements.map(\.identifier), [
            "monogame-framework",
            TrustedComponentCatalog.windowsMediaComponentID
        ])
        XCTAssertFalse(report.runtimeRequirements.contains {
            LegacyRuntimeComponentCatalog.descriptor(forRequirementIdentifier: $0.identifier) != nil
        })
    }

    func testLegacyWindowsMediaFilesResolveOnlyToTheSealedComponent() throws {
        let root = try temporaryRoot("windows-media")
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Audio/Theme.WMA", in: root)

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertEqual(report.runtimeComponents.map(\.kind), [.windowsMedia])
        XCTAssertEqual(
            report.runtimeComponents.first?.evidence,
            [GameTechnologyEvidence(
                marker: .windowsMediaAsset,
                relativePath: "Audio/Theme.WMA"
            )]
        )
        XCTAssertEqual(
            report.runtimeRequirements.map(\.identifier),
            [TrustedComponentCatalog.windowsMediaComponentID]
        )
        let resolved = try XCTUnwrap(
            report.resolvedRequirements(forAppID: "347940").first
        )
        XCTAssertEqual(
            resolved.resolution,
            .sealedComponent(
                componentID: TrustedComponentCatalog.windowsMediaComponentID,
                componentVersion: TrustedComponentCatalog.windowsMediaComponentVersion
            )
        )
        XCTAssertFalse(resolved.automaticRetryEligible)
    }

    func testWindowsMediaRepairPlannerRequiresFreshAuthorizedEvidenceAndTrustedHealth() throws {
        let appID = "347940"
        let authorization = try XCTUnwrap(
            WindowsMediaComponentRepairAuthorization(explicitAppID: appID)
        )
        let requirement = GameRuntimeRequirement(
            appID: appID,
            kind: .runtimeComponent,
            identifier: TrustedComponentCatalog.windowsMediaComponentID,
            source: .automatic
        )
        let resolved = GameRuntimeRequirementResolver.resolve(requirement)
        let currentState = GameTechnologyScanState(
            appID: appID,
            generation: 2,
            lastSuccessfulGeneration: 2,
            freshness: .current,
            attemptedAt: Date(timeIntervalSince1970: 20),
            lastSuccessfulAt: Date(timeIntervalSince1970: 20),
            error: nil
        )
        let link = URL(fileURLWithPath: "/trusted/support/Components/WindowsMedia/1")
        let target = URL(fileURLWithPath: "/trusted/Regression.app/WindowsMedia/1")
        let identity = ComponentIdentity(
            componentID: TrustedComponentCatalog.windowsMediaComponentID,
            componentVersion: TrustedComponentCatalog.windowsMediaComponentVersion,
            variant: .development,
            buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
        )
        let repairableHealth = ComponentHealthReport(
            identity: identity,
            status: .repairable,
            recovery: .createExternalLink(linkURL: link, targetURL: target),
            issue: .externalLinkMissing
        )

        XCTAssertEqual(
            WindowsMediaComponentRepairPlanner.plan(
                projection: GameTechnologyRequirementProjection(
                    scanState: currentState,
                    requirements: [resolved]
                ),
                health: repairableHealth,
                authorization: authorization,
                runtimeIsIdle: true
            ),
            .repair(.createExternalLink(linkURL: link, targetURL: target))
        )
        XCTAssertEqual(
            WindowsMediaComponentRepairPlanner.plan(
                projection: GameTechnologyRequirementProjection(
                    scanState: currentState,
                    requirements: [resolved]
                ),
                health: repairableHealth,
                authorization: authorization,
                runtimeIsIdle: false
            ),
            .blocked(.runtimeActive)
        )
        let intent = URL(fileURLWithPath: "/trusted/Transactions/WindowsMedia/intent")
        let pendingHealth = ComponentHealthReport(
            identity: identity,
            status: .repairable,
            recovery: .reconcilePendingTransaction(intentURL: intent),
            issue: .pendingTransaction
        )
        XCTAssertEqual(
            WindowsMediaComponentRepairPlanner.plan(
                projection: GameTechnologyRequirementProjection(
                    scanState: currentState,
                    requirements: [resolved]
                ),
                health: pendingHealth,
                authorization: authorization,
                runtimeIsIdle: true
            ),
            .repair(.reconcilePendingTransaction(intentURL: intent))
        )
        XCTAssertEqual(
            WindowsMediaComponentRepairPlanner.plan(
                projection: GameTechnologyRequirementProjection(
                    scanState: currentState,
                    requirements: []
                ),
                health: pendingHealth,
                authorization: authorization,
                runtimeIsIdle: true
            ),
            .repair(.reconcilePendingTransaction(intentURL: intent))
        )

        let staleState = GameTechnologyScanState(
            appID: appID,
            generation: 3,
            lastSuccessfulGeneration: 2,
            freshness: .stale,
            attemptedAt: Date(timeIntervalSince1970: 30),
            lastSuccessfulAt: Date(timeIntervalSince1970: 20),
            error: "scan failed"
        )
        XCTAssertEqual(
            WindowsMediaComponentRepairPlanner.plan(
                projection: GameTechnologyRequirementProjection(
                    scanState: staleState,
                    requirements: [resolved]
                ),
                health: repairableHealth,
                authorization: authorization,
                runtimeIsIdle: true
            ),
            .blocked(.staleEvidence)
        )

        let driftedHealth = ComponentHealthReport(
            identity: identity,
            status: .drifted,
            recovery: .reinstallTrustedArtifact,
            issue: .manifestDigestMismatch
        )
        XCTAssertEqual(
            WindowsMediaComponentRepairPlanner.plan(
                projection: GameTechnologyRequirementProjection(
                    scanState: currentState,
                    requirements: [resolved]
                ),
                health: driftedHealth,
                authorization: authorization,
                runtimeIsIdle: true
            ),
            .blocked(.trustedPayloadRequiresReinstallation)
        )
    }

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

    func testRefreshProjectionBindsManifestAppIDAnchoredScanAndSQLiteGeneration() async throws {
        let root = try temporaryRoot("fresh-projection")
        defer { try? FileManager.default.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let steamApps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        let gameRoot = steamApps.appendingPathComponent("common/Forsaken", isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        try write("Audio/theme.wma", in: gameRoot)
        let manifest = """
        "AppState"
        {
          "appid" "347940"
          "name" "Forsaken Isle"
          "installdir" "Forsaken"
          "StateFlags" "4"
        }
        """
        try Data(manifest.utf8).write(
            to: steamApps.appendingPathComponent("appmanifest_347940.acf")
        )
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        let projection = try await GameTechnologyEvidenceScanner.refreshProjection(
            appID: "347940",
            steamRootURL: steamRoot,
            repository: repository,
            observedAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(projection.scanState?.freshness, .current)
        XCTAssertEqual(projection.scanState?.generation, 1)
        XCTAssertEqual(
            projection.currentRequirements.map(\.requirement.identifier),
            [TrustedComponentCatalog.windowsMediaComponentID]
        )
    }

    func testRefreshProjectionRejectsSymlinkedAppIDManifest() async throws {
        let root = try temporaryRoot("symlinked-manifest")
        defer { try? FileManager.default.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let steamApps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        let externalManifest = root.appendingPathComponent("external.acf")
        try FileManager.default.createDirectory(at: steamApps, withIntermediateDirectories: true)
        try Data("""
        "AppState"
        {
          "appid" "347940"
          "name" "Forsaken Isle"
          "installdir" "Forsaken"
          "StateFlags" "4"
        }
        """.utf8).write(to: externalManifest)
        try FileManager.default.createSymbolicLink(
            at: steamApps.appendingPathComponent("appmanifest_347940.acf"),
            withDestinationURL: externalManifest
        )
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        do {
            _ = try await GameTechnologyEvidenceScanner.refreshProjection(
                appID: "347940",
                steamRootURL: steamRoot,
                repository: repository
            )
            XCTFail("un manifest enlazado no debe acreditar evidencia automática")
        } catch {
            XCTAssertNotNil(error as? RegressionCoreError)
        }
        let projection = try await repository.gameTechnologyRequirementProjection(appID: "347940")
        XCTAssertEqual(projection.scanState?.freshness, .stale)
        XCTAssertEqual(projection.scanState?.generation, 1)
        XCTAssertNil(projection.scanState?.lastSuccessfulGeneration)
    }

    func testRefreshProjectionRejectsSymlinkedSteamAppsRoot() async throws {
        let root = try temporaryRoot("symlinked-steamapps")
        defer { try? FileManager.default.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let external = root.appendingPathComponent("external-steamapps", isDirectory: true)
        try FileManager.default.createDirectory(at: steamRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: steamRoot.appendingPathComponent("steamapps"),
            withDestinationURL: external
        )
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        do {
            _ = try await GameTechnologyEvidenceScanner.refreshProjection(
                appID: "347940",
                steamRootURL: steamRoot,
                repository: repository
            )
            XCTFail("steamapps enlazado no debe acreditar evidencia")
        } catch {
            XCTAssertNotNil(error as? RegressionCoreError)
        }
    }

    func testRefreshProjectionRejectsGameRootSwapAfterManifestValidation() async throws {
        let root = try temporaryRoot("manifest-game-swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
        let steamApps = steamRoot.appendingPathComponent("steamapps", isDirectory: true)
        let common = steamApps.appendingPathComponent("common", isDirectory: true)
        let gameRoot = common.appendingPathComponent("Forsaken", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("Audio/theme.wma", in: outside)
        try Data("""
        "AppState"
        {
          "appid" "347940"
          "name" "Forsaken Isle"
          "installdir" "Forsaken"
          "StateFlags" "4"
        }
        """.utf8).write(to: steamApps.appendingPathComponent("appmanifest_347940.acf"))
        let repository = CompatibilityRepository(
            databaseURL: root.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        do {
            _ = try await GameTechnologyEvidenceScanner.refreshProjection(
                appID: "347940",
                steamRootURL: steamRoot,
                repository: repository,
                onManifestValidated: {
                    try? FileManager.default.removeItem(at: gameRoot)
                    try? FileManager.default.createSymbolicLink(at: gameRoot, withDestinationURL: outside)
                }
            )
            XCTFail("un swap manifest→juego no debe acreditar evidencia")
        } catch {
            XCTAssertNotNil(error as? RegressionCoreError)
        }
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
            ["unity-player"]
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
            [.informational]
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
        try write("Audio/theme.wma", in: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("UnityPlayer.dll"),
            withDestinationURL: outside.appendingPathComponent("UnityPlayer.dll")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Moon_Data"),
            withDestinationURL: outside.appendingPathComponent("Moon_Data")
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("theme.wma"),
            withDestinationURL: outside.appendingPathComponent("Audio/theme.wma")
        )

        let report = try GameTechnologyEvidenceScanner.scan(gameRootURL: root)

        XCTAssertTrue(report.technologies.isEmpty)
        XCTAssertTrue(report.runtimeComponents.isEmpty)
        XCTAssertTrue(report.runtimeRequirements.isEmpty)
        XCTAssertFalse(report.evidence.contains { $0.relativePath.contains(outside.path) })
    }

    func testSubtreeSwapDuringAnchoredTraversalFailsClosed() throws {
        let root = try temporaryRoot("subtree-swap-root")
        let outside = try temporaryRoot("subtree-swap-outside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try write("Audio/theme.wma", in: root)
        try write("injected.wma", in: outside)
        let audio = root.appendingPathComponent("Audio", isDirectory: true)
        let displaced = root.appendingPathComponent("Audio-before-swap", isDirectory: true)
        var swapped = false

        XCTAssertThrowsError(try GameTechnologyEvidenceScanner.scan(
            gameRootURL: root,
            limits: .standard,
            onDirectoryOpened: { relativePath in
                guard relativePath == "Audio", !swapped else { return }
                swapped = true
                try? FileManager.default.moveItem(at: audio, to: displaced)
                try? FileManager.default.createSymbolicLink(
                    at: audio,
                    withDestinationURL: outside
                )
            }
        ))
        XCTAssertTrue(swapped)
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
        try write("Audio/deeper/theme.wma", in: deep)
        let shallowReport = try GameTechnologyEvidenceScanner.scan(
            gameRootURL: deep,
            limits: GameTechnologyScanLimits(
                maximumDepth: 2,
                maximumEntries: 20,
                maximumMetadataBytes: 1_024
            )
        )
        XCTAssertTrue(shallowReport.technologies.isEmpty)
        XCTAssertTrue(shallowReport.runtimeComponents.isEmpty)
    }

    func testHiddenWindowsMediaAssetIsDetectedAndHiddenEntriesConsumeStandardBudget() throws {
        let mediaRoot = try temporaryRoot("hidden-media")
        defer { try? FileManager.default.removeItem(at: mediaRoot) }
        try write("Audio/.theme.WMA", in: mediaRoot)

        let mediaReport = try GameTechnologyEvidenceScanner.scan(gameRootURL: mediaRoot)
        XCTAssertEqual(mediaReport.runtimeComponents.map(\.kind), [.windowsMedia])

        let falsePositiveRoot = try temporaryRoot("media-suffix-negatives")
        defer { try? FileManager.default.removeItem(at: falsePositiveRoot) }
        try write("wma", in: falsePositiveRoot)
        try write("track.wma.", in: falsePositiveRoot)
        let falsePositiveReport = try GameTechnologyEvidenceScanner.scan(
            gameRootURL: falsePositiveRoot
        )
        XCTAssertTrue(falsePositiveReport.runtimeComponents.isEmpty)

        let budgetRoot = try temporaryRoot("hidden-budget")
        defer { try? FileManager.default.removeItem(at: budgetRoot) }
        for index in 0...4_096 {
            try Data().write(
                to: budgetRoot.appendingPathComponent(".hidden-\(index)")
            )
        }
        XCTAssertThrowsError(try GameTechnologyEvidenceScanner.scan(gameRootURL: budgetRoot))
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
            [.directXRuntimeUnknown, .visualCppX86]
        )
        XCTAssertTrue(first.evidence.map(\.relativePath).allSatisfy { !$0.contains("token=secret") })
        XCTAssertTrue(first.evidence.map(\.relativePath).allSatisfy { !$0.hasPrefix("/") })
    }
}
