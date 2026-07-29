import Foundation
@testable import RegressionCore
import XCTest

final class CompatibilityProfileSelectionTests: XCTestCase {
    func testSelectedBackendWinsWhenBothBackendsHaveEquivalentPlayableEvidence() throws {
        let crossOver = makeProfile(
            backend: .crossOver,
            fingerprint: "crossover",
            playableRuns: 1,
            unverifiedRuns: 0
        )
        let regression = makeProfile(
            backend: .regression,
            fingerprint: "regression",
            playableRuns: 1,
            unverifiedRuns: 1
        )

        let selected = try XCTUnwrap(CompatibilityProfile.preferredValidated(
            from: [crossOver, regression],
            selectedBackend: .regression
        ))

        XCTAssertEqual(selected.backend, .regression)
        XCTAssertEqual(selected.configurationFingerprint, "regression")
    }

    func testFallsBackToOtherBackendWhenSelectedBackendHasNoValidatedEvidence() throws {
        let pendingRegression = makeProfile(
            backend: .regression,
            fingerprint: "regression-pending",
            unverifiedRuns: 1
        )
        let playableCrossOver = makeProfile(
            backend: .crossOver,
            fingerprint: "crossover-playable",
            playableRuns: 1
        )

        let selected = try XCTUnwrap(CompatibilityProfile.preferredValidated(
            from: [pendingRegression, playableCrossOver],
            selectedBackend: .regression
        ))

        XCTAssertEqual(selected.backend, .crossOver)
    }

    func testBestValidatedProfileIsChosenWithinSelectedBackend() throws {
        let playable = makeProfile(
            backend: .regression,
            fingerprint: "playable",
            playableRuns: 2
        )
        let perfect = makeProfile(
            backend: .regression,
            fingerprint: "perfect",
            perfectRuns: 1,
            failedRuns: 2
        )

        let selected = try XCTUnwrap(CompatibilityProfile.preferredValidated(
            from: [playable, perfect],
            selectedBackend: .regression
        ))

        XCTAssertEqual(selected.configurationFingerprint, "perfect")
    }

    func testReturnsNilWhenThereIsNoValidatedEvidence() {
        let pending = makeProfile(
            backend: .regression,
            fingerprint: "pending",
            failedRuns: 1,
            unverifiedRuns: 1
        )

        XCTAssertNil(CompatibilityProfile.preferredValidated(
            from: [pending],
            selectedBackend: .regression
        ))
    }

    private func makeProfile(
        backend: BackendKind,
        fingerprint: String,
        perfectRuns: Int = 0,
        playableRuns: Int = 0,
        failedRuns: Int = 0,
        unverifiedRuns: Int = 0
    ) -> CompatibilityProfile {
        CompatibilityProfile(
            appID: "2054970",
            gameName: "Dragon's Dogma 2",
            backend: backend,
            configurationFingerprint: fingerprint,
            successfulRuns: perfectRuns + playableRuns,
            failedRuns: failedRuns,
            perfectRuns: perfectRuns,
            playableRuns: playableRuns,
            unverifiedRuns: unverifiedRuns,
            averageLaunchMilliseconds: nil,
            lastSuccessfulAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
