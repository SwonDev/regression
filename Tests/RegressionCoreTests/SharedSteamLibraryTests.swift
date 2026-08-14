import Darwin
import Foundation
@testable import RegressionCore
import XCTest

final class SharedSteamLibraryTests: XCTestCase {
    func testCustodyValidationEvidenceAndFactoryAreNotPublicAPI() throws {
        let root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let moduleDirectory = Bundle(for: SharedSteamLibraryTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Modules", isDirectory: true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: moduleDirectory.appendingPathComponent("RegressionCore.swiftmodule").path
            )
        )

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-custody-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("External.swift")
        try """
        import Foundation
        import RegressionCore
        func unavailable<T>() -> T { fatalError() }
        let _: PhysicalLibraryCustodyValidationEvidence = unavailable()
        _ = try PhysicalLibraryCustodyCommandPolicy.linkedValidationEvidence(
            request: unavailable(), run: unavailable(), validationBoundary: unavailable()
        )
        """.write(to: source, atomically: true, encoding: .utf8)

        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-typecheck",
            "-I", moduleDirectory.path,
            "-Xcc", "-fmodule-map-file=\(root.path)/Sources/CSQLite/module.modulemap",
            source.path,
        ]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertNotEqual(process.terminationStatus, 0, "Un cliente externo fabricó evidencia")
        XCTAssertTrue(
            diagnostic.contains("cannot find type 'PhysicalLibraryCustodyValidationEvidence'")
                && diagnostic.contains("has no member 'linkedValidationEvidence'"),
            "Diagnóstico inesperado: \(diagnostic)"
        )
    }

    func testLegacyBooleanFinalizationAPIIsNotExternallyCallable() throws {
        let root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let moduleDirectory = Bundle(for: SharedSteamLibraryTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Modules", isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-custody-finalize-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("External.swift")
        try """
        import Foundation
        import RegressionCore
        func unavailable<T>() -> T { fatalError() }
        func bypass(_ manager: SharedSteamLibraryManager) async throws {
            _ = try await manager.finalizePhysicalCustody(
                regression: unavailable(),
                legacyIdentity: unavailable(),
                validationLease: unavailable(),
                validationPassed: true,
                runningState: unavailable()
            )
            _ = try await manager.finalizePhysicalCustodyValidated(
                regression: unavailable(),
                legacyIdentity: unavailable(),
                request: unavailable(),
                repository: unavailable(),
                runningState: unavailable()
            )
        }
        """.write(to: source, atomically: true, encoding: .utf8)

        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-typecheck",
            "-I", moduleDirectory.path,
            "-Xcc", "-fmodule-map-file=\(root.path)/Sources/CSQLite/module.modulemap",
            source.path,
        ]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(
            data: errors.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        XCTAssertNotEqual(process.terminationStatus, 0, "Un cliente externo cerró custodia con Bool")
        XCTAssertTrue(
            diagnostic.contains("has no member 'finalizePhysicalCustody'")
                && diagnostic.contains("inaccessible due to 'package' protection level"),
            "Diagnóstico inesperado: \(diagnostic)"
        )
    }

    func testFreshInstallCreatesIndependentPhysicalRegressionLibraryWithoutLegacySource() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.crossOverSteamApps)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let first = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        XCTAssertEqual(first.status, .independent)
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.regressionSteamApps))
        XCTAssertFalse(fixture.pathExists(fixture.crossOverSteamApps))
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.regressionSteamApps.path)
        )
        XCTAssertEqual(first.inventory.manifestAppIDs, [])
        let originalIdentity = try fixture.identity(at: fixture.regressionSteamApps)

        let second = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        XCTAssertEqual(second.status, .independent)
        XCTAssertEqual(try fixture.identity(at: fixture.regressionSteamApps), originalIdentity)
        let interlock = await manager.currentPhysicalLibraryCustodyInterlock()
        XCTAssertEqual(
            interlock,
            .init(status: .independent, mutationPolicy: .unrestricted)
        )
    }

    func testFreshInstallAdoptsExistingPhysicalRegressionLibraryWithoutReplacingIt() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.crossOverSteamApps)
        try FileManager.default.createDirectory(
            at: fixture.regressionSteamApps,
            withIntermediateDirectories: false
        )
        let marker = fixture.regressionSteamApps.appendingPathComponent("libraryfolders.vdf")
        try Data("biblioteca propia".utf8).write(to: marker)
        let originalIdentity = try fixture.identity(at: fixture.regressionSteamApps)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        XCTAssertEqual(assessment.status, .independent)
        XCTAssertEqual(try fixture.identity(at: fixture.regressionSteamApps), originalIdentity)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "biblioteca propia")
        XCTAssertEqual(assessment.inventory.regularFileCount, 1)
    }

    func testFreshIndependentLibraryDoesNotDependOnFutureCrossOverInstallation() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.crossOverSteamApps)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let initialized = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )
        XCTAssertEqual(initialized.status, .independent)

        try FileManager.default.createDirectory(
            at: fixture.crossOverSteamApps,
            withIntermediateDirectories: false
        )
        let reassessed = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )
        let interlock = await manager.currentPhysicalLibraryCustodyInterlock()

        XCTAssertEqual(reassessed.status, .independent)
        XCTAssertEqual(interlock.status, .independent)
        XCTAssertEqual(interlock.mutationPolicy, .unrestricted)
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.regressionSteamApps))
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
    }

    func testFreshIndependentLibraryBlocksIfFutureCrossOverSteamAppsContainsFiles() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.crossOverSteamApps)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let initialized = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )
        XCTAssertEqual(initialized.status, .independent)

        try FileManager.default.createDirectory(
            at: fixture.crossOverSteamApps,
            withIntermediateDirectories: false
        )
        let duplicate = fixture.crossOverSteamApps.appendingPathComponent("appmanifest_42.acf")
        try Data("AppState".utf8).write(to: duplicate)

        let reassessed = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )
        let interlock = await manager.currentPhysicalLibraryCustodyInterlock()

        XCTAssertTrue(reassessed.blockedReason?.contains("recibo") == true)
        XCTAssertEqual(interlock.mutationPolicy, .blocked)
        XCTAssertEqual(try String(contentsOf: duplicate, encoding: .utf8), "AppState")
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.regressionSteamApps))
    }

    func testFreshInstallFailsClosedWhenRegressionSteamAppsIsASymbolicLink() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.crossOverSteamApps)
        let external = fixture.root.appendingPathComponent("external-steamapps", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let marker = external.appendingPathComponent("preservar")
        try Data("intacto".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: fixture.regressionSteamApps,
            withDestinationURL: external
        )
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        XCTAssertTrue(assessment.blockedReason?.contains("no es un directorio físico") == true)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "intacto")
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.regressionSteamApps.path),
            external.path
        )
    }

    func testAssessmentDerivesDestinationInsideRegressionBottle() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        try fixture.writeManifest(appID: "42")
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        XCTAssertEqual(assessment.status, .eligibleForTransfer)
        XCTAssertEqual(assessment.destinationSteamAppsURL, fixture.regressionSteamApps)
        XCTAssertEqual(assessment.inventory.manifestAppIDs, ["42"])
    }

    func testCallerCannotRedirectCustodyOutsideRegressionBottle() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            regressionOwnedSteamAppsURL: fixture.root.appendingPathComponent("external/steamapps"),
            runningState: .init()
        )

        XCTAssertEqual(assessment.destinationSteamAppsURL, fixture.regressionSteamApps)
        XCTAssertTrue(assessment.blockedReason?.contains("dentro de la botella") == true)
    }

    func testMigrationMovesSinglePhysicalTreeAndWaitsForRuntimeValidation() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        try fixture.writeManifest(appID: "42")
        let originalIdentity = try fixture.identity(at: fixture.crossOverSteamApps)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )

        XCTAssertEqual(assessment.status, .pendingValidation)
        XCTAssertFalse(fixture.pathExists(fixture.crossOverSteamApps))
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.regressionSteamApps))
        XCTAssertEqual(try fixture.identity(at: fixture.regressionSteamApps), originalIdentity)
        XCTAssertEqual(try fixture.physicalSteamAppsTrees(), [fixture.regressionSteamApps])
        XCTAssertEqual(try fixture.stagedLinks().count, 1)
    }

    func testValidationLeaseAuthorizesOnlyRegressionAndFinalizeMakesOwnershipDurable() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        try fixture.writeManifest(appID: "42")
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )

        let unauthorized = await manager.authorizePhysicalLibraryCustodyMutation(
            backend: .regression,
            validationLease: nil
        )
        XCTAssertFalse(unauthorized)
        let lease = try await manager.beginPhysicalCustodyValidation(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )
        let regressionAuthorized = await manager.authorizePhysicalLibraryCustodyMutation(
            backend: .regression,
            validationLease: lease
        )
        let crossOverAuthorized = await manager.authorizePhysicalLibraryCustodyMutation(
            backend: .crossOver,
            validationLease: lease
        )
        XCTAssertTrue(regressionAuthorized)
        XCTAssertFalse(crossOverAuthorized)

        let authority = try await custodyValidationAuthority(in: fixture.root)
        let completed = try await manager.finalizePhysicalCustodyValidated(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            request: authority.request,
            repository: authority.repository,
            runningState: .init()
        )

        XCTAssertEqual(completed.status, .independent)
        XCTAssertFalse(fixture.pathExists(fixture.crossOverSteamApps))
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.regressionSteamApps))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.receipt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
        XCTAssertTrue(try fixture.stagedLinks().isEmpty)

        let restarted = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let assessment = await restarted.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )
        XCTAssertEqual(assessment.status, .independent)
    }

    func testCrossOverNeverReceivesCustodyMutationAuthorityBeforeCutover() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let snapshot = await manager.currentPhysicalLibraryCustodyInterlock()
        XCTAssertEqual(snapshot.status, .eligibleForTransfer)
        XCTAssertEqual(snapshot.mutationPolicy, .unrestricted)
        XCTAssertFalse(snapshot.crossOverUnavailable)

        let authorized = await manager.authorizePhysicalLibraryCustodyMutation(
            backend: .crossOver,
            validationLease: nil
        )
        XCTAssertFalse(authorized)
        await assertUnsafeLibraryState(containing: "Regression") {
            _ = try await manager.acquirePhysicalLibraryCustodyMutationPermit(
                backend: .crossOver,
                validationLease: nil
            )
        }
        XCTAssertFalse(
            fixture.pathExists(
                fixture.backupRoot.appendingPathComponent("physical-custody.lock")
            )
        )
    }

    func testCustodyFinalizationRejectsRequestWithoutExactDatabaseRow() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        let authority = try await custodyValidationAuthority(in: fixture.root)
        let forged = PhysicalLibraryCustodyValidationRequest(
            appID: authority.request.appID,
            runID: UUID()
        )

        await assertInvalidEvidence(containing: "no existe") {
            _ = try await manager.finalizePhysicalCustodyValidated(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                request: forged,
                repository: authority.repository,
                runningState: .init()
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testCustodyFinalizationRejectsHistoricalAndAutomaticDatabaseEvidence() async throws {
        for scenario in [(VerificationSource.visualInspection, -100.0), (.automatic, 1.0)] {
            let fixture = try CustodyFixture()
            defer { fixture.remove() }
            try fixture.makeSharedLayout()
            let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
            _ = try await manager.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { .init() }
            )
            let authority = try await custodyValidationAuthority(
                in: fixture.root,
                source: scenario.0,
                startedAtOffset: scenario.1
            )

            await assertInvalidEvidence(containing: "no es una validación local perfecta") {
                _ = try await manager.finalizePhysicalCustodyValidated(
                    regression: fixture.regression,
                    legacyIdentity: fixture.legacyIdentity,
                    request: authority.request,
                    repository: authority.repository,
                    runningState: .init()
                )
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journal.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        }
    }

    func testFailedRuntimeValidationRestoresExactInitialTopology() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout(relativeLink: true)
        let originalRawLink = try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.regressionSteamApps.path
        )
        let originalIdentity = try fixture.identity(at: fixture.crossOverSteamApps)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        _ = try await manager.beginPhysicalCustodyValidation(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        let rolledBack = try await manager.rollbackPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        XCTAssertEqual(rolledBack.status, .eligibleForTransfer)
        XCTAssertEqual(try fixture.identity(at: fixture.crossOverSteamApps), originalIdentity)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.regressionSteamApps.path),
            originalRawLink
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
        XCTAssertEqual(try fixture.physicalSteamAppsTrees(), [fixture.crossOverSteamApps])
    }

    func testEveryCutoverCrashWindowRecoversIdempotently() async throws {
        let points: [PhysicalLibraryCustodyFaultPoint] = [
            .afterPrepared,
            .afterWillStageDestination,
            .afterDestinationStagedRename,
            .afterDestinationStagedJournal,
            .afterWillCommitCutover,
            .afterCutoverRename,
            .afterCutoverJournal,
            .afterVerifyingJournal
        ]
        for point in points {
            let fixture = try CustodyFixture()
            defer { fixture.remove() }
            try fixture.makeSharedLayout()
            try fixture.writeManifest(appID: "42")
            let injected = SharedSteamLibraryManager(
                backupRootURL: fixture.backupRoot,
                directoryEnumeratorProvider: CustodyFixture.enumerator,
                custodyFault: { observed in
                    if String(describing: observed) == String(describing: point) {
                        throw InjectedCrash()
                    }
                }
            )
            do {
                _ = try await injected.migratePhysicalCustody(
                    regression: fixture.regression,
                    legacyIdentity: fixture.legacyIdentity,
                    runningStateProvider: { .init() }
                )
                XCTFail("La ventana \(point) debía interrumpirse")
            } catch is InjectedCrash {
                // Simula un proceso nuevo tras el crash.
            }

            let recovered = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
            let result = try await recovered.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { .init() }
            )
            XCTAssertEqual(result.status, .pendingValidation, "Fallo al recuperar \(point)")
            XCTAssertFalse(fixture.pathExists(fixture.crossOverSteamApps))
            XCTAssertTrue(fixture.isPhysicalDirectory(fixture.regressionSteamApps))
            XCTAssertEqual(try fixture.physicalSteamAppsTrees().count, 1)
        }
    }

    func testSteamReappearingAtLastGateStopsBeforeCutoverAndRollbackIsExact() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let states = LockedStates([
            .init(),
            .init(),
            .init(),
            .init(regressionPIDs: [404]),
        ])

        await assertUnsafeLibraryState(containing: "Steam debe estar completamente cerrado") {
            _ = try await manager.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { states.next() }
            )
        }
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
        XCTAssertFalse(fixture.pathExists(fixture.regressionSteamApps))
        XCTAssertEqual(try fixture.stagedLinks().count, 1)

        _ = try await manager.rollbackPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.regressionSteamApps.path))
        let interlock = await manager.currentPhysicalLibraryCustodyInterlock()
        XCTAssertEqual(interlock.mutationPolicy, .unrestricted)
    }

    func testInventoryMutationAtLastGateStopsBeforeCutover() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let changed = fixture.crossOverSteamApps.appendingPathComponent("late-change.bin")
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: CustodyFixture.enumerator,
            custodyFault: { point in
                if String(describing: point)
                    == String(describing: PhysicalLibraryCustodyFaultPoint.afterDestinationStagedJournal)
                {
                    try Data("cambio tardío".utf8).write(to: changed)
                }
            }
        )

        await assertUnsafeLibraryState(containing: "cambió antes del cutover") {
            _ = try await manager.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { .init() }
            )
        }
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
        XCTAssertFalse(fixture.pathExists(fixture.regressionSteamApps))
        XCTAssertEqual(try fixture.stagedLinks().count, 1)
    }

    func testCrossVolumeAssessmentFailsBeforeMutation() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            volumeIdentityProvider: { url in
                url.path.contains("crossover-bottle") ? "source" : "destination"
            }
        )

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        XCTAssertTrue(assessment.blockedReason?.contains("volúmenes distintos") == true)
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: fixture.regressionSteamApps.path))
    }

    func testOccupiedDestinationFailsClosedWithoutReplacingIt() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        try FileManager.default.removeItem(at: fixture.regressionSteamApps)
        try FileManager.default.createDirectory(at: fixture.regressionSteamApps, withIntermediateDirectories: false)
        try Data("preservar".utf8).write(to: fixture.regressionSteamApps.appendingPathComponent("marker"))
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )

        XCTAssertTrue(assessment.blockedReason?.contains("ocupado") == true)
        XCTAssertEqual(
            try String(contentsOf: fixture.regressionSteamApps.appendingPathComponent("marker")),
            "preservar"
        )
    }

    func testAdversarialJournalSymlinkFailsClosed() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        try FileManager.default.createDirectory(at: fixture.backupRoot, withIntermediateDirectories: true)
        let target = fixture.root.appendingPathComponent("attacker.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.journal, withDestinationURL: target)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let snapshot = await manager.currentPhysicalLibraryCustodyInterlock()

        XCTAssertEqual(snapshot.mutationPolicy, .blocked)
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
    }

    func testSparseHundredTenGiBLibraryMovesByRenameWithoutDuplication() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let sparse = fixture.crossOverSteamApps.appendingPathComponent("common/huge.sparse")
        try FileManager.default.createDirectory(at: sparse.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(sparse.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let logicalBytes: off_t = 110 * 1_024 * 1_024 * 1_024
        XCTAssertEqual(ftruncate(descriptor, logicalBytes), 0)
        close(descriptor)
        let identity = try fixture.identity(at: fixture.crossOverSteamApps)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let result = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )

        XCTAssertEqual(result.inventory.totalRegularFileBytes, UInt64(logicalBytes))
        XCTAssertEqual(try fixture.identity(at: fixture.regressionSteamApps), identity)
        XCTAssertEqual(try fixture.physicalSteamAppsTrees().count, 1)
    }

    func testEvidenceFinalizationRejectsAnActiveSteamSession() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        _ = try await manager.beginPhysicalCustodyValidation(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningState: .init()
        )
        let authority = try await custodyValidationAuthority(in: fixture.root)

        await assertUnsafeLibraryState(containing: "Steam debe estar completamente cerrado") {
            _ = try await manager.finalizePhysicalCustodyValidated(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                request: authority.request,
                repository: authority.repository,
                runningState: .init(regressionPIDs: [99])
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testFinalizationCrashWindowsRecoverWithoutLosingRollbackMarkerPrematurely() async throws {
        let points: [PhysicalLibraryCustodyFaultPoint] = [
            .afterWillFinalizeJournal,
            .afterFinalizeReceipt,
            .afterFinalizeMarkerUnlink,
            .afterCompletedJournal,
            .beforeFinalJournalUnlink
        ]
        for point in points {
            let fixture = try CustodyFixture()
            defer { fixture.remove() }
            try fixture.makeSharedLayout()
            let injected = SharedSteamLibraryManager(
                backupRootURL: fixture.backupRoot,
                directoryEnumeratorProvider: CustodyFixture.enumerator,
                custodyFault: { observed in
                    if String(describing: observed) == String(describing: point) {
                        throw InjectedCrash()
                    }
                }
            )
            _ = try await injected.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { .init() }
            )
            let authority = try await custodyValidationAuthority(in: fixture.root)
            do {
                _ = try await injected.finalizePhysicalCustodyValidated(
                    regression: fixture.regression,
                    legacyIdentity: fixture.legacyIdentity,
                    request: authority.request,
                    repository: authority.repository,
                    runningState: .init()
                )
                XCTFail("La ventana \(point) debía interrumpirse")
            } catch is InjectedCrash {}

            let recovered = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
            let result = try await recovered.finalizePhysicalCustodyValidated(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                request: authority.request,
                repository: authority.repository,
                runningState: .init()
            )
            XCTAssertEqual(result.status, .independent, "Fallo al recuperar \(point)")
            XCTAssertTrue(fixture.isPhysicalDirectory(fixture.regressionSteamApps))
            XCTAssertFalse(fixture.pathExists(fixture.crossOverSteamApps))
            XCTAssertTrue(try fixture.stagedLinks().isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.journal.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.receipt.path))
        }
    }

    func testCrashAfterMarkerQuarantineRecoversWithoutHiddenLeaf() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: CustodyFixture.enumerator,
            custodyFault: { point in
                if String(describing: point)
                    == String(describing: PhysicalLibraryCustodyFaultPoint.afterFinalizeMarkerQuarantine)
                {
                    throw InjectedCrash()
                }
            }
        )
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        let authority = try await custodyValidationAuthority(in: fixture.root)
        do {
            _ = try await manager.finalizePhysicalCustodyValidated(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                request: authority.request,
                repository: authority.repository,
                runningState: .init()
            )
            XCTFail("Se esperaba interrupción")
        } catch is InjectedCrash {}

        let restarted = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let result = try await restarted.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        XCTAssertEqual(result.status, .independent)
        XCTAssertTrue(try fixture.custodyQuarantines().isEmpty)
        XCTAssertTrue(try fixture.stagedLinks().isEmpty)
    }

    func testCrashAfterJournalQuarantineRecoversWithoutOrphan() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: CustodyFixture.enumerator,
            custodyFault: { point in
                if String(describing: point)
                    == String(describing: PhysicalLibraryCustodyFaultPoint.afterJournalQuarantine)
                {
                    throw InjectedCrash()
                }
            }
        )
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        do {
            _ = try await manager.rollbackPhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningState: .init()
            )
            XCTFail("Se esperaba interrupción")
        } catch is InjectedCrash {}

        let restarted = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let result = try await restarted.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        XCTAssertEqual(result.status, .pendingValidation)
        XCTAssertTrue(try fixture.custodyQuarantines().isEmpty)
    }

    func testCrashBetweenRollbackMarkerAndJournalCleanupResumesToEligible() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: CustodyFixture.enumerator,
            custodyFault: { point in
                if point == .afterRollbackStartedMarkerUnlink { throw InjectedCrash() }
            }
        )
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        do {
            _ = try await manager.rollbackPhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningState: .init()
            )
            XCTFail("Se esperaba interrupción")
        } catch is InjectedCrash {}

        let restarted = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let result = try await restarted.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        XCTAssertEqual(result.status, .eligibleForTransfer)
        XCTAssertFalse(fixture.pathExists(fixture.journal))
        XCTAssertFalse(fixture.pathExists(fixture.backupRoot.appendingPathComponent("physical-custody-started.json")))
    }

    func testCrashAfterStartedMarkerQuarantineRecoversWithoutResidue() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: CustodyFixture.enumerator,
            custodyFault: { point in
                if point == .afterStartedMarkerQuarantine { throw InjectedCrash() }
            }
        )
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        do {
            _ = try await manager.rollbackPhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningState: .init()
            )
            XCTFail("Se esperaba interrupción")
        } catch is InjectedCrash {}

        let restarted = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let result = try await restarted.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        XCTAssertEqual(result.status, .eligibleForTransfer)
        XCTAssertTrue(try fixture.custodyQuarantines().isEmpty)
    }

    func testDeletingPrimaryReceiptAfterFinalUsesDurableMirror() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        let authority = try await custodyValidationAuthority(in: fixture.root)
        _ = try await manager.finalizePhysicalCustodyValidated(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            request: authority.request,
            repository: authority.repository,
            runningState: .init()
        )
        try FileManager.default.removeItem(at: fixture.receipt)

        let restarted = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let snapshot = await restarted.currentPhysicalLibraryCustodyInterlock()
        XCTAssertEqual(snapshot.status, .independent)
        XCTAssertEqual(snapshot.mutationPolicy, .unrestricted)
        XCTAssertTrue(snapshot.crossOverUnavailable)
    }

    func testParentDirectorySwapAfterJournalIsDetectedBeforeAnyRename() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let regressionSteamRoot = fixture.regressionSteamApps.deletingLastPathComponent()
        let displaced = regressionSteamRoot.deletingLastPathComponent()
            .appendingPathComponent("Steam-displaced")
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: CustodyFixture.enumerator,
            custodyFault: { point in
                guard String(describing: point) == String(describing: PhysicalLibraryCustodyFaultPoint.afterPrepared) else {
                    return
                }
                try FileManager.default.moveItem(at: regressionSteamRoot, to: displaced)
                try FileManager.default.createDirectory(at: regressionSteamRoot, withIntermediateDirectories: false)
                throw InjectedCrash()
            }
        )
        do {
            _ = try await manager.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { .init() }
            )
            XCTFail("Se esperaba interrupción")
        } catch is InjectedCrash {}

        let restarted = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        await assertUnsafeLibraryState(containing: "padre") {
            _ = try await restarted.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { .init() }
            )
        }
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
        XCTAssertFalse(fixture.pathExists(fixture.regressionSteamApps))
    }

    func testSharedMutationPermitPreventsMigrationRaceUntilReleased() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let permit = try await manager.acquirePhysicalLibraryCustodyMutationPermit(
            backend: .regression,
            validationLease: nil
        )

        await assertUnsafeLibraryState(containing: "otra operación") {
            _ = try await manager.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { .init() }
            )
        }
        permit.release()
        let result = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        XCTAssertEqual(result.status, .pendingValidation)
    }

    func testDurableLaunchIntentBlocksMigrationWhenSpawnedPIDIsStillAlive() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let intent = try await manager.registerPhysicalLibraryLaunchIntent(backend: .regression)
        try await manager.attachPhysicalLibraryLaunch(
            BackendLaunch(
                backend: .regression,
                processID: getpid(),
                command: "/usr/bin/true",
                arguments: [],
                logURL: fixture.root.appendingPathComponent("launch.log"),
                startedAt: Date()
            ),
            to: intent
        )

        await assertUnsafeLibraryState(containing: "lanzador") {
            _ = try await manager.migratePhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningStateProvider: { .init() }
            )
        }
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
        XCTAssertFalse(fixture.isPhysicalDirectory(fixture.regressionSteamApps))
        try await manager.resolvePhysicalLibraryLaunchIntent(intent)
    }

    func testConcurrentLaunchIntentRegistrationHasExactlyOneDurableWinner() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let first = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let second = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let results = await withTaskGroup(
            of: Result<PhysicalLibraryCustodyLaunchIntent, Error>.self,
            returning: [Result<PhysicalLibraryCustodyLaunchIntent, Error>].self
        ) { group in
            for manager in [first, second] {
                group.addTask {
                    do { return .success(try await manager.registerPhysicalLibraryLaunchIntent(backend: .regression)) }
                    catch { return .failure(error) }
                }
            }
            var values: [Result<PhysicalLibraryCustodyLaunchIntent, Error>] = []
            for await value in group { values.append(value) }
            return values
        }
        let winners = results.compactMap { try? $0.get() }
        XCTAssertEqual(winners.count, 1)
        let snapshot = await first.currentPhysicalLibraryCustodyInterlock()
        XCTAssertEqual(snapshot.mutationPolicy, .blocked)
        try await first.resolvePhysicalLibraryLaunchIntent(try XCTUnwrap(winners.first))
    }

    func testSubstitutedRollbackMarkerIsNeverDeletedDuringFinalization() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        let marker = try XCTUnwrap(try fixture.stagedLinks().first)
        let rawTarget = try FileManager.default.destinationOfSymbolicLink(atPath: marker.path)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(atPath: marker.path, withDestinationPath: rawTarget)
        let authority = try await custodyValidationAuthority(in: fixture.root)

        await assertUnsafeLibraryState(containing: "sustituido") {
            _ = try await manager.finalizePhysicalCustodyValidated(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                request: authority.request,
                repository: authority.repository,
                runningState: .init()
            )
        }
        XCTAssertTrue(fixture.pathExists(marker))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.receipt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    func testSubstitutedRollbackMarkerIsNeverRestored() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        let marker = try XCTUnwrap(try fixture.stagedLinks().first)
        let rawTarget = try FileManager.default.destinationOfSymbolicLink(atPath: marker.path)
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.createSymbolicLink(atPath: marker.path, withDestinationPath: rawTarget)

        await assertUnsafeLibraryState(containing: "sustituido") {
            _ = try await manager.rollbackPhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningState: .init()
            )
        }
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
        XCTAssertFalse(fixture.pathExists(fixture.regressionSteamApps))
        XCTAssertTrue(fixture.pathExists(marker))
    }

    func testRollbackMarkerSwapImmediatelyBeforeQuarantineIsPreservedNotDeleted() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let swapped = LockedFlag()
        let regressionSteamApps = fixture.regressionSteamApps
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: CustodyFixture.enumerator,
            custodyFault: { point in
                guard String(describing: point)
                    == String(describing: PhysicalLibraryCustodyFaultPoint.beforeFinalizeMarkerQuarantine),
                    swapped.take() else { return }
                let parent = regressionSteamApps.deletingLastPathComponent()
                let marker = try FileManager.default.contentsOfDirectory(
                    at: parent,
                    includingPropertiesForKeys: nil
                ).first {
                    $0.lastPathComponent.hasPrefix(".steamapps-custody-")
                        && $0.lastPathComponent.hasSuffix(".rollback")
                }
                guard let marker else { throw InjectedCrash() }
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: marker.path)
                try FileManager.default.removeItem(at: marker)
                try FileManager.default.createSymbolicLink(atPath: marker.path, withDestinationPath: target)
            }
        )
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )
        let authority = try await custodyValidationAuthority(in: fixture.root)

        await assertUnsafeLibraryState(containing: "sustituido") {
            _ = try await manager.finalizePhysicalCustodyValidated(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                request: authority.request,
                repository: authority.repository,
                runningState: .init()
            )
        }
        XCTAssertEqual(try fixture.stagedLinks().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.journal.path))
    }

    func testJournalSwapImmediatelyBeforeQuarantineIsPreservedNotDeleted() async throws {
        let fixture = try CustodyFixture()
        defer { fixture.remove() }
        try fixture.makeSharedLayout()
        let swapped = LockedFlag()
        let journal = fixture.journal
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: CustodyFixture.enumerator,
            beforeJournalUnlink: {
                guard swapped.take() else { return }
                try? FileManager.default.removeItem(at: journal)
                try? Data("journal atacante".utf8).write(to: journal)
            }
        )
        _ = try await manager.migratePhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: fixture.legacyIdentity,
            runningStateProvider: { .init() }
        )

        await assertUnsafeLibraryState(containing: "sustituido") {
            _ = try await manager.rollbackPhysicalCustody(
                regression: fixture.regression,
                legacyIdentity: fixture.legacyIdentity,
                runningState: .init()
            )
        }
        XCTAssertEqual(try String(contentsOf: fixture.journal), "journal atacante")
        XCTAssertTrue(fixture.isPhysicalDirectory(fixture.crossOverSteamApps))
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.regressionSteamApps.path
            )
        )
    }
}

