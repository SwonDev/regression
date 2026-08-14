import CSQLite
import Foundation
@testable import RegressionCore
import XCTest

final class CompatibilityCatalogTests: XCTestCase {
    func testExternalCatalogMutationSurfaceIsNotPublicAPI() throws {
        let root = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        let moduleDirectory = Bundle(for: CompatibilityCatalogTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Modules", isDirectory: true)
        let scratch = temporaryDirectory("external-catalog-api")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = scratch.appendingPathComponent("External.swift")
        try """
        import Foundation
        import RegressionCore
        func unavailable<T>() -> T { fatalError() }
        func mutate(_ repository: CompatibilityRepository) async throws {
            try await repository.registerExternalSource(unavailable())
            _ = try await repository.reserveExternalRequest(source: unavailable())
            _ = try await repository.externalSyncState(sourceID: "codeweavers")
            try await repository.recordExternalSyncSuccess(sourceID: "codeweavers")
            try await repository.recordExternalSyncFailure(sourceID: "codeweavers", message: "x")
            try await repository.upsertExternalRecord(
                unavailable(), for: unavailable(), matchMethod: unavailable(), confidence: 1
            )
            try await repository.recordExternalLookupStatus(
                sourceID: "codeweavers", game: unavailable(), status: unavailable()
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

        XCTAssertNotEqual(process.terminationStatus, 0)
        for method in [
            "registerExternalSource", "reserveExternalRequest", "externalSyncState",
            "recordExternalSyncSuccess", "recordExternalSyncFailure", "upsertExternalRecord",
            "recordExternalLookupStatus",
        ] {
            XCTAssertTrue(
                diagnostic.contains("'\(method)' is inaccessible due to 'internal' protection level"),
                "La API \(method) sigue expuesta o produjo un diagnóstico inesperado: \(diagnostic)"
            )
        }
    }

    func testProvisionalSteamAppNameCannotReplaceKnownManifestName() async throws {
        let directory = temporaryDirectory("game-name-precedence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        let known = makeContext(appID: "4570720", name: "DragonSword : Awakening")
        try await repository.beginRun(known)
        try await repository.failRunBeforeLaunch(id: known.id, reason: "prueba controlada")

        let provisional = makeContext(appID: "4570720", name: "steam app 4570720")
        try await repository.beginRun(provisional)
        try await repository.failRunBeforeLaunch(id: provisional.id, reason: "prueba controlada")

        let runs = try await repository.recentRuns()
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(
            Set(runs.map(\.gameName)),
            Set(["DragonSword : Awakening"]),
            "Un evento temprano de telemetría no puede degradar un nombre público ya conocido."
        )
        try await repository.close()
    }

    func testManifestReconciliationRepairsHistoricalProvisionalName() async throws {
        let directory = temporaryDirectory("game-name-reconciliation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        let provisional = makeContext(appID: "4570720", name: "Steam App 4570720")
        try await repository.beginRun(provisional)
        try await repository.failRunBeforeLaunch(id: provisional.id, reason: "prueba controlada")
        try await repository.reconcileDiscoveredGames([
            SteamGame(
                appID: "4570720",
                name: "DragonSword : Awakening",
                installDirectory: "DragonSword  Awakening",
                manifestURL: directory.appendingPathComponent("appmanifest_4570720.acf"),
                sourceBackend: .crossOver
            )
        ])

        let runs = try await repository.recentRuns()
        let run = try XCTUnwrap(runs.first)
        XCTAssertEqual(run.gameName, "DragonSword : Awakening")
        try await repository.close()
    }

    func testLegacyDatabaseMigratesAtomicallyAndPreservesPerfectGameplayEvidence() async throws {
        let directory = temporaryDirectory("legacy-migration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let context = makeContext(appID: "77", name: "Legacy Game")

        var repository: CompatibilityRepository? = CompatibilityRepository(databaseURL: databaseURL)
        try await repository?.prepare()
        try await repository?.beginRun(context)
        try await repository?.markLaunched(
            id: context.id,
            processID: 770,
            executable: "C:\\Games\\legacy.exe",
            launchMilliseconds: 100
        )
        try await closeTrackedRun(context, processID: 770, repository: repository!)
        try await repository?.verifyRun(RunVerification(
            runID: context.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "Contrato histórico completo"
        ))
        try await repository?.close()
        repository = nil

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                DROP TRIGGER IF EXISTS run_verifications_complete_perfect_insert;
                DROP TRIGGER IF EXISTS run_verifications_complete_perfect_update;
                DROP TRIGGER IF EXISTS observations_complete_perfect_insert;
                DROP TRIGGER IF EXISTS observations_complete_perfect_update;
                DROP TRIGGER IF EXISTS research_case_reopens_after_verdict_correction;
                DROP TRIGGER IF EXISTS run_verifications_perfect_requires_launch_insert;
                DROP TRIGGER IF EXISTS run_verifications_perfect_requires_launch_update;
                DROP TRIGGER IF EXISTS run_processes_open_invalidates_perfect_insert;
                DROP TRIGGER IF EXISTS run_processes_open_invalidates_perfect_update;
                DROP TRIGGER IF EXISTS run_processes_mutation_invalidates_perfect_insert;
                DROP TRIGGER IF EXISTS run_processes_mutation_invalidates_perfect_update;
                DROP TRIGGER IF EXISTS run_processes_mutation_invalidates_perfect_delete;
                DROP TRIGGER IF EXISTS runs_semantic_mutation_invalidates_perfect;
                DROP TRIGGER IF EXISTS runs_perfect_history_prevents_delete;
                DROP TRIGGER IF EXISTS runs_verified_history_prevents_delete;
                DROP TABLE IF EXISTS research_gate_results;
                DROP TABLE IF EXISTS research_artifacts;
                DROP TABLE IF EXISTS research_experiments;
                DROP TABLE IF EXISTS research_hypotheses;
                DROP TABLE IF EXISTS compatibility_research_cases;
                DROP TABLE IF EXISTS external_game_links;
                DROP TABLE IF EXISTS external_game_records;
                DROP TABLE IF EXISTS external_catalog_sync_state;
                DROP TABLE IF EXISTS external_catalog_sources;
                DROP TABLE IF EXISTS verified_game_certifications;
                DROP TABLE IF EXISTS run_engine_snapshots;
                DROP TABLE IF EXISTS observation_engine_snapshots;
                DROP TABLE IF EXISTS engine_facts;
                DROP TABLE IF EXISTS engine_snapshots;
                ALTER TABLE run_verifications DROP COLUMN gameplay;
                ALTER TABLE compatibility_observations DROP COLUMN gameplay;
                DELETE FROM schema_migrations WHERE version >= 3;
                PRAGMA user_version=2;
                """)
        }

        let migrated = CompatibilityRepository(databaseURL: databaseURL)
        try await migrated.prepare()
        let health = try await migrated.databaseHealth()
        XCTAssertEqual(health.schemaVersion, CompatibilityRepository.currentSchemaVersion)
        XCTAssertTrue(health.isHealthy)
        XCTAssertEqual(health.certificationCount, VerifiedGameCatalog.all.count + 1)
        XCTAssertEqual(health.engineSnapshotCount, 1)
        XCTAssertEqual(health.processCount, 1)
        XCTAssertEqual(health.runtimeTechnologyCount, RuntimeTechnologyCatalog.all.count)
        XCTAssertEqual(health.runtimeCandidateCount, 0)
        let migratedRuns = try await migrated.runDetails()
        XCTAssertEqual(migratedRuns.first?.verification?.gameplay, .passed)

        let migrationBackup = await migrated.lastMigrationBackup()
        let backupURL = try XCTUnwrap(migrationBackup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        let backupMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(backupMode & 0o777, 0o600)
        try await migrated.close()
    }

