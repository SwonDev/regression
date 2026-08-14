import Foundation

extension CompatibilityRepository {
    public func registerResearchCase(_ researchCase: CompatibilityResearchCase) throws {
        try ensurePrepared()
        guard researchCase.state == .open,
              researchCase.winningExperimentID == nil,
              researchCase.resolutionSummary == nil else {
            throw RegressionCoreError.invalidEvidence(
                "un expediente nuevo debe empezar abierto y sin una conclusión precargada"
            )
        }
        guard researchCase.referenceBackend == .regression else {
            throw RegressionCoreError.invalidEvidence(
                "los expedientes nuevos deben usar el baseline propio de Regression"
            )
        }
        guard let appID = SteamAppID.normalized(researchCase.appID) else {
            throw RegressionCoreError.invalidEvidence("el Steam App ID del expediente no es válido")
        }
        let symptom = researchText(researchCase.symptom, limit: 4_000)
        let expectedBehavior = researchText(researchCase.expectedBehavior, limit: 4_000)
        guard !symptom.isEmpty, !expectedBehavior.isEmpty else {
            throw RegressionCoreError.invalidEvidence(
                "un expediente necesita síntoma reproducible y comportamiento esperado"
            )
        }

        try transaction {
            try upsertGame(appID: appID, name: researchCase.gameName, at: researchCase.updatedAt)
            try execute(
                """
                INSERT INTO compatibility_research_cases(
                    id, app_id, symptom, expected_behavior, reference_backend, state,
                    blocker, winning_experiment_id, resolution_summary, created_at, updated_at
                ) VALUES(?, ?, ?, ?, ?, 'open', NULL, NULL, NULL, ?, ?);
                """,
                bindings: [
                    researchCase.id.uuidString,
                    appID,
                    symptom,
                    expectedBehavior,
                    researchCase.referenceBackend.rawValue,
                    dateFormatter.string(from: researchCase.createdAt),
                    dateFormatter.string(from: researchCase.updatedAt)
                ]
            )
        }
    }

