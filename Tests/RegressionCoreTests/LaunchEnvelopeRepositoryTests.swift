import CSQLite
import Foundation
@testable import RegressionCore
import XCTest

final class LaunchEnvelopeRepositoryTests: XCTestCase {
    func testVersionFifteenDatabaseMigratesEnvelopeTablesAndKeepsPriorEvidence() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        try await fixture.repository.close()
        try mutateSQLite(fixture.databaseURL) { database in
            try executeSQLite(database, "DROP TABLE IF EXISTS launch_envelope_receipts;")
            try executeSQLite(database, "DROP TABLE IF EXISTS launch_envelope_events;")
            try executeSQLite(database, "DROP TABLE IF EXISTS launch_envelopes;")
            try executeSQLite(database, "DELETE FROM schema_migrations WHERE version >= 16;")
            try executeSQLite(database, "PRAGMA user_version=15;")
        }

        let migrated = CompatibilityRepository(databaseURL: fixture.databaseURL)
        try await migrated.prepare()
        let health = try await migrated.databaseHealth()

        XCTAssertEqual(health.schemaVersion, 17)
        XCTAssertEqual(health.runCount, 1)
        XCTAssertEqual(health.launchEnvelopeCount, 0)
        XCTAssertTrue(health.isHealthy)
    }

    func testRecordsIntentThenTransitionsAndReceiptsAtomicallyWithoutExecutablePayload() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()

        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await fixture.repository.advanceLaunchEnvelopeWithReceipt(
            id: intent.id,
            to: .awaitingTelemetry,
            result: .awaitingTelemetry
        )

        let stored = try await fixture.repository.launchEnvelope(id: intent.id)
        let events = try await fixture.repository.launchEnvelopeEvents(id: intent.id)
        let receipts = try await fixture.repository.launchEnvelopeReceipts(id: intent.id)
        XCTAssertEqual(stored?.phase, .awaitingTelemetry)
        XCTAssertEqual(events.map(\.phase), [
            .intentDurable, .spawnAuthorized, .spawnStarted, .awaitingTelemetry,
        ])
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipt.result, .awaitingTelemetry)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self).contains("/"))
    }

    func testRejectsFabricatedIntentWithoutStoredPreflightAndFreshRequirements() async throws {
        let fixture = try await Fixture.make(recordPreflight: false, recordRequirements: false)
        defer { fixture.remove() }
        let intent = try fixture.intent()

        await XCTAssertThrowsErrorAsync {
            try await fixture.repository.recordLaunchEnvelope(intent)
        }
    }

    func testInterruptedSpawnWithoutPIDBecomesRollbackPendingInsteadOfOrphanedTelemetry() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await fixture.repository.close()

        let reopened = CompatibilityRepository(databaseURL: fixture.databaseURL)
        try await reopened.prepare()
        let recovered = try await reopened.reconcileInterruptedLaunchEnvelopes()
        let recoveredEnvelope = try await reopened.launchEnvelope(id: intent.id)

        XCTAssertEqual(recovered, [intent.id])
        XCTAssertEqual(recoveredEnvelope?.phase, .rollbackPending)
    }

    func testSpawnBoundaryReadsClockInsideQueuedRepositoryTransaction() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let acceptedClock = TestClock(checkedAt.addingTimeInterval(LaunchEnvelopeService.maximumSealedPreflightAge))
        let accepted = try await Fixture.make(preflightCheckedAt: checkedAt, clock: acceptedClock.now)
        defer { accepted.remove() }
        let acceptedIntent = try accepted.intent(now: { checkedAt })
        try await accepted.repository.recordLaunchEnvelope(acceptedIntent)
        try await accepted.repository.authorizeLaunchEnvelopeSpawn(id: acceptedIntent.id)
        let acceptedAuthority = try await accepted.repository.gameLaunchSpawnAuthority(for: acceptedIntent.id)
        do {
            try await acceptedAuthority.markSpawnStartedAtProcessBoundary()
        } catch {
            XCTFail("El TTL de 90 segundos exactos debía aceptarse: \(error)")
        }

        let rejectedClock = TestClock(checkedAt)
        let rejected = try await Fixture.make(preflightCheckedAt: checkedAt, clock: rejectedClock.now)
        defer { rejected.remove() }
        let rejectedIntent = try rejected.intent(now: { checkedAt })
        try await rejected.repository.recordLaunchEnvelope(rejectedIntent)
        try await rejected.repository.authorizeLaunchEnvelopeSpawn(id: rejectedIntent.id)
        let rejectedAuthority = try await rejected.repository.gameLaunchSpawnAuthority(for: rejectedIntent.id)
        let actorEntered = DispatchSemaphore(value: 0)
        let releaseActor = DispatchSemaphore(value: 0)
        let blocker = Task {
            await rejected.repository.blockLaunchEnvelopeActorForTesting(
                started: actorEntered,
                release: releaseActor
            )
        }
        XCTAssertEqual(actorEntered.wait(timeout: .now() + 2), .success)
        let marker = Task {
            try await rejectedAuthority.markSpawnStartedAtProcessBoundary()
        }
        rejectedClock.set(checkedAt.addingTimeInterval(LaunchEnvelopeService.maximumSealedPreflightAge + 0.001))
        releaseActor.signal()
        await blocker.value
        await XCTAssertThrowsErrorAsync {
            _ = try await marker.value
        }
    }

    func testSynchronousProcessRunFailureClosesRunEnvelopeEventAndReceiptAtomically() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        let spawnAuthority = try await fixture.repository.gameLaunchSpawnAuthority(for: intent.id)
        let bottle = fixture.root.appendingPathComponent("Bottle", isDirectory: true)
        try FileManager.default.createDirectory(at: bottle, withIntermediateDirectories: true)
        let installation = RegressionInstallation(
            applicationURL: fixture.root.appendingPathComponent("Regression.app", isDirectory: true),
            bottleURL: bottle,
            steamExecutableURL: bottle.appendingPathComponent("Steam.exe"),
            engineLauncherURL: URL(fileURLWithPath: "/usr/bin/false"),
            health: .ready,
            healthDetail: "ok"
        )
        let authority = ProcessLaunchAuthority(
            regressionInstallation: installation,
            custodyPermit: nil,
            normalizedAppID: fixture.context.appID,
            regressionComponentHealthProvider: { _ in Fixture.readyRuntimeHealth() },
            rendererLaunchValidator: { _, _ in },
            gameLaunchAuthority: spawnAuthority
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await ProcessLauncher().launch(
                backend: .regression,
                executableURL: URL(fileURLWithPath: "/definitely/not/a/regression-executable"),
                arguments: [],
                logDirectoryURL: fixture.root.appendingPathComponent("Logs", isDirectory: true),
                authority: authority
            )
        }

        let envelope = try await fixture.repository.launchEnvelope(id: intent.id)
        let receipts = try await fixture.repository.launchEnvelopeReceipts(id: intent.id)
        let events = try await fixture.repository.launchEnvelopeEvents(id: intent.id)
        let run = try await fixture.repository.runDetails().first { $0.id == fixture.context.id }
        XCTAssertEqual(envelope?.phase, .failedBeforeSpawn)
        XCTAssertEqual(receipts.map(\.result), [.failedBeforeSpawn])
        XCTAssertEqual(events.map(\.phase), [.intentDurable, .spawnAuthorized, .spawnStarted, .failedBeforeSpawn])
        XCTAssertEqual(run?.result, .failed)
        XCTAssertNotNil(run?.endedAt)
        XCTAssertNil(run?.processID)
    }

    func testSpawnBoundaryRejectsRefreshedTechnologyGenerationBeforeAnyProcess() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        let authority = try await fixture.repository.gameLaunchSpawnAuthority(for: intent.id)
        // Publicar una generación nueva después de autorizar invalida la identidad sellada.
        try await fixture.repository.recordSuccessfulGameTechnologyScan(
            appID: fixture.context.appID,
            requirements: [],
            scannedAt: Date()
        )

        await XCTAssertThrowsErrorAsync { try await authority.markSpawnStartedAtProcessBoundary() }
        let envelope = try await fixture.repository.launchEnvelope(id: intent.id)
        let run = try await fixture.repository.runDetails().first { $0.id == fixture.context.id }
        XCTAssertEqual(envelope?.phase, .spawnAuthorized)
        XCTAssertNil(run?.processID)
    }

    func testPreSpawnFailureClosesRunEnvelopeEventAndReceiptInOneDurableOperation() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)

        try await fixture.repository.failLaunchEnvelopeBeforeSpawn(id: intent.id)
        let envelope = try await fixture.repository.launchEnvelope(id: intent.id)
        let receipts = try await fixture.repository.launchEnvelopeReceipts(id: intent.id)
        let events = try await fixture.repository.launchEnvelopeEvents(id: intent.id)
        let run = try await fixture.repository.runDetails().first { $0.id == fixture.context.id }
        XCTAssertEqual(envelope?.phase, .failedBeforeSpawn)
        XCTAssertEqual(receipts.map(\.result), [.failedBeforeSpawn])
        XCTAssertEqual(events.map(\.phase), [.intentDurable, .spawnAuthorized, .failedBeforeSpawn])
        XCTAssertEqual(run?.result, .failed)
        XCTAssertNotNil(run?.endedAt)
        XCTAssertNil(run?.processID)
        await XCTAssertThrowsErrorAsync {
            try await fixture.repository.failLaunchEnvelopeBeforeSpawn(id: intent.id)
        }
        let repeatedRun = try await fixture.repository.runDetails().first { $0.id == fixture.context.id }
        XCTAssertEqual(repeatedRun?.result, .failed)
    }

    func testInterruptedClosedCrashWithRepresentativeProcessAdvancesToVerificationAndIsIdempotent() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await Self.finish(fixture: fixture)

        let first = try await fixture.repository.reconcileInterruptedLaunchEnvelopes()
        let second = try await fixture.repository.reconcileInterruptedLaunchEnvelopes()
        let envelope = try await fixture.repository.launchEnvelope(id: intent.id)
        XCTAssertEqual(first, [intent.id])
        XCTAssertEqual(second, [])
        XCTAssertEqual(envelope?.phase, .awaitingVerification)
    }

    func testAmbiguousInterruptedSpawnRequiresExplicitRecoveryBeforeItCanResolve() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        _ = try await fixture.repository.reconcileInterruptedLaunchEnvelopes()

        try await fixture.repository.resolveLaunchEnvelopeRollbackAfterExplicitRecovery(id: intent.id)
        let envelope = try await fixture.repository.launchEnvelope(id: intent.id)
        let receipts = try await fixture.repository.launchEnvelopeReceipts(id: intent.id)
        XCTAssertEqual(envelope?.phase, .rolledBack)
        XCTAssertEqual(receipts.map(\.result), [.rolledBack])
    }

    func testAwaitingTelemetryWithoutProcessKeepsCumulativeReceiptsThroughQuarantineRecovery() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await fixture.repository.advanceLaunchEnvelopeWithReceipt(
            id: intent.id,
            to: .awaitingTelemetry,
            result: .awaitingTelemetry
        )

        let quarantined = try await fixture.repository.reconcileInterruptedLaunchEnvelopes()
        let pendingEnvelope = try await fixture.repository.launchEnvelope(id: intent.id)
        let pendingHealth = try await fixture.repository.databaseHealth()
        XCTAssertEqual(quarantined, [intent.id])
        XCTAssertEqual(pendingEnvelope?.phase, .rollbackPending)
        XCTAssertTrue(pendingHealth.isHealthy)

        try await fixture.repository.resolveLaunchEnvelopeRollbackAfterExplicitRecovery(id: intent.id)
        let recoveredEnvelope = try await fixture.repository.launchEnvelope(id: intent.id)
        let receipts = try await fixture.repository.launchEnvelopeReceipts(id: intent.id)
        let recoveredHealth = try await fixture.repository.databaseHealth()
        XCTAssertEqual(recoveredEnvelope?.phase, .rolledBack)
        XCTAssertEqual(receipts.map(\.result), [.awaitingTelemetry, .rolledBack])
        XCTAssertTrue(recoveredHealth.isHealthy)
    }

    func testAwaitingTelemetryClosedBeforeAnyProcessPreservesFailureReceiptHistory() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await fixture.repository.advanceLaunchEnvelopeWithReceipt(
            id: intent.id,
            to: .awaitingTelemetry,
            result: .awaitingTelemetry
        )
        try await fixture.repository.finishRun(
            id: fixture.context.id,
            endedAt: Date(),
            exitCode: 1,
            result: .failed,
            afterConfiguration: [:],
            delta: ConfigurationDelta(added: [:], removed: [:], changed: [:])
        )

        let reconciled = try await fixture.repository.reconcileInterruptedLaunchEnvelopes()
        let envelope = try await fixture.repository.launchEnvelope(id: intent.id)
        let receipts = try await fixture.repository.launchEnvelopeReceipts(id: intent.id)
        let health = try await fixture.repository.databaseHealth()
        XCTAssertEqual(reconciled, [intent.id])
        XCTAssertEqual(envelope?.phase, .failedBeforeSpawn)
        XCTAssertEqual(receipts.map(\.result), [.awaitingTelemetry, .failedBeforeSpawn])
        XCTAssertTrue(health.isHealthy)
    }

    func testCumulativeRecoveryReceiptSetRejectsUnexpectedAdditionalResult() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await fixture.repository.advanceLaunchEnvelopeWithReceipt(
            id: intent.id,
            to: .awaitingTelemetry,
            result: .awaitingTelemetry
        )
        _ = try await fixture.repository.reconcileInterruptedLaunchEnvelopes()
        try await fixture.repository.resolveLaunchEnvelopeRollbackAfterExplicitRecovery(id: intent.id)
        try await fixture.repository.close()
        try mutateSQLite(fixture.databaseURL) { database in
            try executeSQLite(database, "DROP TRIGGER launch_envelope_receipts_insert_guard;")
            try executeSQLite(
                database,
                """
                INSERT INTO launch_envelope_receipts(id, envelope_id, app_id, backend, result, created_at)
                VALUES ('\(UUID().uuidString)', '\(intent.id.uuidString)', '219990', 'regression',
                        'failedBeforeSpawn', '2026-01-01T00:00:00.000Z');
                """
            )
        }
        let reopened = CompatibilityRepository(databaseURL: fixture.databaseURL)
        try await reopened.prepare()
        let health = try await reopened.databaseHealth()
        XCTAssertFalse(health.isHealthy)
    }

    func testVersionSixteenPopulatedEnvelopeMigratesToV17AndPermitsTerminalPreSpawnFailure() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await fixture.repository.close()
        try mutateSQLite(fixture.databaseURL) { database in
            try executeSQLite(database, "DROP TRIGGER launch_envelopes_transition_guard;")
            try executeSQLite(database, LaunchEnvelopeSchema.sql)
            try executeSQLite(database, "DELETE FROM schema_migrations WHERE version >= 17;")
            try executeSQLite(database, "PRAGMA user_version=16;")
        }

        let migrated = CompatibilityRepository(databaseURL: fixture.databaseURL)
        try await migrated.prepare()
        try await migrated.advanceLaunchEnvelopeWithReceipt(
            id: intent.id,
            to: .failedBeforeSpawn,
            result: .failedBeforeSpawn
        )
        let health = try await migrated.databaseHealth()
        let migratedEnvelope = try await migrated.launchEnvelope(id: intent.id)
        XCTAssertEqual(health.schemaVersion, 17)
        XCTAssertEqual(migratedEnvelope?.phase, .failedBeforeSpawn)
    }

    func testV17MigrationRollbackRestoresV16TriggerAndDataWhenReplacementCannotBeCreated() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.close()
        try mutateSQLite(fixture.databaseURL) { database in
            try executeSQLite(database, "DROP TRIGGER launch_envelopes_transition_guard;")
            try executeSQLite(database, LaunchEnvelopeSchema.sql)
            try executeSQLite(database, "DELETE FROM schema_migrations WHERE version >= 17;")
            try executeSQLite(database, "PRAGMA user_version=16;")
            try executeSQLite(
                database,
                """
                CREATE TRIGGER abort_launch_envelope_v17_migration
                BEFORE INSERT ON schema_migrations WHEN NEW.version=17
                BEGIN
                    SELECT RAISE(ABORT, 'forced v17 migration rollback');
                END;
                """
            )
        }
        let migration = CompatibilityRepository(databaseURL: fixture.databaseURL)
        await XCTAssertThrowsErrorAsync { try await migration.prepare() }
        try? await migration.close()
        try mutateSQLite(fixture.databaseURL) { database in
            XCTAssertEqual(try scalarSQLiteText(database, "PRAGMA user_version;"), "16")
            XCTAssertEqual(
                try scalarSQLiteText(
                    database,
                    "SELECT type FROM sqlite_master WHERE name='launch_envelopes_transition_guard';"
                ),
                "trigger"
            )
            XCTAssertEqual(
                try scalarSQLiteText(database, "SELECT COUNT(*) FROM launch_envelopes;"),
                "1"
            )
        }
    }

    func testTelemetryAndExplicitVerificationAdvanceEnvelopeWithoutAutoCertification() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        let startedAt = Date()
        let endedAt = startedAt.addingTimeInterval(1)
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await fixture.repository.advanceLaunchEnvelopeWithReceipt(
            id: intent.id,
            to: .awaitingTelemetry,
            result: .awaitingTelemetry
        )
        try await fixture.repository.markLaunched(
            id: fixture.context.id,
            processID: 42,
            executable: "Game.exe",
            startedAt: startedAt,
            launchMilliseconds: 1
        )
        try await fixture.repository.markProcessEnded(
            id: fixture.context.id,
            processID: 42,
            endedAt: endedAt,
            exitCode: 1
        )
        try await fixture.repository.finishRun(
            id: fixture.context.id,
            endedAt: endedAt,
            exitCode: 1,
            result: .crashed,
            afterConfiguration: [:],
            delta: ConfigurationDelta(added: [:], removed: [:], changed: [:])
        )

        let telemetryReconciled = try await fixture.repository.reconcileLaunchEnvelopeAfterTelemetry(
            runID: fixture.context.id,
            at: endedAt
        )
        let awaitingVerification = try await fixture.repository.launchEnvelope(id: intent.id)
        XCTAssertTrue(telemetryReconciled)
        XCTAssertEqual(awaitingVerification?.phase, .awaitingVerification)

        let verificationCompleted = try await fixture.repository.verifyRunAndCompleteEnvelope(RunVerification(
            runID: fixture.context.id,
            verdict: .failed,
            source: .user,
            verifiedAt: endedAt
        ))
        let receipts = try await fixture.repository.launchEnvelopeReceipts(id: intent.id)
        let completed = try await fixture.repository.launchEnvelope(id: intent.id)
        XCTAssertTrue(verificationCompleted)
        XCTAssertEqual(completed?.phase, .completed)
        XCTAssertEqual(receipts.map(\.result), [.awaitingTelemetry, .verificationRecorded])
    }

    func testDurableEnvelopeRunCanBeAdoptedWithoutInMemoryTelemetryIntent() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await fixture.repository.advanceLaunchEnvelopeWithReceipt(
            id: intent.id,
            to: .awaitingTelemetry,
            result: .awaitingTelemetry
        )

        let adopted = try await fixture.repository.adoptableLaunchEnvelopeRun(
            appID: fixture.context.appID,
            backend: .regression
        )
        XCTAssertEqual(adopted?.envelopeID, intent.id)
        XCTAssertEqual(adopted?.context.id, fixture.context.id)
        XCTAssertEqual(adopted?.context.appID, fixture.context.appID)
    }

    func testAtomicVerificationRollsBackWhenEnvelopeCannotComplete() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        try await Self.markSpawnStarted(fixture: fixture, envelopeID: intent.id)
        try await Self.finish(fixture: fixture)

        await XCTAssertThrowsErrorAsync {
            try await fixture.repository.verifyRunAndCompleteEnvelope(RunVerification(
                runID: fixture.context.id,
                verdict: .failed,
                source: .user,
                verifiedAt: Date().addingTimeInterval(1)
            ))
        }

        let envelopeAfterRollback = try await fixture.repository.launchEnvelope(id: intent.id)
        let runAfterRollback = try await fixture.repository.runDetails().first {
            $0.id == fixture.context.id
        }
        XCTAssertEqual(envelopeAfterRollback?.phase, .spawnStarted)
        XCTAssertNil(runAfterRollback?.verification)
    }

    /// Un run sin envelope es el que la telemetría observó porque el usuario abrió el juego desde
    /// el propio Steam de la botella: ahí Regression no autoriza el lanzamiento y no hay sobre que
    /// cerrar. Rechazarlo dejaba esos runs imposibles de verificar y perdía el veredicto sin
    /// guardarlo, que es lo que se veía en la app como «Pendiente de verificación visual» después
    /// de marcar el juego a mano.
    func testAtomicVerificationAcceptsRunObservedWithoutEnvelope() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        try await Self.finish(fixture: fixture)

        let completedEnvelope = try await fixture.repository.verifyRunAndCompleteEnvelope(
            RunVerification(
                runID: fixture.context.id,
                verdict: .failed,
                source: .user,
                verifiedAt: Date().addingTimeInterval(1)
            )
        )

        XCTAssertFalse(completedEnvelope, "sin envelope no hay sobre que cerrar")
        let run = try await fixture.repository.runDetails().first { $0.id == fixture.context.id }
        XCTAssertEqual(run?.verification?.verdict, .failed)
    }

    func testSpawnAuthorizationIsTheOnlyPublicPreSpawnTransition() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)

        await XCTAssertThrowsErrorAsync {
            try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        }
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RegressionCore/CompatibilityRepository+LaunchEnvelope.swift")
        let source = try String(contentsOf: sourceURL)
        XCTAssertFalse(source.contains("public func advanceLaunchEnvelope("))
        XCTAssertFalse(source.contains("public func markLaunchEnvelopeSpawnStarted("))
    }

    func testSpawnAuthorityRevalidatesDatabaseBetweenAuthorizationAndProcessBoundary() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        let authority = try await fixture.repository.gameLaunchSpawnAuthority(for: intent.id)

        try mutateSQLite(fixture.databaseURL) { database in
            try executeSQLite(database, "PRAGMA foreign_keys=OFF;")
            try executeSQLite(database, "DROP TRIGGER launch_envelope_events_insert_guard;")
            try executeSQLite(
                database,
                """
                INSERT INTO launch_envelope_events(id, envelope_id, phase, recorded_at)
                VALUES ('\(UUID().uuidString)', '\(UUID().uuidString)', 'spawnStarted', '2026-08-14T00:00:00Z');
                """
            )
        }

        await XCTAssertThrowsErrorAsync {
            try await authority.markSpawnStartedAtProcessBoundary()
        }
        let envelope = try await fixture.repository.launchEnvelope(id: intent.id)
        XCTAssertEqual(envelope?.phase, .spawnAuthorized)
    }

    func testSpawnAuthorityRejectsReplacedPreflightIdentityAtProcessBoundary() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        let authority = try await fixture.repository.gameLaunchSpawnAuthority(for: intent.id)
        try mutateSQLite(fixture.databaseURL) { database in
            try executeSQLite(database, "UPDATE run_preflight_reports SET created_at='2000-01-01T00:00:00Z' WHERE run_id='\(fixture.context.id.uuidString)';")
        }
        await XCTAssertThrowsErrorAsync { try await authority.markSpawnStartedAtProcessBoundary() }
    }

    func testSpawnAuthorityRejectsExpiredSealedPreflightAtProcessBoundary() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        let authority = try await fixture.repository.gameLaunchSpawnAuthority(for: intent.id)
        try mutateSQLite(fixture.databaseURL) { database in
            let expired = "2000-01-01T00:00:00Z"
            try executeSQLite(database, "DROP TRIGGER launch_envelopes_transition_guard;")
            try executeSQLite(database, "UPDATE launch_envelopes SET preflight_checked_at='\(expired)' WHERE id='\(intent.id.uuidString)';")
            try executeSQLite(database, "UPDATE run_preflight_reports SET created_at='\(expired)' WHERE run_id='\(fixture.context.id.uuidString)';")
        }
        await XCTAssertThrowsErrorAsync { try await authority.markSpawnStartedAtProcessBoundary() }
    }

    func testExportIncludesEnvelopeEventsAndMalformedRowsFailHealthClosed() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.remove() }
        let intent = try fixture.intent()
        try await fixture.repository.recordLaunchEnvelope(intent)
        try await fixture.repository.authorizeLaunchEnvelopeSpawn(id: intent.id)
        let exportURL = fixture.root.appendingPathComponent("export.json")
        try await fixture.repository.exportJSON(to: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(CompatibilityExport.self, from: Data(contentsOf: exportURL))
        XCTAssertEqual(export.launchEnvelopeEvents.map(\.phase), [.intentDurable, .spawnAuthorized])

        try await fixture.repository.close()
        try mutateSQLite(fixture.databaseURL) { database in
            try executeSQLite(database, "DROP TRIGGER launch_envelopes_transition_guard;")
            try executeSQLite(
                database,
                "UPDATE launch_envelopes SET requirement_identities_json='{}' WHERE id='\(intent.id.uuidString)';"
            )
        }
        let reopened = CompatibilityRepository(databaseURL: fixture.databaseURL)
        try await reopened.prepare()
        let health = try await reopened.databaseHealth()
        XCTAssertEqual(health.launchEnvelopeViolationCount, 1)
        XCTAssertFalse(health.isHealthy)
    }
}

