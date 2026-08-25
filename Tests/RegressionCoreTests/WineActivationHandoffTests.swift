import Foundation
import XCTest
@testable import RegressionCore

final class WineActivationHandoffTests: XCTestCase {
    private let bottle = URL(fileURLWithPath: "/Users/prueba/Library/Application Support/Regression/Bottles/Steam")

    private func userInfo(
        pid: Any? = NSNumber(value: 4242),
        prefix: String? = "/Users/prueba/Library/Application Support/Regression/Bottles/Steam",
        configuration: String? = nil
    ) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [:]
        if let pid { info[WineActivationHandoff.processIdentifierKey] = pid }
        if let prefix { info[WineActivationHandoff.bottleKey] = prefix }
        if let configuration { info[WineActivationHandoff.configurationDirectoryKey] = configuration }
        return info
    }

    func testRequestIsReadFromTheNotificationPayload() throws {
        let request = try XCTUnwrap(WineActivationHandoff.request(from: userInfo(configuration: "/cfg")))
        XCTAssertEqual(request.processIdentifier, 4242)
        XCTAssertEqual(request.configurationDirectory, "/cfg")
        XCTAssertTrue(request.bottlePath.hasSuffix("Bottles/Steam"))
    }

    /// La notificación es distribuida: cualquier proceso del sistema puede publicarla, así que
    /// una carga malformada no puede acabar en una cesión.
    func testMalformedPayloadsAreRejected() {
        XCTAssertNil(WineActivationHandoff.request(from: nil))
        XCTAssertNil(WineActivationHandoff.request(from: [:]))
        XCTAssertNil(WineActivationHandoff.request(from: userInfo(pid: nil)))
        XCTAssertNil(WineActivationHandoff.request(from: userInfo(pid: "no soy un pid")))
        XCTAssertNil(WineActivationHandoff.request(from: userInfo(pid: NSNumber(value: 0))))
        XCTAssertNil(WineActivationHandoff.request(from: userInfo(pid: NSNumber(value: -1))))
    }

    /// Wine publica el PID como número, pero acepta también su forma textual.
    func testTextualProcessIdentifierIsAccepted() throws {
        let request = try XCTUnwrap(WineActivationHandoff.request(from: userInfo(pid: "77")))
        XCTAssertEqual(request.processIdentifier, 77)
    }

    func testYieldsToAProcessOfOurOwnBottle() throws {
        let request = try XCTUnwrap(WineActivationHandoff.request(from: userInfo()))
        XCTAssertTrue(WineActivationHandoff.shouldYield(
            to: request, applicationIsActive: true, ourProcessIdentifier: 10, bottle: bottle
        ))
    }

    /// Ceder sin estar activo no sirve de nada y enturbia el protocolo.
    func testDoesNotYieldWhenTheApplicationIsNotActive() throws {
        let request = try XCTUnwrap(WineActivationHandoff.request(from: userInfo()))
        XCTAssertFalse(WineActivationHandoff.shouldYield(
            to: request, applicationIsActive: false, ourProcessIdentifier: 10, bottle: bottle
        ))
    }

    func testDoesNotYieldToItself() throws {
        let request = try XCTUnwrap(WineActivationHandoff.request(from: userInfo()))
        XCTAssertFalse(WineActivationHandoff.shouldYield(
            to: request, applicationIsActive: true, ourProcessIdentifier: 4242, bottle: bottle
        ))
    }

    func testDoesNotYieldToAnotherBottle() throws {
        let request = try XCTUnwrap(WineActivationHandoff.request(from: userInfo(
            prefix: "/Users/prueba/Library/Application Support/Otra/Bottles/Steam"
        )))
        XCTAssertFalse(WineActivationHandoff.shouldYield(
            to: request, applicationIsActive: true, ourProcessIdentifier: 10, bottle: bottle
        ))
    }

    /// Un prefijo ausente no acredita nada, así que no autoriza la cesión.
    func testDoesNotYieldWhenThePrefixIsMissing() throws {
        let request = try XCTUnwrap(WineActivationHandoff.request(from: userInfo(prefix: "")))
        XCTAssertFalse(WineActivationHandoff.shouldYield(
            to: request, applicationIsActive: true, ourProcessIdentifier: 10, bottle: bottle
        ))
    }

    /// La ruta puede llegar sin normalizar; sigue siendo la misma botella.
    func testEquivalentPathsAreTheSameBottle() throws {
        let request = try XCTUnwrap(WineActivationHandoff.request(from: userInfo(
            prefix: "/Users/prueba/Library/Application Support/Regression/Bottles/./Steam/"
        )))
        XCTAssertTrue(WineActivationHandoff.shouldYield(
            to: request, applicationIsActive: true, ourProcessIdentifier: 10, bottle: bottle
        ))
    }
}
