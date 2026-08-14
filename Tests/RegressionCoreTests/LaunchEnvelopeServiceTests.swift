import Foundation
@testable import RegressionCore
import XCTest

final class LaunchEnvelopeServiceTests: XCTestCase {
    func testPrepareRequiresExactFreshPreflightAndRequirementsBeforeItCreatesIntent() throws {
        let service = LaunchEnvelopeService()
        let request = LaunchEnvelopeRequest(
            appID: "219990",
            backend: .regression,
            runID: UUID(),
            preflight: preflight(appID: "219990"),
            requirements: projection(appID: "219990", freshness: .stale),
            componentHealth: .init(runtime: readyRuntimeHealth(), windowsMedia: nil),
            rendererIsEligible: true
        )

        XCTAssertThrowsError(try service.prepare(request)) { error in
            XCTAssertEqual(
                error as? LaunchEnvelopeError,
                .requirementsNotFresh(appID: "219990")
            )
        }
    }

    func testPrepareCreatesDurableSafeIntentWithoutExecutableInstructions() throws {
        let id = UUID()
        let service = LaunchEnvelopeService()
        let intent = try service.prepare(LaunchEnvelopeRequest(
            appID: "219990",
            backend: .regression,
            runID: id,
            preflight: preflight(appID: "219990"),
            requirements: projection(appID: "219990", freshness: .current),
            componentHealth: .init(runtime: readyRuntimeHealth(), windowsMedia: nil),
            rendererIsEligible: true
        ))

        XCTAssertEqual(intent.runID, id)
        XCTAssertEqual(intent.appID, "219990")
        XCTAssertEqual(intent.backend, .regression)
        XCTAssertEqual(intent.phase, .intentDurable)
        XCTAssertTrue(intent.requirementIdentities.isEmpty)
        XCTAssertFalse(intent.description.contains("/"))
        XCTAssertFalse(intent.description.lowercased().contains("dll"))
    }

    func testSealedPreflightTTLAcceptsNinetySecondsAndRejectsAnythingOlder() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let accepted = LaunchEnvelopeService(now: {
            checkedAt.addingTimeInterval(LaunchEnvelopeService.maximumSealedPreflightAge)
        })
        let rejected = LaunchEnvelopeService(now: {
            checkedAt.addingTimeInterval(LaunchEnvelopeService.maximumSealedPreflightAge + 0.001)
        })
        let request = LaunchEnvelopeRequest(
            appID: "219990",
            backend: .regression,
            runID: UUID(),
            preflight: preflight(appID: "219990", checkedAt: checkedAt),
            requirements: projection(appID: "219990", freshness: .current),
            componentHealth: .init(runtime: readyRuntimeHealth(), windowsMedia: nil),
            rendererIsEligible: true
        )