private extension LaunchEnvelopeRepositoryTests {
    struct Fixture {
        let root: URL
        let databaseURL: URL
        let repository: CompatibilityRepository
        let context: RunContext
        let preflight: GameTestPreflightReport

        static func make(
            recordPreflight: Bool = true,
            recordRequirements: Bool = true,
            preflightCheckedAt: Date = Date(),
            clock: @escaping @Sendable () -> Date = Date.init
        ) async throws -> Self {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("regression-envelope-\(UUID().uuidString)", isDirectory: true)
            let databaseURL = root.appendingPathComponent("compatibility.sqlite")
            let repository = CompatibilityRepository(databaseURL: databaseURL, clock: clock)
            try await repository.prepare()
            let context = RunContext(
                appID: "219990",
                gameName: "Grim Dawn",
                backend: .regression,
                bottleName: "Steam",
                providerVersion: "test",
                command: "regression-engine",
                arguments: ["-applaunch", "219990"],
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
            let preflight = GameTestPreflightReport(
                appID: context.appID,
                gameName: context.gameName,
                backend: .regression,
                checkedAt: preflightCheckedAt,
                checks: GameTestPreflightCheckID.allCases.map {
                    GameTestPreflightCheck(
                        checkID: $0,
                        status: .ready,
                        title: $0.rawValue,
                        detail: "ok"
                    )
                }
            )
            if recordPreflight {
                try await repository.recordPreflight(preflight, forRunID: context.id)
            }
            if recordRequirements {
                try await repository.recordSuccessfulGameTechnologyScan(
                    appID: context.appID,
                    requirements: [],
                    scannedAt: preflight.checkedAt
                )
            }
            return Fixture(
                root: root,
                databaseURL: databaseURL,
                repository: repository,
                context: context,
                preflight: preflight
            )
        }

        func intent(
            now: @escaping @Sendable () -> Date = Date.init
        ) throws -> LaunchEnvelopeIntent {
            try LaunchEnvelopeService(now: now).prepare(
                LaunchEnvelopeRequest(
                    appID: context.appID,
                    backend: .regression,
                    runID: context.id,
                    preflight: preflight,
                    requirements: GameTechnologyRequirementProjection(
                        scanState: GameTechnologyScanState(
                            appID: context.appID,
                            generation: 1,
                            lastSuccessfulGeneration: 1,
                            freshness: .current,
                            attemptedAt: preflight.checkedAt,
                            lastSuccessfulAt: preflight.checkedAt,
                            error: nil
                        ),
                        requirements: []
                    ),
                    componentHealth: LaunchEnvelopeComponentHealth(
                        runtime: ComponentHealthReport(
                            identity: ComponentIdentity(
                                componentID: TrustedComponentCatalog.steamRuntimePrerequisitesComponentID,
                                componentVersion: TrustedComponentCatalog.steamRuntimePrerequisitesComponentVersion,
                                variant: .publicInstalled,
                                buildIdentifier: TrustedComponentCatalog.supportedBuildIdentifier
                            ),
                            status: .ready,
                            recovery: .none
                        ),
                        windowsMedia: nil
                    ),
                    rendererIsEligible: true
                )
            )
        }

        static func readyRuntimeHealth() -> ComponentHealthReport {
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

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) {
            self.value = value
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: Date) {
            lock.lock()
            self.value = value
            lock.unlock()
        }
    }

