import Darwin
import Foundation
@testable import RegressionCore
import XCTest

final class SharedSteamLibraryTests: XCTestCase {
    func testPhysicalCustodyAssessmentInventoriesCurrentCrossOverOwnedLayout() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        try fixture.writeCrossOverManifest(appID: "42", name: "Juego compartido")

        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        XCTAssertEqual(assessment.status, .eligibleForTransfer)
        XCTAssertEqual(assessment.inventory.manifestAppIDs, ["42"])
        XCTAssertEqual(assessment.inventory.manifestSHA256ByAppID["42"]?.count, 64)
        XCTAssertGreaterThanOrEqual(assessment.inventory.regularFileCount, 1)
        XCTAssertFalse(assessment.inventory.structuralFingerprint.isEmpty)
        XCTAssertEqual(assessment.sourceSteamAppsURL, fixture.crossOverSteamApps)
        XCTAssertEqual(assessment.destinationSteamAppsURL, fixture.regressionOwnedSteamApps)
    }

    func testPreparePhysicalCustodyPlanIsDurablePrivateAndDoesNotMoveLibrary() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        try fixture.writeCrossOverManifest(appID: "42", name: "Juego compartido")
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let plan = try await manager.preparePhysicalCustodyPlan(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        XCTAssertEqual(plan.phase, .planned)
        XCTAssertEqual(plan.sourceSteamAppsURL, fixture.crossOverSteamApps)
        XCTAssertEqual(plan.destinationSteamAppsURL, fixture.regressionOwnedSteamApps)
        XCTAssertEqual(plan.transitionalLinks[fixture.crossOverSteamApps], fixture.regressionOwnedSteamApps)
        XCTAssertEqual(plan.transitionalLinks[fixture.regressionSteamApps], fixture.regressionOwnedSteamApps)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.crossOverSteamApps.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.regressionOwnedSteamApps.path))
        XCTAssertEqual(
            try fixture.resolvedSymbolicLink(at: fixture.regressionSteamApps),
            fixture.crossOverSteamApps.standardizedFileURL
        )

        let journal = manager.physicalCustodyJournalURL
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: journal.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(mode & 0o777, 0o600)

        let plannedAssessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )
        XCTAssertEqual(plannedAssessment.status, .migrationPlanned)
    }

    func testPhysicalCustodyAssessmentRecognizesCompletedOwnershipLayout() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.regressionOwnedSteamApps,
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(at: fixture.crossOverSteamApps)
        try FileManager.default.createSymbolicLink(
            at: fixture.crossOverSteamApps,
            withDestinationURL: fixture.regressionOwnedSteamApps
        )
        try FileManager.default.removeItem(at: fixture.regressionSteamApps)
        try FileManager.default.createSymbolicLink(
            at: fixture.regressionSteamApps,
            withDestinationURL: fixture.regressionOwnedSteamApps
        )
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        XCTAssertEqual(assessment.status, .alreadyOwned)
    }

    func testCompletedOwnershipCanBeRecognizedFromLegacyIdentityWithoutCrossOverInstallation() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCompletedOwnershipLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: PhysicalLibraryCustodyIdentity(
                legacySteamAppsURL: fixture.crossOverSteamApps
            ),
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        XCTAssertEqual(assessment.status, .alreadyOwned)
    }

    func testPhysicalCustodyRejectsSourceReachedThroughSymlinkedAncestor() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        let linkedBottle = fixture.root.appendingPathComponent("linked-crossover-bottle")
        try FileManager.default.createSymbolicLink(
            at: linkedBottle,
            withDestinationURL: fixture.crossOver.bottleURL
        )
        let legacySteamApps = linkedBottle
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
        try FileManager.default.removeItem(at: fixture.regressionSteamApps)
        try FileManager.default.createSymbolicLink(
            at: fixture.regressionSteamApps,
            withDestinationURL: legacySteamApps
        )
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            legacyIdentity: PhysicalLibraryCustodyIdentity(legacySteamAppsURL: legacySteamApps),
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        guard case let .blocked(reason) = assessment.status else {
            return XCTFail("Un ancestro enlazado debía bloquear la evaluación")
        }
        XCTAssertTrue(reason.contains("ancestro") && reason.contains("enlace simbólico"), reason)
    }

    func testPhysicalCustodyUsesCanonicalCaseInsensitiveOverlap() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        let differentlyCasedSource = URL(
            fileURLWithPath: fixture.crossOverSteamApps.path.uppercased(),
            isDirectory: true
        )
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: differentlyCasedSource.appendingPathComponent("future"),
            runningState: RunningBackendState()
        )

        guard case let .blocked(reason) = assessment.status else {
            return XCTFail("El solapamiento canónico debía bloquear la evaluación")
        }
        XCTAssertTrue(reason.contains("solapa"), reason)
    }

    func testPhysicalCustodyInventoryRejectsDuplicateCanonicalAppID() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        try fixture.writeCrossOverManifest(appID: "42", name: "Juego")
        try fixture.writeCrossOverManifest(appID: "00042", name: "Duplicado")
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        guard case let .blocked(reason) = assessment.status else {
            return XCTFail("Un App ID canónico duplicado debía bloquear el inventario")
        }
        XCTAssertTrue(reason.contains("App ID") && reason.contains("duplicado"), reason)
    }

    func testPhysicalCustodyInventoryFailsClosedWhenEnumeratorReportsUnreadableSubtree() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        let failingURL = fixture.crossOverSteamApps.appendingPathComponent("inaccesible")
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: { root, keys, options, reportFailure in
                reportFailure(failingURL, "Permiso denegado")
                return FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: options
                )
            }
        )

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        guard case let .blocked(reason) = assessment.status else {
            return XCTFail("Un error del enumerador debía bloquear el inventario")
        }
        XCTAssertTrue(reason.contains("enumerar") && reason.contains("inaccesible"), reason)
    }

    func testPhysicalCustodyInventoryEnforcesEntryDepthAndByteBudgets() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        try FileManager.default.createDirectory(
            at: fixture.crossOverSteamApps.appendingPathComponent("a/b", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(
            to: fixture.crossOverSteamApps.appendingPathComponent("a/b/payload.bin")
        )

        let entryManager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            inventoryLimits: .init(maxEntries: 1, maxDepth: 32, maxTotalRegularFileBytes: 1_024)
        )
        let entryAssessment = await entryManager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )
        XCTAssertTrue(entryAssessment.status.blockedReason?.contains("entradas") == true)

        let depthManager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            inventoryLimits: .init(maxEntries: 32, maxDepth: 1, maxTotalRegularFileBytes: 1_024)
        )
        let depthAssessment = await depthManager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )
        XCTAssertTrue(depthAssessment.status.blockedReason?.contains("profundidad") == true)

        let byteManager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            inventoryLimits: .init(maxEntries: 32, maxDepth: 32, maxTotalRegularFileBytes: 2)
        )
        let byteAssessment = await byteManager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )
        XCTAssertTrue(byteAssessment.status.blockedReason?.contains("bytes") == true)
    }

    func testStandardInventoryEntryBudgetIsBoundedWellBelowLegacyPressureCeiling() {
        XCTAssertEqual(PhysicalLibraryInventoryLimits.standard.maxEntries, 1_000_000)
        XCTAssertLessThan(PhysicalLibraryInventoryLimits.standard.maxEntries, 5_000_000)
    }

    func testPhysicalCustodyInventoryHonorsTaskCancellation() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let regression = fixture.regression
        let crossOver = fixture.crossOver
        let destination = fixture.regressionOwnedSteamApps

        let assessment = await Task { () -> PhysicalLibraryCustodyAssessment in
            withUnsafeCurrentTask { $0?.cancel() }
            return await manager.assessPhysicalCustody(
                regression: regression,
                crossOver: crossOver,
                regressionOwnedSteamAppsURL: destination,
                runningState: RunningBackendState()
            )
        }.value

        XCTAssertTrue(assessment.status.blockedReason?.contains("cancelado") == true)
    }

    func testPhysicalCustodyPlanRecoversIdempotentlyAfterPlanningInterruptionAndCanRollBack() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        try fixture.writeCrossOverManifest(appID: "42", name: "Juego compartido")

        let firstManager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let original = try await firstManager.preparePhysicalCustodyPlan(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        let recoveredManager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        let recovered = try await recoveredManager.recoverPhysicalCustodyPlan(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )
        let repeated = try await recoveredManager.preparePhysicalCustodyPlan(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        XCTAssertEqual(recovered, original)
        XCTAssertEqual(repeated, original)
        try await recoveredManager.cancelPhysicalCustodyPlan()
        try await recoveredManager.cancelPhysicalCustodyPlan()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.physicalCustodyJournal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.crossOverSteamApps.path))
    }

    func testPhysicalCustodyPreflightRejectsRunningSteamWithoutWritingJournal() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        await assertUnsafeLibraryState(containing: "Steam debe estar completamente cerrado") {
            _ = try await manager.preparePhysicalCustodyPlan(
                regression: fixture.regression,
                crossOver: fixture.crossOver,
                regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
                runningState: RunningBackendState(regressionPIDs: [123])
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.physicalCustodyJournal.path))
    }

    func testPhysicalCustodyPreflightRejectsUnexpectedSourceSymlink() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.crossOverSteamApps)
        try FileManager.default.createSymbolicLink(
            at: fixture.crossOverSteamApps,
            withDestinationURL: fixture.root.appendingPathComponent("unexpected", isDirectory: true)
        )
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )
        guard case let .blocked(reason) = assessment.status else {
            return XCTFail("La fuente enlazada debía bloquear la transferencia")
        }
        XCTAssertTrue(reason.contains("enlace simbólico inesperado"))
    }

    func testPhysicalCustodyPreflightRejectsOccupiedDestination() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        try FileManager.default.createDirectory(
            at: fixture.regressionOwnedSteamApps,
            withIntermediateDirectories: true
        )
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        await assertUnsafeLibraryState(containing: "destino de Regression ya está ocupado") {
            _ = try await manager.preparePhysicalCustodyPlan(
                regression: fixture.regression,
                crossOver: fixture.crossOver,
                regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
                runningState: RunningBackendState()
            )
        }
    }

    func testPhysicalCustodyPreflightRejectsCrossVolumeMove() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            volumeIdentityProvider: { url in
                url.path.contains("crossover-bottle") ? "source-volume" : "destination-volume"
            }
        )

        await assertUnsafeLibraryState(containing: "volúmenes distintos") {
            _ = try await manager.preparePhysicalCustodyPlan(
                regression: fixture.regression,
                crossOver: fixture.crossOver,
                regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
                runningState: RunningBackendState()
            )
        }
    }

    func testPhysicalCustodyRecoveryRejectsInventoryChangedAfterInterruption() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.preparePhysicalCustodyPlan(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )
        try Data("cambio posterior".utf8).write(
            to: fixture.crossOverSteamApps.appendingPathComponent("changed.bin")
        )

        await assertUnsafeLibraryState(containing: "inventario cambió") {
            _ = try await manager.recoverPhysicalCustodyPlan(
                regression: fixture.regression,
                crossOver: fixture.crossOver,
                regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
                runningState: RunningBackendState()
            )
        }
    }

    func testPhysicalCustodyPlanCancellationRejectsUnexpectedJournalDirectory() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.physicalCustodyJournal,
            withIntermediateDirectories: true
        )
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        await assertUnsafeLibraryState(containing: "no es un archivo regular") {
            try await manager.cancelPhysicalCustodyPlan()
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.physicalCustodyJournal.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPhysicalCustodyPlanCancellationCannotDeleteDirectorySubstitutedBeforeUnlink() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        let journal = fixture.physicalCustodyJournal
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            directoryEnumeratorProvider: { root, keys, options, reportFailure in
                FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: keys,
                    options: options,
                    errorHandler: { url, error in
                        reportFailure(url, error.localizedDescription)
                        return false
                    }
                )
            },
            beforeJournalUnlink: {
                try? FileManager.default.removeItem(at: journal)
                try? FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
            }
        )
        _ = try await manager.preparePhysicalCustodyPlan(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        await assertUnsafeLibraryState(containing: "cancelar") {
            try await manager.cancelPhysicalCustodyPlan()
        }
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testPhysicalCustodyJournalReaderRejectsFIFOWithoutOpeningIt() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.backupRoot, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(fixture.physicalCustodyJournal.path, 0o600), 0)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        await assertUnsafeLibraryState(containing: "archivo regular") {
            _ = try await manager.recoverPhysicalCustodyPlan(
                regression: fixture.regression,
                legacyIdentity: .init(legacySteamAppsURL: fixture.crossOverSteamApps),
                regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
                runningState: RunningBackendState()
            )
        }
    }

    func testPhysicalCustodyJournalReaderRejectsOversizedFileBeforeDecoding() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.backupRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 65).write(to: fixture.physicalCustodyJournal)
        let manager = SharedSteamLibraryManager(
            backupRootURL: fixture.backupRoot,
            inventoryLimits: .init(
                maxEntries: 32,
                maxDepth: 32,
                maxTotalRegularFileBytes: 1_024,
                maxJournalBytes: 64
            )
        )

        await assertUnsafeLibraryState(containing: "límite") {
            _ = try await manager.recoverPhysicalCustodyPlan(
                regression: fixture.regression,
                legacyIdentity: .init(legacySteamAppsURL: fixture.crossOverSteamApps),
                regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
                runningState: RunningBackendState()
            )
        }
    }

    func testPhysicalCustodyAssessmentDoesNotTreatInvalidJournalAsPlanned() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        try FileManager.default.createDirectory(at: fixture.backupRoot, withIntermediateDirectories: true)
        try Data("no es JSON".utf8).write(to: fixture.physicalCustodyJournal)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        guard case let .blocked(reason) = assessment.status else {
            return XCTFail("Un journal corrupto no debía convertirse en migrationPlanned")
        }
        XCTAssertTrue(reason.contains("journal") && reason.contains("recuperar"), reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.physicalCustodyJournal.path))
    }

    func testPhysicalCustodyAssessmentRejectsJournalForDifferentDestination() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try fixture.makeCurrentSharedLayout()
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        _ = try await manager.preparePhysicalCustodyPlan(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.regressionOwnedSteamApps,
            runningState: RunningBackendState()
        )

        let assessment = await manager.assessPhysicalCustody(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            regressionOwnedSteamAppsURL: fixture.root.appendingPathComponent("otro-destino/steamapps"),
            runningState: RunningBackendState()
        )

        guard case let .blocked(reason) = assessment.status else {
            return XCTFail("Un journal de otra ruta no debía convertirse en migrationPlanned")
        }
        XCTAssertTrue(reason.contains("journal") && reason.contains("instalaciones"), reason)
    }

    func testPhysicalCustodyJournalRejectsSymlinkedParentWithoutDeletingTarget() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        let physicalBackup = fixture.root.appendingPathComponent("physical-backup", isDirectory: true)
        let linkedBackup = fixture.root.appendingPathComponent("linked-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: physicalBackup, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: physicalBackup.appendingPathComponent("physical-custody-journal.json")
        )
        try FileManager.default.createSymbolicLink(at: linkedBackup, withDestinationURL: physicalBackup)
        let manager = SharedSteamLibraryManager(backupRootURL: linkedBackup)

        await assertUnsafeLibraryState(containing: "ancestro") {
            try await manager.cancelPhysicalCustodyPlan()
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: physicalBackup.appendingPathComponent("physical-custody-journal.json").path
            )
        )
    }

    func testConfigureRollsBackOriginalSteamAppsWhenReceiptCannotBeWritten() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        try Data("preservar".utf8).write(to: fixture.regressionSteamApps.appendingPathComponent("marker.txt"))
        try FileManager.default.createDirectory(
            at: fixture.backupRoot.appendingPathComponent("shared-library-receipt.json"),
            withIntermediateDirectories: true
        )

        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)
        do {
            _ = try await manager.configure(
                regression: fixture.regression,
                crossOver: fixture.crossOver,
                runningState: RunningBackendState()
            )
            XCTFail("La escritura del recibo debía fallar")
        } catch {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.regressionSteamApps.appendingPathComponent("marker.txt").path
                )
            )
            XCTAssertThrowsError(
                try FileManager.default.destinationOfSymbolicLink(
                    atPath: fixture.regressionSteamApps.path
                )
            )
        }
    }

    func testConfigureCreatesRecoverableSharedLibraryAndPrivateReceipt() async throws {
        let fixture = try SharedLibraryFixture()
        defer { fixture.remove() }
        let manifest = fixture.crossOver.steamRootURL
            .appendingPathComponent("steamapps/appmanifest_42.acf")
        try Data(#"""
        "AppState"
        {
            "appid" "42"
            "name" "Juego compartido"
            "installdir" "Shared Game"
        }
        """#.utf8).write(to: manifest)
        let manager = SharedSteamLibraryManager(backupRootURL: fixture.backupRoot)

        let link = try await manager.configure(
            regression: fixture.regression,
            crossOver: fixture.crossOver,
            runningState: RunningBackendState()
        )
        let assessment = await manager.assess(
            regression: fixture.regression,
            crossOver: fixture.crossOver
        )
        XCTAssertEqual(link, fixture.regressionSteamApps)
        XCTAssertEqual(assessment.status, .ready)
        XCTAssertEqual(
            SteamManifestParser.games(
                in: fixture.regression.steamRootURL,
                backend: .regression
            ).map(\.appID),
            ["42"]
        )

        let receipt = fixture.backupRoot.appendingPathComponent("shared-library-receipt.json")
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: receipt.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
    }
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

private extension PhysicalLibraryCustodyStatus {
    var blockedReason: String? {
        guard case let .blocked(reason) = self else { return nil }
        return reason
    }
}

private final class SharedLibraryFixture {
    let root: URL
    let backupRoot: URL
    let regressionSteamApps: URL
    let crossOverSteamApps: URL
    let regressionOwnedSteamApps: URL
    let regression: RegressionInstallation
    let crossOver: CrossOverInstallation

    init() throws {
        // /var es un enlace de sistema a /private/var. Toda la matriz protege que su
        // canonicalización no se confunda con un ancestro mutable controlado por el usuario.
        root = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent("regression-shared-library-\(UUID().uuidString)", isDirectory: true)
        backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let regressionBottle = root.appendingPathComponent("regression-bottle", isDirectory: true)
        let crossOverBottle = root.appendingPathComponent("crossover-bottle", isDirectory: true)
        let relativeSteam = "drive_c/Program Files (x86)/Steam"
        let regressionSteam = regressionBottle.appendingPathComponent(relativeSteam, isDirectory: true)
        let crossOverSteam = crossOverBottle.appendingPathComponent(relativeSteam, isDirectory: true)
        regressionSteamApps = regressionSteam.appendingPathComponent("steamapps", isDirectory: true)
        try FileManager.default.createDirectory(at: regressionSteamApps, withIntermediateDirectories: true)
        crossOverSteamApps = crossOverSteam.appendingPathComponent("steamapps", isDirectory: true)
        regressionOwnedSteamApps = root
            .appendingPathComponent("regression-library", isDirectory: true)
            .appendingPathComponent("steamapps", isDirectory: true)
        try FileManager.default.createDirectory(at: crossOverSteamApps, withIntermediateDirectories: true)

        regression = RegressionInstallation(
            applicationURL: root.appendingPathComponent("Regression.app"),
            bottleURL: regressionBottle,
            steamExecutableURL: regressionSteam.appendingPathComponent("Steam.exe"),
            engineLauncherURL: root.appendingPathComponent("regression-engine"),
            health: .ready,
            healthDetail: "ok"
        )
        crossOver = CrossOverInstallation(
            applicationURL: root.appendingPathComponent("CrossOver.app"),
            version: "26.3",
            build: "1",
            bottleName: "Steam",
            bottleURL: crossOverBottle,
            steamExecutableURL: crossOverSteam.appendingPathComponent("steam.exe"),
            wineCLIURL: root.appendingPathComponent("wine"),
            bottleCLIURL: root.appendingPathComponent("cxbottle"),
            feedURL: nil,
            health: .ready,
            healthDetail: "ok"
        )
    }

    var physicalCustodyJournal: URL {
        backupRoot.appendingPathComponent("physical-custody-journal.json")
    }

    func makeCurrentSharedLayout() throws {
        try FileManager.default.removeItem(at: regressionSteamApps)
        try FileManager.default.createSymbolicLink(
            at: regressionSteamApps,
            withDestinationURL: crossOverSteamApps
        )
    }

    func makeCompletedOwnershipLayout() throws {
        try FileManager.default.createDirectory(
            at: regressionOwnedSteamApps,
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(at: crossOverSteamApps)
        try FileManager.default.createSymbolicLink(
            at: crossOverSteamApps,
            withDestinationURL: regressionOwnedSteamApps
        )
        try FileManager.default.removeItem(at: regressionSteamApps)
        try FileManager.default.createSymbolicLink(
            at: regressionSteamApps,
            withDestinationURL: regressionOwnedSteamApps
        )
    }

    func writeCrossOverManifest(appID: String, name: String) throws {
        let manifest = crossOverSteamApps.appendingPathComponent("appmanifest_\(appID).acf")
        try Data(#"""
        "AppState"
        {
            "appid" "\#(appID)"
            "name" "\#(name)"
            "installdir" "Shared Game"
        }
        """#.utf8).write(to: manifest)
    }

    func resolvedSymbolicLink(at url: URL) throws -> URL {
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let resolved = destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : url.deletingLastPathComponent().appendingPathComponent(destination)
        return resolved.standardizedFileURL
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