    func testLocalCertificationPinsExactEvidenceAndDeactivatesWithItsLastPerfectVerdict() async throws {
        let directory = temporaryDirectory("certification-provenance")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "90", name: "Certified Game")
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 900,
            executable: "C:\\Games\\certified.exe",
            launchMilliseconds: 100
        )
        try await closeTrackedRun(context, processID: 900, repository: repository)
        try await repository.verifyRun(RunVerification(
            runID: context.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "Verificación completa"
        ))

        let active = try await repository.certifications()
        let certification = try XCTUnwrap(active.first { $0.appID == context.appID })
        XCTAssertEqual(certification.origin, .localVerification)
        XCTAssertEqual(certification.sourceRunID, context.id)
        XCTAssertNil(certification.sourceObservationID)
        XCTAssertEqual(certification.configurationFingerprint, context.configurationFingerprint)
        XCTAssertNotNil(certification.engineFingerprint)
        XCTAssertEqual(certification.catalogRevision, "local")
        XCTAssertTrue(certification.isActive)

        try await repository.verifyRun(RunVerification(
            runID: context.id,
            verdict: .failed,
            rendering: .failed,
            source: .visualInspection,
            notes: "Veredicto corregido"
        ))
        let activeAfterCorrection = try await repository.certifications()
        XCTAssertNil(activeAfterCorrection.first { $0.appID == context.appID })
        let completeHistory = try await repository.certifications(activeOnly: false)
        let inactive = try XCTUnwrap(completeHistory.first { $0.appID == context.appID })
        XCTAssertFalse(inactive.isActive)
        XCTAssertNil(inactive.sourceRunID)
        XCTAssertNil(inactive.engineFingerprint)
        try await repository.close()
    }

    func testManualPerfectCertificationSurvivesRestartAndJSONExport() async throws {
        let directory = temporaryDirectory("manual-certification-restart")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let context = makeContext(appID: "92", name: "Persistent Perfect Game")

        let firstRepository = CompatibilityRepository(databaseURL: databaseURL)
        try await firstRepository.prepare()
        try await firstRepository.beginRun(context)
        try await firstRepository.markLaunched(
            id: context.id,
            processID: 920,
            executable: "C:\\Games\\persistent.exe",
            launchMilliseconds: 140
        )
        try await closeTrackedRun(context, processID: 920, repository: firstRepository)
        try await firstRepository.verifyRun(RunVerification(
            runID: context.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .user,
            notes: "Confirmación manual completa"
        ))
        try await firstRepository.close()

        let reopenedRepository = CompatibilityRepository(databaseURL: databaseURL)
        try await reopenedRepository.prepare()
        let reopenedCertifications = try await reopenedRepository.certifications()
        let certification = try XCTUnwrap(
            reopenedCertifications.first { $0.appID == context.appID }
        )
        XCTAssertEqual(certification.origin, .localVerification)
        XCTAssertEqual(certification.sourceRunID, context.id)
        XCTAssertEqual(certification.configurationFingerprint, context.configurationFingerprint)
        XCTAssertNotNil(certification.engineFingerprint)
        XCTAssertTrue(certification.isActive)

        let exportURL = directory.appendingPathComponent("compatibility-export.json")
        try await reopenedRepository.exportJSON(to: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(
            CompatibilityExport.self,
            from: Data(contentsOf: exportURL)
        )
        let exportedCertification = try XCTUnwrap(
            payload.certifications.first { $0.appID == context.appID && $0.isActive }
        )
        XCTAssertEqual(exportedCertification.sourceRunID, context.id)
        XCTAssertEqual(exportedCertification.engineFingerprint, certification.engineFingerprint)
        XCTAssertEqual(payload.processes.count, 1)
        XCTAssertEqual(payload.processes.first?.runID, context.id)
        let exactProcesses = try await reopenedRepository.runProcesses(
            runID: context.id,
            limit: 1
        )
        XCTAssertEqual(exactProcesses.map(\.runID), [context.id])
        XCTAssertEqual(payload.databaseHealth.schemaVersion, CompatibilityRepository.currentSchemaVersion)
        try await reopenedRepository.close()
    }

    func testRuntimeCandidateNeedsIsolationRollbackMatrixAndMeasuredImprovement() async throws {
        let directory = temporaryDirectory("runtime-candidate-gates")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "93", name: "Optimization Game")
        try await repository.beginRun(context)

        let candidateID = UUID()
        let unsafeCandidate = RuntimeCandidate(
            id: candidateID,
            technologyID: "dxmt",
            appID: context.appID,
            targetVersion: "0.80",
            scope: .perGame,
            objective: "Mejorar el frame pacing",
            state: .validated,
            sourceURL: URL(string: "https://github.com/3Shain/dxmt/releases/tag/v0.80")!
        )
        try await repository.registerRuntimeCandidate(unsafeCandidate)
        let activeCandidatesBeforePromotion = try await repository.runtimeCandidateCount(
            activeOnly: true
        )
        XCTAssertEqual(activeCandidatesBeforePromotion, 1)
        let unsafeDecision = RuntimeSelectionPolicy.promotionDecision(
            for: unsafeCandidate,
            assessments: [],
            technology: RuntimeTechnologyCatalog.all.first {
                $0.id == unsafeCandidate.technologyID
            }
        )
        XCTAssertFalse(unsafeDecision.isEligible)
        XCTAssertGreaterThanOrEqual(unsafeDecision.blockers.count, 5)

        XCTAssertThrowsError(try mutateSQLite(databaseURL) { database in
            try executeSQLite(
                database,
                "UPDATE runtime_candidates SET state='promoted' WHERE id='\(candidateID.uuidString)';"
            )
        })

        let protectedCandidate = RuntimeCandidate(
            id: candidateID,
            technologyID: "dxmt",
            appID: context.appID,
            targetVersion: "0.80",
            scope: .perGame,
            objective: "Mejorar el frame pacing",
            state: .validated,
            sourceURL: URL(string: "https://github.com/3Shain/dxmt/releases/tag/v0.80")!,
            sourceFingerprint: "sha256:test-source",
            sourceVerified: true,
            isIsolated: true,
            rollbackReference: "backups/runtime-candidate-93",
            baselineEngineFingerprint: "engine-baseline",
            candidateEngineFingerprint: "engine-candidate",
            validationMatrixPassed: true
        )
        try await repository.registerRuntimeCandidate(protectedCandidate)
        try await repository.recordOptimizationAssessment(OptimizationAssessment(
            appID: context.appID,
            backend: .regression,
            engineFingerprint: "engine-baseline",
            state: .baselineMeasured,
            resolution: "3024x1964",
            qualityPreset: "alto",
            averageFPS: 55,
            onePercentLowFPS: 48,
            frameTimeP95Milliseconds: 20
        ))
        try await repository.recordOptimizationAssessment(OptimizationAssessment(
            appID: context.appID,
            backend: .regression,
            engineFingerprint: "engine-candidate",
            candidateID: candidateID,
            state: .bestKnown,
            resolution: "3024x1964",
            qualityPreset: "alto",
            averageFPS: 54,
            onePercentLowFPS: 47,
            frameTimeP95Milliseconds: 21
        ))
        do {
            try await repository.promoteRuntimeCandidate(id: candidateID)
            XCTFail("Un candidato medido pero peor que el baseline no debe promocionarse")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        try await repository.recordOptimizationAssessment(OptimizationAssessment(
            appID: context.appID,
            backend: .regression,
            engineFingerprint: "engine-candidate",
            candidateID: candidateID,
            state: .bestKnown,
            resolution: "3024x1964",
            qualityPreset: "alto",
            averageFPS: 60,
            onePercentLowFPS: 52,
            frameTimeP95Milliseconds: 18
        ))
        try await repository.promoteRuntimeCandidate(id: candidateID)
        let promotedCandidate = try await repository.runtimeCandidates()
            .first { $0.id == candidateID }
        XCTAssertEqual(
            promotedCandidate?.state,
            .promoted
        )
        let activeCandidatesAfterPromotion = try await repository.runtimeCandidateCount(
            activeOnly: true
        )
        XCTAssertEqual(activeCandidatesAfterPromotion, 0)
        try await repository.close()
    }

    func testRuntimePromotionRejectsUntrustedSourcesAndIncompleteMetricCoverage() {
        let candidateID = UUID()
        let candidate = RuntimeCandidate(
            id: candidateID,
            technologyID: "dxmt",
            appID: "95",
            targetVersion: "0.80",
            scope: .perGame,
            objective: "Comparar un runtime aislado",
            state: .validated,
            sourceURL: URL(string: "https://github.com/3Shain/dxmt/releases/tag/v0.80")!,
            sourceFingerprint: "sha256:test-source",
            sourceVerified: true,
            isIsolated: true,
            rollbackReference: "backups/runtime-candidate-95",
            baselineEngineFingerprint: "engine-baseline",
            candidateEngineFingerprint: "engine-candidate",
            validationMatrixPassed: true
        )
        let assessments = [
            OptimizationAssessment(
                appID: "95",
                backend: .regression,
                engineFingerprint: "engine-baseline",
                state: .baselineMeasured,
                resolution: "1920x1080",
                qualityPreset: "alto",
                averageFPS: 60,
                onePercentLowFPS: 50
            ),
            OptimizationAssessment(
                appID: "95",
                backend: .regression,
                engineFingerprint: "engine-candidate",
                candidateID: candidateID,
                state: .bestKnown,
                resolution: "1920x1080",
                qualityPreset: "alto",
                averageFPS: 70
            )
        ]
        let technology = RuntimeTechnologyCatalog.all.first { $0.id == "dxmt" }
        let incompleteDecision = RuntimeSelectionPolicy.promotionDecision(
            for: candidate,
            assessments: assessments,
            technology: technology
        )
        XCTAssertFalse(incompleteDecision.isEligible)
        XCTAssertTrue(incompleteDecision.blockers.contains { $0.contains("comparación equivalente") })

        let untrustedCandidate = RuntimeCandidate(
            id: candidateID,
            technologyID: "dxmt",
            appID: "95",
            targetVersion: "0.80",
            scope: .perGame,
            objective: "Fuente no oficial",
            state: .validated,
            sourceURL: URL(string: "https://example.invalid/dxmt-v0.80.zip")!,
            sourceFingerprint: "sha256:test-source",
            sourceVerified: true,
            isIsolated: true,
            rollbackReference: "backups/runtime-candidate-95",
            baselineEngineFingerprint: "engine-baseline",
            candidateEngineFingerprint: "engine-candidate",
            validationMatrixPassed: true
        )
        let untrustedDecision = RuntimeSelectionPolicy.promotionDecision(
            for: untrustedCandidate,
            assessments: assessments,
            technology: technology
        )
        XCTAssertFalse(untrustedDecision.isEligible)
        XCTAssertTrue(untrustedDecision.blockers.contains { $0.contains("sitio oficial") })
    }

    func testBestKnownOptimizationCannotBeStoredWithoutAMetric() async throws {
        let directory = temporaryDirectory("optimization-requires-metric")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "94", name: "Unmeasured Game")
        try await repository.beginRun(context)

        do {
            try await repository.recordOptimizationAssessment(OptimizationAssessment(
                appID: context.appID,
                backend: .regression,
                engineFingerprint: "engine-unmeasured",
                state: .bestKnown
            ))
            XCTFail("Una opción óptima sin métricas no debe persistir")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        let storedAssessments = try await repository.optimizationAssessments()
        XCTAssertTrue(storedAssessments.isEmpty)

        do {
            try await repository.recordOptimizationAssessment(OptimizationAssessment(
                appID: context.appID,
                backend: .regression,
                engineFingerprint: "engine-invalid",
                state: .candidateMeasured,
                averageFPS: -.infinity
            ))
            XCTFail("Una métrica no finita no debe persistir")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }

        XCTAssertThrowsError(try mutateSQLite(
            directory.appendingPathComponent("compatibility.sqlite")
        ) { database in
            try executeSQLite(
                database,
                """
                INSERT INTO optimization_assessments(
                    id, app_id, backend, engine_fingerprint, state,
                    average_fps, notes, measured_at
                ) VALUES(
                    '\(UUID().uuidString)', '94', 'regression', 'engine-direct',
                    'bestKnown', 60, '', '2026-07-28T00:00:00.000Z'
                );
                """
            )
        })
        try await repository.close()
    }

    func testPerfectEvidenceRequiresEveryDimension() async throws {
        let directory = temporaryDirectory("perfect-evidence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "88", name: "Incomplete Game")
        try await repository.beginRun(context)

        do {
            try await repository.verifyRun(RunVerification(
                runID: context.id,
                verdict: .perfect,
                rendering: .passed,
                inputPrecision: .passed,
                graphicsSettings: .passed,
                source: .visualInspection
            ))
            XCTFail("Una certificación perfecta incompleta no debe guardarse")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        let recentRuns = try await repository.recentRuns()
        XCTAssertNil(recentRuns.first?.verification)
        try await repository.close()
    }

    func testPerfectEvidenceCannotAttachToAPreparingRun() async throws {
        let directory = temporaryDirectory("perfect-requires-launch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "91", name: "Never Launched")
        try await repository.beginRun(context)

        do {
            try await repository.verifyRun(RunVerification(
                runID: context.id,
                verdict: .perfect,
                rendering: .passed,
                inputPrecision: .passed,
                graphicsSettings: .passed,
                gameplay: .passed,
                source: .visualInspection
            ))
            XCTFail("Una ejecución no iniciada no puede crear un blindado")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        let certifications = try await repository.certifications()
        XCTAssertNil(certifications.first { $0.appID == context.appID })
        try await repository.close()
    }

    func testInterruptedRunsBecomeUnverifiedInsteadOfRemainingActive() async throws {
        let directory = temporaryDirectory("interrupted-run")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "89", name: "Interrupted Game")
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 123,
            executable: "C:\\Games\\interrupted.exe",
            launchMilliseconds: 250
        )

        let reconciled = try await repository.reconcileInterruptedRuns(
            at: Date(timeIntervalSince1970: 2_000),
            reason: "Cierre controlado de la prueba"
        )
        XCTAssertEqual(reconciled, 1)
        let recentRuns = try await repository.recentRuns()
        let run = try XCTUnwrap(recentRuns.first)
        XCTAssertEqual(run.result, .unknown)
        XCTAssertEqual(run.endedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertNil(run.verification)
        let secondReconciliation = try await repository.reconcileInterruptedRuns()
        XCTAssertEqual(secondReconciliation, 0)
        try await repository.close()
    }

    func testPerfectVerificationRejectsReconciledRunWithOpenPrimaryProcess() async throws {
        let directory = temporaryDirectory("perfect-reconciled-open-primary")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "8901", name: "Interrupted Open Process")
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 8_901,
            executable: "C:\\Games\\interrupted-open.exe",
            launchMilliseconds: 250
        )
        let reconciledAt = Date().addingTimeInterval(1)
        let reconciled = try await repository.reconcileInterruptedRuns(at: reconciledAt)
        XCTAssertEqual(reconciled, 1)
        let processes = try await repository.runProcesses(runID: context.id)
        let process = try XCTUnwrap(processes.first)
        XCTAssertNil(process.endedAt)

        do {
            try await repository.verifyRun(perfectVerification(
                runID: context.id,
                verifiedAt: reconciledAt.addingTimeInterval(1)
            ))
            XCTFail("Una ejecución reconciliada con su proceso abierto no puede blindarse")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        let certifications = try await repository.certifications()
        XCTAssertNil(certifications.first { $0.appID == context.appID })
        try await repository.close()
    }

    func testPerfectVerificationRejectsRunWithAdditionalProcessOpen() async throws {
        let directory = temporaryDirectory("perfect-additional-process-open")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "8902", name: "Additional Process Open")
        try await repository.beginRun(context)
        let primaryStartedAt = Date()
        try await repository.markLaunched(
            id: context.id,
            processID: 8_902,
            executable: "C:\\Games\\launcher.exe",
            startedAt: primaryStartedAt,
            launchMilliseconds: 100
        )
        try await repository.markAdditionalProcessStarted(
            id: context.id,
            processID: 8_903,
            executable: "C:\\Games\\game.exe",
            startedAt: primaryStartedAt.addingTimeInterval(1)
        )
        try await repository.markProcessEnded(
            id: context.id,
            processID: 8_902,
            endedAt: primaryStartedAt.addingTimeInterval(2),
            exitCode: 0
        )
        let runEndedAt = primaryStartedAt.addingTimeInterval(3)
        try await repository.finishRun(
            id: context.id,
            endedAt: runEndedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: context.configuration,
            delta: ConfigurationDiffer.difference(
                before: context.configuration,
                after: context.configuration
            )
        )

        do {
            try await repository.verifyRun(perfectVerification(
                runID: context.id,
                verifiedAt: runEndedAt.addingTimeInterval(1)
            ))
            XCTFail("Un proceso adicional abierto impide certificar la sesión completa")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        try await repository.close()
    }

    func testPerfectVerificationRequiresTheTrackedRepresentativeProcess() async throws {
        let directory = temporaryDirectory("perfect-non-representative-process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8907", name: "Non Representative Process")
        let startedAt = Date()
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 8_907,
            executable: "C:\\Games\\representative.exe",
            startedAt: startedAt,
            launchMilliseconds: 100
        )
        let endedAt = startedAt.addingTimeInterval(1)
        try await repository.markProcessEnded(
            id: context.id,
            processID: 8_907,
            endedAt: endedAt,
            exitCode: 0
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: endedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: context.configuration,
            delta: ConfigurationDiffer.difference(
                before: context.configuration,
                after: context.configuration
            )
        )
        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                UPDATE run_processes SET is_representative=0
                WHERE run_id='\(context.id.uuidString)' AND process_id=8907;
                """)
        }

        do {
            try await repository.verifyRun(perfectVerification(
                runID: context.id,
                verifiedAt: endedAt.addingTimeInterval(1)
            ))
            XCTFail("Una fila sin autoridad representativa no puede certificar un run perfecto")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        try mutateSQLite(databaseURL) { database in
            XCTAssertThrowsError(try executeSQLite(database, """
                INSERT INTO run_verifications(
                    run_id, verdict, rendering, input_precision, graphics_settings,
                    gameplay, source, notes, verified_at
                ) VALUES(
                    '\(context.id.uuidString)', 'perfect', 'passed', 'passed', 'passed',
                    'passed', 'visualInspection', '', '2099-01-01T00:00:00.000Z'
                );
                """))
        }
        try await repository.close()
    }

    func testLegacyPerfectWithoutRepresentativeIsExcludedFromEveryPublicConsumer() async throws {
        let directory = temporaryDirectory("legacy-perfect-without-representative")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(
            appID: "8908",
            name: "Legacy Representative Consumer",
            configuration: ["backend": "regression", "provider.version": "test"]
        )
        try await recordClosedPerfectRun(
            context,
            processID: 619_821,
            repository: repository
        )
        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                DROP TRIGGER run_processes_mutation_invalidates_perfect_update;
                UPDATE run_processes SET is_representative=0
                WHERE run_id='\(context.id.uuidString)' AND process_id=619821;
                """)
        }

        let health = try await repository.databaseHealth()
        XCTAssertEqual(health.perfectEvidenceViolationCount, 1)
        XCTAssertEqual(health.activeCertificationViolationCount, 1)
        XCTAssertFalse(health.isHealthy)

        let profiles = try await repository.compatibilityProfiles()
        XCTAssertEqual(
            profiles.first { $0.appID == context.appID }?.perfectRuns,
            0
        )
        let engines = try await repository.engineProfiles()
        XCTAssertFalse(engines.contains { $0.perfectRuns > 0 })
        let certifications = try await repository.certifications()
        XCTAssertNil(certifications.first { $0.appID == context.appID })
        let recent = try await repository.recentRuns()
        XCTAssertEqual(
            recent.first { $0.id == context.id }?.verification?.verdict,
            .invalidated
        )
        let details = try await repository.runDetails()
        XCTAssertEqual(
            details.first { $0.id == context.id }?.verification?.verdict,
            .invalidated
        )
        let sealedRun = try await repository.sealedPerfectRun(
            appID: context.appID,
            runID: context.id
        )
        XCTAssertNil(sealedRun)
        let exportURL = directory.appendingPathComponent("legacy-invalid-export.json")
        try await repository.exportJSON(to: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(
            CompatibilityExport.self,
            from: Data(contentsOf: exportURL)
        )
        XCTAssertEqual(
            payload.runs.first { $0.id == context.id }?.verification?.verdict,
            .invalidated
        )
        try await repository.close()

        let reopened = CompatibilityRepository(databaseURL: databaseURL)
        do {
            try await reopened.prepare()
            XCTFail("La reapertura no debe inventar autoridad representativa")
        } catch {}
        try mutateSQLite(databaseURL) { database in
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT verdict FROM run_verifications
                    WHERE run_id='\(context.id.uuidString)';
                    """),
                VerificationVerdict.invalidated.rawValue
            )
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT CAST(is_active AS TEXT) FROM verified_game_certifications
                    WHERE app_id='\(context.appID)' AND backend='regression';
                    """),
                "0"
            )
        }
    }

    func testPerfectVerificationAcceptsRunWhenEveryTrackedProcessIsClosed() async throws {
        let directory = temporaryDirectory("perfect-all-processes-closed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "8903", name: "All Processes Closed")
        try await repository.beginRun(context)
        let primaryStartedAt = Date()
        try await repository.markLaunched(
            id: context.id,
            processID: 8_904,
            executable: "C:\\Games\\launcher.exe",
            startedAt: primaryStartedAt,
            launchMilliseconds: 100
        )
        try await repository.markAdditionalProcessStarted(
            id: context.id,
            processID: 8_905,
            executable: "C:\\Games\\game.exe",
            startedAt: primaryStartedAt.addingTimeInterval(1)
        )
        try await repository.markProcessEnded(
            id: context.id,
            processID: 8_904,
            endedAt: primaryStartedAt.addingTimeInterval(2),
            exitCode: 0
        )
        try await repository.markProcessEnded(
            id: context.id,
            processID: 8_905,
            endedAt: primaryStartedAt.addingTimeInterval(3),
            exitCode: 0
        )
        let runEndedAt = primaryStartedAt.addingTimeInterval(4)
        try await repository.finishRun(
            id: context.id,
            endedAt: runEndedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: context.configuration,
            delta: ConfigurationDiffer.difference(
                before: context.configuration,
                after: context.configuration
            )
        )

        try await repository.verifyRun(perfectVerification(
            runID: context.id,
            verifiedAt: runEndedAt.addingTimeInterval(1)
        ))

        let certifications = try await repository.certifications()
        let certification = try XCTUnwrap(
            certifications.first { $0.appID == context.appID }
        )
        XCTAssertEqual(certification.sourceRunID, context.id)
        try await repository.close()
    }

    func testDirectProcessInsertAfterPerfectInvalidatesRunCertification() async throws {
        let directory = temporaryDirectory("perfect-late-process-insert")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8904", name: "Late Process Insert")
        try await recordClosedPerfectRun(
            context,
            processID: 8_906,
            repository: repository
        )
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                INSERT INTO run_processes(
                    run_id, process_id, executable, started_at, ended_at, exit_code,
                    is_representative
                ) VALUES(
                    '\(context.id.uuidString)', 8907, 'C:\\Games\\late.exe',
                    '2026-08-13T22:00:00.000Z', '2026-08-13T22:00:01.000Z', 0, 0
                );
                """)
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT verdict FROM run_verifications
                    WHERE run_id='\(context.id.uuidString)';
                    """),
                VerificationVerdict.invalidated.rawValue
            )
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT CAST(is_active AS TEXT) FROM verified_game_certifications
                    WHERE app_id='\(context.appID)' AND backend='regression';
                    """),
                "0"
            )
        }
    }

    func testDirectProcessReopenAfterPerfectInvalidatesRunCertification() async throws {
        let directory = temporaryDirectory("perfect-process-reopen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8905", name: "Reopened Process")
        try await recordClosedPerfectRun(
            context,
            processID: 8_908,
            repository: repository
        )
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                UPDATE run_processes
                SET ended_at='2026-08-13T22:00:02.000Z', exit_code=0
                WHERE run_id='\(context.id.uuidString)' AND process_id=8908;
                """)
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT verdict FROM run_verifications
                    WHERE run_id='\(context.id.uuidString)';
                    """),
                VerificationVerdict.invalidated.rawValue
            )
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT CAST(is_active AS TEXT) FROM verified_game_certifications
                    WHERE app_id='\(context.appID)' AND backend='regression';
                    """),
                "0"
            )
        }
    }

    func testDirectProcessDeleteAfterPerfectInvalidatesRunCertification() async throws {
        let directory = temporaryDirectory("perfect-process-delete")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8908", name: "Deleted Process")
        try await recordClosedPerfectRun(
            context,
            processID: 8_913,
            repository: repository
        )
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                DELETE FROM run_processes
                WHERE run_id='\(context.id.uuidString)' AND process_id=8913;
                """)
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT verdict FROM run_verifications
                    WHERE run_id='\(context.id.uuidString)';
                    """),
                VerificationVerdict.invalidated.rawValue
            )
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT CAST(is_active AS TEXT) FROM verified_game_certifications
                    WHERE app_id='\(context.appID)' AND backend='regression';
                    """),
                "0"
            )
        }
    }

    func testFinishRunAfterPerfectInvalidatesExactRunEvidenceThroughPublicAPI() async throws {
        let directory = temporaryDirectory("perfect-run-refinished")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "8917", name: "Refinished Perfect Run")
        try await recordClosedPerfectRun(context, processID: 8_917, repository: repository)

        try await repository.finishRun(
            id: context.id,
            endedAt: Date().addingTimeInterval(10),
            exitCode: 1,
            result: .crashed,
            afterConfiguration: context.configuration,
            delta: ConfigurationDiffer.difference(
                before: context.configuration,
                after: context.configuration
            )
        )

        let storedDetails = try await repository.runDetails()
        let detail = try XCTUnwrap(storedDetails.first { $0.id == context.id })
        XCTAssertEqual(detail.verification?.verdict, .invalidated)
        let certifications = try await repository.certifications(activeOnly: false)
        let certification = try XCTUnwrap(
            certifications.first { $0.appID == context.appID && $0.backend == .regression }
        )
        XCTAssertFalse(certification.isActive)
        XCTAssertNil(certification.sourceRunID)
        let profiles = try await repository.compatibilityProfiles()
        XCTAssertEqual(profiles.first { $0.appID == context.appID }?.perfectRuns, 0)
        try await repository.close()
        try mutateSQLite(directory.appendingPathComponent("compatibility.sqlite")) { database in
            XCTAssertThrowsError(try executeSQLite(database, """
                DELETE FROM runs WHERE id='\(context.id.uuidString)';
                """))
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT CAST(COUNT(*) AS TEXT) FROM runs
                    WHERE id='\(context.id.uuidString)';
                    """),
                "1"
            )
        }
    }

    func testPerfectRunDeleteIsBlockedToPreserveEvidenceHistory() async throws {
        let directory = temporaryDirectory("perfect-run-delete-history")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8918", name: "Preserved Perfect Run")
        try await recordClosedPerfectRun(context, processID: 8_918, repository: repository)
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            XCTAssertThrowsError(try executeSQLite(database, """
                DELETE FROM runs WHERE id='\(context.id.uuidString)';
                """))
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT verdict FROM run_verifications
                    WHERE run_id='\(context.id.uuidString)';
                    """),
                VerificationVerdict.perfect.rawValue
            )
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT CAST(is_active AS TEXT) FROM verified_game_certifications
                    WHERE app_id='\(context.appID)' AND backend='regression';
                    """),
                "1"
            )
        }
    }

    func testDirectRunConfigurationMutationInvalidatesPerfectEvidence() async throws {
        let directory = temporaryDirectory("perfect-run-configuration-mutation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8920", name: "Mutated Perfect Configuration")
        try await recordClosedPerfectRun(context, processID: 8_920, repository: repository)
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                UPDATE runs SET after_configuration_fingerprint=NULL
                WHERE id='\(context.id.uuidString)';
                """)
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT verdict FROM run_verifications
                    WHERE run_id='\(context.id.uuidString)';
                    """),
                VerificationVerdict.invalidated.rawValue
            )
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT CAST(is_active AS TEXT) FROM verified_game_certifications
                    WHERE app_id='\(context.appID)' AND backend='regression';
                    """),
                "0"
            )
        }
    }

    func testTrackedProcessJoiningAfterPerfectInvalidatesEveryRunConsumer() async throws {
        let directory = temporaryDirectory("perfect-late-tracked-process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "8907", name: "Late Tracked Process")
        try await recordClosedPerfectRun(
            context,
            processID: 8_911,
            repository: repository
        )
        let initialEngines = try await repository.engineProfiles()
        let engineFingerprint = try XCTUnwrap(
            initialEngines.first { $0.perfectRuns == 1 }?.fingerprint
        )
        let initialHealth = try await repository.databaseHealth()

        try await repository.markAdditionalProcessStarted(
            id: context.id,
            processID: 8_912,
            executable: "C:\\Games\\late-child.exe",
            startedAt: Date().addingTimeInterval(1)
        )

        let details = try await repository.runDetails()
        let detail = try XCTUnwrap(details.first { $0.id == context.id })
        XCTAssertEqual(detail.verification?.verdict, .invalidated)
        let certifications = try await repository.certifications()
        XCTAssertNil(certifications.first { $0.appID == context.appID })
        let profiles = try await repository.compatibilityProfiles()
        XCTAssertEqual(
            profiles.first { $0.appID == context.appID }?.perfectRuns,
            0
        )
        let engines = try await repository.engineProfiles()
        XCTAssertEqual(
            engines.first { $0.fingerprint == engineFingerprint }?.perfectRuns,
            0
        )
        let health = try await repository.databaseHealth()
        XCTAssertEqual(health.certificationCount, initialHealth.certificationCount - 1)
        XCTAssertTrue(health.isHealthy)
        try await repository.close()
    }

    func testLateRunProcessDoesNotInvalidateNewerHistoricalObservationCertification() async throws {
        let directory = temporaryDirectory("perfect-observation-survives-late-process")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8906", name: "Historical Observation")
        try await recordClosedPerfectRun(
            context,
            processID: 8_909,
            repository: repository
        )
        let observation = CompatibilityObservation(
            appID: context.appID,
            gameName: context.gameName,
            backend: .regression,
            providerVersion: "historical",
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            configurationFingerprint: context.configurationFingerprint,
            configuration: context.configuration,
            source: .imported,
            notes: "Evidencia histórica independiente",
            observedAt: Date().addingTimeInterval(60)
        )
        try await repository.recordObservation(observation)
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                INSERT INTO run_processes(
                    run_id, process_id, executable, started_at, is_representative
                ) VALUES(
                    '\(context.id.uuidString)', 8910, 'C:\\Games\\late.exe',
                    '2026-08-13T22:00:00.000Z', 0
                );
                """)
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT source_observation_id FROM verified_game_certifications
                    WHERE app_id='\(context.appID)' AND backend='regression' AND is_active=1;
                    """),
                observation.id.uuidString
            )
        }
    }

    func testClosedProcessCertificationTriggersRemainIdempotentOnCurrentSchema() async throws {
        let directory = temporaryDirectory("perfect-trigger-idempotence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        for _ in 0..<2 {
            let repository = CompatibilityRepository(databaseURL: databaseURL)
            try await repository.prepare()
            try await repository.close()
        }
        try mutateSQLite(databaseURL) { database in
            for trigger in [
                "run_verifications_perfect_requires_launch_insert",
                "run_verifications_perfect_requires_launch_update",
                "run_processes_mutation_invalidates_perfect_insert",
                "run_processes_mutation_invalidates_perfect_update",
                "run_processes_mutation_invalidates_perfect_delete",
                "runs_semantic_mutation_invalidates_perfect",
                "runs_verified_history_prevents_delete",
                "repair_attempt_evidence_guard_insert",
                "repair_attempt_evidence_guard_update",
            ] {
                XCTAssertEqual(
                    try scalarSQLiteText(database, """
                        SELECT CAST(COUNT(*) AS TEXT) FROM sqlite_master
                        WHERE type='trigger' AND name='\(trigger)';
                        """),
                    "1"
                )
            }
            XCTAssertEqual(
                try scalarSQLiteText(database, "PRAGMA user_version;"),
                String(CompatibilityRepository.currentSchemaVersion)
            )
        }
    }

    func testPerfectVerificationMustFollowLatestTrackedProcessEnd() async throws {
        let directory = temporaryDirectory("perfect-after-latest-process-end")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(appID: "8909", name: "Late Process End")
        let startedAt = Date()
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 8_914,
            executable: "C:\\Games\\late-end.exe",
            startedAt: startedAt,
            launchMilliseconds: 100
        )
        let runEndedAt = startedAt.addingTimeInterval(2)
        let processEndedAt = startedAt.addingTimeInterval(4)
        try await repository.markProcessEnded(
            id: context.id,
            processID: 8_914,
            endedAt: processEndedAt,
            exitCode: 0
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: runEndedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: context.configuration,
            delta: ConfigurationDiffer.difference(
                before: context.configuration,
                after: context.configuration
            )
        )

        do {
            try await repository.verifyRun(perfectVerification(
                runID: context.id,
                verifiedAt: startedAt.addingTimeInterval(3)
            ))
            XCTFail("Perfecto no puede preceder al cierre del último proceso rastreado")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        try await repository.verifyRun(perfectVerification(
            runID: context.id,
            verifiedAt: processEndedAt.addingTimeInterval(1)
        ))
        try await repository.close()
    }

    func testDatabaseHealthCountsSemanticPerfectAndCertificationViolations() async throws {
        let directory = temporaryDirectory("perfect-semantic-health")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8910", name: "Semantic Health")
        try await recordClosedPerfectRun(
            context,
            processID: 8_915,
            repository: repository
        )

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                DROP TRIGGER run_processes_mutation_invalidates_perfect_insert;
                INSERT INTO run_processes(
                    run_id, process_id, executable, started_at, ended_at, exit_code,
                    is_representative
                ) VALUES(
                    '\(context.id.uuidString)', 8916, 'C:\\Games\\future.exe',
                    '2099-01-01T00:00:00.000Z', '2099-01-01T00:00:01.000Z', 0, 0
                );
                """)
        }
        let health = try await repository.databaseHealth()
        XCTAssertEqual(health.perfectEvidenceViolationCount, 1)
        XCTAssertEqual(health.activeCertificationViolationCount, 1)
        XCTAssertFalse(health.isHealthy)
        try await repository.close()
    }

    func testDatabaseHealthCertificationPredicateRequiresCanonicalLaunchedRun() async throws {
        let directory = temporaryDirectory("perfect-canonical-certification-health")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        let context = makeContext(appID: "8919", name: "Canonical Certification Health")
        try await recordClosedPerfectRun(context, processID: 8_919, repository: repository)

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                DROP TRIGGER runs_semantic_mutation_invalidates_perfect;
                UPDATE runs SET process_id=NULL WHERE id='\(context.id.uuidString)';
                """)
        }
        let health = try await repository.databaseHealth()
        XCTAssertEqual(health.perfectEvidenceViolationCount, 1)
        XCTAssertEqual(health.activeCertificationViolationCount, 1)
        XCTAssertFalse(health.isHealthy)
        try await repository.close()
    }

    func testClosedProcessTriggerInstallationRollsBackOnIntermediateFailure() async throws {
        let directory = temporaryDirectory("perfect-trigger-install-rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()

        var originalInsertGuard: String?
        try mutateSQLite(databaseURL) { database in
            originalInsertGuard = try scalarSQLiteText(database, """
                SELECT sql FROM sqlite_master
                WHERE type='trigger'
                  AND name='run_verifications_perfect_requires_launch_insert';
                """)
        }

        do {
            try await repository.installClosedProcessCertificationGuardsForTesting("""
                DROP TRIGGER run_verifications_perfect_requires_launch_insert;
                CREATE TRIGGER run_verifications_perfect_requires_launch_insert
                BEFORE INSERT ON run_verifications
                BEGIN
                    SELECT 1;
                END;
                INVALID SQL AFTER A SUCCESSFUL DROP AND CREATE;
                """)
            XCTFail("El error SQL intermedio debía abortar la instalación de triggers")
        } catch {}
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT sql FROM sqlite_master
                    WHERE type='trigger'
                      AND name='run_verifications_perfect_requires_launch_insert';
                    """),
                originalInsertGuard
            )
            XCTAssertEqual(
                try scalarSQLiteText(database, """
                    SELECT CAST(COUNT(*) AS TEXT) FROM sqlite_master
                    WHERE type='trigger'
                      AND name='run_processes_mutation_invalidates_perfect_insert';
                    """),
                "1"
            )
        }
    }

    func testPerfectRunCanBeReconciledWithItsCompiledRuntimeProfile() async throws {
        let directory = temporaryDirectory("compiled-profile-reconciliation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let context = makeContext(
            appID: "619820",
            name: "Heroes of Hammerwatch II",
            configuration: ["backend": "regression", "provider.version": "1.7.3"],
            providerVersion: "1.7.3"
        )
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 619_820,
            executable: "C:\\Games\\HWR2.exe",
            launchMilliseconds: 100
        )
        let endedAt = Date(timeIntervalSince1970: 2_000.0006)
        try await repository.markProcessEnded(
            id: context.id,
            processID: 619_820,
            endedAt: endedAt,
            exitCode: 0
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: endedAt,
            exitCode: 0,
            result: .succeeded,
            afterConfiguration: context.configuration,
            delta: ConfigurationDiffer.difference(
                before: context.configuration,
                after: context.configuration
            )
        )
        do {
            try await repository.verifyRun(RunVerification(
                runID: context.id,
                verdict: .perfect,
                rendering: .passed,
                inputPrecision: .passed,
                graphicsSettings: .passed,
                gameplay: .passed,
                source: .visualInspection,
                verifiedAt: endedAt.addingTimeInterval(-1)
            ))
            XCTFail("Una verificación realmente anterior al cierre debe rechazarse")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }

        try await repository.verifyRun(RunVerification(
            runID: context.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "Confirmación visual completa",
            verifiedAt: endedAt.addingTimeInterval(0.0001)
        ))

        let first = try await repository.reconcileCompiledRuntimeProfile(runID: context.id)
        let second = try await repository.reconcileCompiledRuntimeProfile(runID: context.id)
        XCTAssertEqual(first.configurationFingerprint, second.configurationFingerprint)
        XCTAssertEqual(first.engineFingerprint, second.engineFingerprint)
        XCTAssertNotEqual(first.engineFingerprint, context.configurationFingerprint)

        let details = try await repository.runDetails()
        let detail = try XCTUnwrap(details.first { $0.id == context.id })
        XCTAssertEqual(
            detail.configuration["profile.id"],
            "heroes-hammerwatch-2.opengl-forward-compatible"
        )
        let certifications = try await repository.certifications()
        let certification = try XCTUnwrap(
            certifications.first { $0.appID == context.appID }
        )
        XCTAssertEqual(certification.sourceRunID, context.id)
        XCTAssertEqual(certification.configurationFingerprint, first.configurationFingerprint)
        XCTAssertEqual(certification.engineFingerprint, first.engineFingerprint)
        try mutateSQLite(directory.appendingPathComponent("compatibility.sqlite")) { database in
            try executeSQLite(database, """
                DROP TRIGGER run_processes_mutation_invalidates_perfect_update;
                UPDATE run_processes SET is_representative=0
                WHERE run_id='\(context.id.uuidString)' AND process_id=619820;
                """)
        }
        do {
            _ = try await repository.reconcileCompiledRuntimeProfile(runID: context.id)
            XCTFail("La reconciliación no puede reutilizar un perfecto sin representante")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        try await repository.close()
    }

    func testExternalRatingDoesNotTurnInvalidDataIntoPerfectCompatibility() {
        let rating = ExternalCompatibilityRating(
            platform: .macOS,
            value: 99,
            testedCrossOverVersion: "desconocida",
            testedAt: nil
        )
        XCTAssertNil(rating.value)
    }

    func testHistoricalExternalSourceIdentityHasNoNetworkLocation() {
        let source = CodeWeaversCompatibilityProvider.codeWeaversSource

        XCTAssertEqual(source.id, "codeweavers")
        XCTAssertTrue(source.baseURL.isFileURL)
        XCTAssertTrue(source.informationURL.isFileURL)
        XCTAssertEqual(source.cacheLifetime, 0)
    }

    func testLegacyCrossOverTechnologyRowRemainsStoredButIsNotPubliclyListed() async throws {
        let directory = temporaryDirectory("retired-runtime-technology")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()
        try mutateSQLite(databaseURL) { database in
            try executeSQLite(
                database,
                """
                INSERT OR REPLACE INTO runtime_technologies(
                    id, display_name, category, official_url, release_url,
                    distribution_policy, update_policy, stable_version,
                    latest_known_version, checked_at, catalog_revision, notes, synced_at
                ) VALUES(
                    'crossover', 'Legacy External Runtime', 'referenceRuntime',
                    'https://legacy.invalid/runtime', NULL, 'licensedReference', 'referenceOnly',
                    'legacy', NULL, '2026-01-01T00:00:00.000Z', 'legacy', 'historical',
                    '2026-01-01T00:00:00.000Z'
                );
                """
            )
        }

        let visible = try await repository.runtimeTechnologies()

        XCTAssertFalse(visible.contains { $0.id == "crossover" })
        try await repository.close()
    }

    func testExternalCatalogSynchronizerIsRetiredAndDoesNotMutateHistory() async throws {
        let directory = temporaryDirectory("external-cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let synchronizer = ExternalCatalogSynchronizer(repository: repository)
        let game = SteamGame(
            appID: "4242",
            name: "Catalog Test",
            installDirectory: "Catalog Test",
            manifestURL: URL(fileURLWithPath: "/tmp/appmanifest_4242.acf"),
            sourceBackend: .regression
        )

        let outcome = await synchronizer.refresh(game: game, force: true)
        let storedEntries = try await repository.externalEntries()
        XCTAssertEqual(outcome, .retired)
        XCTAssertTrue(storedEntries.isEmpty)
        try await repository.close()
    }

    func testLegacyCrossOverRowsRemainStoredButAreAbsentFromPublicComparisonAndExport() async throws {
        let directory = temporaryDirectory("legacy-public-filter")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        let regression = makeContext(appID: "420", name: "Regression Visible")
        try await repository.beginRun(regression)
        try await repository.failRunBeforeLaunch(id: regression.id, reason: "prueba controlada")
        let legacyRun = makeContext(
            appID: "421",
            name: "CrossOver Histórico",
            configuration: ["backend": "crossOver"],
            providerVersion: "legacy",
            backend: .crossOver
        )
        try await repository.beginRun(legacyRun)
        try await repository.markLaunched(
            id: legacyRun.id,
            processID: 421,
            executable: #"C:\Games\legacy.exe"#,
            launchMilliseconds: 100
        )
        try await repository.markProcessEnded(
            id: legacyRun.id,
            processID: 421,
            endedAt: Date(),
            exitCode: 0
        )
        try await repository.finishRun(
            id: legacyRun.id,
            endedAt: Date(),
            exitCode: 0,
            result: .succeeded,
            afterConfiguration: legacyRun.configuration,
            delta: ConfigurationDelta(added: [:], removed: [:], changed: [:])
        )
        try await repository.verifyRun(RunVerification(
            runID: legacyRun.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "evidencia histórica"
        ))
        try await repository.recordObservation(CompatibilityObservation(
            appID: "421",
            gameName: "CrossOver Histórico",
            backend: .crossOver,
            providerVersion: "legacy",
            verdict: .failed,
            configurationFingerprint: "legacy-config",
            configuration: ["backend": "crossOver"],
            source: .imported,
            notes: "fila preservada"
        ))
        let source = CodeWeaversCompatibilityProvider.codeWeaversSource
        let externalGame = SteamGame(
            appID: "421",
            name: "CrossOver Histórico",
            installDirectory: "Legacy",
            manifestURL: directory.appendingPathComponent("appmanifest_421.acf"),
            sourceBackend: .crossOver
        )
        let legacyRecord = ExternalGameRecord(
            sourceID: source.id,
            externalAppID: "legacy-421",
            canonicalURL: URL(fileURLWithPath: "/historical/codeweavers/421"),
            name: externalGame.name,
            company: nil,
            category: nil,
            steamAppID: externalGame.appID,
            macOSRating: .init(
                platform: .macOS,
                value: 5,
                testedCrossOverVersion: "legacy",
                testedAt: nil
            ),
            linuxRating: .init(
                platform: .linux,
                value: nil,
                testedCrossOverVersion: nil,
                testedAt: nil
            ),
            fetchedAt: Date(),
            contentFingerprint: "historical"
        )
        await assertExternalCatalogRejected {
            try await repository.registerExternalSource(source)
        }
        await assertExternalCatalogRejected {
            _ = try await repository.reserveExternalRequest(source: source)
        }
        await assertExternalCatalogRejected {
            _ = try await repository.externalSyncState(sourceID: source.id)
        }
        await assertExternalCatalogRejected {
            try await repository.recordExternalSyncSuccess(sourceID: source.id)
        }
        await assertExternalCatalogRejected {
            try await repository.recordExternalSyncFailure(sourceID: source.id, message: "legacy")
        }
        await assertExternalCatalogRejected {
            try await repository.upsertExternalRecord(
                legacyRecord,
                for: externalGame,
                matchMethod: .steamAppID,
                confidence: 1
            )
        }
        await assertExternalCatalogRejected {
            try await repository.recordExternalLookupStatus(
                sourceID: source.id,
                game: externalGame,
                status: .noMatch
            )
        }
        try await repository.close()
        try mutateSQLite(directory.appendingPathComponent("compatibility.sqlite")) { database in
            try executeSQLite(database, """
                PRAGMA foreign_keys=ON;
                INSERT INTO external_catalog_sources(
                    id, display_name, base_url, information_url,
                    minimum_request_interval_seconds, cache_lifetime_seconds,
                    created_at, updated_at
                ) VALUES(
                    'codeweavers', 'CodeWeavers histórico', 'https://invalid.example',
                    'https://invalid.example', 60, 3600,
                    '2026-08-13T00:00:00.000Z', '2026-08-13T00:00:00.000Z'
                );
                INSERT INTO external_catalog_sync_state(source_id) VALUES('codeweavers');
                INSERT INTO external_game_records(
                    source_id, external_app_id, canonical_url, name, company, category,
                    steam_app_id, mac_rating, mac_tested_version, mac_tested_at,
                    linux_rating, linux_tested_version, linux_tested_at,
                    fetched_at, content_fingerprint, entity_tag, last_modified
                ) VALUES(
                    'codeweavers', 'legacy-421', 'https://invalid.example/421',
                    'CrossOver Histórico', NULL, NULL, '421', 5, 'legacy', NULL,
                    NULL, NULL, NULL, '2026-08-13T00:00:00.000Z', 'historical', NULL, NULL
                );
                INSERT INTO external_game_links(
                    source_id, app_id, external_app_id, status, match_method,
                    confidence, query_name, last_attempt_at, error_message, linked_at
                ) VALUES(
                    'codeweavers', '421', 'legacy-421', 'linked', 'steamAppID',
                    1, 'CrossOver Histórico', '2026-08-13T00:00:00.000Z', NULL,
                    '2026-08-13T00:00:00.000Z'
                );
                """)
        }
        try await repository.prepare()

        let publicObservations = try await repository.observations()
        let publicRunDetails = try await repository.runDetails()
        let publicRuns = try await repository.recentRuns()
        let publicProcesses = try await repository.runProcesses(runID: legacyRun.id)
        let publicProfiles = try await repository.compatibilityProfiles()
        let publicEngines = try await repository.engineProfiles()
        let publicCertifications = try await repository.certifications(activeOnly: false)
        let publicExternalEntries = try await repository.externalEntries(sourceID: source.id)
        XCTAssertFalse(publicObservations.contains { $0.backend == .crossOver })
        XCTAssertFalse(publicRunDetails.contains { $0.backend == .crossOver })
        XCTAssertFalse(publicRuns.contains { $0.backend == .crossOver })
        XCTAssertTrue(publicProcesses.isEmpty)
        XCTAssertFalse(publicProfiles.contains { $0.backend == .crossOver })
        XCTAssertFalse(publicEngines.contains { $0.backend == .crossOver })
        XCTAssertFalse(publicCertifications.contains { $0.backend == .crossOver })
        XCTAssertTrue(publicExternalEntries.isEmpty)
        let health = try await repository.databaseHealth()
        XCTAssertEqual(health.runCount, 2)
        XCTAssertEqual(health.processCount, 1)
        XCTAssertEqual(health.externalRecordCount, 1)
        let comparisons = try await repository.compatibilityComparisons()
        XCTAssertFalse(comparisons.contains { $0.appID == "421" })
        XCTAssertTrue(comparisons.allSatisfy {
            $0.localBackend != .crossOver
                && $0.publicMacRating == nil
                && $0.publicTestedVersion == nil
                && $0.alignment == .insufficientEvidence
        })

        let exportURL = directory.appendingPathComponent("public.json")
        try await repository.exportJSON(to: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(
            CompatibilityExport.self,
            from: Data(contentsOf: exportURL)
        )
        XCTAssertTrue(export.externalCatalog.isEmpty)
        XCTAssertFalse(export.runs.contains { $0.backend == .crossOver })
        XCTAssertFalse(export.processes.contains { $0.runID == legacyRun.id })
        XCTAssertFalse(export.observations.contains { $0.backend == .crossOver })
        XCTAssertFalse(export.profiles.contains { $0.backend == .crossOver })
        XCTAssertFalse(export.engines.contains { $0.backend == .crossOver })
        XCTAssertFalse(export.certifications.contains { $0.backend == .crossOver })
        try await repository.close()
    }

    func testVersionThirteenResearchMigrationPreservesLegacyAndAcceptsAutonomousEvidence() async throws {
        let directory = temporaryDirectory("research-v14")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        var repository: CompatibilityRepository? = CompatibilityRepository(databaseURL: databaseURL)
        try await repository?.prepare()
        try await repository?.close()
        repository = nil

        let legacyCaseID = UUID()
        let legacyHypothesisID = UUID()
        let legacyExperimentID = UUID()
        let legacyArtifactID = UUID()
        try mutateSQLite(databaseURL) { database in
            try executeSQLite(
                database,
                """
                DROP TRIGGER IF EXISTS research_hypothesis_matches_case_insert;
                DROP TRIGGER IF EXISTS research_hypothesis_matches_case_update;
                DROP TRIGGER IF EXISTS research_experiment_pass_guard_insert;
                DROP TRIGGER IF EXISTS research_experiment_pass_guard_update;
                DROP TRIGGER IF EXISTS research_experiment_lock_passed;
                DROP TRIGGER IF EXISTS research_case_verify_guard_insert;
                DROP TRIGGER IF EXISTS research_case_verify_guard_update;
                DROP TRIGGER IF EXISTS research_hypothesis_lock_verified;
                DROP TRIGGER IF EXISTS research_hypothesis_insert_lock_verified;
                DROP TRIGGER IF EXISTS research_hypothesis_delete_lock_verified;
                DROP TRIGGER IF EXISTS research_gate_lock_update;
                DROP TRIGGER IF EXISTS research_gate_lock_delete;
                DROP TRIGGER IF EXISTS research_gate_lock_insert;
                DROP TRIGGER IF EXISTS research_artifact_lock_update;
                DROP TRIGGER IF EXISTS research_artifact_lock_delete;
                DROP TRIGGER IF EXISTS research_artifact_lock_insert;
                DROP TRIGGER IF EXISTS research_case_reopens_after_verdict_correction;
                DROP TABLE research_gate_results;
                DROP TABLE research_artifacts;
                DROP TABLE research_experiments;
                DROP TABLE research_hypotheses;
                DROP TABLE compatibility_research_cases;
                CREATE TABLE compatibility_research_cases(
                    id TEXT PRIMARY KEY,
                    app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE CASCADE,
                    symptom TEXT NOT NULL CHECK(trim(symptom)!=''),
                    expected_behavior TEXT NOT NULL CHECK(trim(expected_behavior)!=''),
                    reference_backend TEXT NOT NULL CHECK(reference_backend='crossOver'),
                    state TEXT NOT NULL CHECK(state IN (
                        'open','investigating','validationPending','verified','pausedExternalDependency'
                    )),
                    blocker TEXT,
                    winning_experiment_id TEXT REFERENCES research_experiments(id),
                    resolution_summary TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    CHECK(state!='pausedExternalDependency' OR (
                        blocker IS NOT NULL AND trim(blocker)!=''
                    )),
                    CHECK(state!='verified' OR (
                        winning_experiment_id IS NOT NULL
                        AND resolution_summary IS NOT NULL AND trim(resolution_summary)!=''
                    ))
                );
                CREATE TABLE research_hypotheses(
                    id TEXT PRIMARY KEY,
                    case_id TEXT NOT NULL
                        REFERENCES compatibility_research_cases(id) ON DELETE CASCADE,
                    rank INTEGER NOT NULL CHECK(rank > 0),
                    statement TEXT NOT NULL CHECK(trim(statement)!=''),
                    prediction TEXT NOT NULL CHECK(trim(prediction)!=''),
                    status TEXT NOT NULL CHECK(status IN ('proposed','testing','supported','falsified')),
                    evidence TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE(case_id, rank)
                );
                CREATE TABLE research_experiments(
                    id TEXT PRIMARY KEY,
                    case_id TEXT NOT NULL
                        REFERENCES compatibility_research_cases(id) ON DELETE CASCADE,
                    hypothesis_id TEXT REFERENCES research_hypotheses(id) ON DELETE SET NULL,
                    dimension TEXT NOT NULL CHECK(dimension IN (
                        'environment','windowsRuntime','graphicsBackend','dynamicLibraries',
                        'dllOverride','registry','display','launcher','dependency','permission','sourcePatch'
                    )),
                    change_summary TEXT NOT NULL CHECK(trim(change_summary)!=''),
                    state TEXT NOT NULL CHECK(state IN (
                        'planned','ready','running','validation','passed','failed','rolledBack'
                    )),
                    is_isolated INTEGER NOT NULL CHECK(is_isolated IN (0,1)),
                    rollback_reference TEXT,
                    baseline_engine_fingerprint TEXT,
                    candidate_engine_fingerprint TEXT,
                    run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
                    runtime_candidate_id TEXT REFERENCES runtime_candidates(id) ON DELETE SET NULL,
                    notes TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    CHECK(state='planned' OR (
                        is_isolated=1 AND rollback_reference IS NOT NULL
                        AND trim(rollback_reference)!=''
                        AND baseline_engine_fingerprint IS NOT NULL
                        AND trim(baseline_engine_fingerprint)!=''
                    )),
                    CHECK(state!='passed' OR (
                        candidate_engine_fingerprint IS NOT NULL
                        AND trim(candidate_engine_fingerprint)!=''
                        AND candidate_engine_fingerprint!=baseline_engine_fingerprint
                        AND run_id IS NOT NULL
                    ))
                );
                CREATE TABLE research_gate_results(
                    experiment_id TEXT NOT NULL
                        REFERENCES research_experiments(id) ON DELETE CASCADE,
                    gate TEXT NOT NULL CHECK(gate IN (
                        'crossOverReference','rendering','inputPrecision','graphicsSettings',
                        'gameplay','ownResources','regressionMatrix','rollbackVerified'
                    )),
                    status TEXT NOT NULL CHECK(status IN ('pending','passed','failed')),
                    evidence_reference TEXT NOT NULL,
                    checked_at TEXT NOT NULL,
                    PRIMARY KEY(experiment_id, gate),
                    CHECK(status='pending' OR trim(evidence_reference)!='')
                );
                CREATE TABLE research_artifacts(
                    id TEXT PRIMARY KEY,
                    experiment_id TEXT NOT NULL
                        REFERENCES research_experiments(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK(kind IN (
                        'crossOverCapture','regressionCapture','moduleInventory',
                        'configurationSnapshot','buildReport','testReport','signatureReport',
                        'rollbackManifest','logExcerpt','performanceCapture'
                    )),
                    reference TEXT NOT NULL CHECK(trim(reference)!=''),
                    fingerprint TEXT,
                    captured_at TEXT NOT NULL,
                    UNIQUE(experiment_id, kind, reference)
                );
                INSERT INTO games(app_id, name, updated_at)
                VALUES('951', 'Legacy Research', '2026-08-13T00:00:00.000Z');
                INSERT INTO compatibility_research_cases(
                    id, app_id, symptom, expected_behavior, reference_backend, state,
                    blocker, winning_experiment_id, resolution_summary, created_at, updated_at
                ) VALUES(
                    '\(legacyCaseID.uuidString)', '951', 'Histórico', 'Funcionamiento',
                    'crossOver', 'open', NULL, NULL, NULL,
                    '2026-08-13T00:00:00.000Z', '2026-08-13T00:00:00.000Z'
                );
                INSERT INTO research_hypotheses(
                    id, case_id, rank, statement, prediction, status, evidence,
                    created_at, updated_at
                ) VALUES(
                    '\(legacyHypothesisID.uuidString)', '\(legacyCaseID.uuidString)', 1,
                    'Hipótesis', 'Predicción', 'proposed', '',
                    '2026-08-13T00:00:00.000Z', '2026-08-13T00:00:00.000Z'
                );
                INSERT INTO research_experiments(
                    id, case_id, hypothesis_id, dimension, change_summary, state,
                    is_isolated, rollback_reference, baseline_engine_fingerprint,
                    candidate_engine_fingerprint, run_id, runtime_candidate_id, notes,
                    created_at, updated_at
                ) VALUES(
                    '\(legacyExperimentID.uuidString)', '\(legacyCaseID.uuidString)',
                    '\(legacyHypothesisID.uuidString)', 'environment', 'Histórico', 'planned',
                    0, NULL, NULL, NULL, NULL, NULL, '',
                    '2026-08-13T00:00:00.000Z', '2026-08-13T00:00:00.000Z'
                );
                INSERT INTO research_gate_results(
                    experiment_id, gate, status, evidence_reference, checked_at
                ) VALUES(
                    '\(legacyExperimentID.uuidString)', 'crossOverReference', 'passed',
                    'legacy', '2026-08-13T00:00:00.000Z'
                );
                INSERT INTO research_artifacts(
                    id, experiment_id, kind, reference, fingerprint, captured_at
                ) VALUES(
                    '\(legacyArtifactID.uuidString)', '\(legacyExperimentID.uuidString)',
                    'crossOverCapture', 'legacy', NULL, '2026-08-13T00:00:00.000Z'
                );
                DELETE FROM schema_migrations WHERE version>=14;
                PRAGMA user_version=13;
                """
            )
        }

        let migrated = CompatibilityRepository(databaseURL: databaseURL)
        try await migrated.prepare()
        let migratedHealth = try await migrated.databaseHealth()
        XCTAssertEqual(migratedHealth.schemaVersion, CompatibilityRepository.currentSchemaVersion)
        let publicCases = try await migrated.researchCases()
        XCTAssertFalse(publicCases.contains { $0.id == legacyCaseID })

        let autonomous = CompatibilityResearchCase(
            appID: "952",
            gameName: "Autonomous Research",
            symptom: "Fallo reproducible",
            expectedBehavior: "Debe funcionar"
        )
        try await migrated.registerResearchCase(autonomous)
        let experiment = ResearchExperiment(
            caseID: autonomous.id,
            dimension: .environment,
            changeSummary: "Baseline propio"
        )
        try await migrated.registerResearchExperiment(experiment)
        try await migrated.recordResearchGate(ResearchGateResult(
            experimentID: experiment.id,
            gate: .baselineReference,
            status: .passed,
            evidenceReference: "baseline"
        ))
        try await migrated.recordResearchArtifact(ResearchArtifact(
            experimentID: experiment.id,
            kind: .baselineCapture,
            reference: "baseline",
            fingerprint: "sha256:" + String(repeating: "a", count: 64)
        ))
        let autonomousGates = try await migrated.researchGates(experimentID: experiment.id)
        let autonomousArtifacts = try await migrated.researchArtifacts(experimentID: experiment.id)
        XCTAssertTrue(autonomousGates.contains { $0.gate == .baselineReference })
        XCTAssertTrue(autonomousArtifacts.contains { $0.kind == .baselineCapture })
        let exportURL = directory.appendingPathComponent("research-public.json")
        try await migrated.exportJSON(to: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(
            CompatibilityExport.self,
            from: Data(contentsOf: exportURL)
        )
        XCTAssertEqual(export.researchCases.map(\.id), [autonomous.id])
        XCTAssertEqual(export.researchExperiments.map(\.id), [experiment.id])
        XCTAssertEqual(export.researchGates.map(\.gate), [.baselineReference])
        XCTAssertEqual(export.researchArtifacts.map(\.kind), [.baselineCapture])
        XCTAssertFalse(export.researchHypotheses.contains { $0.id == legacyHypothesisID })
        try await migrated.close()

        try mutateSQLite(databaseURL) { database in
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT reference_backend FROM compatibility_research_cases "
                    + "WHERE id='\(legacyCaseID.uuidString)';"
            ), "crossOver")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT gate FROM research_gate_results "
                    + "WHERE experiment_id='\(legacyExperimentID.uuidString)';"
            ), "crossOverReference")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT kind FROM research_artifacts WHERE id='\(legacyArtifactID.uuidString)';"
            ), "crossOverCapture")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT reference_backend FROM compatibility_research_cases "
                    + "WHERE id='\(autonomous.id.uuidString)';"
            ), "regression")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT gate FROM research_gate_results "
                    + "WHERE experiment_id='\(experiment.id.uuidString)';"
            ), "baselineReference")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT kind FROM research_artifacts "
                    + "WHERE experiment_id='\(experiment.id.uuidString)';"
            ), "baselineCapture")
            XCTAssertNil(try scalarSQLiteText(database, "PRAGMA foreign_key_check;"))
        }
    }

    func testVersionThirteenResearchMigrationPreservesPassedExperimentWithImmutableTriggers() async throws {
        let directory = temporaryDirectory("research-v14-passed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()

        let researchCase = CompatibilityResearchCase(
            appID: "953",
            gameName: "Passed Research",
            symptom: "Fallo reproducido",
            expectedBehavior: "Funcionamiento estable"
        )
        try await repository.registerResearchCase(researchCase)
        try await repository.beginResearch(caseID: researchCase.id)
        let hypothesis = ResearchHypothesis(
            caseID: researchCase.id,
            rank: 1,
            statement: "La causa está aislada.",
            prediction: "El candidato elimina el fallo."
        )
        try await repository.registerResearchHypothesis(hypothesis)
        let experiment = ResearchExperiment(
            caseID: researchCase.id,
            hypothesisID: hypothesis.id,
            dimension: .environment,
            changeSummary: "Candidato aislado",
            state: .ready,
            isIsolated: true,
            rollbackReference: "backups/passed-research",
            baselineEngineFingerprint: "engine-baseline"
        )
        try await repository.registerResearchExperiment(experiment)

        let context = makeContext(appID: researchCase.appID, name: researchCase.gameName)
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 9_530,
            executable: "C:\\Games\\passed.exe",
            launchMilliseconds: 100
        )
        try await closeTrackedRun(context, processID: 9_530, repository: repository)
        try await repository.verifyRun(RunVerification(
            runID: context.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "Evidencia temporal de migración"
        ))
        try await repository.attachResearchRun(experimentID: experiment.id, runID: context.id)
        for gate in CompatibilityResearchProtocol.mandatoryGates {
            try await repository.recordResearchGate(ResearchGateResult(
                experimentID: experiment.id,
                gate: gate,
                status: .passed,
                evidenceReference: "evidence/\(gate.rawValue)"
            ))
        }
        for kind in CompatibilityResearchProtocol.mandatoryArtifacts {
            try await repository.recordResearchArtifact(ResearchArtifact(
                experimentID: experiment.id,
                kind: kind,
                reference: "evidence/\(kind.rawValue)",
                fingerprint: "sha256:\(String(repeating: "a", count: 64))"
            ))
        }
        try await repository.completeResearchCase(
            caseID: researchCase.id,
            experimentID: experiment.id,
            resolution: "El candidato aislado resolvió el fallo."
        )
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                DELETE FROM schema_migrations WHERE version>=14;
                PRAGMA user_version=13;
                """)
        }

        let migrated = CompatibilityRepository(databaseURL: databaseURL)
        try await migrated.prepare()
        let health = try await migrated.databaseHealth()
        XCTAssertEqual(health.schemaVersion, CompatibilityRepository.currentSchemaVersion)
        let migratedExperiments = try await migrated.researchExperiments()
        let storedExperiment = try XCTUnwrap(
            migratedExperiments.first { $0.id == experiment.id }
        )
        XCTAssertEqual(storedExperiment.state, .passed)
        let migratedCases = try await migrated.researchCases()
        let storedCase = try XCTUnwrap(
            migratedCases.first { $0.id == researchCase.id }
        )
        XCTAssertEqual(storedCase.state, .verified)
        try await migrated.close()

        try mutateSQLite(databaseURL) { database in
            XCTAssertNil(try scalarSQLiteText(database, "PRAGMA foreign_key_check;"))
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' "
                    + "AND name LIKE 'research_%';"
            ), "17")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT state FROM research_experiments WHERE id='\(experiment.id.uuidString)';"
            ), "passed")
            XCTAssertThrowsError(try executeSQLite(
                database,
                """
                UPDATE research_experiments SET state='failed'
                WHERE id='\(experiment.id.uuidString)';
                """
            ))
        }
    }

    func testFailedVersionThirteenResearchMigrationRollsBackRowsVersionAndTriggers() async throws {
        let directory = temporaryDirectory("research-v14-rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()

        let researchCase = CompatibilityResearchCase(
            appID: "954",
            gameName: "Rollback Research",
            symptom: "Fallo reproducido",
            expectedBehavior: "Funcionamiento estable"
        )
        try await repository.registerResearchCase(researchCase)
        let experiment = ResearchExperiment(
            caseID: researchCase.id,
            dimension: .environment,
            changeSummary: "Candidato temporal"
        )
        try await repository.registerResearchExperiment(experiment)
        let artifact = ResearchArtifact(
            experimentID: experiment.id,
            kind: .logExcerpt,
            reference: "evidence/log",
            fingerprint: "sha256:\(String(repeating: "b", count: 64))"
        )
        try await repository.recordResearchArtifact(artifact)
        try await repository.close()

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(database, """
                PRAGMA ignore_check_constraints=ON;
                UPDATE research_artifacts SET fingerprint='legacy-unchecked'
                WHERE id='\(artifact.id.uuidString)';
                PRAGMA ignore_check_constraints=OFF;
                DELETE FROM schema_migrations WHERE version>=14;
                PRAGMA user_version=13;
                """)
        }

        let failedMigration = CompatibilityRepository(databaseURL: databaseURL)
        do {
            try await failedMigration.prepare()
            XCTFail("La migración debía rechazar la huella v13 incompatible con el contrato v14.")
        } catch {
            XCTAssertTrue(String(describing: error).contains("CHECK constraint failed"))
        }

        try mutateSQLite(databaseURL) { database in
            XCTAssertEqual(try scalarSQLiteText(database, "PRAGMA user_version;"), "13")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' "
                    + "AND name LIKE 'research_%';"
            ), "17")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT fingerprint FROM research_artifacts WHERE id='\(artifact.id.uuidString)';"
            ), "legacy-unchecked")
            XCTAssertEqual(try scalarSQLiteText(
                database,
                "SELECT name FROM sqlite_master WHERE type='trigger' "
                    + "AND name='research_experiment_lock_passed';"
            ), "research_experiment_lock_passed")
            XCTAssertNil(try scalarSQLiteText(
                database,
                "SELECT name FROM sqlite_master WHERE type='table' "
                    + "AND name='research_experiments_v14';"
            ))
        }
    }

    func testRequestReservationPersistsPublishedCrawlDelay() async throws {
        let directory = temporaryDirectory("request-gate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let source = ExternalCatalogSource(
            id: "test-source",
            displayName: "Test",
            baseURL: URL(string: "https://example.test")!,
            informationURL: URL(string: "https://example.test/about")!,
            minimumRequestInterval: 100,
            cacheLifetime: 60
        )
        let start = Date(timeIntervalSince1970: 10_000)

        let firstReservation = try await repository.reserveExternalRequest(source: source, now: start)
        let secondReservation = try await repository.reserveExternalRequest(
            source: source,
            now: start.addingTimeInterval(1)
        )
        XCTAssertEqual(firstReservation, start)
        XCTAssertEqual(secondReservation, start.addingTimeInterval(100))
        try await repository.close()
    }

    func testEngineIdentityNormalizesGameSettingsAndAggregatesOutcomes() async throws {
        let directory = temporaryDirectory("engine-identity")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()

        let baseEngine = [
            "backend": "regression",
            "provider.version": "1.4",
            "bottle.CX_GRAPHICS_BACKEND": "d3dmetal",
            "component.graphics.dxgi.dll": "bytes=10;sha256=abc"
        ]
        var firstConfiguration = baseEngine
        firstConfiguration["gameconfig.a.resolution-width"] = "3024"
        var secondConfiguration = baseEngine
        secondConfiguration["gameconfig.b.resolution-width"] = "1512"

        let first = makeContext(
            appID: "1001",
            name: "Engine One",
            configuration: firstConfiguration,
            providerVersion: "1.4"
        )
        let second = makeContext(
            appID: "1002",
            name: "Engine Two",
            configuration: secondConfiguration,
            providerVersion: "1.4"
        )
        try await repository.beginRun(first)
        try await repository.markLaunched(
            id: first.id,
            processID: 1001,
            executable: "C:\\Games\\engine-one.exe",
            launchMilliseconds: 100
        )
        try await closeTrackedRun(first, processID: 1001, repository: repository)
        try await repository.verifyRun(RunVerification(
            runID: first.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection
        ))
        try await repository.beginRun(second)
        try await repository.failRunBeforeLaunch(id: second.id, reason: "fallo controlado")

        let engines = try await repository.engineProfiles()
        let engine = try XCTUnwrap(engines.first { $0.providerVersion == "1.4" })
        XCTAssertEqual(engine.gameCount, 2)
        XCTAssertEqual(engine.perfectRuns, 1)
        XCTAssertEqual(engine.failedRuns, 1)
        XCTAssertEqual(engine.graphicsBackend, "d3dmetal")
        XCTAssertFalse(engine.values.keys.contains { $0.hasPrefix("gameconfig.") })
        try await repository.close()
    }

    private func makeContext(
        appID: String,
        name: String,
        configuration: [String: String] = ["backend": "regression"],
        providerVersion: String = "Test",
        backend: BackendKind = .regression
    ) -> RunContext {
        return RunContext(
            appID: appID,
            gameName: name,
            backend: backend,
            bottleName: "Steam",
            providerVersion: providerVersion,
            command: "$APP/wine",
            arguments: ["-applaunch", appID],
            system: SystemSnapshot(
                macOSVersion: "26.0",
                architecture: "arm64",
                deviceModel: "MacTest",
                displayWidth: 3024,
                displayHeight: 1964,
                displayScale: 2
            ),
            configuration: configuration,
            configurationFingerprint: ConfigurationCollector.fingerprint(configuration)
        )
    }

    private func perfectVerification(runID: UUID, verifiedAt: Date) -> RunVerification {
        RunVerification(
            runID: runID,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            verifiedAt: verifiedAt
        )
    }

    private func recordClosedPerfectRun(
        _ context: RunContext,
        processID: Int32,
        repository: CompatibilityRepository
    ) async throws {
        let startedAt = Date()
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: processID,
            executable: "C:\\Games\\closed.exe",
            startedAt: startedAt,
            launchMilliseconds: 100
        )
        let endedAt = startedAt.addingTimeInterval(1)
        try await repository.markProcessEnded(
            id: context.id,
            processID: processID,
            endedAt: endedAt,
            exitCode: 0
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: endedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: context.configuration,
            delta: ConfigurationDiffer.difference(
                before: context.configuration,
                after: context.configuration
            )
        )
        try await repository.verifyRun(perfectVerification(
            runID: context.id,
            verifiedAt: endedAt.addingTimeInterval(1)
        ))
    }

    private func closeTrackedRun(
        _ context: RunContext,
        processID: Int32,
        repository: CompatibilityRepository
    ) async throws {
        let endedAt = Date()
        try await repository.markProcessEnded(
            id: context.id,
            processID: processID,
            endedAt: endedAt,
            exitCode: 0
        )
        try await repository.finishRun(
            id: context.id,
            endedAt: endedAt,
            exitCode: 0,
            result: .unknown,
            afterConfiguration: context.configuration,
            delta: ConfigurationDiffer.difference(
                before: context.configuration,
                after: context.configuration
            )
        )
    }

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("regression-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    private func mutateSQLite(
        _ url: URL,
        body: (OpaquePointer) throws -> Void
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLiteTest", code: 1)
        }
        defer { sqlite3_close_v2(database) }
        try body(database)
    }

    private func executeSQLite(_ database: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
            throw NSError(domain: "SQLiteTest", code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func scalarSQLiteText(_ database: OpaquePointer, _ sql: String) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "SQLiteTest", code: 2)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: value)
    }

    private func assertExternalCatalogRejected(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("La fuente histórica aceptó una escritura nueva.", file: file, line: line)
        } catch RegressionCoreError.externalCatalog {
            return
        } catch {
            XCTFail("Error inesperado: \(error)", file: file, line: line)
        }
    }
}