    func mutateSQLite(_ url: URL, body: (OpaquePointer) throws -> Void) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "LaunchEnvelopeTests", code: 1)
        }
        defer { sqlite3_close_v2(database) }
        try body(database)
    }

    func executeSQLite(_ database: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "LaunchEnvelopeTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? "SQLite"]
            )
        }
    }

    func scalarSQLiteText(_ database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "LaunchEnvelopeTests", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "LaunchEnvelopeTests", code: 3)
        }
        guard let text = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "LaunchEnvelopeTests", code: 4)
        }
        return String(cString: text)
    }

    func XCTAssertThrowsErrorAsync(
        _ body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("Se esperaba un rechazo", file: file, line: line)
        } catch {
            // esperado
        }
    }

    static func finish(fixture: Fixture) async throws {
        let startedAt = Date()
        let endedAt = startedAt.addingTimeInterval(1)
        try await fixture.repository.markLaunched(
            id: fixture.context.id,
            processID: 42,
            executable: "Game.exe",
            startedAt: startedAt,
            launchMilliseconds: 1
        )
        try await fixture.repository.markProcessEnded(
            id: fixture.context.id,
            processID: 42,
            endedAt: endedAt,
            exitCode: 1
        )
        try await fixture.repository.finishRun(
            id: fixture.context.id,
            endedAt: endedAt,
            exitCode: 1,
            result: .crashed,
            afterConfiguration: [:],
            delta: ConfigurationDelta(added: [:], removed: [:], changed: [:])
        )
    }

    static func markSpawnStarted(
        fixture: Fixture,
        envelopeID: UUID
    ) async throws {
        let authority = try await fixture.repository.gameLaunchSpawnAuthority(for: envelopeID)
        try await authority.markSpawnStartedAtProcessBoundary()
    }
}
