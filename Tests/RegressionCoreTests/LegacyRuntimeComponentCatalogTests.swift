import Foundation
import XCTest

@testable import RegressionCore

final class LegacyRuntimeComponentCatalogTests: XCTestCase {
    func testKnownLegacyRequirementsRemainTypedAndNonExecutableUntilASealedPayloadExists() throws {
        let requirements = [
            "directx-june-2010-runtime",
            "microsoft-xna-framework-3.1",
            "microsoft-xna-framework-4.0",
            "microsoft-dotnet-framework-4.0",
            "microsoft-vc-runtime-arm64"
        ]

        for identifier in requirements {
            let descriptor = try XCTUnwrap(
                LegacyRuntimeComponentCatalog.descriptor(forRequirementIdentifier: identifier)
            )
            XCTAssertEqual(descriptor.hashRequirement, .sha256RequiredBeforeInstallation)
            XCTAssertEqual(descriptor.source, .officialPublisher)
            XCTAssertFalse(descriptor.license.isEmpty)

            let resolution = try XCTUnwrap(
                LegacyRuntimeComponentCatalog.resolution(
                    forRequirementIdentifier: identifier,
                )
            )
            XCTAssertEqual(resolution.componentID, descriptor.componentID)
            XCTAssertEqual(resolution.componentVersion, descriptor.componentVersion)
            XCTAssertFalse(resolution.isReady)
        }
    }

    func testUnknownOrAmbiguousLegacyRequirementsBlockWithAnExplanation() throws {
        let xna = try XCTUnwrap(
            LegacyRuntimeComponentCatalog.resolution(
                forRequirementIdentifier: "microsoft-xna-framework-unknown",
            )
        )
        XCTAssertEqual(xna.state, .required)
        XCTAssertTrue(xna.explanation.localizedCaseInsensitiveContains("versión"))

        let dotNet = try XCTUnwrap(
            LegacyRuntimeComponentCatalog.resolution(
                forRequirementIdentifier: "microsoft-dotnet-framework-observed",
            )
        )
        XCTAssertEqual(dotNet.state, .observed)
        XCTAssertTrue(dotNet.explanation.localizedCaseInsensitiveContains("versión"))
    }

    func testArbitraryComponentHealthCannotMoveLegacyRequirementToReady() throws {
        let descriptor = try XCTUnwrap(
            LegacyRuntimeComponentCatalog.descriptor(
                componentID: "microsoft-dotnet-framework-4.0"
            )
        )
        let ready = ComponentHealthReport(
            identity: ComponentIdentity(
                componentID: descriptor.componentID,
                componentVersion: descriptor.componentVersion,
                variant: .publicInstalled,
                buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
            ),
            status: .ready,
            recovery: .none
        )
        XCTAssertEqual(ready.status, .ready)
        XCTAssertEqual(
            LegacyRuntimeComponentCatalog.resolution(
                forRequirementIdentifier: "microsoft-dotnet-framework-4.0"
            )?.state,
            .installableMissing,
            "Un reporte de salud arbitrario no es un descriptor sellado de un componente legacy."
        )
    }

    func testResolverDoesNotPromoteLegacyEvidenceToAutomaticRepair() {
        let directX = GameRuntimeRequirement(
            appID: "123",
            kind: .runtimeComponent,
            identifier: "directx-june-2010-runtime",
            source: .automatic
        )
        let arm64 = GameRuntimeRequirement(
            appID: "123",
            kind: .runtimeComponent,
            identifier: "microsoft-vc-runtime-arm64",
            source: .automatic
        )

        XCTAssertEqual(
            GameRuntimeRequirementResolver.resolve(directX).resolution,
            .legacyComponent(
                componentID: "directx-june-2010-runtime",
                componentVersion: "June 2010",
                state: .installableMissing
            )
        )
        XCTAssertEqual(
            GameRuntimeRequirementResolver.resolve(arm64).resolution,
            .legacyComponent(
                componentID: "microsoft-vc-runtime-arm64",
                componentVersion: "latest-supported",
                state: .unsupported
            )
        )
        XCTAssertFalse(GameRuntimeRequirementResolver.resolve(directX).automaticRetryEligible)
    }
}