    public func researchCases(appID: String? = nil) throws -> [CompatibilityResearchCase] {
        try ensurePrepared()
        let normalizedAppID = try appID.map { value -> String in
            guard let result = SteamAppID.normalized(value) else {
                throw RegressionCoreError.invalidEvidence("el Steam App ID no es válido")
            }
            return result
        }
        let filter = normalizedAppID == nil
            ? "WHERE c.reference_backend='regression'"
            : "WHERE c.reference_backend='regression' AND c.app_id=?"
        let bindings: [Any] = normalizedAppID.map { [$0] } ?? []
        return try query(
            """
            SELECT c.id, c.app_id, g.name, c.symptom, c.expected_behavior,
                   c.reference_backend, c.state, c.blocker, c.winning_experiment_id,
                   c.resolution_summary, c.created_at, c.updated_at
            FROM compatibility_research_cases c
            JOIN games g ON g.app_id=c.app_id
            \(filter)
            ORDER BY
                CASE c.state
                    WHEN 'investigating' THEN 0
                    WHEN 'validationPending' THEN 1
                    WHEN 'open' THEN 2
                    WHEN 'pausedExternalDependency' THEN 3
                    ELSE 4
                END,
                c.updated_at DESC;
            """,
            bindings: bindings
        ) { statement -> CompatibilityResearchCase? in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let backend = BackendKind(rawValue: Self.text(statement, 5)),
                let state = CompatibilityResearchCaseState(rawValue: Self.text(statement, 6)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 10)),
                let updatedAt = dateFormatter.date(from: Self.text(statement, 11))
            else { return nil }
            return CompatibilityResearchCase(
                id: id,
                appID: Self.text(statement, 1),
                gameName: Self.text(statement, 2),
                symptom: Self.text(statement, 3),
                expectedBehavior: Self.text(statement, 4),
                referenceBackend: backend,
                state: state,
                blocker: Self.optionalText(statement, 7),
                winningExperimentID: Self.optionalText(statement, 8).flatMap(UUID.init(uuidString:)),
                resolutionSummary: Self.optionalText(statement, 9),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    public func beginResearch(caseID: UUID) throws {
        try transitionResearchCase(
            id: caseID,
            state: .investigating,
            blocker: nil
        )
    }

    public func requestResearchValidation(caseID: UUID) throws {
        try transitionResearchCase(
            id: caseID,
            state: .validationPending,
            blocker: nil
        )
    }

    public func pauseResearch(caseID: UUID, externalBlocker: String) throws {
        let blocker = researchText(externalBlocker, limit: 2_000)
        guard !blocker.isEmpty else {
            throw RegressionCoreError.invalidEvidence(
                "una pausa solo es válida si identifica la dependencia externa concreta"
            )
        }
        try transitionResearchCase(
            id: caseID,
            state: .pausedExternalDependency,
            blocker: blocker
        )
    }

    public func registerResearchHypothesis(_ hypothesis: ResearchHypothesis) throws {
        try ensurePrepared()
        guard hypothesis.rank > 0 else {
            throw RegressionCoreError.invalidEvidence("el rango de una hipótesis debe ser positivo")
        }
        let statement = researchText(hypothesis.statement, limit: 2_000)
        let prediction = researchText(hypothesis.prediction, limit: 2_000)
        guard !statement.isEmpty, !prediction.isEmpty else {
            throw RegressionCoreError.invalidEvidence(
                "cada hipótesis debe ser concreta y tener una predicción falsable"
            )
        }
        _ = try autonomousResearchCase(id: hypothesis.caseID)
        try execute(
            """
            INSERT INTO research_hypotheses(
                id, case_id, rank, statement, prediction, status,
                evidence, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                rank=excluded.rank,
                statement=excluded.statement,
                prediction=excluded.prediction,
                status=excluded.status,
                evidence=excluded.evidence,
                updated_at=excluded.updated_at;
            """,
            bindings: [
                hypothesis.id.uuidString,
                hypothesis.caseID.uuidString,
                hypothesis.rank,
                statement,
                prediction,
                hypothesis.status.rawValue,
                researchText(hypothesis.evidence, limit: 4_000),
                dateFormatter.string(from: hypothesis.createdAt),
                dateFormatter.string(from: hypothesis.updatedAt)
            ]
        )
    }

    public func researchHypotheses(caseID: UUID? = nil) throws -> [ResearchHypothesis] {
        try ensurePrepared()
        let filter = caseID == nil
            ? "WHERE EXISTS (SELECT 1 FROM compatibility_research_cases c "
                + "WHERE c.id=research_hypotheses.case_id AND c.reference_backend='regression')"
            : "WHERE case_id=? AND EXISTS (SELECT 1 FROM compatibility_research_cases c "
                + "WHERE c.id=research_hypotheses.case_id AND c.reference_backend='regression')"
        let bindings: [Any] = caseID.map { [$0.uuidString] } ?? []
        return try query(
            """
            SELECT id, case_id, rank, statement, prediction, status,
                   evidence, created_at, updated_at
            FROM research_hypotheses
            \(filter)
            ORDER BY case_id, rank, created_at;
            """,
            bindings: bindings
        ) { statement -> ResearchHypothesis? in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let parentID = UUID(uuidString: Self.text(statement, 1)),
                let status = ResearchHypothesisStatus(rawValue: Self.text(statement, 5)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 7)),
                let updatedAt = dateFormatter.date(from: Self.text(statement, 8))
            else { return nil }
            return ResearchHypothesis(
                id: id,
                caseID: parentID,
                rank: Self.optionalInt(statement, 2) ?? 0,
                statement: Self.text(statement, 3),
                prediction: Self.text(statement, 4),
                status: status,
                evidence: Self.text(statement, 6),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    public func registerResearchExperiment(_ experiment: ResearchExperiment) throws {
        try ensurePrepared()
        let researchCase = try autonomousResearchCase(id: experiment.caseID)
        if let hypothesisID = experiment.hypothesisID {
            guard try researchHypotheses(caseID: experiment.caseID)
                .contains(where: { $0.id == hypothesisID }) else {
                throw RegressionCoreError.invalidEvidence(
                    "la hipótesis no pertenece al expediente del experimento"
                )
            }
        }
        let changeSummary = researchText(experiment.changeSummary, limit: 2_000)
        guard !changeSummary.isEmpty else {
            throw RegressionCoreError.invalidEvidence(
                "un experimento debe declarar la única dimensión que cambia"
            )
        }
        if experiment.state != .planned {
            try validateStagedExperiment(experiment)
        }
        if experiment.state == .passed {
            let decision = try researchCompletionDecision(
                caseID: researchCase.id,
                experimentID: experiment.id,
                proposedExperiment: experiment
            )
            guard decision.isEligible else {
                throw RegressionCoreError.invalidEvidence(decision.blockers.joined(separator: " "))
            }
        }

        try execute(
            """
            INSERT INTO research_experiments(
                id, case_id, hypothesis_id, dimension, change_summary, state,
                is_isolated, rollback_reference, baseline_engine_fingerprint,
                candidate_engine_fingerprint, run_id, runtime_candidate_id,
                notes, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                hypothesis_id=excluded.hypothesis_id,
                dimension=excluded.dimension,
                change_summary=excluded.change_summary,
                state=excluded.state,
                is_isolated=excluded.is_isolated,
                rollback_reference=excluded.rollback_reference,
                baseline_engine_fingerprint=excluded.baseline_engine_fingerprint,
                candidate_engine_fingerprint=excluded.candidate_engine_fingerprint,
                run_id=excluded.run_id,
                runtime_candidate_id=excluded.runtime_candidate_id,
                notes=excluded.notes,
                updated_at=excluded.updated_at;
            """,
            bindings: researchExperimentBindings(experiment)
        )
    }

    public func researchExperiments(caseID: UUID? = nil) throws -> [ResearchExperiment] {
        try ensurePrepared()
        let filter = caseID == nil
            ? "WHERE EXISTS (SELECT 1 FROM compatibility_research_cases c "
                + "WHERE c.id=research_experiments.case_id AND c.reference_backend='regression')"
            : "WHERE case_id=? AND EXISTS (SELECT 1 FROM compatibility_research_cases c "
                + "WHERE c.id=research_experiments.case_id AND c.reference_backend='regression')"
        let bindings: [Any] = caseID.map { [$0.uuidString] } ?? []
        return try query(
            """
            SELECT id, case_id, hypothesis_id, dimension, change_summary, state,
                   is_isolated, rollback_reference, baseline_engine_fingerprint,
                   candidate_engine_fingerprint, run_id, runtime_candidate_id,
                   notes, created_at, updated_at
            FROM research_experiments
            \(filter)
            ORDER BY updated_at DESC;
            """,
            bindings: bindings
        ) { statement -> ResearchExperiment? in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let parentID = UUID(uuidString: Self.text(statement, 1)),
                let dimension = ResearchExperimentDimension(rawValue: Self.text(statement, 3)),
                let state = ResearchExperimentState(rawValue: Self.text(statement, 5)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 13)),
                let updatedAt = dateFormatter.date(from: Self.text(statement, 14))
            else { return nil }
            return ResearchExperiment(
                id: id,
                caseID: parentID,
                hypothesisID: Self.optionalText(statement, 2).flatMap(UUID.init(uuidString:)),
                dimension: dimension,
                changeSummary: Self.text(statement, 4),
                state: state,
                isIsolated: Self.optionalInt(statement, 6) == 1,
                rollbackReference: Self.optionalText(statement, 7),
                baselineEngineFingerprint: Self.optionalText(statement, 8),
                candidateEngineFingerprint: Self.optionalText(statement, 9),
                runID: Self.optionalText(statement, 10).flatMap(UUID.init(uuidString:)),
                runtimeCandidateID: Self.optionalText(statement, 11).flatMap(UUID.init(uuidString:)),
                notes: Self.text(statement, 12),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    public func attachResearchRun(experimentID: UUID, runID: UUID) throws {
        try ensurePrepared()
        guard let experiment = try researchExperimentRecord(id: experimentID),
              let researchCase = try researchCaseRecord(id: experiment.caseID) else {
            throw RegressionCoreError.invalidEvidence("el experimento no existe")
        }
        try requireAutonomousResearchCase(researchCase)
        guard [.ready, .running, .validation].contains(experiment.state) else {
            throw RegressionCoreError.invalidEvidence(
                "solo un experimento preparado y activo puede vincular una ejecución"
            )
        }
        struct RunIdentity {
            let appID: String
            let backend: BackendKind
            let processID: Int?
            let engineFingerprint: String
        }
        let identities: [RunIdentity] = try query(
            """
            SELECT r.app_id, r.backend, r.process_id, e.engine_fingerprint
            FROM runs r
            JOIN run_engine_snapshots e ON e.run_id=r.id
            WHERE r.id=?;
            """,
            bindings: [runID.uuidString]
        ) { statement -> RunIdentity? in
            guard let backend = BackendKind(rawValue: Self.text(statement, 1)) else { return nil }
            return RunIdentity(
                appID: Self.text(statement, 0),
                backend: backend,
                processID: Self.optionalInt(statement, 2),
                engineFingerprint: Self.text(statement, 3)
            )
        }
        guard let identity = identities.first,
              identity.appID == researchCase.appID,
              identity.backend == .regression,
              identity.processID != nil else {
            throw RegressionCoreError.invalidEvidence(
                "el experimento solo puede vincular una ejecución real del mismo juego en Regression"
            )
        }
        try validateStagedExperiment(experiment)
        try execute(
            """
            UPDATE research_experiments
            SET run_id=?, candidate_engine_fingerprint=?, state='validation', updated_at=?
            WHERE id=?;
            """,
            bindings: [
                runID.uuidString,
                identity.engineFingerprint,
                dateFormatter.string(from: Date()),
                experimentID.uuidString
            ]
        )
        try transitionResearchCase(
            id: researchCase.id,
            state: .validationPending,
            blocker: nil
        )
    }

    public func finishResearchExperiment(
        id: UUID,
        state: ResearchExperimentState,
        notes: String
    ) throws {
        try ensurePrepared()
        guard state == .failed || state == .rolledBack else {
            throw RegressionCoreError.invalidEvidence(
                "solo los resultados fallidos o revertidos se cierran por esta vía"
            )
        }
        guard let experiment = try researchExperimentRecord(id: id),
              experiment.state != .passed else {
            throw RegressionCoreError.invalidEvidence(
                "el experimento no existe o ya forma parte de un cierre verificado"
            )
        }
        _ = try autonomousResearchCase(id: experiment.caseID)
        try execute(
            """
            UPDATE research_experiments
            SET state=?, notes=?, updated_at=?
            WHERE id=? AND state!='passed';
            """,
            bindings: [
                state.rawValue,
                researchText(notes, limit: 4_000),
                dateFormatter.string(from: Date()),
                id.uuidString
            ]
        )
    }

    public func recordResearchGate(_ result: ResearchGateResult) throws {
        try ensurePrepared()
        guard let experiment = try researchExperimentRecord(id: result.experimentID),
              experiment.state != .passed else {
            throw RegressionCoreError.invalidEvidence(
                "no se puede alterar la matriz de un experimento inexistente o ya cerrado"
            )
        }
        _ = try autonomousResearchCase(id: experiment.caseID)
        let evidence = researchText(result.evidenceReference, limit: 2_000)
        if result.status != .pending, evidence.isEmpty {
            throw RegressionCoreError.invalidEvidence(
                "una puerta superada o fallida necesita una evidencia concreta"
            )
        }
        try execute(
            """
            INSERT INTO research_gate_results(
                experiment_id, gate, status, evidence_reference, checked_at
            ) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(experiment_id, gate) DO UPDATE SET
                status=excluded.status,
                evidence_reference=excluded.evidence_reference,
                checked_at=excluded.checked_at;
            """,
            bindings: [
                result.experimentID.uuidString,
                result.gate.rawValue,
                result.status.rawValue,
                evidence,
                dateFormatter.string(from: result.checkedAt)
            ]
        )
    }

    public func researchGates(experimentID: UUID? = nil) throws -> [ResearchGateResult] {
        try ensurePrepared()
        let filter = experimentID == nil
            ? "WHERE EXISTS (SELECT 1 FROM research_experiments e "
                + "JOIN compatibility_research_cases c ON c.id=e.case_id "
                + "WHERE e.id=research_gate_results.experiment_id "
                + "AND c.reference_backend='regression')"
            : "WHERE experiment_id=? AND EXISTS (SELECT 1 FROM research_experiments e "
                + "JOIN compatibility_research_cases c ON c.id=e.case_id "
                + "WHERE e.id=research_gate_results.experiment_id "
                + "AND c.reference_backend='regression')"
        let bindings: [Any] = experimentID.map { [$0.uuidString] } ?? []
        return try query(
            """
            SELECT experiment_id, gate, status, evidence_reference, checked_at
            FROM research_gate_results
            \(filter)
            ORDER BY experiment_id, gate;
            """,
            bindings: bindings
        ) { statement -> ResearchGateResult? in
            guard
                let parentID = UUID(uuidString: Self.text(statement, 0)),
                let gate = ResearchValidationGate(rawValue: Self.text(statement, 1)),
                let status = ResearchGateStatus(rawValue: Self.text(statement, 2)),
                let checkedAt = dateFormatter.date(from: Self.text(statement, 4))
            else { return nil }
            return ResearchGateResult(
                experimentID: parentID,
                gate: gate,
                status: status,
                evidenceReference: Self.text(statement, 3),
                checkedAt: checkedAt
            )
        }
    }

    public func recordResearchArtifact(_ artifact: ResearchArtifact) throws {
        try ensurePrepared()
        guard let experiment = try researchExperimentRecord(id: artifact.experimentID),
              experiment.state != .passed else {
            throw RegressionCoreError.invalidEvidence(
                "no se puede alterar la evidencia de un experimento inexistente o ya cerrado"
            )
        }
        let researchCase = try autonomousResearchCase(id: experiment.caseID)
        let reference = researchText(artifact.reference, limit: 2_000)
        guard !reference.isEmpty else {
            throw RegressionCoreError.invalidEvidence("la evidencia necesita una referencia privada")
        }
        let fingerprint: String?
        if let value = artifact.fingerprint {
            guard let normalized = normalizedResearchSHA256(value) else {
                throw RegressionCoreError.invalidEvidence(
                    "la huella de la evidencia debe ser un SHA-256 completo"
                )
            }
            fingerprint = normalized
        } else {
            fingerprint = nil
        }
        if CompatibilityResearchProtocol.mandatoryArtifacts(for: researchCase.referenceBackend)
            .contains(artifact.kind),
           fingerprint?.isEmpty != false {
            throw RegressionCoreError.invalidEvidence(
                "la evidencia obligatoria necesita una huella verificable"
            )
        }
        try execute(
            """
            INSERT INTO research_artifacts(
                id, experiment_id, kind, reference, fingerprint, captured_at
            ) VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind=excluded.kind,
                reference=excluded.reference,
                fingerprint=excluded.fingerprint,
                captured_at=excluded.captured_at;
            """,
            bindings: [
                artifact.id.uuidString,
                artifact.experimentID.uuidString,
                artifact.kind.rawValue,
                reference,
                fingerprint ?? NSNull(),
                dateFormatter.string(from: artifact.capturedAt)
            ]
        )
    }

    public func researchArtifacts(experimentID: UUID? = nil) throws -> [ResearchArtifact] {
        try ensurePrepared()
        let filter = experimentID == nil
            ? "WHERE EXISTS (SELECT 1 FROM research_experiments e "
                + "JOIN compatibility_research_cases c ON c.id=e.case_id "
                + "WHERE e.id=research_artifacts.experiment_id "
                + "AND c.reference_backend='regression')"
            : "WHERE experiment_id=? AND EXISTS (SELECT 1 FROM research_experiments e "
                + "JOIN compatibility_research_cases c ON c.id=e.case_id "
                + "WHERE e.id=research_artifacts.experiment_id "
                + "AND c.reference_backend='regression')"
        let bindings: [Any] = experimentID.map { [$0.uuidString] } ?? []
        return try query(
            """
            SELECT id, experiment_id, kind, reference, fingerprint, captured_at
            FROM research_artifacts
            \(filter)
            ORDER BY captured_at, kind;
            """,
            bindings: bindings
        ) { statement -> ResearchArtifact? in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let parentID = UUID(uuidString: Self.text(statement, 1)),
                let kind = ResearchArtifactKind(rawValue: Self.text(statement, 2)),
                let capturedAt = dateFormatter.date(from: Self.text(statement, 5))
            else { return nil }
            return ResearchArtifact(
                id: id,
                experimentID: parentID,
                kind: kind,
                reference: Self.text(statement, 3),
                fingerprint: Self.optionalText(statement, 4),
                capturedAt: capturedAt
            )
        }
    }

    public func researchCompletionDecision(
        caseID: UUID,
        experimentID: UUID
    ) throws -> ResearchCompletionDecision {
        try ensurePrepared()
        return try researchCompletionDecision(
            caseID: caseID,
            experimentID: experimentID,
            proposedExperiment: nil
        )
    }

    public func completeResearchCase(
        caseID: UUID,
        experimentID: UUID,
        resolution: String
    ) throws {
        try ensurePrepared()
        let resolutionSummary = researchText(resolution, limit: 4_000)
        guard !resolutionSummary.isEmpty else {
            throw RegressionCoreError.invalidEvidence(
                "el cierre necesita explicar la causa raíz y la solución reproducible"
            )
        }
        let decision = try researchCompletionDecision(
            caseID: caseID,
            experimentID: experimentID
        )
        guard decision.isEligible else {
            throw RegressionCoreError.invalidEvidence(decision.blockers.joined(separator: " "))
        }
        let now = dateFormatter.string(from: Date())
        try transaction {
            try execute(
                "UPDATE research_experiments SET state='passed', updated_at=? WHERE id=?;",
                bindings: [now, experimentID.uuidString]
            )
            try execute(
                """
                UPDATE research_hypotheses
                SET status='supported', updated_at=?
                WHERE id=(SELECT hypothesis_id FROM research_experiments WHERE id=?);
                """,
                bindings: [now, experimentID.uuidString]
            )
            try execute(
                """
                UPDATE compatibility_research_cases
                SET state='verified', blocker=NULL, winning_experiment_id=?,
                    resolution_summary=?, updated_at=?
                WHERE id=?;
                """,
                bindings: [
                    experimentID.uuidString,
                    resolutionSummary,
                    now,
                    caseID.uuidString
                ]
            )
        }
    }

    public func researchCaseCount(activeOnly: Bool = false) throws -> Int {
        try ensurePrepared()
        let filter = activeOnly ? "WHERE state!='verified'" : ""
        return try scalarInt("SELECT COUNT(*) FROM compatibility_research_cases \(filter);")
    }

    public func researchExperimentCount(activeOnly: Bool = false) throws -> Int {
        try ensurePrepared()
        let filter = activeOnly ? "WHERE state NOT IN ('passed','failed','rolledBack')" : ""
        return try scalarInt("SELECT COUNT(*) FROM research_experiments \(filter);")
    }

    func validateResearchData() throws {
        let invalidCases = try scalarInt(
            """
            SELECT COUNT(*) FROM compatibility_research_cases c
            WHERE
                (c.state='pausedExternalDependency'
                 AND (c.blocker IS NULL OR trim(c.blocker)=''))
                OR (c.state='verified' AND (
                    c.winning_experiment_id IS NULL
                    OR c.resolution_summary IS NULL OR trim(c.resolution_summary)=''
                    OR NOT EXISTS (
                        SELECT 1 FROM research_experiments e
                        WHERE e.id=c.winning_experiment_id
                          AND e.case_id=c.id AND e.state='passed'
                    )
                ));
            """
        )
        let invalidPassedExperiments = try scalarInt(
            """
            SELECT COUNT(*) FROM research_experiments e
            WHERE e.state='passed' AND (
                e.is_isolated!=1
                OR e.rollback_reference IS NULL OR trim(e.rollback_reference)=''
                OR e.baseline_engine_fingerprint IS NULL
                OR trim(e.baseline_engine_fingerprint)=''
                OR e.candidate_engine_fingerprint IS NULL
                OR trim(e.candidate_engine_fingerprint)=''
                OR e.baseline_engine_fingerprint=e.candidate_engine_fingerprint
                OR e.run_id IS NULL
                OR (
                    SELECT COUNT(DISTINCT gate) FROM research_gate_results g
                    WHERE g.experiment_id=e.id AND g.status='passed'
                      AND g.gate IN (\(ResearchSchema.autonomousMandatoryGatesSQL))
                )!=\(CompatibilityResearchProtocol.mandatoryGates.count)
                AND (SELECT reference_backend FROM compatibility_research_cases
                     WHERE id=e.case_id)='regression'
                OR (
                    SELECT COUNT(DISTINCT gate) FROM research_gate_results g
                    WHERE g.experiment_id=e.id AND g.status='passed'
                      AND g.gate IN (\(ResearchSchema.legacyMandatoryGatesSQL))
                )!=\(CompatibilityResearchProtocol.mandatoryGates(for: .crossOver).count)
                AND (SELECT reference_backend FROM compatibility_research_cases
                     WHERE id=e.case_id)='crossOver'
                OR (
                    SELECT COUNT(DISTINCT kind) FROM research_artifacts a
                    WHERE a.experiment_id=e.id
                      AND a.fingerprint IS NOT NULL AND trim(a.fingerprint)!=''
                      AND a.kind IN (\(ResearchSchema.autonomousMandatoryArtifactsSQL))
                )!=\(CompatibilityResearchProtocol.mandatoryArtifacts.count)
                AND (SELECT reference_backend FROM compatibility_research_cases
                     WHERE id=e.case_id)='regression'
                OR (
                    SELECT COUNT(DISTINCT kind) FROM research_artifacts a
                    WHERE a.experiment_id=e.id
                      AND a.fingerprint IS NOT NULL AND trim(a.fingerprint)!=''
                      AND a.kind IN (\(ResearchSchema.legacyMandatoryArtifactsSQL))
                )!=\(CompatibilityResearchProtocol.mandatoryArtifacts(for: .crossOver).count)
                AND (SELECT reference_backend FROM compatibility_research_cases
                     WHERE id=e.case_id)='crossOver'
            );
            """
        )
        guard invalidCases == 0, invalidPassedExperiments == 0 else {
            throw RegressionCoreError.database(
                "Hay expedientes de I+D cerrados sin matriz o evidencia completa"
            )
        }
    }

    private func transitionResearchCase(
        id: UUID,
        state: CompatibilityResearchCaseState,
        blocker: String?
    ) throws {
        try ensurePrepared()
        guard state != .verified else {
            throw RegressionCoreError.invalidEvidence(
                "un expediente solo se verifica mediante su puerta de cierre completa"
            )
        }
        guard let current = try researchCaseRecord(id: id) else {
            throw RegressionCoreError.invalidEvidence("el expediente no existe")
        }
        try requireAutonomousResearchCase(current)
        guard current.state != .verified else {
            throw RegressionCoreError.invalidEvidence(
                "un expediente verificado es histórico; abre uno nuevo para una regresión distinta"
            )
        }
        try execute(
            """
            UPDATE compatibility_research_cases
            SET state=?, blocker=?, updated_at=? WHERE id=?;
            """,
            bindings: [
                state.rawValue,
                blocker ?? NSNull(),
                dateFormatter.string(from: Date()),
                id.uuidString
            ]
        )
    }

    private func validateStagedExperiment(_ experiment: ResearchExperiment) throws {
        guard experiment.isIsolated,
              experiment.rollbackReference?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false,
              experiment.baselineEngineFingerprint?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw RegressionCoreError.invalidEvidence(
                "antes de ejecutar hacen falta aislamiento, rollback y huella del baseline"
            )
        }
    }

    private func researchCompletionDecision(
        caseID: UUID,
        experimentID: UUID,
        proposedExperiment: ResearchExperiment?
    ) throws -> ResearchCompletionDecision {
        guard let researchCase = try researchCaseRecord(id: caseID) else {
            return ResearchCompletionDecision(
                isEligible: false,
                blockers: ["El expediente no existe."]
            )
        }
        try requireAutonomousResearchCase(researchCase)
        let storedExperiment = try researchExperimentRecord(id: experimentID)
        let experiment = proposedExperiment ?? storedExperiment
        guard let experiment, experiment.caseID == caseID else {
            return ResearchCompletionDecision(
                isEligible: false,
                blockers: ["El experimento no pertenece al expediente."]
            )
        }

        var blockers: [String] = []
        if experiment.state != .validation {
            blockers.append(
                "El experimento debe estar en validación y vinculado a su ejecución exacta."
            )
        }
        if !experiment.isIsolated {
            blockers.append("El candidato no está aislado del baseline.")
        }
        if experiment.rollbackReference?.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty != false {
            blockers.append("Falta una referencia de rollback.")
        }
        if experiment.baselineEngineFingerprint?.isEmpty != false {
            blockers.append("Falta la huella del motor baseline.")
        }
        if experiment.candidateEngineFingerprint?.isEmpty != false {
            blockers.append("Falta la huella del motor candidato.")
        }
        if experiment.baselineEngineFingerprint == experiment.candidateEngineFingerprint {
            blockers.append("El candidato no demuestra una identidad de motor distinta.")
        }
        guard let runID = experiment.runID else {
            blockers.append("Falta vincular la ejecución exacta de Regression.")
            return ResearchCompletionDecision(isEligible: false, blockers: blockers)
        }

        let passedGates = Set(
            try researchGateRecords(experimentID: experiment.id)
                .filter { $0.status == .passed && !$0.evidenceReference.isEmpty }
                .map(\.gate)
        )
        for gate in CompatibilityResearchProtocol.mandatoryGates(
            for: researchCase.referenceBackend
        ) where !passedGates.contains(gate) {
            blockers.append("Falta superar la puerta \(gate.rawValue).")
        }

        let artifactKinds = Set(
            try researchArtifactRecords(experimentID: experiment.id)
                .filter { $0.fingerprint?.isEmpty == false }
                .map(\.kind)
        )
        for kind in CompatibilityResearchProtocol.mandatoryArtifacts(
            for: researchCase.referenceBackend
        )
            where !artifactKinds.contains(kind) {
            blockers.append("Falta la evidencia \(kind.rawValue).")
        }

        let perfectEvidenceCount = try scalarInt(
            """
            SELECT COUNT(*) FROM runs r
            JOIN run_verifications v ON v.run_id=r.id
            JOIN verified_game_certifications c
              ON c.source_run_id=r.id AND c.app_id=r.app_id
             AND c.backend='regression' AND c.is_active=1
            WHERE r.id=? AND r.app_id=? AND r.backend='regression'
              AND \(RunPerfectEvidenceSQL.predicate(
                  run: "r",
                  verification: "v"
              ))
              AND v.rendering='passed' AND v.input_precision='passed'
              AND v.graphics_settings='passed' AND v.gameplay='passed';
            """,
            bindings: [runID.uuidString, researchCase.appID]
        )
        if perfectEvidenceCount != 1 {
            blockers.append(
                "La ejecución vinculada todavía no tiene un blindado perfecto y activo de Regression."
            )
        }
        return ResearchCompletionDecision(isEligible: blockers.isEmpty, blockers: blockers)
    }

    private func autonomousResearchCase(id: UUID) throws -> CompatibilityResearchCase {
        guard let researchCase = try researchCaseRecord(id: id) else {
            throw RegressionCoreError.invalidEvidence("el expediente no existe")
        }
        try requireAutonomousResearchCase(researchCase)
        return researchCase
    }

    private func requireAutonomousResearchCase(
        _ researchCase: CompatibilityResearchCase
    ) throws {
        guard researchCase.referenceBackend == .regression else {
            throw RegressionCoreError.invalidEvidence(
                "el expediente histórico es de solo lectura; abre uno nuevo con baseline Regression"
            )
        }
    }

    private func researchExperimentBindings(_ experiment: ResearchExperiment) -> [Any] {
        [
            experiment.id.uuidString,
            experiment.caseID.uuidString,
            experiment.hypothesisID?.uuidString ?? NSNull(),
            experiment.dimension.rawValue,
            researchText(experiment.changeSummary, limit: 2_000),
            experiment.state.rawValue,
            experiment.isIsolated,
            experiment.rollbackReference.map { researchText($0, limit: 2_000) } ?? NSNull(),
            experiment.baselineEngineFingerprint ?? NSNull(),
            experiment.candidateEngineFingerprint ?? NSNull(),
            experiment.runID?.uuidString ?? NSNull(),
            experiment.runtimeCandidateID?.uuidString ?? NSNull(),
            researchText(experiment.notes, limit: 4_000),
            dateFormatter.string(from: experiment.createdAt),
            dateFormatter.string(from: experiment.updatedAt)
        ]
    }

    /// Acceso interno por identidad para terminar o corregir un expediente histórico conocido.
    /// Las consultas públicas continúan ocultando ese grafo.
    private func researchCaseRecord(id: UUID) throws -> CompatibilityResearchCase? {
        try query(
            """
            SELECT c.id, c.app_id, g.name, c.symptom, c.expected_behavior,
                   c.reference_backend, c.state, c.blocker, c.winning_experiment_id,
                   c.resolution_summary, c.created_at, c.updated_at
            FROM compatibility_research_cases c
            JOIN games g ON g.app_id=c.app_id
            WHERE c.id=?;
            """,
            bindings: [id.uuidString]
        ) { statement -> CompatibilityResearchCase? in
            guard
                let recordID = UUID(uuidString: Self.text(statement, 0)),
                let backend = BackendKind(rawValue: Self.text(statement, 5)),
                let state = CompatibilityResearchCaseState(rawValue: Self.text(statement, 6)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 10)),
                let updatedAt = dateFormatter.date(from: Self.text(statement, 11))
            else { return nil }
            return CompatibilityResearchCase(
                id: recordID,
                appID: Self.text(statement, 1),
                gameName: Self.text(statement, 2),
                symptom: Self.text(statement, 3),
                expectedBehavior: Self.text(statement, 4),
                referenceBackend: backend,
                state: state,
                blocker: Self.optionalText(statement, 7),
                winningExperimentID: Self.optionalText(statement, 8).flatMap(UUID.init(uuidString:)),
                resolutionSummary: Self.optionalText(statement, 9),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }.first
    }

    private func researchExperimentRecord(id: UUID) throws -> ResearchExperiment? {
        try query(
            """
            SELECT id, case_id, hypothesis_id, dimension, change_summary, state,
                   is_isolated, rollback_reference, baseline_engine_fingerprint,
                   candidate_engine_fingerprint, run_id, runtime_candidate_id,
                   notes, created_at, updated_at
            FROM research_experiments WHERE id=?;
            """,
            bindings: [id.uuidString]
        ) { statement -> ResearchExperiment? in
            guard
                let recordID = UUID(uuidString: Self.text(statement, 0)),
                let parentID = UUID(uuidString: Self.text(statement, 1)),
                let dimension = ResearchExperimentDimension(rawValue: Self.text(statement, 3)),
                let state = ResearchExperimentState(rawValue: Self.text(statement, 5)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 13)),
                let updatedAt = dateFormatter.date(from: Self.text(statement, 14))
            else { return nil }
            return ResearchExperiment(
                id: recordID,
                caseID: parentID,
                hypothesisID: Self.optionalText(statement, 2).flatMap(UUID.init(uuidString:)),
                dimension: dimension,
                changeSummary: Self.text(statement, 4),
                state: state,
                isIsolated: Self.optionalInt(statement, 6) == 1,
                rollbackReference: Self.optionalText(statement, 7),
                baselineEngineFingerprint: Self.optionalText(statement, 8),
                candidateEngineFingerprint: Self.optionalText(statement, 9),
                runID: Self.optionalText(statement, 10).flatMap(UUID.init(uuidString:)),
                runtimeCandidateID: Self.optionalText(statement, 11).flatMap(UUID.init(uuidString:)),
                notes: Self.text(statement, 12),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }.first
    }

    private func researchGateRecords(experimentID: UUID) throws -> [ResearchGateResult] {
        try query(
            """
            SELECT experiment_id, gate, status, evidence_reference, checked_at
            FROM research_gate_results WHERE experiment_id=? ORDER BY gate;
            """,
            bindings: [experimentID.uuidString]
        ) { statement in
            guard
                let parentID = UUID(uuidString: Self.text(statement, 0)),
                let gate = ResearchValidationGate(rawValue: Self.text(statement, 1)),
                let status = ResearchGateStatus(rawValue: Self.text(statement, 2)),
                let checkedAt = dateFormatter.date(from: Self.text(statement, 4))
            else { return nil }
            return ResearchGateResult(
                experimentID: parentID,
                gate: gate,
                status: status,
                evidenceReference: Self.text(statement, 3),
                checkedAt: checkedAt
            )
        }
    }

    private func researchArtifactRecords(experimentID: UUID) throws -> [ResearchArtifact] {
        try query(
            """
            SELECT id, experiment_id, kind, reference, fingerprint, captured_at
            FROM research_artifacts WHERE experiment_id=? ORDER BY captured_at, kind;
            """,
            bindings: [experimentID.uuidString]
        ) { statement in
            guard
                let recordID = UUID(uuidString: Self.text(statement, 0)),
                let parentID = UUID(uuidString: Self.text(statement, 1)),
                let kind = ResearchArtifactKind(rawValue: Self.text(statement, 2)),
                let capturedAt = dateFormatter.date(from: Self.text(statement, 5))
            else { return nil }
            return ResearchArtifact(
                id: recordID,
                experimentID: parentID,
                kind: kind,
                reference: Self.text(statement, 3),
                fingerprint: Self.optionalText(statement, 4),
                capturedAt: capturedAt
            )
        }
    }

    private func researchText(_ value: String, limit: Int) -> String {
        PrivacySanitizer.redactedLogExcerpt(
            value.trimmingCharacters(in: .whitespacesAndNewlines),
            limit: limit
        )
    }

    private func normalizedResearchSHA256(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = clean.hasPrefix("sha256:") ? String(clean.dropFirst(7)) : clean
        guard digest.count == 64,
              digest.unicodeScalars.allSatisfy(
                  CharacterSet(charactersIn: "0123456789abcdef").contains
              ) else {
            return nil
        }
        return "sha256:\(digest)"
    }
}

enum ResearchSchema {
    static let autonomousMandatoryGatesSQL = CompatibilityResearchProtocol.mandatoryGates
        .map { "'\($0.rawValue)'" }
        .joined(separator: ",")
    static let legacyMandatoryGatesSQL = CompatibilityResearchProtocol.mandatoryGates(
        for: .crossOver
    )
        .map { "'\($0.rawValue)'" }
        .joined(separator: ",")
    static let autonomousMandatoryArtifactsSQL = CompatibilityResearchProtocol.mandatoryArtifacts
        .map { "'\($0.rawValue)'" }
        .joined(separator: ",")
    static let legacyMandatoryArtifactsSQL = CompatibilityResearchProtocol.mandatoryArtifacts(
        for: .crossOver
    )
        .map { "'\($0.rawValue)'" }
        .joined(separator: ",")

    static let sql = """
        CREATE TABLE IF NOT EXISTS compatibility_research_cases(
            id TEXT PRIMARY KEY,
            app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE CASCADE,
            symptom TEXT NOT NULL CHECK(trim(symptom)!=''),
            expected_behavior TEXT NOT NULL CHECK(trim(expected_behavior)!=''),
            reference_backend TEXT NOT NULL DEFAULT 'regression'
                CHECK(reference_backend IN ('crossOver','regression')),
            state TEXT NOT NULL CHECK(state IN (
                'open','investigating','validationPending','verified','pausedExternalDependency'
            )),
            blocker TEXT,
            winning_experiment_id TEXT REFERENCES research_experiments(id),
            resolution_summary TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            CHECK(state!='pausedExternalDependency' OR (blocker IS NOT NULL AND trim(blocker)!='')),
            CHECK(state!='verified' OR (
                winning_experiment_id IS NOT NULL
                AND resolution_summary IS NOT NULL AND trim(resolution_summary)!=''
            ))
        );
        CREATE INDEX IF NOT EXISTS compatibility_research_cases_app_state_idx
            ON compatibility_research_cases(app_id, state, updated_at DESC);

        CREATE TABLE IF NOT EXISTS research_hypotheses(
            id TEXT PRIMARY KEY,
            case_id TEXT NOT NULL REFERENCES compatibility_research_cases(id) ON DELETE CASCADE,
            rank INTEGER NOT NULL CHECK(rank > 0),
            statement TEXT NOT NULL CHECK(trim(statement)!=''),
            prediction TEXT NOT NULL CHECK(trim(prediction)!=''),
            status TEXT NOT NULL CHECK(status IN ('proposed','testing','supported','falsified')),
            evidence TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(case_id, rank)
        );

        CREATE TABLE IF NOT EXISTS research_experiments(
            id TEXT PRIMARY KEY,
            case_id TEXT NOT NULL REFERENCES compatibility_research_cases(id) ON DELETE CASCADE,
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
                is_isolated=1
                AND rollback_reference IS NOT NULL AND trim(rollback_reference)!=''
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
        CREATE INDEX IF NOT EXISTS research_experiments_case_state_idx
            ON research_experiments(case_id, state, updated_at DESC);
        CREATE INDEX IF NOT EXISTS research_experiments_run_idx ON research_experiments(run_id);

        CREATE TABLE IF NOT EXISTS research_gate_results(
            experiment_id TEXT NOT NULL REFERENCES research_experiments(id) ON DELETE CASCADE,
            gate TEXT NOT NULL CHECK(gate IN (
                'crossOverReference','baselineReference','rendering','inputPrecision','graphicsSettings',
                'gameplay','ownResources','regressionMatrix','rollbackVerified'
            )),
            status TEXT NOT NULL CHECK(status IN ('pending','passed','failed')),
            evidence_reference TEXT NOT NULL,
            checked_at TEXT NOT NULL,
            PRIMARY KEY(experiment_id, gate),
            CHECK(status='pending' OR trim(evidence_reference)!='')
        );

        CREATE TABLE IF NOT EXISTS research_artifacts(
            id TEXT PRIMARY KEY,
            experiment_id TEXT NOT NULL REFERENCES research_experiments(id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN (
                'crossOverCapture','baselineCapture','regressionCapture','moduleInventory',
                'configurationSnapshot','buildReport','testReport','signatureReport',
                'rollbackManifest','logExcerpt','performanceCapture'
            )),
            reference TEXT NOT NULL CHECK(trim(reference)!=''),
            fingerprint TEXT CHECK(fingerprint IS NULL OR (
                length(fingerprint)=71
                AND lower(substr(fingerprint, 1, 7))='sha256:'
                AND lower(substr(fingerprint, 8)) NOT GLOB '*[^0-9a-f]*'
            )),
            captured_at TEXT NOT NULL,
            UNIQUE(experiment_id, kind, reference)
        );
        CREATE INDEX IF NOT EXISTS research_artifacts_experiment_kind_idx
            ON research_artifacts(experiment_id, kind);

        CREATE TRIGGER IF NOT EXISTS research_hypothesis_matches_case_insert
        BEFORE INSERT ON research_experiments
        WHEN NEW.hypothesis_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM research_hypotheses h
            WHERE h.id=NEW.hypothesis_id AND h.case_id=NEW.case_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'research hypothesis belongs to another case');
        END;

        CREATE TRIGGER IF NOT EXISTS research_hypothesis_matches_case_update
        BEFORE UPDATE OF hypothesis_id, case_id ON research_experiments
        WHEN NEW.hypothesis_id IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM research_hypotheses h
            WHERE h.id=NEW.hypothesis_id AND h.case_id=NEW.case_id
        )
        BEGIN
            SELECT RAISE(ABORT, 'research hypothesis belongs to another case');
        END;

        CREATE TRIGGER IF NOT EXISTS research_experiment_pass_guard_insert
        BEFORE INSERT ON research_experiments
        WHEN NEW.state='passed'
        BEGIN
            SELECT RAISE(ABORT, 'research experiment must be validated before passing');
        END;

        CREATE TRIGGER IF NOT EXISTS research_experiment_pass_guard_update
        BEFORE UPDATE OF state ON research_experiments
        WHEN NEW.state='passed' AND (
            NEW.is_isolated!=1
            OR NEW.rollback_reference IS NULL OR trim(NEW.rollback_reference)=''
            OR NEW.baseline_engine_fingerprint IS NULL
            OR trim(NEW.baseline_engine_fingerprint)=''
            OR NEW.candidate_engine_fingerprint IS NULL
            OR trim(NEW.candidate_engine_fingerprint)=''
            OR NEW.baseline_engine_fingerprint=NEW.candidate_engine_fingerprint
            OR NEW.run_id IS NULL
            OR (
                SELECT COUNT(DISTINCT gate) FROM research_gate_results g
                WHERE g.experiment_id=NEW.id AND g.status='passed'
                  AND g.gate IN (\(autonomousMandatoryGatesSQL))
            )!=\(CompatibilityResearchProtocol.mandatoryGates.count)
            AND (SELECT reference_backend FROM compatibility_research_cases
                 WHERE id=NEW.case_id)='regression'
            OR (
                SELECT COUNT(DISTINCT gate) FROM research_gate_results g
                WHERE g.experiment_id=NEW.id AND g.status='passed'
                  AND g.gate IN (\(legacyMandatoryGatesSQL))
            )!=\(CompatibilityResearchProtocol.mandatoryGates(for: .crossOver).count)
            AND (SELECT reference_backend FROM compatibility_research_cases
                 WHERE id=NEW.case_id)='crossOver'
            OR (
                SELECT COUNT(DISTINCT kind) FROM research_artifacts a
                WHERE a.experiment_id=NEW.id
                  AND a.fingerprint IS NOT NULL AND trim(a.fingerprint)!=''
                  AND a.kind IN (\(autonomousMandatoryArtifactsSQL))
            )!=\(CompatibilityResearchProtocol.mandatoryArtifacts.count)
            AND (SELECT reference_backend FROM compatibility_research_cases
                 WHERE id=NEW.case_id)='regression'
            OR (
                SELECT COUNT(DISTINCT kind) FROM research_artifacts a
                WHERE a.experiment_id=NEW.id
                  AND a.fingerprint IS NOT NULL AND trim(a.fingerprint)!=''
                  AND a.kind IN (\(legacyMandatoryArtifactsSQL))
            )!=\(CompatibilityResearchProtocol.mandatoryArtifacts(for: .crossOver).count)
            AND (SELECT reference_backend FROM compatibility_research_cases
                 WHERE id=NEW.case_id)='crossOver'
            OR NOT EXISTS (
                SELECT 1 FROM runs r
                JOIN run_verifications v ON v.run_id=r.id
                JOIN verified_game_certifications c
                  ON c.source_run_id=r.id AND c.app_id=r.app_id
                 AND c.backend='regression' AND c.is_active=1
                WHERE r.id=NEW.run_id
                  AND r.app_id=(
                      SELECT app_id FROM compatibility_research_cases WHERE id=NEW.case_id
                  )
                  AND r.backend='regression'
                  AND \(RunPerfectEvidenceSQL.predicate(
                      run: "r",
                      verification: "v"
                  ))
                  AND v.rendering='passed' AND v.input_precision='passed'
                  AND v.graphics_settings='passed' AND v.gameplay='passed'
            )
        )
        BEGIN
            SELECT RAISE(ABORT, 'research experiment lacks complete reproducible evidence');
        END;

        CREATE TRIGGER IF NOT EXISTS research_experiment_lock_passed
        BEFORE UPDATE ON research_experiments
        WHEN OLD.state='passed'
        BEGIN
            SELECT RAISE(ABORT, 'passed research experiments are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_case_verify_guard_insert
        BEFORE INSERT ON compatibility_research_cases
        WHEN NEW.state='verified' AND NOT EXISTS (
            SELECT 1 FROM research_experiments e
            WHERE e.id=NEW.winning_experiment_id
              AND e.case_id=NEW.id AND e.state='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'verified research case requires a passed experiment');
        END;

        CREATE TRIGGER IF NOT EXISTS research_case_verify_guard_update
        BEFORE UPDATE OF state, winning_experiment_id, resolution_summary
        ON compatibility_research_cases
        WHEN NEW.state='verified' AND NOT EXISTS (
            SELECT 1 FROM research_experiments e
            WHERE e.id=NEW.winning_experiment_id
              AND e.case_id=NEW.id AND e.state='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'verified research case requires a passed experiment');
        END;

        CREATE TRIGGER IF NOT EXISTS research_hypothesis_lock_verified
        BEFORE UPDATE ON research_hypotheses
        WHEN EXISTS (
            SELECT 1 FROM compatibility_research_cases c
            WHERE c.id=OLD.case_id AND c.state='verified'
        )
        BEGIN
            SELECT RAISE(ABORT, 'verified research hypotheses are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_hypothesis_insert_lock_verified
        BEFORE INSERT ON research_hypotheses
        WHEN EXISTS (
            SELECT 1 FROM compatibility_research_cases c
            WHERE c.id=NEW.case_id AND c.state='verified'
        )
        BEGIN
            SELECT RAISE(ABORT, 'verified research hypotheses are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_hypothesis_delete_lock_verified
        BEFORE DELETE ON research_hypotheses
        WHEN EXISTS (
            SELECT 1 FROM compatibility_research_cases c
            WHERE c.id=OLD.case_id AND c.state='verified'
        )
        BEGIN
            SELECT RAISE(ABORT, 'verified research hypotheses are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_gate_lock_update
        BEFORE UPDATE ON research_gate_results
        WHEN EXISTS (
            SELECT 1 FROM research_experiments e
            WHERE e.id=OLD.experiment_id AND e.state='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'passed research gates are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_gate_lock_delete
        BEFORE DELETE ON research_gate_results
        WHEN EXISTS (
            SELECT 1 FROM research_experiments e
            WHERE e.id=OLD.experiment_id AND e.state='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'passed research gates are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_gate_lock_insert
        BEFORE INSERT ON research_gate_results
        WHEN EXISTS (
            SELECT 1 FROM research_experiments e
            WHERE e.id=NEW.experiment_id AND e.state='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'passed research gates are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_artifact_lock_update
        BEFORE UPDATE ON research_artifacts
        WHEN EXISTS (
            SELECT 1 FROM research_experiments e
            WHERE e.id=OLD.experiment_id AND e.state='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'passed research artifacts are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_artifact_lock_delete
        BEFORE DELETE ON research_artifacts
        WHEN EXISTS (
            SELECT 1 FROM research_experiments e
            WHERE e.id=OLD.experiment_id AND e.state='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'passed research artifacts are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_artifact_lock_insert
        BEFORE INSERT ON research_artifacts
        WHEN EXISTS (
            SELECT 1 FROM research_experiments e
            WHERE e.id=NEW.experiment_id AND e.state='passed'
        )
        BEGIN
            SELECT RAISE(ABORT, 'passed research artifacts are immutable');
        END;

        CREATE TRIGGER IF NOT EXISTS research_case_reopens_after_verdict_correction
        AFTER UPDATE OF verdict ON run_verifications
        WHEN OLD.verdict='perfect' AND NEW.verdict!='perfect'
        BEGIN
            UPDATE compatibility_research_cases
            SET state='investigating',
                blocker=NULL,
                winning_experiment_id=NULL,
                resolution_summary='Reabierto: se corrigió el veredicto de la ejecución vinculada.',
                updated_at=NEW.verified_at
            WHERE state='verified' AND winning_experiment_id IN (
                SELECT id FROM research_experiments WHERE run_id=NEW.run_id
            );
        END;
        """
}