private struct InjectedCrash: Error {}

private final class LockedStates: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [RunningBackendState]

    init(_ states: [RunningBackendState]) { self.states = states }

    func next() -> RunningBackendState {
        lock.lock()
        defer { lock.unlock() }
        return states.isEmpty ? .init() : states.removeFirst()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard available else { return false }
        available = false
        return true
    }
}

private struct CustodyValidationAuthority {
    let request: PhysicalLibraryCustodyValidationRequest
    let repository: CompatibilityRepository
}

private func custodyValidationAuthority(
    in root: URL,
    source: VerificationSource = .visualInspection,
    startedAtOffset: TimeInterval = 1,
    requestAppID: String = "219990"
) async throws -> CustodyValidationAuthority {
    let runID = UUID()
    let boundary = Date()
    let startedAt = boundary.addingTimeInterval(startedAtOffset)
    let endedAt = startedAt.addingTimeInterval(100)
    let request = PhysicalLibraryCustodyValidationRequest(appID: requestAppID, runID: runID)
    let repository = CompatibilityRepository(
        databaseURL: root.appendingPathComponent(
            "custody-authority-\(runID.uuidString).sqlite"
        )
    )
    try await repository.prepare()
    try await repository.beginRun(RunContext(
        id: runID,
        appID: request.appID,
        gameName: "Prueba de custodia",
        backend: .regression,
        bottleName: "Steam",
        providerVersion: "test",
        startedAt: startedAt,
        command: "$APP/regression-engine",
        arguments: ["-applaunch", request.appID],
        system: SystemSnapshot(
            macOSVersion: "test",
            architecture: "arm64",
            deviceModel: "test",
            displayWidth: 1,
            displayHeight: 1,
            displayScale: 1
        ),
        configuration: [:],
        configurationFingerprint: "custody-test"
    ))
    try await repository.markLaunched(
        id: runID,
        processID: 123,
        executable: "game.exe",
        startedAt: startedAt,
        launchMilliseconds: 50
    )
    try await repository.markProcessEnded(
        id: runID,
        processID: 123,
        endedAt: endedAt,
        exitCode: 0
    )
    try await repository.finishRun(
        id: runID,
        endedAt: endedAt,
        exitCode: 0,
        result: .succeeded,
        afterConfiguration: [:],
        delta: ConfigurationDelta(added: [:], removed: [:], changed: [:])
    )
    let verification = RunVerification(
        runID: runID,
        verdict: .perfect,
        rendering: .passed,
        inputPrecision: .passed,
        graphicsSettings: .passed,
        gameplay: .passed,
        source: source,
        verifiedAt: endedAt.addingTimeInterval(1)
    )
    try await repository.verifyRun(verification)
    let sealed = try await repository.sealedPerfectRun(appID: request.appID, runID: runID)
    guard sealed?.verification?.verdict == .perfect else {
        throw RegressionCoreError.invalidEvidence(
            "la fixture de custodia no produjo una ejecución perfecta sellada"
        )
    }
    return CustodyValidationAuthority(request: request, repository: repository)
}

