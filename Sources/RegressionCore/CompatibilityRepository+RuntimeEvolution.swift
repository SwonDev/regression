import Foundation

extension CompatibilityRepository {
    func synchronizeRuntimeTechnologyCatalog() throws {
        let syncedAt = dateFormatter.string(from: Date())
        try transaction {
            for technology in RuntimeTechnologyCatalog.all {
                try execute(
                    """
                    INSERT INTO runtime_technologies(
                        id, display_name, category, official_url, release_url,
                        distribution_policy, update_policy, stable_version,
                        latest_known_version, checked_at, catalog_revision, notes, synced_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        display_name=excluded.display_name,
                        category=excluded.category,
                        official_url=excluded.official_url,
                        release_url=excluded.release_url,
                        distribution_policy=excluded.distribution_policy,
                        update_policy=excluded.update_policy,
                        stable_version=excluded.stable_version,
                        latest_known_version=excluded.latest_known_version,
                        checked_at=excluded.checked_at,
                        catalog_revision=excluded.catalog_revision,
                        notes=excluded.notes,
                        synced_at=excluded.synced_at;
                    """,
                    bindings: [
                        technology.id,
                        technology.displayName,
                        technology.category.rawValue,
                        technology.officialURL.absoluteString,
                        technology.releaseURL?.absoluteString ?? NSNull(),
                        technology.distributionPolicy.rawValue,
                        technology.updatePolicy.rawValue,
                        technology.stableVersion ?? NSNull(),
                        technology.latestKnownVersion ?? NSNull(),
                        dateFormatter.string(from: technology.checkedAt),
                        RuntimeTechnologyCatalog.revision,
                        PrivacySanitizer.redactedLogExcerpt(technology.notes, limit: 2_000),
                        syncedAt
                    ]
                )
            }
        }
    }

    public func runtimeTechnologies() throws -> [RuntimeTechnology] {
        try ensurePrepared()
        return try query(
            """
            SELECT id, display_name, category, official_url, release_url,
                   distribution_policy, update_policy, stable_version,
                   latest_known_version, checked_at, notes
            FROM runtime_technologies
            ORDER BY category, display_name COLLATE NOCASE;
            """
        ) { statement in
            guard
                let category = RuntimeTechnologyCategory(rawValue: Self.text(statement, 2)),
                let officialURL = URL(string: Self.text(statement, 3)),
                let distribution = RuntimeDistributionPolicy(rawValue: Self.text(statement, 5)),
                let updatePolicy = RuntimeUpdatePolicy(rawValue: Self.text(statement, 6)),
                let checkedAt = dateFormatter.date(from: Self.text(statement, 9))
            else { return nil }
            return RuntimeTechnology(
                id: Self.text(statement, 0),
                displayName: Self.text(statement, 1),
                category: category,
                officialURL: officialURL,
                releaseURL: Self.optionalText(statement, 4).flatMap(URL.init(string:)),
                distributionPolicy: distribution,
                updatePolicy: updatePolicy,
                stableVersion: Self.optionalText(statement, 7),
                latestKnownVersion: Self.optionalText(statement, 8),
                checkedAt: checkedAt,
                notes: Self.text(statement, 10)
            )
        }
    }

    public func registerRuntimeCandidate(_ candidate: RuntimeCandidate) throws {
        try ensurePrepared()
        if candidate.state == .promoted {
            let technology = try runtimeTechnologies().first { $0.id == candidate.technologyID }
            let decision = RuntimeSelectionPolicy.promotionDecision(
                for: candidate,
                assessments: try optimizationAssessments(appID: candidate.appID),
                technology: technology
            )
            guard decision.isEligible else {
                throw RegressionCoreError.invalidEvidence(decision.blockers.joined(separator: " "))
            }
        }
        try execute(
            """
            INSERT INTO runtime_candidates(
                id, technology_id, app_id, target_version, scope, objective, state,
                source_url, source_fingerprint, source_verified, is_isolated,
                rollback_reference, baseline_engine_fingerprint,
                candidate_engine_fingerprint, validation_matrix_passed,
                created_at, updated_at, notes
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                technology_id=excluded.technology_id,
                app_id=excluded.app_id,
                target_version=excluded.target_version,
                scope=excluded.scope,
                objective=excluded.objective,
                state=excluded.state,
                source_url=excluded.source_url,
                source_fingerprint=excluded.source_fingerprint,
                source_verified=excluded.source_verified,
                is_isolated=excluded.is_isolated,
                rollback_reference=excluded.rollback_reference,
                baseline_engine_fingerprint=excluded.baseline_engine_fingerprint,
                candidate_engine_fingerprint=excluded.candidate_engine_fingerprint,
                validation_matrix_passed=excluded.validation_matrix_passed,
                updated_at=excluded.updated_at,
                notes=excluded.notes;
            """,
            bindings: candidateBindings(candidate)
        )
    }

