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
            try await reopened.transitionRepairAttempt(id: attempt.id, to: .verified)
            XCTFail("Una transición que omite relanzamiento y verificación debía rechazarse")
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

        try await fixture.repository.verifyRun(RunVerification(
            runID: retry.id,
            verdict: .invalidated,
            rendering: .failed,
            inputPrecision: .failed,
            graphicsSettings: .failed,
            gameplay: .failed,
            source: .visualInspection,
            notes: "evidencia revocada",
            verifiedAt: retryEndedAt.addingTimeInterval(2)
        ))
        let invalidated = try await fixture.repository.repairAttempt(id: attempt.id)
        XCTAssertEqual(invalidated?.state, .blocked)
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

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CompatibilityDatabaseHealth.self, from: legacyData)
        XCTAssertNil(decoded.repairAttemptCount)
        XCTAssertNil(decoded.legacyRepairActivationCount)
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

        try await fixture.repository.finishRun(
            id: retry.id,
            endedAt: Date(),
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
}
