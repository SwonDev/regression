import CSQLite
import Foundation
@testable import RegressionCore
import XCTest

final class CompatibilityResearchTests: XCTestCase {
    func testResearchCaseCannotCloseUntilExactRegressionRunAndEveryGateAreVerified() async throws {
        let directory = temporaryDirectory("research-completion")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()

        let researchCase = CompatibilityResearchCase(
            appID: "501",
            gameName: "Research Game",
            symptom: "La imagen parpadea al entrar en gameplay.",
            expectedBehavior: "El baseline estable de Regression renderiza la escena sin parpadeos."
        )
        XCTAssertEqual(researchCase.referenceBackend, .regression)
        XCTAssertTrue(CompatibilityResearchProtocol.mandatoryGates.contains(.baselineReference))
        XCTAssertFalse(CompatibilityResearchProtocol.mandatoryGates.contains(.crossOverReference))
        XCTAssertTrue(CompatibilityResearchProtocol.mandatoryArtifacts.contains(.baselineCapture))
        XCTAssertFalse(CompatibilityResearchProtocol.mandatoryArtifacts.contains(.crossOverCapture))
        try await repository.registerResearchCase(researchCase)
        try await repository.beginResearch(caseID: researchCase.id)

        let hypothesis = ResearchHypothesis(
            caseID: researchCase.id,
            rank: 1,
            statement: "Se están mezclando dos backends gráficos.",
            prediction: "Un perfil por proceso con un único backend eliminará el parpadeo."
        )
        try await repository.registerResearchHypothesis(hypothesis)

        let experiment = ResearchExperiment(
            caseID: researchCase.id,
            hypothesisID: hypothesis.id,
            dimension: .graphicsBackend,
            changeSummary: "Seleccionar D3DMetal únicamente para el ejecutable del juego.",
            state: .ready,
            isIsolated: true,
            rollbackReference: "backups/research-game-before",
            baselineEngineFingerprint: "engine-baseline"
        )
        try await repository.registerResearchExperiment(experiment)

        let incomplete = try await repository.researchCompletionDecision(
            caseID: researchCase.id,
            experimentID: experiment.id
        )
        XCTAssertFalse(incomplete.isEligible)
        XCTAssertTrue(incomplete.blockers.contains { $0.contains("ejecución exacta") })

        let context = makeContext(appID: researchCase.appID, name: researchCase.gameName)
        try await repository.beginRun(context)
        try await repository.markLaunched(
            id: context.id,
            processID: 5_010,
            executable: "C:\\Games\\research.exe",
            launchMilliseconds: 120
        )
        try await repository.verifyRun(RunVerification(
            runID: context.id,
            verdict: .perfect,
            rendering: .passed,
            inputPrecision: .passed,
            graphicsSettings: .passed,
            gameplay: .passed,
            source: .visualInspection,
            notes: "Validación visual completa"
        ))
        try await repository.attachResearchRun(experimentID: experiment.id, runID: context.id)

        try await repository.recordResearchGate(ResearchGateResult(
            experimentID: experiment.id,
            gate: .crossOverReference,
            status: .passed,
            evidenceReference: "evidence/legacy-reference"
        ))
        try await repository.recordResearchArtifact(ResearchArtifact(
            experimentID: experiment.id,
            kind: .crossOverCapture,
            reference: "evidence/legacy-capture",
            fingerprint: "sha256:\(String(repeating: "b", count: 64))"
        ))
        let wrongAuthority = try await repository.researchCompletionDecision(
            caseID: researchCase.id,
            experimentID: experiment.id
        )
        XCTAssertFalse(wrongAuthority.isEligible)
        XCTAssertTrue(wrongAuthority.blockers.contains { $0.contains("baselineReference") })
        XCTAssertTrue(wrongAuthority.blockers.contains { $0.contains("baselineCapture") })

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

        let complete = try await repository.researchCompletionDecision(
            caseID: researchCase.id,
            experimentID: experiment.id
        )
        XCTAssertTrue(complete.isEligible, complete.blockers.joined(separator: " "))
        try await repository.completeResearchCase(
            caseID: researchCase.id,
            experimentID: experiment.id,
            resolution: "La causa era la mezcla de backends; el perfil por proceso la elimina."
        )

        let storedCases = try await repository.researchCases()
        let storedCase = try XCTUnwrap(storedCases.first { $0.id == researchCase.id })
        XCTAssertEqual(storedCase.state, .verified)
        XCTAssertEqual(storedCase.winningExperimentID, experiment.id)
        let storedExperiments = try await repository.researchExperiments()
        let storedExperiment = try XCTUnwrap(
            storedExperiments.first { $0.id == experiment.id }
        )
        XCTAssertEqual(storedExperiment.state, .passed)
        let storedHypotheses = try await repository.researchHypotheses()
        let storedHypothesis = try XCTUnwrap(
            storedHypotheses.first { $0.id == hypothesis.id }
        )
        XCTAssertEqual(storedHypothesis.status, .supported)
        XCTAssertThrowsError(try mutateSQLite(databaseURL) { database in
            try executeSQLite(
                database,
                """
                UPDATE research_experiments SET state='failed'
                WHERE id='\(experiment.id.uuidString)';
                """
            )
        })

        let health = try await repository.databaseHealth()
        XCTAssertEqual(health.researchCaseCount, 1)
        XCTAssertEqual(health.researchHypothesisCount, 1)
        XCTAssertEqual(health.researchExperimentCount, 1)
        XCTAssertEqual(
            health.researchGateCount,
            CompatibilityResearchProtocol.mandatoryGates.count + 1,
            "La puerta legacy cruzada se conserva como historial, pero no cierra el expediente autónomo."
        )
        XCTAssertEqual(
            health.researchArtifactCount,
            CompatibilityResearchProtocol.mandatoryArtifacts.count + 1,
            "El artefacto legacy cruzado se conserva como historial, pero no cierra el expediente autónomo."
        )

        let exportURL = directory.appendingPathComponent("research-export.json")
        try await repository.exportJSON(to: exportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(
            CompatibilityExport.self,
            from: Data(contentsOf: exportURL)
        )
        XCTAssertEqual(payload.researchCases.count, 1)
        XCTAssertEqual(payload.researchExperiments.count, 1)

        try await repository.verifyRun(RunVerification(
            runID: context.id,
            verdict: .failed,
            rendering: .failed,
            source: .visualInspection,
            notes: "La confirmación se corrigió"
        ))
        let reopenedCases = try await repository.researchCases()
        let reopened = try XCTUnwrap(reopenedCases.first { $0.id == researchCase.id })
        XCTAssertEqual(reopened.state, .investigating)
        XCTAssertNil(reopened.winningExperimentID)
        try await repository.close()
    }

    func testSQLiteRejectsResearchPromotionWithoutEvidenceEvenWhenBypassingSwift() async throws {
        let directory = temporaryDirectory("research-trigger-guard")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()

        let researchCase = CompatibilityResearchCase(
            appID: "502",
            gameName: "Guarded Game",
            symptom: "Pantalla negra.",
            expectedBehavior: "La referencia renderiza el menú."
        )
        try await repository.registerResearchCase(researchCase)
        let experiment = ResearchExperiment(
            caseID: researchCase.id,
            dimension: .dynamicLibraries,
            changeSummary: "Probar una única pareja de DLL.",
            state: .ready,
            isIsolated: true,
            rollbackReference: "backups/guarded-game",
            baselineEngineFingerprint: "baseline"
        )
        try await repository.registerResearchExperiment(experiment)

        XCTAssertThrowsError(try mutateSQLite(databaseURL) { database in
            try executeSQLite(
                database,
                """
                INSERT INTO research_artifacts(
                    id, experiment_id, kind, reference, fingerprint, captured_at
                ) VALUES(
                    '\(UUID().uuidString)', '\(experiment.id.uuidString)',
                    'buildReport', 'evidence/build', 'not-a-sha256',
                    '2026-07-28T00:00:00.000Z'
                );
                """
            )
        })
        XCTAssertThrowsError(try mutateSQLite(databaseURL) { database in
            try executeSQLite(
                database,
                """
                UPDATE research_experiments
                SET state='passed', candidate_engine_fingerprint='candidate',
                    run_id='\(UUID().uuidString)'
                WHERE id='\(experiment.id.uuidString)';
                """
            )
        })
        let storedExperiments = try await repository.researchExperiments()
        let stored = try XCTUnwrap(storedExperiments.first { $0.id == experiment.id })
        XCTAssertEqual(stored.state, .ready)
        try await repository.close()
    }

    func testLegacyCrossOverResearchGraphIsPreservedAsReadOnlyHistory() async throws {
        let directory = temporaryDirectory("research-legacy-read-only")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let repository = CompatibilityRepository(databaseURL: databaseURL)
        try await repository.prepare()

        let caseID = UUID()
        let experimentID = UUID()
        try mutateSQLite(databaseURL) { database in
            try executeSQLite(
                database,
                """
                INSERT INTO games(app_id, name, updated_at)
                VALUES('599', 'Legacy Research', '2026-08-13T00:00:00.000Z');
                INSERT INTO compatibility_research_cases(
                    id, app_id, symptom, expected_behavior, reference_backend, state,
                    blocker, winning_experiment_id, resolution_summary, created_at, updated_at
                ) VALUES(
                    '\(caseID.uuidString)', '599', 'Fallo histórico',
                    'Referencia histórica', 'crossOver', 'open', NULL, NULL, NULL,
                    '2026-08-13T00:00:00.000Z', '2026-08-13T00:00:00.000Z'
                );
                INSERT INTO research_experiments(
                    id, case_id, hypothesis_id, dimension, change_summary, state,
                    is_isolated, rollback_reference, baseline_engine_fingerprint,
                    candidate_engine_fingerprint, run_id, runtime_candidate_id, notes,
                    created_at, updated_at
                ) VALUES(
                    '\(experimentID.uuidString)', '\(caseID.uuidString)', NULL,
                    'environment', 'Reproducir expediente heredado', 'ready', 1,
                    'backups/legacy', 'legacy-baseline', NULL, NULL, NULL, '',
                    '2026-08-13T00:00:00.000Z', '2026-08-13T00:00:00.000Z'
                );
                """
            )
        }

        let storedCases = try await repository.researchCases()
        XCTAssertFalse(storedCases.contains { $0.id == caseID })
        let experiment = ResearchExperiment(
            id: experimentID,
            caseID: caseID,
            dimension: .environment,
            changeSummary: "Reproducir el expediente heredado en un candidato aislado.",
            state: .ready,
            isIsolated: true,
            rollbackReference: "backups/legacy",
            baselineEngineFingerprint: "legacy-baseline"
        )
        await assertInvalidEvidence { try await repository.beginResearch(caseID: caseID) }
        await assertInvalidEvidence { try await repository.requestResearchValidation(caseID: caseID) }
        await assertInvalidEvidence {
            try await repository.pauseResearch(caseID: caseID, externalBlocker: "Dependencia externa")
        }
        await assertInvalidEvidence {
            try await repository.registerResearchHypothesis(ResearchHypothesis(
                caseID: caseID,
                rank: 1,
                statement: "No debe aceptarse",
                prediction: "El historial permanecerá intacto"
            ))
        }
        await assertInvalidEvidence { try await repository.registerResearchExperiment(experiment) }
        await assertInvalidEvidence {
            try await repository.attachResearchRun(experimentID: experimentID, runID: UUID())
        }
        await assertInvalidEvidence {
            try await repository.finishResearchExperiment(
                id: experimentID,
                state: .failed,
                notes: "No debe mutarse"
            )
        }
        await assertInvalidEvidence {
            try await repository.recordResearchGate(ResearchGateResult(
                experimentID: experimentID,
                gate: .crossOverReference,
                status: .passed,
                evidenceReference: "legacy"
            ))
        }
        await assertInvalidEvidence {
            try await repository.recordResearchArtifact(ResearchArtifact(
                experimentID: experimentID,
                kind: .crossOverCapture,
                reference: "legacy",
                fingerprint: "sha256:\(String(repeating: "d", count: 64))"
            ))
        }
        await assertInvalidEvidence {
            _ = try await repository.researchCompletionDecision(
                caseID: caseID,
                experimentID: experimentID
            )
        }
        await assertInvalidEvidence {
            try await repository.completeResearchCase(
                caseID: caseID,
                experimentID: experimentID,
                resolution: "No debe mutarse"
            )
        }

        let publicExperiments = try await repository.researchExperiments()
        let publicGates = try await repository.researchGates()
        let publicArtifacts = try await repository.researchArtifacts()
        XCTAssertTrue(publicExperiments.isEmpty)
        XCTAssertTrue(publicGates.isEmpty)
        XCTAssertTrue(publicArtifacts.isEmpty)
        try await repository.close()
    }

    func testResearchPauseRequiresConcreteExternalDependency() async throws {
        let directory = temporaryDirectory("research-pause")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = CompatibilityRepository(
            databaseURL: directory.appendingPathComponent("compatibility.sqlite")
        )
        try await repository.prepare()
        let researchCase = CompatibilityResearchCase(
            appID: "503",
            gameName: "Paused Game",
            symptom: "No hay build público para reproducir la ruta.",
            expectedBehavior: "El juego debe iniciar con el runtime abierto equivalente."
        )
        try await repository.registerResearchCase(researchCase)

        do {
            try await repository.pauseResearch(caseID: researchCase.id, externalBlocker: " ")
            XCTFail("Una pausa vaga no debe persistir")
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                return XCTFail("Error inesperado: \(error)")
            }
        }
        try await repository.pauseResearch(
            caseID: researchCase.id,
            externalBlocker: "La fuente oficial todavía no ha publicado el artefacto reproducible."
        )
        let storedCases = try await repository.researchCases()
        let stored = try XCTUnwrap(storedCases.first { $0.id == researchCase.id })
        XCTAssertEqual(stored.state, .pausedExternalDependency)
        XCTAssertFalse(stored.blocker?.isEmpty ?? true)
        try await repository.close()
    }