    public func runtimeCandidates(appID: String? = nil) throws -> [RuntimeCandidate] {
        try ensurePrepared()
        let filter = appID == nil ? "" : "WHERE app_id=?"
        let bindings: [Any] = appID.map { [$0] } ?? []
        return try query(
            """
            SELECT id, technology_id, app_id, target_version, scope, objective, state,
                   source_url, source_fingerprint, source_verified, is_isolated,
                   rollback_reference, baseline_engine_fingerprint,
                   candidate_engine_fingerprint, validation_matrix_passed,
                   created_at, updated_at, notes
            FROM runtime_candidates
            \(filter)
            ORDER BY updated_at DESC;
            """,
            bindings: bindings
        ) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let scope = RuntimeCandidateScope(rawValue: Self.text(statement, 4)),
                let state = RuntimeCandidateState(rawValue: Self.text(statement, 6)),
                let sourceURL = URL(string: Self.text(statement, 7)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 15)),
                let updatedAt = dateFormatter.date(from: Self.text(statement, 16))
            else { return nil }
            return RuntimeCandidate(
                id: id,
                technologyID: Self.text(statement, 1),
                appID: Self.optionalText(statement, 2),
                targetVersion: Self.text(statement, 3),
                scope: scope,
                objective: Self.text(statement, 5),
                state: state,
                sourceURL: sourceURL,
                sourceFingerprint: Self.optionalText(statement, 8),
                sourceVerified: Self.optionalInt(statement, 9) == 1,
                isIsolated: Self.optionalInt(statement, 10) == 1,
                rollbackReference: Self.optionalText(statement, 11),
                baselineEngineFingerprint: Self.optionalText(statement, 12),
                candidateEngineFingerprint: Self.optionalText(statement, 13),
                validationMatrixPassed: Self.optionalInt(statement, 14) == 1,
                createdAt: createdAt,
                updatedAt: updatedAt,
                notes: Self.text(statement, 17)
            )
        }
    }

    public func runtimeCandidateCount(activeOnly: Bool = false) throws -> Int {
        try ensurePrepared()
        let filter = activeOnly
            ? "WHERE state NOT IN ('rejected','retired','promoted')"
            : ""
        return try scalarInt("SELECT COUNT(*) FROM runtime_candidates \(filter);")
    }

    public func promoteRuntimeCandidate(id: UUID) throws {
        try ensurePrepared()
        guard let candidate = try runtimeCandidates().first(where: { $0.id == id }) else {
            throw RegressionCoreError.invalidEvidence("no existe el candidato solicitado")
        }
        let decision = RuntimeSelectionPolicy.promotionDecision(
            for: candidate,
            assessments: try optimizationAssessments(appID: candidate.appID),
            technology: try runtimeTechnologies().first { $0.id == candidate.technologyID }
        )
        guard decision.isEligible else {
            throw RegressionCoreError.invalidEvidence(decision.blockers.joined(separator: " "))
        }
        try execute(
            "UPDATE runtime_candidates SET state='promoted', updated_at=? WHERE id=?;",
            bindings: [dateFormatter.string(from: Date()), id.uuidString]
        )
    }

    public func recordOptimizationAssessment(_ assessment: OptimizationAssessment) throws {
        try ensurePrepared()
        let metrics = [
            assessment.averageFPS,
            assessment.onePercentLowFPS,
            assessment.frameTimeP95Milliseconds
        ].compactMap { $0 }
        guard metrics.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1_000_000 }) else {
            throw RegressionCoreError.invalidEvidence(
                "las métricas deben ser finitas, positivas y estar dentro de un rango válido"
            )
        }
        if assessment.state == .bestKnown,
           (!assessment.hasMeasuredPerformance
            || assessment.resolution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            || assessment.qualityPreset?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
            throw RegressionCoreError.invalidEvidence(
                "una opción óptima necesita métricas, resolución y preset comparables"
            )
        }
        try execute(
            """
            INSERT INTO optimization_assessments(
                id, app_id, backend, engine_fingerprint, candidate_id, state,
                resolution, quality_preset, average_fps, one_percent_low_fps,
                frame_time_p95_ms, notes, measured_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                app_id=excluded.app_id,
                backend=excluded.backend,
                engine_fingerprint=excluded.engine_fingerprint,
                candidate_id=excluded.candidate_id,
                state=excluded.state,
                resolution=excluded.resolution,
                quality_preset=excluded.quality_preset,
                average_fps=excluded.average_fps,
                one_percent_low_fps=excluded.one_percent_low_fps,
                frame_time_p95_ms=excluded.frame_time_p95_ms,
                notes=excluded.notes,
                measured_at=excluded.measured_at;
            """,
            bindings: [
                assessment.id.uuidString,
                assessment.appID,
                assessment.backend.rawValue,
                assessment.engineFingerprint,
                assessment.candidateID?.uuidString ?? NSNull(),
                assessment.state.rawValue,
                assessment.resolution ?? NSNull(),
                assessment.qualityPreset ?? NSNull(),
                assessment.averageFPS ?? NSNull(),
                assessment.onePercentLowFPS ?? NSNull(),
                assessment.frameTimeP95Milliseconds ?? NSNull(),
                PrivacySanitizer.redactedLogExcerpt(assessment.notes, limit: 2_000),
                dateFormatter.string(from: assessment.measuredAt)
            ]
        )
    }

    public func optimizationAssessments(
        appID: String? = nil,
        candidateID: UUID? = nil
    ) throws -> [OptimizationAssessment] {
        try ensurePrepared()
        var predicates: [String] = []
        var bindings: [Any] = []
        if let appID {
            predicates.append("app_id=?")
            bindings.append(appID)
        }
        if let candidateID {
            predicates.append("candidate_id=?")
            bindings.append(candidateID.uuidString)
        }
        let filter = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        return try query(
            """
            SELECT id, app_id, backend, engine_fingerprint, candidate_id, state,
                   resolution, quality_preset, average_fps, one_percent_low_fps,
                   frame_time_p95_ms, notes, measured_at
            FROM optimization_assessments
            \(filter)
            ORDER BY measured_at DESC;
            """,
            bindings: bindings
        ) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let backend = BackendKind(rawValue: Self.text(statement, 2)),
                let state = OptimizationAssessmentState(rawValue: Self.text(statement, 5)),
                let measuredAt = dateFormatter.date(from: Self.text(statement, 12))
            else { return nil }
            return OptimizationAssessment(
                id: id,
                appID: Self.text(statement, 1),
                backend: backend,
                engineFingerprint: Self.text(statement, 3),
                candidateID: Self.optionalText(statement, 4).flatMap(UUID.init(uuidString:)),
                state: state,
                resolution: Self.optionalText(statement, 6),
                qualityPreset: Self.optionalText(statement, 7),
                averageFPS: Self.optionalDouble(statement, 8),
                onePercentLowFPS: Self.optionalDouble(statement, 9),
                frameTimeP95Milliseconds: Self.optionalDouble(statement, 10),
                notes: Self.text(statement, 11),
                measuredAt: measuredAt
            )
        }
    }

    public func recordRuntimeRequirement(_ requirement: GameRuntimeRequirement) throws {
        try ensurePrepared()
        try execute(
            """
            INSERT INTO game_runtime_requirements(
                app_id, kind, identifier, version_constraint, source, notes, observed_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(app_id, kind, identifier) DO UPDATE SET
                version_constraint=excluded.version_constraint,
                source=excluded.source,
                notes=excluded.notes,
                observed_at=excluded.observed_at;
            """,
            bindings: [
                requirement.appID,
                requirement.kind.rawValue,
                requirement.identifier,
                requirement.versionConstraint ?? NSNull(),
                requirement.source.rawValue,
                PrivacySanitizer.redactedLogExcerpt(requirement.notes, limit: 2_000),
                dateFormatter.string(from: requirement.observedAt)
            ]
        )
    }

    public func runtimeRequirements(appID: String? = nil) throws -> [GameRuntimeRequirement] {
        try ensurePrepared()
        let filter = appID == nil ? "" : "WHERE app_id=?"
        let bindings: [Any] = appID.map { [$0] } ?? []
        return try query(
            """
            SELECT app_id, kind, identifier, version_constraint, source, notes, observed_at
            FROM game_runtime_requirements
            \(filter)
            ORDER BY app_id, kind, identifier;
            """,
            bindings: bindings
        ) { statement in
            guard
                let kind = RuntimeRequirementKind(rawValue: Self.text(statement, 1)),
                let source = VerificationSource(rawValue: Self.text(statement, 4)),
                let observedAt = dateFormatter.date(from: Self.text(statement, 6))
            else { return nil }
            return GameRuntimeRequirement(
                appID: Self.text(statement, 0),
                kind: kind,
                identifier: Self.text(statement, 2),
                versionConstraint: Self.optionalText(statement, 3),
                source: source,
                notes: Self.text(statement, 5),
                observedAt: observedAt
            )
        }
    }

    public func recordRepairReceipt(_ receipt: RepairReceipt) throws {
        try ensurePrepared()
        guard receipt.recipeVersion > 0,
              !receipt.recipeID.isEmpty,
              !receipt.rollbackReference.isEmpty else {
            throw RegressionCoreError.invalidEvidence(
                "un recibo de reparación exige receta versionada y rollback"
            )
        }
        try execute(
            """
            INSERT INTO repair_receipts(
                id, app_id, backend, recipe_id, recipe_version,
                before_fingerprint, after_fingerprint, rollback_reference,
                result, notes, created_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                receipt.id.uuidString,
                receipt.appID,
                receipt.backend.rawValue,
                receipt.recipeID,
                receipt.recipeVersion,
                receipt.beforeFingerprint,
                receipt.afterFingerprint ?? NSNull(),
                receipt.rollbackReference,
                receipt.result.rawValue,
                PrivacySanitizer.redactedLogExcerpt(receipt.notes, limit: 2_000),
                dateFormatter.string(from: receipt.createdAt)
            ]
        )
    }

    public func repairReceipts(appID: String? = nil) throws -> [RepairReceipt] {
        try ensurePrepared()
        let filter = appID == nil ? "" : "WHERE app_id=?"
        let bindings: [Any] = appID.map { [$0] } ?? []
        return try query(
            """
            SELECT id, app_id, backend, recipe_id, recipe_version,
                   before_fingerprint, after_fingerprint, rollback_reference,
                   result, notes, created_at
            FROM repair_receipts
            \(filter)
            ORDER BY created_at DESC;
            """,
            bindings: bindings
        ) { statement in
            guard
                let id = UUID(uuidString: Self.text(statement, 0)),
                let backend = BackendKind(rawValue: Self.text(statement, 2)),
                let result = RepairReceiptResult(rawValue: Self.text(statement, 8)),
                let createdAt = dateFormatter.date(from: Self.text(statement, 10))
            else { return nil }
            return RepairReceipt(
                id: id,
                appID: Self.text(statement, 1),
                backend: backend,
                recipeID: Self.text(statement, 3),
                recipeVersion: Self.optionalInt(statement, 4) ?? 0,
                beforeFingerprint: Self.text(statement, 5),
                afterFingerprint: Self.optionalText(statement, 6),
                rollbackReference: Self.text(statement, 7),
                result: result,
                notes: Self.text(statement, 9),
                createdAt: createdAt
            )
        }
    }

    func validateRuntimeEvolutionData() throws {
        let invalidPromotions = try scalarInt(
            """
            SELECT COUNT(*) FROM runtime_candidates c
            WHERE c.state='promoted' AND (
                c.scope!='perGame' OR c.app_id IS NULL
                OR (SELECT update_policy FROM runtime_technologies t WHERE t.id=c.technology_id)!='candidateOnly'
                OR lower(c.source_url) NOT LIKE 'https://%'
                OR c.source_verified!=1 OR c.source_fingerprint IS NULL OR c.source_fingerprint=''
                OR c.is_isolated!=1 OR c.rollback_reference IS NULL OR c.rollback_reference=''
                OR c.baseline_engine_fingerprint IS NULL OR c.baseline_engine_fingerprint=''
                OR c.candidate_engine_fingerprint IS NULL OR c.candidate_engine_fingerprint=''
                OR c.baseline_engine_fingerprint=c.candidate_engine_fingerprint
                OR c.validation_matrix_passed!=1
                OR NOT EXISTS (
                    SELECT 1
                    FROM optimization_assessments candidate
                    JOIN optimization_assessments baseline
                      ON baseline.app_id=c.app_id
                     AND baseline.backend='regression'
                     AND baseline.engine_fingerprint=c.baseline_engine_fingerprint
                     AND baseline.state IN ('baselineMeasured','bestKnown')
                    WHERE candidate.candidate_id=c.id AND candidate.app_id=c.app_id
                      AND candidate.backend='regression'
                      AND candidate.engine_fingerprint=c.candidate_engine_fingerprint
                      AND candidate.state='bestKnown'
                      AND candidate.resolution IS NOT NULL
                      AND baseline.resolution IS NOT NULL
                      AND lower(trim(candidate.resolution))=lower(trim(baseline.resolution))
                      AND candidate.quality_preset IS NOT NULL
                      AND baseline.quality_preset IS NOT NULL
                      AND lower(trim(candidate.quality_preset))=lower(trim(baseline.quality_preset))
                      AND (candidate.average_fps IS NULL)=(baseline.average_fps IS NULL)
                      AND (candidate.one_percent_low_fps IS NULL)=(baseline.one_percent_low_fps IS NULL)
                      AND (candidate.frame_time_p95_ms IS NULL)=(baseline.frame_time_p95_ms IS NULL)
                      AND (candidate.average_fps IS NULL OR baseline.average_fps IS NULL
                           OR candidate.average_fps>=baseline.average_fps)
                      AND (candidate.one_percent_low_fps IS NULL OR baseline.one_percent_low_fps IS NULL
                           OR candidate.one_percent_low_fps>=baseline.one_percent_low_fps)
                      AND (candidate.frame_time_p95_ms IS NULL OR baseline.frame_time_p95_ms IS NULL
                           OR candidate.frame_time_p95_ms<=baseline.frame_time_p95_ms)
                      AND (
                          (candidate.average_fps IS NOT NULL AND baseline.average_fps IS NOT NULL
                           AND candidate.average_fps>baseline.average_fps)
                          OR (candidate.one_percent_low_fps IS NOT NULL
                              AND baseline.one_percent_low_fps IS NOT NULL
                              AND candidate.one_percent_low_fps>baseline.one_percent_low_fps)
                          OR (candidate.frame_time_p95_ms IS NOT NULL
                              AND baseline.frame_time_p95_ms IS NOT NULL
                              AND candidate.frame_time_p95_ms<baseline.frame_time_p95_ms)
                      )
                )
            );
            """
        )
        let invalidBestKnown = try scalarInt(
            """
            SELECT COUNT(*) FROM optimization_assessments
            WHERE state='bestKnown' AND (
                (average_fps IS NULL AND one_percent_low_fps IS NULL AND frame_time_p95_ms IS NULL)
                OR resolution IS NULL OR trim(resolution)=''
                OR quality_preset IS NULL OR trim(quality_preset)=''
            );
            """
        )
        let invalidMeasurements = try scalarInt(
            """
            SELECT COUNT(*) FROM optimization_assessments WHERE
                (average_fps IS NOT NULL AND (average_fps<=0 OR average_fps>=1000000))
                OR (one_percent_low_fps IS NOT NULL
                    AND (one_percent_low_fps<=0 OR one_percent_low_fps>=1000000))
                OR (frame_time_p95_ms IS NOT NULL
                    AND (frame_time_p95_ms<=0 OR frame_time_p95_ms>=1000000));
            """
        )
        guard invalidPromotions == 0,
              invalidBestKnown == 0,
              invalidMeasurements == 0 else {
            throw RegressionCoreError.database(
                "Hay candidatos promovidos o métricas óptimas sin evidencia suficiente"
            )
        }
    }

    private func candidateBindings(_ candidate: RuntimeCandidate) -> [Any] {
        [
            candidate.id.uuidString,
            candidate.technologyID,
            candidate.appID ?? NSNull(),
            candidate.targetVersion,
            candidate.scope.rawValue,
            PrivacySanitizer.redactedLogExcerpt(candidate.objective, limit: 1_000),
            candidate.state.rawValue,
            candidate.sourceURL.absoluteString,
            candidate.sourceFingerprint ?? NSNull(),
            candidate.sourceVerified,
            candidate.isIsolated,
            candidate.rollbackReference ?? NSNull(),
            candidate.baselineEngineFingerprint ?? NSNull(),
            candidate.candidateEngineFingerprint ?? NSNull(),
            candidate.validationMatrixPassed,
            dateFormatter.string(from: candidate.createdAt),
            dateFormatter.string(from: candidate.updatedAt),
            PrivacySanitizer.redactedLogExcerpt(candidate.notes, limit: 2_000)
        ]
    }
}

enum RuntimeEvolutionSchema {
    static let metricIntegritySQL = """
        DROP TRIGGER IF EXISTS optimization_best_known_requires_measurement_insert;
        DROP TRIGGER IF EXISTS optimization_best_known_requires_measurement_update;
        DROP TRIGGER IF EXISTS optimization_measurement_integrity_insert;
        DROP TRIGGER IF EXISTS optimization_measurement_integrity_update;

        CREATE TRIGGER optimization_measurement_integrity_insert
        BEFORE INSERT ON optimization_assessments
        WHEN
            (NEW.average_fps IS NOT NULL AND (NEW.average_fps<=0 OR NEW.average_fps>=1000000))
            OR (NEW.one_percent_low_fps IS NOT NULL
                AND (NEW.one_percent_low_fps<=0 OR NEW.one_percent_low_fps>=1000000))
            OR (NEW.frame_time_p95_ms IS NOT NULL
                AND (NEW.frame_time_p95_ms<=0 OR NEW.frame_time_p95_ms>=1000000))
            OR (NEW.state='bestKnown' AND (
                (NEW.average_fps IS NULL AND NEW.one_percent_low_fps IS NULL
                 AND NEW.frame_time_p95_ms IS NULL)
                OR NEW.resolution IS NULL OR trim(NEW.resolution)=''
                OR NEW.quality_preset IS NULL OR trim(NEW.quality_preset)=''
            ))
        BEGIN
            SELECT RAISE(ABORT, 'optimization assessment lacks valid comparable metrics');
        END;

        CREATE TRIGGER optimization_measurement_integrity_update
        BEFORE UPDATE ON optimization_assessments
        WHEN
            (NEW.average_fps IS NOT NULL AND (NEW.average_fps<=0 OR NEW.average_fps>=1000000))
            OR (NEW.one_percent_low_fps IS NOT NULL
                AND (NEW.one_percent_low_fps<=0 OR NEW.one_percent_low_fps>=1000000))
            OR (NEW.frame_time_p95_ms IS NOT NULL
                AND (NEW.frame_time_p95_ms<=0 OR NEW.frame_time_p95_ms>=1000000))
            OR (NEW.state='bestKnown' AND (
                (NEW.average_fps IS NULL AND NEW.one_percent_low_fps IS NULL
                 AND NEW.frame_time_p95_ms IS NULL)
                OR NEW.resolution IS NULL OR trim(NEW.resolution)=''
                OR NEW.quality_preset IS NULL OR trim(NEW.quality_preset)=''
            ))
        BEGIN
            SELECT RAISE(ABORT, 'optimization assessment lacks valid comparable metrics');
        END;
        """

    static let promotionGuardsSQL = """
        DROP TRIGGER IF EXISTS runtime_candidate_promotion_guard_insert;
        DROP TRIGGER IF EXISTS runtime_candidate_promotion_guard_update;

        CREATE TRIGGER runtime_candidate_promotion_guard_insert
        BEFORE INSERT ON runtime_candidates
        WHEN NEW.state='promoted' AND (
            NEW.scope!='perGame' OR NEW.app_id IS NULL
            OR (SELECT update_policy FROM runtime_technologies t WHERE t.id=NEW.technology_id)!='candidateOnly'
            OR lower(NEW.source_url) NOT LIKE 'https://%'
            OR NEW.source_verified!=1 OR NEW.source_fingerprint IS NULL OR NEW.source_fingerprint=''
            OR NEW.is_isolated!=1 OR NEW.rollback_reference IS NULL OR NEW.rollback_reference=''
            OR NEW.baseline_engine_fingerprint IS NULL OR NEW.baseline_engine_fingerprint=''
            OR NEW.candidate_engine_fingerprint IS NULL OR NEW.candidate_engine_fingerprint=''
            OR NEW.baseline_engine_fingerprint=NEW.candidate_engine_fingerprint
            OR NEW.validation_matrix_passed!=1
            OR NOT EXISTS (
                SELECT 1
                FROM optimization_assessments candidate
                JOIN optimization_assessments baseline
                  ON baseline.app_id=NEW.app_id
                 AND baseline.backend='regression'
                 AND baseline.engine_fingerprint=NEW.baseline_engine_fingerprint
                 AND baseline.state IN ('baselineMeasured','bestKnown')
                WHERE candidate.candidate_id=NEW.id AND candidate.app_id=NEW.app_id
                  AND candidate.backend='regression'
                  AND candidate.engine_fingerprint=NEW.candidate_engine_fingerprint
                  AND candidate.state='bestKnown'
                  AND candidate.resolution IS NOT NULL
                  AND baseline.resolution IS NOT NULL
                  AND lower(trim(candidate.resolution))=lower(trim(baseline.resolution))
                  AND candidate.quality_preset IS NOT NULL
                  AND baseline.quality_preset IS NOT NULL
                  AND lower(trim(candidate.quality_preset))=lower(trim(baseline.quality_preset))
                  AND (candidate.average_fps IS NULL)=(baseline.average_fps IS NULL)
                  AND (candidate.one_percent_low_fps IS NULL)=(baseline.one_percent_low_fps IS NULL)
                  AND (candidate.frame_time_p95_ms IS NULL)=(baseline.frame_time_p95_ms IS NULL)
                  AND (candidate.average_fps IS NULL OR baseline.average_fps IS NULL
                       OR candidate.average_fps>=baseline.average_fps)
                  AND (candidate.one_percent_low_fps IS NULL OR baseline.one_percent_low_fps IS NULL
                       OR candidate.one_percent_low_fps>=baseline.one_percent_low_fps)
                  AND (candidate.frame_time_p95_ms IS NULL OR baseline.frame_time_p95_ms IS NULL
                       OR candidate.frame_time_p95_ms<=baseline.frame_time_p95_ms)
                  AND (
                      (candidate.average_fps IS NOT NULL AND baseline.average_fps IS NOT NULL
                       AND candidate.average_fps>baseline.average_fps)
                      OR (candidate.one_percent_low_fps IS NOT NULL
                          AND baseline.one_percent_low_fps IS NOT NULL
                          AND candidate.one_percent_low_fps>baseline.one_percent_low_fps)
                      OR (candidate.frame_time_p95_ms IS NOT NULL
                          AND baseline.frame_time_p95_ms IS NOT NULL
                          AND candidate.frame_time_p95_ms<baseline.frame_time_p95_ms)
                  )
            )
        )
        BEGIN
            SELECT RAISE(ABORT, 'runtime candidate promotion lacks comparable improvement');
        END;

        CREATE TRIGGER runtime_candidate_promotion_guard_update
        BEFORE UPDATE OF state ON runtime_candidates
        WHEN NEW.state='promoted' AND (
            NEW.scope!='perGame' OR NEW.app_id IS NULL
            OR (SELECT update_policy FROM runtime_technologies t WHERE t.id=NEW.technology_id)!='candidateOnly'
            OR lower(NEW.source_url) NOT LIKE 'https://%'
            OR NEW.source_verified!=1 OR NEW.source_fingerprint IS NULL OR NEW.source_fingerprint=''
            OR NEW.is_isolated!=1 OR NEW.rollback_reference IS NULL OR NEW.rollback_reference=''
            OR NEW.baseline_engine_fingerprint IS NULL OR NEW.baseline_engine_fingerprint=''
            OR NEW.candidate_engine_fingerprint IS NULL OR NEW.candidate_engine_fingerprint=''
            OR NEW.baseline_engine_fingerprint=NEW.candidate_engine_fingerprint
            OR NEW.validation_matrix_passed!=1
            OR NOT EXISTS (
                SELECT 1
                FROM optimization_assessments candidate
                JOIN optimization_assessments baseline
                  ON baseline.app_id=NEW.app_id
                 AND baseline.backend='regression'
                 AND baseline.engine_fingerprint=NEW.baseline_engine_fingerprint
                 AND baseline.state IN ('baselineMeasured','bestKnown')
                WHERE candidate.candidate_id=NEW.id AND candidate.app_id=NEW.app_id
                  AND candidate.backend='regression'
                  AND candidate.engine_fingerprint=NEW.candidate_engine_fingerprint
                  AND candidate.state='bestKnown'
                  AND candidate.resolution IS NOT NULL
                  AND baseline.resolution IS NOT NULL
                  AND lower(trim(candidate.resolution))=lower(trim(baseline.resolution))
                  AND candidate.quality_preset IS NOT NULL
                  AND baseline.quality_preset IS NOT NULL
                  AND lower(trim(candidate.quality_preset))=lower(trim(baseline.quality_preset))
                  AND (candidate.average_fps IS NULL)=(baseline.average_fps IS NULL)
                  AND (candidate.one_percent_low_fps IS NULL)=(baseline.one_percent_low_fps IS NULL)
                  AND (candidate.frame_time_p95_ms IS NULL)=(baseline.frame_time_p95_ms IS NULL)
                  AND (candidate.average_fps IS NULL OR baseline.average_fps IS NULL
                       OR candidate.average_fps>=baseline.average_fps)
                  AND (candidate.one_percent_low_fps IS NULL OR baseline.one_percent_low_fps IS NULL
                       OR candidate.one_percent_low_fps>=baseline.one_percent_low_fps)
                  AND (candidate.frame_time_p95_ms IS NULL OR baseline.frame_time_p95_ms IS NULL
                       OR candidate.frame_time_p95_ms<=baseline.frame_time_p95_ms)
                  AND (
                      (candidate.average_fps IS NOT NULL AND baseline.average_fps IS NOT NULL
                       AND candidate.average_fps>baseline.average_fps)
                      OR (candidate.one_percent_low_fps IS NOT NULL
                          AND baseline.one_percent_low_fps IS NOT NULL
                          AND candidate.one_percent_low_fps>baseline.one_percent_low_fps)
                      OR (candidate.frame_time_p95_ms IS NOT NULL
                          AND baseline.frame_time_p95_ms IS NOT NULL
                          AND candidate.frame_time_p95_ms<baseline.frame_time_p95_ms)
                  )
            )
        )
        BEGIN
            SELECT RAISE(ABORT, 'runtime candidate promotion lacks comparable improvement');
        END;
        """

    static let sql = """
        CREATE TABLE IF NOT EXISTS runtime_technologies(
            id TEXT PRIMARY KEY,
            display_name TEXT NOT NULL,
            category TEXT NOT NULL CHECK(category IN (
                'cpuTranslation','windowsRuntime','graphicsTranslation','vulkanRuntime','referenceRuntime'
            )),
            official_url TEXT NOT NULL,
            release_url TEXT,
            distribution_policy TEXT NOT NULL CHECK(distribution_policy IN (
                'openSource','localUserProvided','systemProvided','licensedReference'
            )),
            update_policy TEXT NOT NULL CHECK(update_policy IN (
                'pinnedStable','candidateOnly','systemManaged','referenceOnly'
            )),
            stable_version TEXT,
            latest_known_version TEXT,
            checked_at TEXT NOT NULL,
            catalog_revision TEXT NOT NULL,
            notes TEXT NOT NULL,
            synced_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS runtime_candidates(
            id TEXT PRIMARY KEY,
            technology_id TEXT NOT NULL REFERENCES runtime_technologies(id),
            app_id TEXT REFERENCES games(app_id) ON DELETE CASCADE,
            target_version TEXT NOT NULL,
            scope TEXT NOT NULL CHECK(scope IN ('perGame','globalResearch')),
            objective TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state IN (
                'discovered','staged','testing','validated','promoted','rejected','retired'
            )),
            source_url TEXT NOT NULL,
            source_fingerprint TEXT,
            source_verified INTEGER NOT NULL CHECK(source_verified IN (0,1)),
            is_isolated INTEGER NOT NULL CHECK(is_isolated IN (0,1)),
            rollback_reference TEXT,
            baseline_engine_fingerprint TEXT,
            candidate_engine_fingerprint TEXT,
            validation_matrix_passed INTEGER NOT NULL CHECK(validation_matrix_passed IN (0,1)),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            notes TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS runtime_candidates_game_state_idx
            ON runtime_candidates(app_id, state, updated_at DESC);
        CREATE INDEX IF NOT EXISTS runtime_candidates_technology_idx
            ON runtime_candidates(technology_id, state);

        CREATE TABLE IF NOT EXISTS optimization_assessments(
            id TEXT PRIMARY KEY,
            app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE CASCADE,
            backend TEXT NOT NULL CHECK(backend IN ('crossOver','regression')),
            engine_fingerprint TEXT NOT NULL,
            candidate_id TEXT REFERENCES runtime_candidates(id) ON DELETE SET NULL,
            state TEXT NOT NULL CHECK(state IN (
                'unmeasured','baselineMeasured','candidateMeasured','bestKnown','regressed'
            )),
            resolution TEXT,
            quality_preset TEXT,
            average_fps REAL CHECK(average_fps IS NULL OR average_fps >= 0),
            one_percent_low_fps REAL CHECK(one_percent_low_fps IS NULL OR one_percent_low_fps >= 0),
            frame_time_p95_ms REAL CHECK(frame_time_p95_ms IS NULL OR frame_time_p95_ms >= 0),
            notes TEXT NOT NULL,
            measured_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS optimization_assessments_game_idx
            ON optimization_assessments(app_id, state, measured_at DESC);
        CREATE INDEX IF NOT EXISTS optimization_assessments_candidate_idx
            ON optimization_assessments(candidate_id, state);

        CREATE TABLE IF NOT EXISTS game_runtime_requirements(
            app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE CASCADE,
            kind TEXT NOT NULL CHECK(kind IN (
                'runtimeComponent','graphicsBackend','architecture','dependency','permission'
            )),
            identifier TEXT NOT NULL,
            version_constraint TEXT,
            source TEXT NOT NULL CHECK(source IN ('automatic','user','visualInspection','imported')),
            notes TEXT NOT NULL,
            observed_at TEXT NOT NULL,
            PRIMARY KEY(app_id, kind, identifier)
        );

        CREATE TABLE IF NOT EXISTS repair_receipts(
            id TEXT PRIMARY KEY,
            app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE CASCADE,
            backend TEXT NOT NULL CHECK(backend IN ('crossOver','regression')),
            recipe_id TEXT NOT NULL CHECK(recipe_id!=''),
            recipe_version INTEGER NOT NULL CHECK(recipe_version > 0),
            before_fingerprint TEXT NOT NULL CHECK(before_fingerprint!=''),
            after_fingerprint TEXT,
            rollback_reference TEXT NOT NULL CHECK(rollback_reference!=''),
            result TEXT NOT NULL CHECK(result IN ('succeeded','failed','rolledBack')),
            notes TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS repair_receipts_game_idx
            ON repair_receipts(app_id, created_at DESC);

        \(metricIntegritySQL)
        \(promotionGuardsSQL)
        """
}
