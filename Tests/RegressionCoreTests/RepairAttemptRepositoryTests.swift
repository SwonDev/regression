import Foundation
@testable import RegressionCore
import CSQLite
import XCTest

final class RepairAttemptRepositoryTests: XCTestCase {
    func testRepairAttemptLifecycleSurvivesRestartAndRejectsInvalidTransition() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        let appliedAt = Date()
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest(),
            at: appliedAt
        )
        let retry = try await beginRun(
            repository: fixture.repository,
            startedAt: appliedAt.addingTimeInterval(1)
        )
        try await fixture.repository.markLaunched(
            id: retry.id,
            processID: 77,
            executable: "future.exe",
            launchMilliseconds: 5
        )
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .relaunching,
            retryRunID: retry.id
        )
        try await fixture.repository.close()

        let reopened = CompatibilityRepository(databaseURL: fixture.databaseURL)
        try await reopened.prepare()
        let recovered = try await reopened.reconcileInterruptedRepairAttempts()
        XCTAssertTrue(recovered.isEmpty)
        let reconciled = try await reopened.repairAttempt(id: attempt.id)
        XCTAssertEqual(reconciled?.state, .relaunching)
        do {
            try await reopened.transitionRepairAttempt(id: attempt.id, to: .awaitingVerification)
            XCTFail("Un proceso todavía abierto no puede esperar verificación")
        } catch {}
        let retryEndedAt = Date()
        try await reopened.markProcessEnded(
            id: retry.id,
            processID: 77,
            endedAt: retryEndedAt,
            exitCode: 0
        )
        try await reopened.finishRun(
            id: retry.id,
            endedAt: retryEndedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: [:],
            delta: ConfigurationDiffer.difference(before: [:], after: [:])
        )
        try await reopened.transitionRepairAttempt(id: attempt.id, to: .awaitingVerification)
        let awaiting = try await reopened.repairAttempt(id: attempt.id)
        XCTAssertEqual(awaiting?.state, .awaitingVerification)
        do {
            try await reopened.transitionRepairAttempt(id: attempt.id, to: .verified)
            XCTFail("Una transición sin verificación exacta debía rechazarse")
        } catch {}
    }

    func testOnlyOneRepairAttemptCanBeActivePerAppAndRecipe() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(first)
        let second = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        do {
            try await fixture.repository.recordRepairAttempt(second)
            XCTFail("No debe existir más de un intento activo por juego y receta")
        } catch {}
    }

    func testDetectionRequiresAFinishedExactRegressionCrashSource() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pending = try await beginRun(
            repository: fixture.repository,
            startedAt: Date().addingTimeInterval(-20)
        )
        let attempt = RepairAttempt(
            sourceRunID: pending.id,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        do {
            try await fixture.repository.recordRepairAttempt(attempt)
            XCTFail("un run sin terminar no puede originar una detección")
        } catch {}

        try await fixture.repository.markLaunched(
            id: pending.id,
            processID: 123,
            executable: "other.exe",
            launchMilliseconds: 1
        )
        try await fixture.repository.finishRun(
            id: pending.id,
            endedAt: Date().addingTimeInterval(-10),
            exitCode: 1,
            result: .crashed,
            afterConfiguration: [:],
            delta: ConfigurationDiffer.difference(before: [:], after: [:])
        )
        do {
            try await fixture.repository.recordRepairAttempt(attempt)
            XCTFail("el basename fuente debe coincidir exactamente")
        } catch {}

        let predated = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        do {
            try await fixture.repository.recordRepairAttempt(predated)
            XCTFail("la detección no puede preceder al cierre del crash")
        } catch {}

        let crossOverCrash = try await beginCrashedRun(
            repository: fixture.repository,
            appID: "424242",
            executable: "future.exe",
            backend: .crossOver
        )
        let foreignBackend = RepairAttempt(
            sourceRunID: crossOverCrash.id,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        do {
            try await fixture.repository.recordRepairAttempt(foreignBackend)
            XCTFail("un crash de CrossOver no puede originar una reparación de Regression")
        } catch {}
    }

    func testSameExecutableBasenameRemainsIsolatedByAppIDInDurableDetection() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstRun = try await beginCrashedRun(
            repository: fixture.repository,
            appID: "424242",
            executable: "shared.exe"
        )
        let otherRun = try await beginCrashedRun(
            repository: fixture.repository,
            appID: "434343",
            executable: "shared.exe"
        )
        let first = RepairAttempt(
            sourceRunID: firstRun.id,
            appID: "424242",
            executable: "shared.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        let second = RepairAttempt(
            sourceRunID: otherRun.id,
            appID: "434343",
            executable: "shared.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )

        try await fixture.repository.recordRepairAttempt(first)
        try await fixture.repository.recordRepairAttempt(second)

        let firstActive = try await fixture.repository.activeRepairAttempt(
            appID: "424242",
            recipe: .unrealD3D11DualOverlayIsolation
        )
        let secondActive = try await fixture.repository.activeRepairAttempt(
            appID: "434343",
            recipe: .unrealD3D11DualOverlayIsolation
        )
        XCTAssertEqual(firstActive?.id, first.id)
        XCTAssertEqual(secondActive?.id, second.id)
    }

    func testVerificationRequiresRetryRunAndVerificationIdentity() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest()
        )
        do {
            try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .relaunching)
            try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .awaitingVerification)
            try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .verified)
            XCTFail("No se puede verificar sin run de reintento ni verificación explícita")
        } catch {}
    }

    func testSteamObservedAttemptCannotAutoRelaunchWithoutAUserRun() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            launchOrigin: .steamObserved,
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        XCTAssertFalse(attempt.automaticRetryEligible)
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest()
        )
        do {
            try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .relaunching)
            XCTFail("Una ejecución observada en Steam necesita un nuevo gesto")
        } catch {}
    }

    func testSchemaTwelveMigratesAndInventoriesLegacyV1WithoutFabricatingRun() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.repository.close()
        let bottleURL = fixture.directory.appendingPathComponent("bottle")
        let activationDirectory = bottleURL.appendingPathComponent(".regression")
        try FileManager.default.createDirectory(
            at: activationDirectory,
            withIntermediateDirectories: true
        )
        try Data("""
        REGRESSION-COMPILED-REPAIRS\t1
        future.exe\tunreal-d3d11-dual-overlay-isolation-v1
        """.utf8).write(to: CompiledRepairActivationStore.legacyActivationURL(in: bottleURL))

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "DROP TABLE repair_attempts; DROP TABLE legacy_repair_activation_inventory; " +
                    "PRAGMA user_version=12;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(database)
        database = nil

        let migrated = CompatibilityRepository(
            databaseURL: fixture.databaseURL,
            legacyCompiledRepairBottleURL: bottleURL
        )
        try await migrated.prepare()
        let health = try await migrated.databaseHealth()
        let backup = await migrated.lastMigrationBackup()
        let inventory = try await migrated.legacyRepairActivationInventory()
        XCTAssertEqual(health.schemaVersion, CompatibilityRepository.currentSchemaVersion)
        XCTAssertEqual(health.repairAttemptCount, 0)
        XCTAssertEqual(health.legacyRepairActivationCount, 1)
        XCTAssertNotNil(backup)
        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(inventory[0].state, .legacyAppliedUnverified)
        XCTAssertNil(inventory[0].sourceRunID)
        XCTAssertNil(inventory[0].appID)
        XCTAssertEqual(inventory[0].executable, "future.exe")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CompiledRepairActivationStore.legacyActivationURL(in: bottleURL).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CompiledRepairActivationStore.legacyQuarantineURL(in: bottleURL).path
        ))
        XCTAssertEqual(try CompiledRepairActivationStore.activations(in: bottleURL), [])

        try await migrated.close()
        let reopened = CompatibilityRepository(
            databaseURL: fixture.databaseURL,
            legacyCompiledRepairBottleURL: bottleURL
        )
        try await reopened.prepare()
        let reopenedInventory = try await reopened.legacyRepairActivationInventory()
        XCTAssertEqual(reopenedInventory, inventory)
        XCTAssertEqual(try CompiledRepairActivationStore.activations(in: bottleURL), [])
    }

    func testMigrationRecoversInventoryFromAQuarantinedCrashWindow() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.repository.close()
        let bottleURL = fixture.directory.appendingPathComponent("crash-window-bottle")
        let activationDirectory = bottleURL.appendingPathComponent(".regression")
        try FileManager.default.createDirectory(at: activationDirectory, withIntermediateDirectories: true)
        try Data("""
        REGRESSION-COMPILED-REPAIRS\t1
        future.exe\tunreal-d3d11-dual-overlay-isolation-v1
        """.utf8).write(to: CompiledRepairActivationStore.legacyQuarantineURL(in: bottleURL))

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.databaseURL.path, &database), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(
            database,
            "DELETE FROM legacy_repair_activation_inventory;",
            nil,
            nil,
            nil
        ), SQLITE_OK)
        sqlite3_close(database)

        let recovered = CompatibilityRepository(
            databaseURL: fixture.databaseURL,
            legacyCompiledRepairBottleURL: bottleURL
        )
        try await recovered.prepare()
        let inventory = try await recovered.legacyRepairActivationInventory()
        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(inventory[0].state, .legacyAppliedUnverified)
        XCTAssertEqual(try CompiledRepairActivationStore.activations(in: bottleURL), [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CompiledRepairActivationStore.legacyQuarantineURL(in: bottleURL).path
        ))
    }

    func testPrepareFailsClosedWithoutDeletingConflictingLegacyArtifacts() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.repository.close()
        let bottleURL = fixture.directory.appendingPathComponent("conflicting-legacy-bottle")
        let activationDirectory = bottleURL.appendingPathComponent(".regression")
        try FileManager.default.createDirectory(at: activationDirectory, withIntermediateDirectories: true)
        let data = Data("""
        REGRESSION-COMPILED-REPAIRS\t1
        future.exe\tunreal-d3d11-dual-overlay-isolation-v1
        """.utf8)
        try data.write(to: CompiledRepairActivationStore.legacyActivationURL(in: bottleURL))
        try data.write(to: CompiledRepairActivationStore.legacyQuarantineURL(in: bottleURL))
        let repository = CompatibilityRepository(
            databaseURL: fixture.databaseURL,
            legacyCompiledRepairBottleURL: bottleURL
        )

        do {
            try await repository.prepare()
            XCTFail("dos fuentes legacy contradictorias deben bloquear la preparación")
        } catch {}
        XCTAssertEqual(try Data(
            contentsOf: CompiledRepairActivationStore.legacyActivationURL(in: bottleURL)
        ), data)
        XCTAssertEqual(try Data(
            contentsOf: CompiledRepairActivationStore.legacyQuarantineURL(in: bottleURL)
        ), data)
    }

    func testVerifiedRequiresLaterFinishedExactExecutableAndCompatibleVerdict() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        let appliedAt = Date()
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest(),
            at: appliedAt
        )
        let retry = try await beginRun(
            repository: fixture.repository,
            startedAt: appliedAt.addingTimeInterval(1)
        )
        try await fixture.repository.markLaunched(
            id: retry.id,
            processID: 99,
            executable: #"C:\Games\Future\future.exe"#,
            launchMilliseconds: 10
        )
        let retryEndedAt = appliedAt.addingTimeInterval(2)
        try await fixture.repository.markProcessEnded(
            id: retry.id,
            processID: 99,
            endedAt: retryEndedAt,
            exitCode: 0
        )
        try await fixture.repository.finishRun(
            id: retry.id,
            endedAt: retryEndedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: [:],
            delta: ConfigurationDiffer.difference(before: [:], after: [:])
        )
        let verification = RunVerification(
            runID: retry.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "fecha imposible",
            verifiedAt: retryEndedAt.addingTimeInterval(-1)
        )
        do {
            try await fixture.repository.verifyRun(verification)
            XCTFail("una verificación no puede preceder al cierre de su retry")
        } catch {}
        try await fixture.repository.verifyRun(RunVerification(
            runID: retry.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "matriz completa",
            verifiedAt: retryEndedAt.addingTimeInterval(1)
        ))
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .relaunching,
            retryRunID: retry.id
        )
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .awaitingVerification
        )
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .verified,
            verificationID: retry.id
        )
        let verified = try await fixture.repository.repairAttempt(id: attempt.id)
        XCTAssertEqual(verified?.state, .verified)

        try mutateSQLite(fixture.databaseURL) { database in
            try executeSQLite(database, """
                UPDATE runs SET executable='mutated-after-perfect.exe'
                WHERE id='\(retry.id.uuidString)';
                """)
        }
        let invalidated = try await fixture.repository.repairAttempt(id: attempt.id)
        XCTAssertEqual(invalidated?.state, .blocked)
    }

    func testAcceptedWithIssuesMustFollowLatestTrackedProcessEndInSwiftAndSQLite() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        let appliedAt = Date()
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest(),
            at: appliedAt
        )
        let retry = try await beginRun(
            repository: fixture.repository,
            startedAt: appliedAt.addingTimeInterval(1)
        )
        try await fixture.repository.markLaunched(
            id: retry.id,
            processID: 101,
            executable: "future.exe",
            startedAt: appliedAt.addingTimeInterval(1),
            launchMilliseconds: 5
        )
        let runEndedAt = appliedAt.addingTimeInterval(2)
        let processEndedAt = appliedAt.addingTimeInterval(4)
        try await fixture.repository.markProcessEnded(
            id: retry.id,
            processID: 101,
            endedAt: processEndedAt,
            exitCode: 0
        )
        try await fixture.repository.finishRun(
            id: retry.id,
            endedAt: runEndedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: [:],
            delta: ConfigurationDiffer.difference(before: [:], after: [:])
        )
        try await fixture.repository.verifyRun(RunVerification(
            runID: retry.id,
            verdict: .playableWithIssues,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .failed,
            source: .visualInspection,
            verifiedAt: appliedAt.addingTimeInterval(3)
        ))
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .relaunching,
            retryRunID: retry.id
        )
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .awaitingVerification
        )
        do {
            try await fixture.repository.transitionRepairAttempt(
                id: attempt.id,
                to: .acceptedWithIssues,
                verificationID: retry.id
            )
            XCTFail("Swift debía rechazar una verificación anterior al último proceso")
        } catch {}

        try mutateSQLite(fixture.databaseURL) { database in
            XCTAssertThrowsError(try executeSQLite(database, """
                UPDATE repair_attempts
                SET state='acceptedWithIssues', verification_id='\(retry.id.uuidString)'
                WHERE id='\(attempt.id.uuidString)';
                """))
        }

        try await fixture.repository.verifyRun(RunVerification(
            runID: retry.id,
            verdict: .playableWithIssues,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .failed,
            source: .visualInspection,
            verifiedAt: processEndedAt.addingTimeInterval(1)
        ))
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .acceptedWithIssues,
            verificationID: retry.id
        )
        let accepted = try await fixture.repository.repairAttempt(id: attempt.id)
        XCTAssertEqual(accepted?.state, .acceptedWithIssues)
    }

    func testAcceptedWithIssuesIsBlockedByLateRetryProcessInsert() async throws {
        let accepted = try await makeAcceptedWithIssuesFixture()
        defer { try? FileManager.default.removeItem(at: accepted.fixture.directory) }

        try await accepted.fixture.repository.markAdditionalProcessStarted(
            id: accepted.retry.id,
            processID: 202,
            executable: "future-child.exe",
            startedAt: accepted.verifiedAt.addingTimeInterval(1)
        )
        let attempt = try await accepted.fixture.repository.repairAttempt(id: accepted.attemptID)
        XCTAssertEqual(attempt?.state, .blocked)
    }

    func testAcceptedWithIssuesIsBlockedByRetryProcessReopen() async throws {
        let accepted = try await makeAcceptedWithIssuesFixture()
        defer { try? FileManager.default.removeItem(at: accepted.fixture.directory) }

        try mutateSQLite(accepted.fixture.databaseURL) { database in
            try executeSQLite(database, """
                UPDATE run_processes SET ended_at=NULL, exit_code=NULL
                WHERE run_id='\(accepted.retry.id.uuidString)' AND process_id=201;
                """)
        }
        let attempt = try await accepted.fixture.repository.repairAttempt(id: accepted.attemptID)
        XCTAssertEqual(attempt?.state, .blocked)
    }

    func testAcceptedWithIssuesIsBlockedByRetryProcessDelete() async throws {
        let accepted = try await makeAcceptedWithIssuesFixture()
        defer { try? FileManager.default.removeItem(at: accepted.fixture.directory) }

        try mutateSQLite(accepted.fixture.databaseURL) { database in
            try executeSQLite(database, """
                DELETE FROM run_processes
                WHERE run_id='\(accepted.retry.id.uuidString)' AND process_id=201;
                """)
        }
        let attempt = try await accepted.fixture.repository.repairAttempt(id: accepted.attemptID)
        XCTAssertEqual(attempt?.state, .blocked)
    }

    func testPrepareReconcilesLegacyAcceptedAttemptAfterLateRetryMutation() async throws {
        let accepted = try await makeAcceptedWithIssuesFixture()
        defer { try? FileManager.default.removeItem(at: accepted.fixture.directory) }

        try mutateSQLite(accepted.fixture.databaseURL) { database in
            try executeSQLite(database, """
                DROP TRIGGER run_processes_mutation_invalidates_perfect_insert;
                INSERT INTO run_processes(
                    run_id, process_id, executable, started_at, ended_at, exit_code,
                    is_representative
                ) VALUES(
                    '\(accepted.retry.id.uuidString)', 203, 'future-late.exe',
                    '2099-01-01T00:00:00.000Z', '2099-01-01T00:00:01.000Z', 0, 0
                );
                """)
        }
        let unhealthy = try await accepted.fixture.repository.databaseHealth()
        XCTAssertEqual(unhealthy.repairAttemptEvidenceViolationCount, 1)
        XCTAssertFalse(unhealthy.isHealthy)
        try await accepted.fixture.repository.close()

        let reopened = CompatibilityRepository(databaseURL: accepted.fixture.databaseURL)
        try await reopened.prepare()
        let reconciled = try await reopened.repairAttempt(id: accepted.attemptID)
        XCTAssertEqual(reconciled?.state, .blocked)
        let healthy = try await reopened.databaseHealth()
        XCTAssertEqual(healthy.repairAttemptEvidenceViolationCount, 0)
        XCTAssertTrue(healthy.isHealthy)
        try await reopened.close()
    }

    func testAcceptedWithIssuesIsBlockedByEverySemanticRetryMutation() async throws {
        for field in ["app_id", "backend", "executable", "started_at", "result"] {
            let accepted = try await makeAcceptedWithIssuesFixture()
            do {
                try mutateSQLite(accepted.fixture.databaseURL) { database in
                    try executeSQLite(
                        database,
                        semanticRetryMutationSQL(field: field, runID: accepted.retry.id)
                    )
                }
                let attempt = try await accepted.fixture.repository.repairAttempt(
                    id: accepted.attemptID
                )
                XCTAssertEqual(attempt?.state, .blocked, field)
                try await accepted.fixture.repository.close()
            }
            try? FileManager.default.removeItem(at: accepted.fixture.directory)
        }
    }

    func testHealthAndPrepareReconcileEveryLegacySemanticRetryMutation() async throws {
        for field in ["app_id", "backend", "executable", "started_at", "result"] {
            let accepted = try await makeAcceptedWithIssuesFixture()
            do {
                try mutateSQLite(accepted.fixture.databaseURL) { database in
                    try executeSQLite(database, """
                        DROP TRIGGER runs_semantic_mutation_invalidates_perfect;
                        \(semanticRetryMutationSQL(field: field, runID: accepted.retry.id))
                        """)
                }
                let unhealthy = try await accepted.fixture.repository.databaseHealth()
                XCTAssertEqual(unhealthy.repairAttemptEvidenceViolationCount, 1, field)
                XCTAssertFalse(unhealthy.isHealthy, field)
                try await accepted.fixture.repository.close()

                let reopened = CompatibilityRepository(
                    databaseURL: accepted.fixture.databaseURL
                )
                try await reopened.prepare()
                let reconciled = try await reopened.repairAttempt(id: accepted.attemptID)
                XCTAssertEqual(reconciled?.state, .blocked, field)
                let healthy = try await reopened.databaseHealth()
                XCTAssertEqual(healthy.repairAttemptEvidenceViolationCount, 0, field)
                XCTAssertTrue(healthy.isHealthy, field)
                try await reopened.close()
            }
            try? FileManager.default.removeItem(at: accepted.fixture.directory)
        }
    }

    func testRetryBasenameTreatsPercentAndUnderscoreLiterallyInSwiftAndSQLite() async throws {
        for (expected, mismatched) in [
            ("wild%.exe", "C:\\Games\\wild-many.exe"),
            ("wild_.exe", "C:\\Games\\wildX.exe"),
        ] {
            let fixture = try await makeRepositoryFixture()
            do {
                let source = try await beginCrashedRun(
                    repository: fixture.repository,
                    appID: "424242",
                    executable: expected
                )
                let attempt = RepairAttempt(
                    sourceRunID: source.id,
                    appID: "424242",
                    executable: expected,
                    recipe: .unrealD3D11DualOverlayIsolation,
                    recipeVersion: 1,
                    state: .detected
                )
                try await fixture.repository.recordRepairAttempt(attempt)
                try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
                let appliedAt = Date()
                try await fixture.repository.transitionRepairAttempt(
                    id: attempt.id,
                    to: .appliedAwaitingRelaunch,
                    beforeFingerprint: "before",
                    afterFingerprint: "after",
                    rollbackManifest: rollbackManifest(),
                    at: appliedAt
                )
                let retry = try await beginRun(
                    repository: fixture.repository,
                    startedAt: appliedAt.addingTimeInterval(1)
                )
                try await fixture.repository.markLaunched(
                    id: retry.id,
                    processID: 301,
                    executable: mismatched,
                    startedAt: appliedAt.addingTimeInterval(1),
                    launchMilliseconds: 1
                )

                do {
                    try await fixture.repository.transitionRepairAttempt(
                        id: attempt.id,
                        to: .relaunching,
                        retryRunID: retry.id
                    )
                    XCTFail("Swift no debe interpretar \(expected) como patrón LIKE")
                } catch {}

                try mutateSQLite(fixture.databaseURL) { database in
                    XCTAssertThrowsError(try executeSQLite(database, """
                        UPDATE repair_attempts
                        SET state='relaunching', retry_run_id='\(retry.id.uuidString)'
                        WHERE id='\(attempt.id.uuidString)';
                        """), expected)
                }
                try await fixture.repository.close()
            }
            try? FileManager.default.removeItem(at: fixture.directory)
        }
    }

    func testAcceptedWithIssuesRequiresRepresentativePIDAndTrackedProcess() async throws {
        for corruption in ["missingRunPID", "missingTrackedProcess"] {
            let awaiting = try await makeAcceptedWithIssuesFixture(accept: false)
            do {
                try mutateSQLite(awaiting.fixture.databaseURL) { database in
                    switch corruption {
                    case "missingRunPID":
                        try executeSQLite(database, """
                            UPDATE runs SET process_id=NULL
                            WHERE id='\(awaiting.retry.id.uuidString)';
                            """)
                    case "missingTrackedProcess":
                        try executeSQLite(database, """
                            DELETE FROM run_processes
                            WHERE run_id='\(awaiting.retry.id.uuidString)' AND process_id=201;
                            """)
                    default:
                        XCTFail("Corrupción de prueba desconocida")
                    }
                }

                do {
                    try await awaiting.fixture.repository.transitionRepairAttempt(
                        id: awaiting.attemptID,
                        to: .acceptedWithIssues,
                        verificationID: awaiting.retry.id
                    )
                    XCTFail("Swift debe exigir PID y proceso rastreado: \(corruption)")
                } catch {}

                try mutateSQLite(awaiting.fixture.databaseURL) { database in
                    XCTAssertThrowsError(try executeSQLite(database, """
                        UPDATE repair_attempts
                        SET state='acceptedWithIssues',
                            verification_id='\(awaiting.retry.id.uuidString)'
                        WHERE id='\(awaiting.attemptID.uuidString)';
                        """), corruption)
                }
                try await awaiting.fixture.repository.close()
            }
            try? FileManager.default.removeItem(at: awaiting.fixture.directory)
        }
    }

    func testEmptyAppliedAtMakesLegacyAcceptedAttemptUnhealthyAndReconciles() async throws {
        let accepted = try await makeAcceptedWithIssuesFixture()
        defer { try? FileManager.default.removeItem(at: accepted.fixture.directory) }

        try mutateSQLite(accepted.fixture.databaseURL) { database in
            try executeSQLite(database, """
                DROP TRIGGER repair_attempt_evidence_guard_update;
                UPDATE repair_attempts SET applied_at=''
                WHERE id='\(accepted.attemptID.uuidString)';
                """)
        }
        let unhealthy = try await accepted.fixture.repository.databaseHealth()
        XCTAssertEqual(unhealthy.repairAttemptEvidenceViolationCount, 1)
        XCTAssertFalse(unhealthy.isHealthy)
        try await accepted.fixture.repository.close()

        let reopened = CompatibilityRepository(databaseURL: accepted.fixture.databaseURL)
        try await reopened.prepare()
        let reconciled = try await reopened.repairAttempt(id: accepted.attemptID)
        XCTAssertEqual(reconciled?.state, .blocked)
        let healthy = try await reopened.databaseHealth()
        XCTAssertEqual(healthy.repairAttemptEvidenceViolationCount, 0)
        XCTAssertTrue(healthy.isHealthy)
        try await reopened.close()
    }

    func testAcceptedWithIssuesRequiresRepresentativeTrackedProcessInSwiftAndSQLite() async throws {
        let awaiting = try await makeAcceptedWithIssuesFixture(accept: false)
        defer { try? FileManager.default.removeItem(at: awaiting.fixture.directory) }

        try mutateSQLite(awaiting.fixture.databaseURL) { database in
            try executeSQLite(database, """
                UPDATE run_processes SET is_representative=0
                WHERE run_id='\(awaiting.retry.id.uuidString)' AND process_id=201;
                """)
        }
        do {
            try await awaiting.fixture.repository.transitionRepairAttempt(
                id: awaiting.attemptID,
                to: .acceptedWithIssues,
                verificationID: awaiting.retry.id
            )
            XCTFail("Swift debe exigir autoridad representativa del proceso rastreado")
        } catch {}
        try mutateSQLite(awaiting.fixture.databaseURL) { database in
            XCTAssertThrowsError(try executeSQLite(database, """
                UPDATE repair_attempts
                SET state='acceptedWithIssues',
                    verification_id='\(awaiting.retry.id.uuidString)'
                WHERE id='\(awaiting.attemptID.uuidString)';
                """))
        }
        try await awaiting.fixture.repository.close()
    }

    func testPrepareBlocksLegacyAcceptedAttemptWhoseTrackedProcessLostAuthority() async throws {
        let accepted = try await makeAcceptedWithIssuesFixture()
        defer { try? FileManager.default.removeItem(at: accepted.fixture.directory) }

        try mutateSQLite(accepted.fixture.databaseURL) { database in
            try executeSQLite(database, """
                DROP TRIGGER run_processes_mutation_invalidates_perfect_update;
                UPDATE run_processes SET is_representative=0
                WHERE run_id='\(accepted.retry.id.uuidString)' AND process_id=201;
                """)
        }
        let unhealthy = try await accepted.fixture.repository.databaseHealth()
        XCTAssertEqual(unhealthy.repairAttemptEvidenceViolationCount, 1)
        XCTAssertFalse(unhealthy.isHealthy)
        try await accepted.fixture.repository.close()

        let reopened = CompatibilityRepository(databaseURL: accepted.fixture.databaseURL)
        do {
            try await reopened.prepare()
            XCTFail("La base debe seguir fallando cerrada por el run sin representante")
        } catch {}
        try mutateSQLite(accepted.fixture.databaseURL) { database in
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT state FROM repair_attempts
                    WHERE id='\(accepted.attemptID.uuidString)';
                    """),
                RepairAttemptState.blocked.rawValue
            )
        }
    }

    func testFailedAppliedRepairMustPassThroughVerifiedRollback() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest()
        )
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .rollbackPending)
        do {
            try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .rolledBack)
            XCTFail("rolledBack solo puede proceder de un restore verificado")
        } catch {}
        do {
            try await fixture.repository.completeVerifiedRepairRollback(
                id: attempt.id,
                restoredFingerprints: [
                    rollbackManifest().entries[0].targetPath: "drifted",
                    rollbackManifest().entries[1].targetPath: "before-v1"
                ]
            )
            XCTFail("un target con drift no puede cerrar el rollback")
        } catch {}
        let driftedAttempt = try await fixture.repository.repairAttempt(id: attempt.id)
        XCTAssertEqual(driftedAttempt?.state, .rollbackPending)
        do {
            try await fixture.repository.completeVerifiedRepairRollback(
                id: attempt.id,
                restoredFingerprints: Dictionary(
                    uniqueKeysWithValues: rollbackManifest().entries.map {
                        ($0.targetPath, $0.beforeFingerprint)
                    }
                )
            )
            XCTFail("el caller no puede autocertificar un restore")
        } catch {}
        let restored = try await fixture.repository.repairAttempt(id: attempt.id)
        XCTAssertEqual(restored?.state, .rollbackPending)
    }

    func testExportIncludesRepairLifecycleWithoutLeakingPrivateRollbackPaths() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest()
        )
        let exportURL = fixture.directory.appendingPathComponent("export.json")

        try await fixture.repository.exportJSON(to: exportURL)

        let text = try String(contentsOf: exportURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"repairAttempts\""))
        XCTAssertTrue(text.contains(attempt.id.uuidString))
        XCTAssertTrue(text.contains("\"repairAttemptCount\" : 1"))
        XCTAssertTrue(text.contains("\"legacyRepairActivationCount\" : 0"))
        XCTAssertFalse(text.contains("/private/bottle"))
    }

    func testLegacyDatabaseHealthJSONDecodesWithoutV13RepairCounters() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let health = try await fixture.repository.databaseHealth()
        let encoded = try JSONEncoder().encode(health)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "repairAttemptCount")
        object.removeValue(forKey: "legacyRepairActivationCount")
        object.removeValue(forKey: "repairAttemptEvidenceViolationCount")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CompatibilityDatabaseHealth.self, from: legacyData)
        XCTAssertNil(decoded.repairAttemptCount)
        XCTAssertNil(decoded.legacyRepairActivationCount)
        XCTAssertNil(decoded.repairAttemptEvidenceViolationCount)
    }

    func testReconcileRelaunchingUsesRetryRunStateInsteadOfClearingBlindly() async throws {
        let fixture = try await makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        let appliedAt = Date()
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest(),
            at: appliedAt
        )
        let retry = try await beginRun(
            repository: fixture.repository,
            startedAt: appliedAt.addingTimeInterval(1)
        )
        try await fixture.repository.markLaunched(
            id: retry.id,
            processID: 88,
            executable: "future.exe",
            launchMilliseconds: 5
        )
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .relaunching,
            retryRunID: retry.id
        )
        _ = try await fixture.repository.reconcileInterruptedRepairAttempts()
        var reconciled = try await fixture.repository.repairAttempt(id: attempt.id)
        XCTAssertEqual(reconciled?.state, .relaunching)

        let retryEndedAt = Date()
        try await fixture.repository.markProcessEnded(
            id: retry.id,
            processID: 88,
            endedAt: retryEndedAt,
            exitCode: 1
        )
        try await fixture.repository.finishRun(
            id: retry.id,
            endedAt: retryEndedAt,
            exitCode: 1,
            result: .crashed,
            afterConfiguration: [:],
            delta: ConfigurationDiffer.difference(before: [:], after: [:])
        )
        _ = try await fixture.repository.reconcileInterruptedRepairAttempts()
        reconciled = try await fixture.repository.repairAttempt(id: attempt.id)
        XCTAssertEqual(reconciled?.state, .awaitingVerification)
    }

    private struct Fixture {
        let directory: URL
        let databaseURL: URL
        let repository: CompatibilityRepository
        let sourceRunID: UUID
    }

    private struct AcceptedWithIssuesFixture {
        let fixture: Fixture
        let attemptID: UUID
        let retry: RunContext
        let verifiedAt: Date
    }

    private func makeAcceptedWithIssuesFixture(
        accept: Bool = true
    ) async throws -> AcceptedWithIssuesFixture {
        let fixture = try await makeRepositoryFixture()
        let attempt = RepairAttempt(
            sourceRunID: fixture.sourceRunID,
            appID: "424242",
            executable: "future.exe",
            recipe: .unrealD3D11DualOverlayIsolation,
            recipeVersion: 1,
            state: .detected
        )
        try await fixture.repository.recordRepairAttempt(attempt)
        try await fixture.repository.transitionRepairAttempt(id: attempt.id, to: .planned)
        let appliedAt = Date()
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .appliedAwaitingRelaunch,
            beforeFingerprint: "before",
            afterFingerprint: "after",
            rollbackManifest: rollbackManifest(),
            at: appliedAt
        )
        let retry = try await beginRun(
            repository: fixture.repository,
            startedAt: appliedAt.addingTimeInterval(1)
        )
        try await fixture.repository.markLaunched(
            id: retry.id,
            processID: 201,
            executable: "future.exe",
            startedAt: appliedAt.addingTimeInterval(1),
            launchMilliseconds: 5
        )
        let endedAt = appliedAt.addingTimeInterval(2)
        try await fixture.repository.markProcessEnded(
            id: retry.id,
            processID: 201,
            endedAt: endedAt,
            exitCode: 0
        )
        try await fixture.repository.finishRun(
            id: retry.id,
            endedAt: endedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: [:],
            delta: ConfigurationDiffer.difference(before: [:], after: [:])
        )
        let verifiedAt = endedAt.addingTimeInterval(1)
        try await fixture.repository.verifyRun(RunVerification(
            runID: retry.id,
            verdict: .playableWithIssues,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .failed,
            source: .visualInspection,
            verifiedAt: verifiedAt
        ))
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .relaunching,
            retryRunID: retry.id
        )
        try await fixture.repository.transitionRepairAttempt(
            id: attempt.id,
            to: .awaitingVerification
        )
        if accept {
            try await fixture.repository.transitionRepairAttempt(
                id: attempt.id,
                to: .acceptedWithIssues,
                verificationID: retry.id
            )
        }
        return AcceptedWithIssuesFixture(
            fixture: fixture,
            attemptID: attempt.id,
            retry: retry,
            verifiedAt: verifiedAt
        )
    }

    private func makeRepositoryFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-repair-attempt-\(UUID().uuidString)")
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = RunContext(
            appID: "424242",
            gameName: "Future",
            backend: .regression,
            bottleName: "Regression",
            providerVersion: "test",
            startedAt: Date().addingTimeInterval(-2),
            command: "wine",
            arguments: [],
            system: SystemSnapshot(
                macOSVersion: "26.0",
                architecture: "arm64",
                deviceModel: "MacTest",
                displayWidth: 1512,
                displayHeight: 982,
                displayScale: 2
            ),
            configuration: [:],
            configurationFingerprint: ConfigurationCollector.fingerprint([:])
        )
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 42,
            executable: "future.exe",
            startedAt: context.startedAt,
            launchMilliseconds: 1
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: context.startedAt.addingTimeInterval(1),
            exitCode: 1,
            result: .crashed,
            afterConfiguration: [:],
            delta: ConfigurationDiffer.difference(before: [:], after: [:])
        )
        return Fixture(
            directory: directory,
            databaseURL: databaseURL,
            repository: repository,
            sourceRunID: context.id
        )
    }

    private func rollbackManifest() -> RepairRollbackManifest {
        RepairRollbackManifest(
            entries: [
                RepairRollbackEntry(
                    targetPath: "/private/bottle/.regression/compiled-repair-activations-v2.tsv",
                    backupPath: "/private/bottle/.regression/Backups/v2.tsv",
                    beforeFingerprint: "before-v2",
                    afterFingerprint: "after-v2"
                ),
                RepairRollbackEntry(
                    targetPath: "/private/bottle/.regression/compiled-repair-activations-v1.tsv",
                    backupPath: "/private/bottle/.regression/Backups/v1.tsv",
                    beforeFingerprint: "before-v1",
                    afterFingerprint: "after-v1"
                )
            ]
        )
    }

    private func beginRun(
        repository: CompatibilityRepository,
        appID: String = "424242",
        backend: BackendKind = .regression,
        startedAt: Date
    ) async throws -> RunContext {
        let context = RunContext(
            appID: appID,
            gameName: "Future",
            backend: backend,
            bottleName: "Regression",
            providerVersion: "test",
            startedAt: startedAt,
            command: "wine",
            arguments: [],
            system: SystemSnapshot(
                macOSVersion: "26.0",
                architecture: "arm64",
                deviceModel: "MacTest",
                displayWidth: 1512,
                displayHeight: 982,
                displayScale: 2
            ),
            configuration: [:],
            configurationFingerprint: ConfigurationCollector.fingerprint([:])
        )
        try await repository.beginRun(context)
        return context
    }

    private func beginCrashedRun(
        repository: CompatibilityRepository,
        appID: String,
        executable: String,
        backend: BackendKind = .regression
    ) async throws -> RunContext {
        let startedAt = Date().addingTimeInterval(-2)
        let context = try await beginRun(
            repository: repository,
            appID: appID,
            backend: backend,
            startedAt: startedAt
        )
        try await repository.markLaunched(
            id: context.id,
            processID: 124,
            executable: executable,
            startedAt: startedAt,
            launchMilliseconds: 1
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: startedAt.addingTimeInterval(1),
            exitCode: 1,
            result: .crashed,
            afterConfiguration: [:],
            delta: ConfigurationDiffer.difference(before: [:], after: [:])
        )
        return context
    }

    private func mutateSQLite(
        _ databaseURL: URL,
        body: (OpaquePointer) throws -> Void
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw RegressionCoreError.database("No se pudo abrir SQLite para la prueba")
        }
        defer { sqlite3_close(database) }
        try body(database)
    }

    private func executeSQLite(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let detail = errorMessage.map { String(cString: $0) } ?? "Error SQLite"
            throw RegressionCoreError.database(detail)
        }
    }

    private func scalarSQLiteText(_ database: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RegressionCoreError.database("No se pudo preparar la consulta SQLite")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: value)
    }

    private func semanticRetryMutationSQL(field: String, runID: UUID) -> String {
        let mutation: String
        switch field {
        case "app_id":
            mutation = """
                INSERT OR IGNORE INTO games(app_id, name, updated_at)
                VALUES('434343', 'Other Game', '2026-08-13T00:00:00.000Z');
                UPDATE runs SET app_id='434343' WHERE id='\(runID.uuidString)';
                """
        case "backend":
            mutation = "UPDATE runs SET backend='crossOver' WHERE id='\(runID.uuidString)';"
        case "executable":
            mutation = "UPDATE runs SET executable='other.exe' WHERE id='\(runID.uuidString)';"
        case "started_at":
            mutation = """
                UPDATE runs SET started_at='2000-01-01T00:00:00.000Z'
                WHERE id='\(runID.uuidString)';
                """
        case "result":
            mutation = "UPDATE runs SET result='preparing' WHERE id='\(runID.uuidString)';"
        default:
            preconditionFailure("Campo semántico de prueba desconocido: \(field)")
        }
        return mutation
    }
}