        XCTAssertNoThrow(try accepted.prepare(request))
        XCTAssertThrowsError(try rejected.prepare(request)) { error in
            XCTAssertEqual(error as? LaunchEnvelopeError, .preflightStale)
        }
    }

    func testPrepareBlocksOnlyGameWhenWindowsMediaRequirementNeedsExplicitRepair() throws {
        let service = LaunchEnvelopeService()
        let required = ResolvedGameRuntimeRequirement(
            requirement: GameRuntimeRequirement(
                appID: "347940",
                kind: .runtimeComponent,
                identifier: TrustedComponentCatalog.windowsMediaComponentID,
                source: .automatic
            ),
            resolution: .sealedComponent(
                componentID: TrustedComponentCatalog.windowsMediaComponentID,
                componentVersion: TrustedComponentCatalog.windowsMediaComponentVersion
            )
        )
        let request = LaunchEnvelopeRequest(
            appID: "347940",
            backend: .regression,
            runID: UUID(),
            preflight: preflight(appID: "347940"),
            requirements: projection(
                appID: "347940",
                freshness: .current,
                requirements: [required]
            ),
            componentHealth: .init(runtime: readyRuntimeHealth(), windowsMedia: repairableWindowsMediaHealth()),
            rendererIsEligible: true
        )

        XCTAssertThrowsError(try service.prepare(request)) { error in
            XCTAssertEqual(
                error as? LaunchEnvelopeError,
                .explicitComponentRepairRequired(
                    appID: "347940",
                    componentID: TrustedComponentCatalog.windowsMediaComponentID
                )
            )
        }
    }

    func testLegacyComponentReadyWithFabricatedHealthStillHasNoSealedAuthority() throws {
        let legacy = ResolvedGameRuntimeRequirement(
            requirement: GameRuntimeRequirement(
                appID: "219990",
                kind: .runtimeComponent,
                identifier: "microsoft-dotnet-framework-4.0",
                source: .automatic
            ),
            resolution: .legacyComponent(
                componentID: "microsoft-dotnet-framework-4.0",
                componentVersion: "4.0",
                state: .ready
            )
        )
        let request = LaunchEnvelopeRequest(
            appID: "219990",
            backend: .regression,
            runID: UUID(),
            preflight: preflight(appID: "219990"),
            requirements: projection(appID: "219990", freshness: .current, requirements: [legacy]),
            componentHealth: .init(runtime: readyRuntimeHealth(), windowsMedia: nil),
            rendererIsEligible: true
        )

        XCTAssertThrowsError(try LaunchEnvelopeService().prepare(request)) { error in
            XCTAssertEqual(
                error as? LaunchEnvelopeError,
                .legacyComponentNoSealedAuthority(
                    appID: "219990",
                    componentID: "microsoft-dotnet-framework-4.0"
                )
            )
        }
    }

    func testRetryIsBoundedToOneRegressionOriginCompiledAttempt() {
        let service = LaunchEnvelopeService()
        let eligible = LaunchEnvelopeRepairAttempt(
            appID: "219990",
            launchOrigin: .regression,
            recipe: .gameMakerRetinaFullscreen,
            recipeVersion: 1,
            priorAutomaticRetryCount: 0,
            phase: .appliedAwaitingRelaunch
        )
        XCTAssertEqual(service.retryDecision(for: eligible), .automaticRetry)

        let exhausted = LaunchEnvelopeRepairAttempt(
            appID: "219990",
            launchOrigin: .regression,
            recipe: .gameMakerRetinaFullscreen,
            recipeVersion: 1,
            priorAutomaticRetryCount: 1,
            phase: .appliedAwaitingRelaunch
        )
        XCTAssertEqual(service.retryDecision(for: exhausted), .requiresUserGesture(.retryLimitReached))

        let observed = LaunchEnvelopeRepairAttempt(
            appID: "219990",
            launchOrigin: .steamObserved,
            recipe: .gameMakerRetinaFullscreen,
            recipeVersion: 1,
            priorAutomaticRetryCount: 0,
            phase: .appliedAwaitingRelaunch
        )
        XCTAssertEqual(service.retryDecision(for: observed), .requiresUserGesture(.steamObservedOrigin))
    }

    func testInterruptedAppliedRepairRequiresRollbackAndNeverCertifies() {
        let service = LaunchEnvelopeService()
        let attempt = LaunchEnvelopeRepairAttempt(
            appID: "219990",
            launchOrigin: .regression,
            recipe: .gameMakerRetinaFullscreen,
            recipeVersion: 1,
            priorAutomaticRetryCount: 0,
            phase: .appliedAwaitingRelaunch
        )

        XCTAssertEqual(service.recoveryDecision(for: attempt), .rollbackRequired)
        XCTAssertEqual(
            service.postRunDecision(telemetryClosed: false, verificationCompleted: false),
            .awaitTelemetry
        )
        XCTAssertEqual(
            service.postRunDecision(telemetryClosed: true, verificationCompleted: false),
            .requiresExplicitVerification
        )
    }
}

private extension LaunchEnvelopeServiceTests {
    func preflight(appID: String, checkedAt: Date = Date()) -> GameTestPreflightReport {
        GameTestPreflightReport(
            appID: appID,
            gameName: "Test Game",
            backend: .regression,
            checkedAt: checkedAt,
            checks: GameTestPreflightCheckID.allCases.map { check in
                GameTestPreflightCheck(
                    checkID: check,
                    status: .ready,
                    title: check.rawValue,
                    detail: "ok"
                )
            }
        )
    }

    func projection(
        appID: String,
        freshness: GameTechnologyScanFreshness,
        requirements: [ResolvedGameRuntimeRequirement] = []
    ) -> GameTechnologyRequirementProjection {
        GameTechnologyRequirementProjection(
            scanState: GameTechnologyScanState(
                appID: appID,
                generation: 1,
                lastSuccessfulGeneration: freshness == .current ? 1 : nil,
                freshness: freshness,
                attemptedAt: Date(),
                lastSuccessfulAt: freshness == .current ? Date() : nil,
                error: freshness == .current ? nil : "interrumpido"
            ),
            requirements: requirements
        )
    }

    func readyRuntimeHealth() -> ComponentHealthReport {
        ComponentHealthReport(
            identity: ComponentIdentity(
                componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
                componentVersion: TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion,
                variant: .publicInstalled,
                buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
            ),
            status: .ready,
            recovery: .none
        )
    }

    func repairableWindowsMediaHealth() -> ComponentHealthReport {
        ComponentHealthReport(
            identity: ComponentIdentity(
                componentID: TrustedComponentCatalog.windowsMediaComponentID,
                componentVersion: TrustedComponentCatalog.windowsMediaComponentVersion,
                variant: .publicInstalled,
                buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
            ),
            status: .repairable,
            recovery: .createExternalLink(
                linkURL: URL(fileURLWithPath: "/private/tmp/windows-media-link"),
                targetURL: URL(fileURLWithPath: "/private/tmp/windows-media-payload")
            )
        )
    }
}
