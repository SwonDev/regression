import XCTest
@testable import RegressionCore

final class RegressionDistributionPolicyTests: XCTestCase {
    func testFreshInstallationDefaultsToRegression() {
        XCTAssertEqual(
            BackendKind.launchSelection(storedRawValue: nil),
            .regression
        )
    }

    func testExplicitBackendPreferenceIsPreserved() {
        XCTAssertEqual(
            BackendKind.launchSelection(storedRawValue: BackendKind.crossOver.rawValue),
            .crossOver
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

    func testAvailableComparatorPreferenceIsPreserved() {
        XCTAssertEqual(
            BackendKind.availableSelection(
                preferred: .crossOver,
                crossOverAvailable: true
            ),
            .crossOver
        )
    }
}
