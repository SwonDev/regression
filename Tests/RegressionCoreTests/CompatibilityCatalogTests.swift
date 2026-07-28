import CSQLite
import Foundation
@testable import RegressionCore
import XCTest

final class CompatibilityCatalogTests: XCTestCase {
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

    func testCodeWeaversJSONLDParserNormalizesSteamAndPlatformRatings() throws {
        let html = #"""
        <html><head>
        <script type="application/ld+json">{
          "@context":"https://schema.org",
          "@graph":[
            {"@type":"VideoGame","name":"Grim Dawn",
             "url":"https://www.codeweavers.com/compatibility/crossover/grim-dawn",
             "applicationCategory":"Role Playing Games",
             "publisher":{"@type":"Organization","name":"Crate Entertainment"},
             "sameAs":["https://store.steampowered.com/app/219990"]},
            {"@type":"Review","reviewAspect":"CrossOver compatibility on macOS",
             "datePublished":"2026-07-22T15:55:06-0500",
             "about":{"operatingSystem":"macOS","softwareVersion":"26.3.0"},
             "reviewRating":{"ratingValue":"5"}},
            {"@type":"Review","reviewAspect":"CrossOver compatibility on Linux",
             "datePublished":"2026-02-22T09:15:34-0600",
             "about":{"operatingSystem":"Linux","softwareVersion":"26.0.0"},
             "reviewRating":{"ratingValue":4}}
          ]
        }</script></head>
        <body><span id="var_app_id" class="noshow">13436</span></body></html>
        """#
        let record = try CodeWeaversPageParser.parseDetail(
            data: Data(html.utf8),
            requestedURL: URL(string: "https://www.codeweavers.com/compatibility/crossover/grim-dawn")!,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            validators: ExternalCatalogValidators(entityTag: "abc", lastModified: "today")
        )

        XCTAssertEqual(record.externalAppID, "13436")
        XCTAssertEqual(record.steamAppID, "219990")
        XCTAssertEqual(record.company, "Crate Entertainment")
        XCTAssertEqual(record.macOSRating.value, 5)
        XCTAssertEqual(record.macOSRating.testedCrossOverVersion, "26.3.0")
        XCTAssertNotNil(record.macOSRating.testedAt)
        XCTAssertEqual(record.linuxRating.value, 4)
        XCTAssertEqual(record.entityTag, "abc")
        XCTAssertEqual(record.contentFingerprint.count, 64)
    }

    func testCodeWeaversSearchParserKeepsOnlySafeDetailLinks() throws {
        let html = #"""
        <a href="/compatibility/crossover/grim-dawn"><strong>Grim Dawn</strong></a>
        <a href="/compatibility/crossover/grim-dawn#breakdown">Duplicado</a>
        <a href="https://malicious.invalid/compatibility/crossover/grim-dawn">No</a>
        """#
        let results = try CodeWeaversPageParser.parseSearchResults(data: Data(html.utf8))

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Grim Dawn")
        XCTAssertEqual(
            results.first?.detailURL.absoluteString,
            "https://www.codeweavers.com/compatibility/crossover/grim-dawn"
        )
    }

    func testCodeWeaversParserRejectsCanonicalURLOutsideOfficialHost() throws {
        let html = #"""
        <script type="application/ld+json">{
          "@type":"VideoGame", "name":"Impostor",
          "url":"https://evilcodeweavers.com/compatibility/crossover/impostor"
        }</script>
        """#

        XCTAssertThrowsError(try CodeWeaversPageParser.parseDetail(
            data: Data(html.utf8),
            requestedURL: URL(string: "https://www.codeweavers.com/compatibility/crossover/impostor")!,
            fetchedAt: Date(),
            validators: ExternalCatalogValidators()
        ))
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

    func testPublicSearchURLUsesOfficialQueryAndEscapesGameName() throws {
        let url = try XCTUnwrap(
            CodeWeaversCompatibilityProvider.publicSearchURL(for: "Game & Test")
        )
        let components = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
        XCTAssertEqual(query["name"], "Game & Test")
        XCTAssertEqual(query["search"], "app")
        XCTAssertEqual(url.host, "www.codeweavers.com")
    }

    func testCatalogSynchronizerCachesPublicContextWithoutCertifyingLocally() async throws {
        let directory = temporaryDirectory("external-cache")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let provider = StubCompatibilityProvider(appID: "4242", gameName: "Catalog Test")
        let synchronizer = ExternalCatalogSynchronizer(
            repository: repository,
            provider: provider,
            noMatchCacheLifetime: 60
        )
        let game = SteamGame(
            appID: "4242",
            name: "Catalog Test",
            installDirectory: "Catalog Test",
            manifestURL: URL(fileURLWithPath: "/tmp/appmanifest_4242.acf"),
            sourceBackend: .crossOver
        )

        guard case .updated = await synchronizer.refresh(game: game) else {
            return XCTFail("La primera consulta debía persistir la ficha")
        }
        let firstFetchCount = await provider.fetchCount()
        XCTAssertEqual(firstFetchCount, 1)
        let cachedOutcome = await synchronizer.refresh(game: game)
        XCTAssertEqual(cachedOutcome, .freshCache)
        let cachedFetchCount = await provider.fetchCount()
        XCTAssertEqual(cachedFetchCount, 1)

        let storedEntry = try await repository.externalEntry(
            sourceID: provider.source.id,
            appID: game.appID
        )
        let entry = try XCTUnwrap(storedEntry)
        XCTAssertEqual(entry.record?.macOSRating.value, 5)
        let comparisons = try await repository.compatibilityComparisons()
        let comparison = try XCTUnwrap(comparisons.first { $0.appID == game.appID })
        XCTAssertEqual(comparison.localState, .unverified)
        XCTAssertEqual(comparison.alignment, .insufficientEvidence)
        let certifications = try await repository.certifications()
        XCTAssertNil(certifications.first { $0.appID == game.appID })
        try await repository.close()
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
        providerVersion: String = "Test"
    ) -> RunContext {
        return RunContext(
            appID: appID,
            gameName: name,
            backend: .regression,
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
}

private actor StubCompatibilityProvider: ExternalCompatibilityProviding {
    nonisolated let source = ExternalCatalogSource(
        id: "codeweavers",
        displayName: "CodeWeavers Test",
        baseURL: URL(string: "https://www.codeweavers.com/compatibility")!,
        informationURL: URL(string: "https://www.codeweavers.com/compatibility")!,
        minimumRequestInterval: 0,
        cacheLifetime: 3_600
    )

    private let record: ExternalGameRecord
    private var fetches = 0

    init(appID: String, gameName: String) {
        record = ExternalGameRecord(
            sourceID: "codeweavers",
            externalAppID: "test-record",
            canonicalURL: CodeWeaversCompatibilityProvider.probableDetailURL(for: gameName)!,
            name: gameName,
            company: "Test Publisher",
            category: "Games",
            steamAppID: appID,
            macOSRating: ExternalCompatibilityRating(
                platform: .macOS,
                value: 5,
                testedCrossOverVersion: "26.3.0",
                testedAt: Date(timeIntervalSince1970: 900)
            ),
            linuxRating: ExternalCompatibilityRating(
                platform: .linux,
                value: nil,
                testedCrossOverVersion: nil,
                testedAt: nil
            ),
            fetchedAt: Date(),
            contentFingerprint: String(repeating: "a", count: 64)
        )
    }

    func fetchRecord(
        at detailURL: URL,
        validators: ExternalCatalogValidators?
    ) async throws -> ExternalCatalogFetchResult {
        fetches += 1
        return .modified(record)
    }

    func search(named gameName: String) async throws -> [ExternalCatalogSearchCandidate] {
        []
    }

    func fetchCount() -> Int { fetches }
}