private func assertUnsafeLibraryState(
    containing expected: String,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Se esperaba unsafeLibraryState", file: file, line: line)
    } catch let RegressionCoreError.unsafeLibraryState(detail) {
        XCTAssertTrue(detail.contains(expected), "Detalle inesperado: \(detail)", file: file, line: line)
    } catch {
        XCTFail("Error inesperado: \(error)", file: file, line: line)
    }
}

private func assertInvalidEvidence(
    containing expected: String,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Se esperaba invalidEvidence", file: file, line: line)
    } catch let RegressionCoreError.invalidEvidence(detail) {
        XCTAssertTrue(detail.contains(expected), "Detalle inesperado: \(detail)", file: file, line: line)
    } catch {
        XCTFail("Error inesperado: \(error)", file: file, line: line)
    }
}

private extension PhysicalLibraryCustodyAssessment {
    var blockedReason: String? {
        guard case let .blocked(reason) = status else { return nil }
        return reason
    }
}

private final class CustodyFixture {
    static let enumerator: SharedSteamLibraryManager.DirectoryEnumeratorProvider = {
        root, keys, options, reportFailure in
        FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options,
            errorHandler: { url, error in
                reportFailure(url, error.localizedDescription)
                return false
            }
        )
    }

    let root: URL
    let backupRoot: URL
    let regressionSteamApps: URL
    let crossOverSteamApps: URL
    let regression: RegressionInstallation

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/custody-test-fixtures", isDirectory: true)
            .appendingPathComponent("regression-custody-\(UUID().uuidString)", isDirectory: true)
        backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let regressionBottle = root.appendingPathComponent("regression-bottle", isDirectory: true)
        let crossOverBottle = root.appendingPathComponent("crossover-bottle", isDirectory: true)
        let relativeSteam = "drive_c/Program Files (x86)/Steam"
        let regressionSteam = regressionBottle.appendingPathComponent(relativeSteam, isDirectory: true)
        let crossOverSteam = crossOverBottle.appendingPathComponent(relativeSteam, isDirectory: true)
        regressionSteamApps = regressionSteam.appendingPathComponent("steamapps", isDirectory: true)
        crossOverSteamApps = crossOverSteam.appendingPathComponent("steamapps", isDirectory: true)
        try FileManager.default.createDirectory(at: regressionSteam, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: crossOverSteamApps, withIntermediateDirectories: true)
        regression = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app"),
            bottleURL: regressionBottle,
            steamExecutableURL: regressionSteam.appendingPathComponent("Steam.exe"),
            engineLauncherURL: root.appendingPathComponent("engine"),
            health: .ready,
            healthDetail: "ok"
        )
    }

    var legacyIdentity: PhysicalLibraryCustodyIdentity {
        .init(legacySteamAppsURL: crossOverSteamApps)
    }

    var journal: URL { backupRoot.appendingPathComponent("physical-custody-journal.json") }
    var receipt: URL { backupRoot.appendingPathComponent("physical-custody-receipt.json") }

    func makeSharedLayout(relativeLink: Bool = false) throws {
        if pathExists(regressionSteamApps) { try FileManager.default.removeItem(at: regressionSteamApps) }
        if relativeLink {
            let relative = "../../../../crossover-bottle/drive_c/Program Files (x86)/Steam/steamapps"
            try FileManager.default.createSymbolicLink(atPath: regressionSteamApps.path, withDestinationPath: relative)
        } else {
            try FileManager.default.createSymbolicLink(at: regressionSteamApps, withDestinationURL: crossOverSteamApps)
        }
    }

    func writeManifest(appID: String) throws {
        try Data(#"""
        "AppState"
        {
            "appid" "\#(appID)"
            "name" "Juego"
            "installdir" "Game"
        }
        """#.utf8).write(to: crossOverSteamApps.appendingPathComponent("appmanifest_\(appID).acf"))
    }

    func identity(at url: URL) throws -> [UInt64] {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { throw CocoaError(.fileNoSuchFile) }
        return [UInt64(metadata.st_dev), UInt64(metadata.st_ino)]
    }

    func pathExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func isPhysicalDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    func physicalSteamAppsTrees() throws -> [URL] {
        [crossOverSteamApps, regressionSteamApps].filter(isPhysicalDirectory)
    }

    func stagedLinks() throws -> [URL] {
        let parent = regressionSteamApps.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix(".steamapps-custody-")
                    && $0.lastPathComponent.hasSuffix(".rollback")
                    && (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil
            }
    }

    func custodyQuarantines() throws -> [URL] {
        let roots = [backupRoot, regressionSteamApps.deletingLastPathComponent()]
        return try roots.flatMap { root in
            guard FileManager.default.fileExists(atPath: root.path) else { return [URL]() }
            return try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasSuffix(".quarantine") }
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