    func testVersionNineDatabaseMigratesAtomicallyToResearchLedger() async throws {
        let directory = temporaryDirectory("research-v9-migration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("compatibility.sqlite")
        let context = makeContext(appID: "504", name: "Version Nine Game")

        var repository: CompatibilityRepository? = CompatibilityRepository(databaseURL: databaseURL)
        try await repository?.prepare()
        try await repository?.beginRun(context)
        try await repository?.failRunBeforeLaunch(id: context.id, reason: "Historial v9")
        try await repository?.close()
        repository = nil

        try mutateSQLite(databaseURL) { database in
            try executeSQLite(
                database,
                """
                DROP TRIGGER IF EXISTS research_case_reopens_after_verdict_correction;
                DROP TABLE IF EXISTS research_gate_results;
                DROP TABLE IF EXISTS research_artifacts;
                DROP TABLE IF EXISTS research_experiments;
                DROP TABLE IF EXISTS research_hypotheses;
                DROP TABLE IF EXISTS compatibility_research_cases;
                DELETE FROM schema_migrations WHERE version>=10;
                PRAGMA user_version=9;
                """
            )
        }

        let migrated = CompatibilityRepository(databaseURL: databaseURL)
        try await migrated.prepare()
        let health = try await migrated.databaseHealth()
        XCTAssertEqual(health.schemaVersion, CompatibilityRepository.currentSchemaVersion)
        XCTAssertEqual(health.runCount, 1)
        XCTAssertEqual(health.researchCaseCount, 0)
        XCTAssertTrue(health.isHealthy)
        let backup = await migrated.lastMigrationBackup()
        XCTAssertNotNil(backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup?.path ?? ""))
        try await migrated.close()
    }

    private func makeContext(appID: String, name: String) -> RunContext {
        let configuration = [
            "backend": "regression",
            "component.graphics": "candidate"
        ]
        return RunContext(
            appID: appID,
            gameName: name,
            backend: .regression,
            bottleName: "Steam",
            providerVersion: "Research Test",
            command: "$APP/regression-engine",
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

    private func assertInvalidEvidence(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("La API aceptó una mutación de historial de solo lectura", file: file, line: line)
        } catch let error as RegressionCoreError {
            guard case .invalidEvidence = error else {
                XCTFail("Se esperaba invalidEvidence y se obtuvo \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("Se esperaba RegressionCoreError y se obtuvo \(error)", file: file, line: line)
        }
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
