import XCTest
@testable import RegressionCore

final class RegressionDistributionPolicyTests: XCTestCase {
    func testFreshInstallationDefaultsToRegression() {
        XCTAssertEqual(
            BackendKind.launchSelection(storedRawValue: nil),
            .regression
        )
    }

    func testLegacyCrossOverPreferenceIsNormalizedToRegression() {
        XCTAssertEqual(
            BackendKind.launchSelection(storedRawValue: BackendKind.crossOver.rawValue),
            .regression
        )
        XCTAssertEqual(
            BackendKind.launchSelection(storedRawValue: BackendKind.regression.rawValue),
            .regression
        )
    }

    func testInvalidStoredPreferenceFallsBackToRegression() {
        XCTAssertEqual(
            BackendKind.launchSelection(storedRawValue: "invalid"),
            .regression
        )
    }

    func testUnavailableComparatorFallsBackToRegression() {
        XCTAssertEqual(
            BackendKind.availableSelection(
                preferred: .crossOver,
                crossOverAvailable: false
            ),
            .regression
        )
    }

    func testHistoricalComparatorAvailabilityCannotChangeSelection() {
        XCTAssertEqual(
            BackendKind.availableSelection(
                preferred: .crossOver,
                crossOverAvailable: true
            ),
            .regression
        )
    }
}
