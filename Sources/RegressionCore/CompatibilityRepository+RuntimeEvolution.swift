import CSQLite
import Foundation

extension CompatibilityRepository {
    func inventoryLegacyCompiledRepairActivationsIfAvailable() throws {
        guard let bottleURL = legacyCompiledRepairBottleURL,
              let snapshot = try CompiledRepairActivationStore.legacySnapshot(in: bottleURL) else {
            return
        }
        let observedAt = dateFormatter.string(from: Date())
        for activation in snapshot.activations {
            try execute(
                """
                INSERT OR IGNORE INTO legacy_repair_activation_inventory(
                    id, executable, recipe_id, state, source_fingerprint, observed_at
                ) VALUES(?, ?, ?, 'legacyAppliedUnverified', ?, ?);
                """,
                bindings: [
                    UUID().uuidString,
                    activation.executable,
                    activation.recipe.rawValue,
                    snapshot.fingerprint,
                    observedAt
                ]
            )
        }
        try CompiledRepairActivationStore.quarantineLegacyActivation(
            expectedFingerprint: snapshot.fingerprint,
            in: bottleURL
        )
    }

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
            WHERE id != ?
            ORDER BY category, display_name COLLATE NOCASE;
            """,
            bindings: [RuntimeTechnologyCatalog.retiredCrossOverTechnologyID]
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
        guard let normalizedAppID = SteamAppID.normalized(requirement.appID),
              normalizedAppID == requirement.appID,
              !requirement.identifier.isEmpty,
              requirement.identifier.utf8.count <= 160 else {
            throw RegressionCoreError.invalidEvidence(
                "el requisito de runtime no es canónico"
            )
        }
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

    /// Sustituye únicamente la proyección automática de un juego después de un escaneo completo.
    /// Compatibilidad para consumidores existentes; el momento de la generación se toma aquí.
    public func replaceAutomaticRuntimeRequirements(
        appID: String,
        with requirements: [GameRuntimeRequirement]
    ) throws {
        try recordSuccessfulGameTechnologyScan(
            appID: appID,
            requirements: requirements,
            scannedAt: Date()
        )
    }

    /// Publica una generación automática completa y su estado actual en una única transacción.
    /// Las observaciones humanas/importadas se conservan.
    public func recordSuccessfulGameTechnologyScan(
        appID: String,
        requirements: [GameRuntimeRequirement],
        scannedAt: Date = Date()
    ) throws {
        try ensurePrepared()
        guard let normalizedAppID = SteamAppID.normalized(appID),
              requirements.allSatisfy({
                  $0.appID == normalizedAppID
                    && $0.source == .automatic
                    && !$0.identifier.isEmpty
                    && $0.identifier.utf8.count <= 160
              }),
              Set(requirements.map(\.id)).count == requirements.count else {
            throw RegressionCoreError.invalidEvidence(
                "la proyección automática de requisitos no es canónica"
            )
        }
        try ensureGameTechnologyScanStateSchema()
        try transaction {
            let generation = try nextGameTechnologyScanGeneration(appID: normalizedAppID)
            try execute(
                "DELETE FROM game_runtime_requirements WHERE app_id=? AND source=?;",
                bindings: [normalizedAppID, VerificationSource.automatic.rawValue]
            )
            for requirement in requirements {
                try execute(
                    """
                    INSERT INTO game_runtime_requirements(
                        app_id, kind, identifier, version_constraint, source, notes, observed_at
                    ) VALUES(?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(app_id, kind, identifier) DO UPDATE SET
                        version_constraint=excluded.version_constraint,
                        notes=excluded.notes,
                        observed_at=excluded.observed_at
                    WHERE game_runtime_requirements.source=?;
                    """,
                    bindings: [
                        requirement.appID,
                        requirement.kind.rawValue,
                        requirement.identifier,
                        requirement.versionConstraint ?? NSNull(),
                        requirement.source.rawValue,
                        PrivacySanitizer.redactedLogExcerpt(
                            requirement.notes,
                            limit: 2_000
                        ),
                        dateFormatter.string(from: requirement.observedAt),
                        VerificationSource.automatic.rawValue,
                    ]
                )
            }
            let timestamp = dateFormatter.string(from: scannedAt)
            try execute(
                """
                INSERT INTO game_technology_scan_states(
                    app_id, generation, last_successful_generation, freshness,
                    attempted_at, last_successful_at, error
                ) VALUES(?, ?, ?, 'current', ?, ?, NULL)
                ON CONFLICT(app_id) DO UPDATE SET
                    generation=excluded.generation,
                    last_successful_generation=excluded.last_successful_generation,
                    freshness='current',
                    attempted_at=excluded.attempted_at,
                    last_successful_at=excluded.last_successful_at,
                    error=NULL;
                """,
                bindings: [normalizedAppID, generation, generation, timestamp, timestamp]
            )
        }
    }

    /// Conserva la última generación buena, pero la retira explícitamente de la proyección
    /// vigente. El texto de error se sanea y nunca se interpreta como una acción.
    public func recordFailedGameTechnologyScan(
        appID: String,
        error: String,
        attemptedAt: Date = Date()
    ) throws {
        try ensurePrepared()
        guard let normalizedAppID = SteamAppID.normalized(appID) else {
            throw RegressionCoreError.invalidEvidence(
                "el Steam App ID del inventario fallido no es válido"
            )
        }
        try ensureGameTechnologyScanStateSchema()
        var safeError = PrivacySanitizer.redactedLogExcerpt(error, limit: 1_000)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if safeError.isEmpty {
            safeError = "Error de inventario no especificado."
        }
        try transaction {
            let generation = try nextGameTechnologyScanGeneration(appID: normalizedAppID)
            try execute(
                """
                INSERT INTO game_technology_scan_states(
                    app_id, generation, last_successful_generation, freshness,
                    attempted_at, last_successful_at, error
                ) VALUES(?, ?, NULL, 'stale', ?, NULL, ?)
                ON CONFLICT(app_id) DO UPDATE SET
                    generation=excluded.generation,
                    freshness='stale',
                    attempted_at=excluded.attempted_at,
                    error=excluded.error;
                """,
                bindings: [
                    normalizedAppID,
                    generation,
                    dateFormatter.string(from: attemptedAt),
                    safeError,
                ]
            )
        }
    }

    public func gameTechnologyScanState(
        appID: String
    ) throws -> GameTechnologyScanState? {
        try ensurePrepared()
        guard let normalizedAppID = SteamAppID.normalized(appID) else {
            throw RegressionCoreError.invalidEvidence(
                "el Steam App ID del estado de inventario no es válido"
            )
        }
        try ensureGameTechnologyScanStateSchema()
        let states: [GameTechnologyScanState] = try query(
            """
            SELECT app_id, generation, last_successful_generation, freshness,
                   attempted_at, last_successful_at, error
            FROM game_technology_scan_states
            WHERE app_id=?;
            """,
            bindings: [normalizedAppID]
        ) { statement in
            guard
                let freshness = GameTechnologyScanFreshness(
                    rawValue: Self.text(statement, 3)
                ),
                let attemptedAt = dateFormatter.date(from: Self.text(statement, 4))
            else { return nil }
            return GameTechnologyScanState(
                appID: Self.text(statement, 0),
                generation: Int(Self.optionalInt(statement, 1) ?? 0),
                lastSuccessfulGeneration: Self.optionalInt(statement, 2),
                freshness: freshness,
                attemptedAt: attemptedAt,
                lastSuccessfulAt: Self.optionalText(statement, 5).flatMap(
                    dateFormatter.date(from:)
                ),
                error: Self.optionalText(statement, 6)
            )
        }
        return states.first
    }

    public func gameTechnologyRequirementProjection(
        appID: String
    ) throws -> GameTechnologyRequirementProjection {
        let state = try gameTechnologyScanState(appID: appID)
        let requirements = try storedRuntimeRequirements(appID: appID).map(
            GameRuntimeRequirementResolver.resolve
        )
        return GameTechnologyRequirementProjection(
            scanState: state,
            requirements: requirements
        )
    }

    public func runtimeRequirements(appID: String? = nil) throws -> [GameRuntimeRequirement] {
        if let appID {
            guard let normalizedAppID = SteamAppID.normalized(appID),
                  normalizedAppID == appID else {
                throw RegressionCoreError.invalidEvidence(
                    "el Steam App ID de los requisitos no es válido"
                )
            }
        }
        let stored = try storedRuntimeRequirements(appID: appID)
        let currentAutomaticAppIDs: Set<String> = try Set(query(
            """
            SELECT app_id
            FROM game_technology_scan_states
            WHERE freshness='current';
            """
        ) { statement in
            Self.text(statement, 0)
        })
        return stored.filter { requirement in
            requirement.source != .automatic
                || currentAutomaticAppIDs.contains(requirement.appID)
        }
    }

    private func storedRuntimeRequirements(
        appID: String? = nil
    ) throws -> [GameRuntimeRequirement] {
        try ensurePrepared()
        try ensureGameTechnologyScanStateSchema()
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

    private func ensureGameTechnologyScanStateSchema() throws {
        try executeScript(RuntimeEvolutionSchema.gameTechnologyScanStateSQL)
    }

    private func nextGameTechnologyScanGeneration(appID: String) throws -> Int {
        try scalarInt(
            "SELECT COALESCE(MAX(generation), 0) + 1 "
                + "FROM game_technology_scan_states WHERE app_id=?;",
            bindings: [appID]
        )
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

    public func recordRepairAttempt(_ attempt: RepairAttempt) throws {
        try ensurePrepared()
        guard attempt.state == .detected,
              attempt.sourceRunID != nil,
              let appID = SteamAppID.normalized(attempt.appID),
              appID == attempt.appID,
              attempt.recipeVersion > 0,
              !attempt.executable.isEmpty,
              attempt.executable == attempt.executable.lowercased(),
              !attempt.executable.contains("/"),
              !attempt.executable.contains("\\"),
              attempt.executable.hasSuffix(".exe") else {
            throw RegressionCoreError.invalidEvidence(
                "un intento nuevo exige identidad cerrada y estado detectado"
            )
        }
        try validateRepairSource(attempt)
        let manifestJSON = try rollbackManifestJSON(attempt.rollbackManifest)
        let bindings: [Any] = [
            attempt.id.uuidString,
            attempt.sourceRunID?.uuidString ?? NSNull(),
            attempt.retryRunID?.uuidString ?? NSNull(),
            attempt.verificationID?.uuidString ?? NSNull(),
            appID,
            attempt.executable,
            attempt.launchOrigin.rawValue,
            attempt.recipe.rawValue,
            attempt.recipeVersion,
            attempt.state.rawValue,
            attempt.beforeFingerprint ?? NSNull(),
            attempt.afterFingerprint ?? NSNull(),
            attempt.rollbackReference ?? NSNull(),
            manifestJSON,
            attempt.appliedAt.map(dateFormatter.string(from:)) ?? NSNull(),
            PrivacySanitizer.redactedLogExcerpt(attempt.notes, limit: 2_000),
            dateFormatter.string(from: attempt.createdAt),
            dateFormatter.string(from: attempt.updatedAt)
        ]
        try execute(
            """
            INSERT INTO repair_attempts(
                id, source_run_id, retry_run_id, verification_id, app_id, executable,
                launch_origin, recipe_id, recipe_version, state, before_fingerprint,
                after_fingerprint, rollback_reference, rollback_manifest_json, applied_at,
                notes, created_at, updated_at
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: bindings
        )
    }

    public func repairAttempt(id: UUID) throws -> RepairAttempt? {
        try repairAttempts().first { $0.id == id }
    }

    public func activeRepairAttempt(
        appID: String,
        recipe: CompiledRepairRecipe
    ) throws -> RepairAttempt? {
        try repairAttempts(appID: appID, activeOnly: true).first { $0.recipe == recipe }
    }

    public func repairAttempts(
        appID: String? = nil,
        activeOnly: Bool = false
    ) throws -> [RepairAttempt] {
        try ensurePrepared()
        var predicates: [String] = []
        var bindings: [Any] = []
        if let appID {
            guard let normalized = SteamAppID.normalized(appID) else { return [] }
            predicates.append("app_id=?")
            bindings.append(normalized)
        }
        if activeOnly {
            predicates.append(
                "state IN ('detected','planned','appliedAwaitingRelaunch','relaunching'," +
                "'awaitingVerification','rollbackPending')"
            )
        }
        let filter = predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
        return try query(
            """
            SELECT id, source_run_id, retry_run_id, verification_id, app_id, executable,
                   launch_origin, recipe_id, recipe_version, state, before_fingerprint,
                   after_fingerprint, rollback_reference, rollback_manifest_json, applied_at,
                   notes, created_at, updated_at
            FROM repair_attempts
            \(filter)
            ORDER BY created_at DESC, id;
            """,
            bindings: bindings
        ) { statement in
            guard let id = UUID(uuidString: Self.text(statement, 0)),
                  let launchOrigin = RepairAttemptLaunchOrigin(rawValue: Self.text(statement, 6)),
                  let recipe = CompiledRepairRecipe(rawValue: Self.text(statement, 7)),
                  let state = RepairAttemptState(rawValue: Self.text(statement, 9)),
                  let createdAt = dateFormatter.date(from: Self.text(statement, 16)),
                  let updatedAt = dateFormatter.date(from: Self.text(statement, 17)) else {
                return nil
            }
            return RepairAttempt(
                id: id,
                sourceRunID: Self.optionalText(statement, 1).flatMap(UUID.init(uuidString:)),
                retryRunID: Self.optionalText(statement, 2).flatMap(UUID.init(uuidString:)),
                verificationID: Self.optionalText(statement, 3).flatMap(UUID.init(uuidString:)),
                appID: Self.text(statement, 4),
                executable: Self.text(statement, 5),
                launchOrigin: launchOrigin,
                recipe: recipe,
                recipeVersion: Self.optionalInt(statement, 8) ?? 0,
                state: state,
                beforeFingerprint: Self.optionalText(statement, 10),
                afterFingerprint: Self.optionalText(statement, 11),
                rollbackReference: Self.optionalText(statement, 12),
                rollbackManifest: try decodeRollbackManifest(Self.optionalText(statement, 13)),
                appliedAt: Self.optionalText(statement, 14).flatMap(dateFormatter.date(from:)),
                notes: Self.text(statement, 15),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    public func transitionRepairAttempt(
        id: UUID,
        to nextState: RepairAttemptState,
        retryRunID: UUID? = nil,
        verificationID: UUID? = nil,
        beforeFingerprint: String? = nil,
        afterFingerprint: String? = nil,
        rollbackReference: String? = nil,
        rollbackManifest: RepairRollbackManifest? = nil,
        notes: String? = nil,
        at date: Date = Date()
    ) throws {
        try ensurePrepared()
        guard let current = try repairAttempt(id: id),
              current.state.canTransition(to: nextState) else {
            throw RegressionCoreError.invalidEvidence("la transición de reparación no es válida")
        }
        let mergedRetryRunID = retryRunID ?? current.retryRunID
        let mergedVerificationID = verificationID ?? current.verificationID
        let mergedBefore = beforeFingerprint ?? current.beforeFingerprint
        let mergedAfter = afterFingerprint ?? current.afterFingerprint
        let mergedRollback = rollbackReference ?? current.rollbackReference
        let mergedManifest = rollbackManifest ?? current.rollbackManifest
        let mergedAppliedAt = nextState == .appliedAwaitingRelaunch
            ? (current.appliedAt ?? date)
            : current.appliedAt
        if nextState == .appliedAwaitingRelaunch,
           [mergedBefore, mergedAfter].contains(where: { value in
               value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
           }) || nextState == .appliedAwaitingRelaunch && !isCompleteRollbackManifest(mergedManifest) {
            throw RegressionCoreError.invalidEvidence(
                "una reparación aplicada exige huellas antes/después y rollback"
            )
        }
        if current.launchOrigin == .steamObserved,
           nextState == .relaunching,
           mergedRetryRunID == nil {
            throw RegressionCoreError.invalidEvidence(
                "una ejecución observada en Steam requiere un nuevo gesto registrado"
            )
        }
        if [.relaunching, .awaitingVerification, .verified, .acceptedWithIssues].contains(nextState) {
            try validateRepairRetry(
                attempt: current,
                retryRunID: mergedRetryRunID,
                verificationID: mergedVerificationID,
                targetState: nextState,
                appliedAt: mergedAppliedAt
            )
        }
        if nextState == .rolledBack {
            throw RegressionCoreError.invalidEvidence(
                "rolledBack solo puede registrarse mediante restore verificado"
            )
        }
        let manifestJSON = try rollbackManifestJSON(mergedManifest)
        let bindings: [Any] = [
            nextState.rawValue,
            mergedRetryRunID?.uuidString ?? NSNull(),
            mergedVerificationID?.uuidString ?? NSNull(),
            mergedBefore ?? NSNull(),
            mergedAfter ?? NSNull(),
            mergedRollback ?? NSNull(),
            manifestJSON,
            mergedAppliedAt.map(dateFormatter.string(from:)) ?? NSNull(),
            PrivacySanitizer.redactedLogExcerpt(notes ?? current.notes, limit: 2_000),
            dateFormatter.string(from: date),
            id.uuidString
        ]
        try execute(
            """
            UPDATE repair_attempts
            SET state=?, retry_run_id=?, verification_id=?, before_fingerprint=?,
                after_fingerprint=?, rollback_reference=?, rollback_manifest_json=?,
                applied_at=?, notes=?, updated_at=?
            WHERE id=?;
            """,
            bindings: bindings
        )
    }

    public func legacyRepairActivationInventory() throws -> [LegacyRepairActivationInventory] {
        try ensurePrepared()
        return try query(
            """
            SELECT id, executable, recipe_id, state, source_fingerprint, observed_at
            FROM legacy_repair_activation_inventory
            ORDER BY executable, recipe_id;
            """
        ) { statement in
            guard let id = UUID(uuidString: Self.text(statement, 0)),
                  let recipe = CompiledRepairRecipe(rawValue: Self.text(statement, 2)),
                  let state = RepairAttemptState(rawValue: Self.text(statement, 3)),
                  let observedAt = dateFormatter.date(from: Self.text(statement, 5)) else {
                return nil
            }
            return LegacyRepairActivationInventory(
                id: id,
                executable: Self.text(statement, 1),
                recipe: recipe,
                state: state,
                sourceFingerprint: Self.text(statement, 4),
                observedAt: observedAt
            )
        }
    }

    public func completeVerifiedRepairRollback(
        id: UUID,
        restoredFingerprints: [String: String],
        at date: Date = Date()
    ) throws {
        _ = id
        _ = restoredFingerprints
        _ = date
        throw RegressionCoreError.invalidEvidence(
            "el rollback permanece pendiente hasta disponer de verificación filesystem anclada"
        )
    }

    /// Tras un cierre inesperado, un relanzamiento sin verificación vuelve a la puerta durable
    /// anterior. No se considera fallido ni aplicado con éxito y puede reanudarse de forma segura.
    @discardableResult
    public func reconcileInterruptedRepairAttempts(at date: Date = Date()) throws -> [UUID] {
        try ensurePrepared()
        let interrupted = try repairAttempts(activeOnly: true).filter { $0.state == .relaunching }
        var changed: [UUID] = []
        for attempt in interrupted {
            guard let retryRunID = attempt.retryRunID else {
                try execute(
                    "UPDATE repair_attempts SET state='rollbackPending', updated_at=? WHERE id=?;",
                    bindings: [dateFormatter.string(from: date), attempt.id.uuidString]
                )
                changed.append(attempt.id)
                continue
            }
            do {
                try validateRepairRetry(
                    attempt: attempt,
                    retryRunID: retryRunID,
                    verificationID: attempt.verificationID,
                    targetState: .relaunching,
                    appliedAt: attempt.appliedAt
                )
            } catch {
                try execute(
                    "UPDATE repair_attempts SET state='rollbackPending', updated_at=? WHERE id=?;",
                    bindings: [dateFormatter.string(from: date), attempt.id.uuidString]
                )
                changed.append(attempt.id)
                continue
            }
            let runState: [(ended: Bool, result: String, executable: String?)] = try query(
                "SELECT ended_at IS NOT NULL, result, executable FROM runs WHERE id=?;",
                bindings: [retryRunID.uuidString]
            ) { statement in
                (
                    sqlite3_column_int(statement, 0) == 1,
                    Self.text(statement, 1),
                    Self.optionalText(statement, 2)
                )
            }
            guard let run = runState.first else { continue }
            if run.ended {
                try execute(
                    "UPDATE repair_attempts SET state='awaitingVerification', updated_at=? WHERE id=?;",
                    bindings: [dateFormatter.string(from: date), attempt.id.uuidString]
                )
                changed.append(attempt.id)
            }
        }
        return changed.sorted { $0.uuidString < $1.uuidString }
    }

    private func rollbackManifestJSON(_ manifest: RepairRollbackManifest?) throws -> Any {
        guard let manifest else { return NSNull() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(manifest), as: UTF8.self)
    }

    private func decodeRollbackManifest(_ json: String?) throws -> RepairRollbackManifest? {
        guard let json else { return nil }
        return try JSONDecoder().decode(RepairRollbackManifest.self, from: Data(json.utf8))
    }

    private func isCompleteRollbackManifest(_ manifest: RepairRollbackManifest?) -> Bool {
        guard let manifest, manifest.entries.count == 2 else { return false }
        return manifest.entries.allSatisfy { entry in
            entry.targetPath.hasPrefix("/")
                && entry.backupPath.hasPrefix("/")
                && !entry.beforeFingerprint.isEmpty
                && !entry.afterFingerprint.isEmpty
        }
    }

    private func validateRepairRetry(
        attempt: RepairAttempt,
        retryRunID: UUID?,
        verificationID: UUID?,
        targetState: RepairAttemptState,
        appliedAt: Date?
    ) throws {
        guard let retryRunID, let appliedAt else {
            throw RegressionCoreError.invalidEvidence("el reintento exige run posterior a la aplicación")
        }
        let rows: [(
            startedAt: Date,
            endedAt: Date?,
            result: String,
            executable: String?,
            verdict: String?,
            verifiedAt: Date?
        )] = try query(
            """
            SELECT r.started_at, r.ended_at, r.result, r.executable, v.verdict, v.verified_at
            FROM runs r LEFT JOIN run_verifications v ON v.run_id=r.id
            WHERE r.id=? AND r.app_id=? AND r.backend='regression';
            """,
            bindings: [retryRunID.uuidString, attempt.appID]
        ) { statement in
            guard let startedAt = dateFormatter.date(from: Self.text(statement, 0)) else { return nil }
            return (
                startedAt,
                Self.optionalText(statement, 1).flatMap(dateFormatter.date(from:)),
                Self.text(statement, 2),
                Self.optionalText(statement, 3),
                Self.optionalText(statement, 4),
                Self.optionalText(statement, 5).flatMap(dateFormatter.date(from:))
            )
        }
        guard let row = rows.first,
              row.startedAt > appliedAt,
              row.executable.map(Self.executableBasename) == attempt.executable else {
            throw RegressionCoreError.invalidEvidence("el run de reintento no coincide con el intento")
        }
        if [.awaitingVerification, .verified, .acceptedWithIssues].contains(targetState),
           row.endedAt == nil || row.result == RunResult.preparing.rawValue {
            throw RegressionCoreError.invalidEvidence("el reintento debe haber terminado")
        }
        if targetState == .verified {
            guard verificationID == retryRunID,
                  row.verdict == VerificationVerdict.perfect.rawValue,
                  let endedAt = row.endedAt,
                  let verifiedAt = row.verifiedAt,
                  verifiedAt >= endedAt else {
                throw RegressionCoreError.invalidEvidence("verified exige veredicto perfecto exacto")
            }
        }
        if targetState == .acceptedWithIssues {
            guard verificationID == retryRunID,
                  row.verdict == VerificationVerdict.playableWithIssues.rawValue,
                  let endedAt = row.endedAt,
                  let verifiedAt = row.verifiedAt,
                  verifiedAt >= endedAt else {
                throw RegressionCoreError.invalidEvidence("acceptedWithIssues exige su veredicto exacto")
            }
        }
    }

    private func validateRepairSource(_ attempt: RepairAttempt) throws {
        guard let sourceRunID = attempt.sourceRunID else {
            throw RegressionCoreError.invalidEvidence("la detección exige un crash fuente")
        }
        let rows: [(endedAt: Date, executable: String?)] = try query(
            """
            SELECT ended_at, executable FROM runs
            WHERE id=? AND app_id=? AND backend='regression' AND result='crashed'
              AND ended_at IS NOT NULL;
            """,
            bindings: [sourceRunID.uuidString, attempt.appID]
        ) { statement in
            guard let endedAt = dateFormatter.date(from: Self.text(statement, 0)) else { return nil }
            return (endedAt, Self.optionalText(statement, 1))
        }
        guard let source = rows.first,
              source.endedAt <= attempt.createdAt,
              source.executable.map(Self.executableBasename) == attempt.executable else {
            throw RegressionCoreError.invalidEvidence(
                "la detección exige un crash Regression finalizado del ejecutable exacto"
            )
        }
    }

    private static func executableBasename(_ executable: String) -> String {
        executable.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
            .map { String($0).lowercased() } ?? ""
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
        let invalidRepairAttempts = try scalarInt(
            """
            SELECT COUNT(*) FROM repair_attempts attempt
            WHERE NOT EXISTS (
                SELECT 1 FROM runs source
                WHERE source.id=attempt.source_run_id AND source.app_id=attempt.app_id
                  AND source.backend='regression' AND source.result='crashed'
                  AND source.ended_at IS NOT NULL AND source.ended_at<=attempt.created_at
                  AND (
                      lower(source.executable)=attempt.executable
                      OR lower(replace(source.executable, char(92), '/'))
                         LIKE '%/' || attempt.executable
                  )
            ) OR (
                attempt.retry_run_id IS NOT NULL AND NOT EXISTS (
                    SELECT 1 FROM runs retry
                    WHERE retry.id=attempt.retry_run_id AND retry.app_id=attempt.app_id
                      AND retry.backend='regression' AND retry.id!=attempt.source_run_id
                )
            ) OR (
                attempt.state IN (
                    'appliedAwaitingRelaunch','relaunching','awaitingVerification',
                    'verified','acceptedWithIssues','rollbackPending','rolledBack'
                ) AND (
                    attempt.before_fingerprint IS NULL OR attempt.before_fingerprint=''
                    OR attempt.after_fingerprint IS NULL OR attempt.after_fingerprint=''
                    OR attempt.rollback_manifest_json IS NULL OR attempt.rollback_manifest_json=''
                    OR attempt.applied_at IS NULL OR attempt.applied_at=''
                )
            ) OR (
                attempt.state IN ('awaitingVerification','verified','acceptedWithIssues')
                AND attempt.retry_run_id IS NULL
            ) OR (
                attempt.state IN ('verified','acceptedWithIssues')
                AND (attempt.verification_id IS NULL
                     OR attempt.verification_id!=attempt.retry_run_id
                     OR NOT EXISTS (
                         SELECT 1 FROM run_verifications verification
                         JOIN runs retry ON retry.id=verification.run_id
                         WHERE verification.run_id=attempt.verification_id
                           AND retry.ended_at IS NOT NULL
                           AND verification.verified_at>=retry.ended_at
                           AND (
                               (attempt.state='verified' AND verification.verdict='perfect')
                               OR (attempt.state='acceptedWithIssues'
                                   AND verification.verdict='playableWithIssues')
                           )
                     ))
            );
            """
        )
        guard invalidPromotions == 0,
              invalidBestKnown == 0,
              invalidMeasurements == 0,
              invalidRepairAttempts == 0 else {
            throw RegressionCoreError.database(
                "Hay candidatos, métricas o reparaciones sin evidencia suficiente"
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
    static let gameTechnologyScanStateSQL = """
        CREATE TABLE IF NOT EXISTS game_technology_scan_states(
            app_id TEXT PRIMARY KEY REFERENCES games(app_id) ON DELETE CASCADE,
            generation INTEGER NOT NULL CHECK(generation > 0),
            last_successful_generation INTEGER,
            freshness TEXT NOT NULL CHECK(freshness IN ('current','stale')),
            attempted_at TEXT NOT NULL,
            last_successful_at TEXT,
            error TEXT,
            CHECK(last_successful_generation IS NULL OR last_successful_generation > 0),
            CHECK(freshness!='current' OR (
                last_successful_generation=generation
                AND last_successful_at IS NOT NULL
                AND error IS NULL
            )),
            CHECK(freshness!='stale' OR error IS NOT NULL)
        );
        """

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

        \(gameTechnologyScanStateSQL)

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

enum RepairAttemptSchema {
    static let sql = """
        CREATE TABLE IF NOT EXISTS repair_attempts(
            id TEXT PRIMARY KEY,
            source_run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE RESTRICT,
            retry_run_id TEXT REFERENCES runs(id) ON DELETE RESTRICT,
            verification_id TEXT REFERENCES run_verifications(run_id) ON DELETE RESTRICT,
            app_id TEXT NOT NULL REFERENCES games(app_id) ON DELETE CASCADE,
            executable TEXT NOT NULL CHECK(executable!=''),
            launch_origin TEXT NOT NULL CHECK(launch_origin IN ('regression','steamObserved')),
            recipe_id TEXT NOT NULL CHECK(recipe_id IN (
                'unreal-d3d11-dual-overlay-isolation-v1',
                'unity-intro-winegstreamer-isolation-v1',
                'unity-macos-focus-borderless-v1',
                'gamemaker-retina-fullscreen-v1'
            )),
            recipe_version INTEGER NOT NULL CHECK(recipe_version > 0),
            state TEXT NOT NULL CHECK(state IN (
                'detected','planned','appliedAwaitingRelaunch','relaunching',
                'awaitingVerification','verified','acceptedWithIssues','failed',
                'rollbackPending','rollbackFailed','rolledBack','blocked',
                'legacyAppliedUnverified'
            )),
            before_fingerprint TEXT,
            after_fingerprint TEXT,
            rollback_reference TEXT,
            rollback_manifest_json TEXT,
            applied_at TEXT,
            notes TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS repair_attempts_source_run_idx
            ON repair_attempts(source_run_id, created_at DESC);
        CREATE INDEX IF NOT EXISTS repair_attempts_retry_run_idx
            ON repair_attempts(retry_run_id, updated_at DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS repair_attempts_one_active_recipe
            ON repair_attempts(app_id, recipe_id)
            WHERE state IN (
                'detected','planned','appliedAwaitingRelaunch','relaunching',
                'awaitingVerification','rollbackPending'
            );

        CREATE TABLE IF NOT EXISTS legacy_repair_activation_inventory(
            id TEXT PRIMARY KEY,
            executable TEXT NOT NULL,
            recipe_id TEXT NOT NULL,
            state TEXT NOT NULL CHECK(state='legacyAppliedUnverified'),
            source_fingerprint TEXT NOT NULL,
            observed_at TEXT NOT NULL,
            UNIQUE(executable, recipe_id, source_fingerprint)
        );

        CREATE TRIGGER IF NOT EXISTS repair_attempt_identity_guard_insert
        BEFORE INSERT ON repair_attempts
        WHEN NOT EXISTS (
            SELECT 1 FROM runs source
            WHERE source.id=NEW.source_run_id AND source.app_id=NEW.app_id
              AND source.backend='regression' AND source.result='crashed'
              AND source.ended_at IS NOT NULL AND source.ended_at<=NEW.created_at
              AND (
                  lower(source.executable)=NEW.executable
                  OR lower(replace(source.executable, char(92), '/'))
                     LIKE '%/' || NEW.executable
              )
        ) OR (
            NEW.retry_run_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM runs retry
                WHERE retry.id=NEW.retry_run_id AND retry.app_id=NEW.app_id
                  AND retry.backend='regression' AND retry.id!=NEW.source_run_id
            )
        ) OR (
            NEW.verification_id IS NOT NULL AND (
                NEW.retry_run_id IS NULL OR NEW.verification_id!=NEW.retry_run_id
                OR NOT EXISTS (
                    SELECT 1 FROM run_verifications verification
                    WHERE verification.run_id=NEW.verification_id
                )
            )
        )
        BEGIN
            SELECT RAISE(ABORT, 'repair attempt evidence identity mismatch');
        END;

        CREATE TRIGGER IF NOT EXISTS repair_attempt_identity_guard_update
        BEFORE UPDATE OF retry_run_id, verification_id, app_id, source_run_id ON repair_attempts
        WHEN NOT EXISTS (
            SELECT 1 FROM runs source
            WHERE source.id=NEW.source_run_id AND source.app_id=NEW.app_id
              AND source.backend='regression' AND source.result='crashed'
              AND source.ended_at IS NOT NULL AND source.ended_at<=NEW.created_at
              AND (
                  lower(source.executable)=NEW.executable
                  OR lower(replace(source.executable, char(92), '/'))
                     LIKE '%/' || NEW.executable
              )
        ) OR (
            NEW.retry_run_id IS NOT NULL AND NOT EXISTS (
                SELECT 1 FROM runs retry
                WHERE retry.id=NEW.retry_run_id AND retry.app_id=NEW.app_id
                  AND retry.backend='regression' AND retry.id!=NEW.source_run_id
            )
        ) OR (
            NEW.verification_id IS NOT NULL AND (
                NEW.retry_run_id IS NULL OR NEW.verification_id!=NEW.retry_run_id
                OR NOT EXISTS (
                    SELECT 1 FROM run_verifications verification
                    WHERE verification.run_id=NEW.verification_id
                )
            )
        )
        BEGIN
            SELECT RAISE(ABORT, 'repair attempt evidence identity mismatch');
        END;

        CREATE TRIGGER IF NOT EXISTS repair_attempt_transition_guard
        BEFORE UPDATE OF state ON repair_attempts
        WHEN OLD.state!=NEW.state AND NOT (
            (OLD.state='detected' AND NEW.state IN ('planned','blocked','failed'))
            OR (OLD.state='planned' AND NEW.state IN (
                'appliedAwaitingRelaunch','blocked','failed'
            ))
            OR (OLD.state='appliedAwaitingRelaunch' AND NEW.state IN (
                'relaunching','rollbackPending','blocked'
            ))
            OR (OLD.state='relaunching' AND NEW.state IN (
                'awaitingVerification','rollbackPending','blocked'
            ))
            OR (OLD.state='awaitingVerification' AND NEW.state IN (
                'verified','acceptedWithIssues','rollbackPending','blocked'
            ))
            OR (OLD.state IN ('verified','acceptedWithIssues') AND NEW.state='blocked')
            OR (OLD.state='rollbackPending' AND NEW.state IN ('rolledBack','rollbackFailed'))
            OR (OLD.state='rollbackFailed' AND NEW.state='rollbackPending')
        )
        BEGIN
            SELECT RAISE(ABORT, 'invalid repair attempt transition');
        END;

        CREATE TRIGGER IF NOT EXISTS repair_attempt_evidence_guard_insert
        BEFORE INSERT ON repair_attempts
        WHEN (
            NEW.state IN ('appliedAwaitingRelaunch','relaunching','awaitingVerification',
                          'verified','acceptedWithIssues','rollbackPending','rolledBack')
            AND (NEW.before_fingerprint IS NULL OR NEW.before_fingerprint=''
                 OR NEW.after_fingerprint IS NULL OR NEW.after_fingerprint=''
                 OR NEW.rollback_manifest_json IS NULL OR NEW.rollback_manifest_json=''
                 OR NEW.applied_at IS NULL OR NEW.applied_at='')
        ) OR (
            NEW.state IN ('awaitingVerification','verified','acceptedWithIssues')
            AND NEW.retry_run_id IS NULL
        ) OR (
            NEW.state IN ('verified','acceptedWithIssues') AND NEW.verification_id IS NULL
        ) OR (
            NEW.rollback_manifest_json IS NOT NULL AND json_valid(NEW.rollback_manifest_json)!=1
        ) OR (
            NEW.state IN ('relaunching','awaitingVerification','verified','acceptedWithIssues')
            AND NOT EXISTS (
                SELECT 1 FROM runs retry
                WHERE retry.id=NEW.retry_run_id AND retry.app_id=NEW.app_id
                  AND retry.backend='regression' AND retry.started_at>NEW.applied_at
                  AND (
                      lower(retry.executable)=NEW.executable
                      OR lower(retry.executable) LIKE '%/' || NEW.executable
                      OR lower(replace(retry.executable, char(92), '/'))
                         LIKE '%/' || NEW.executable
                  )
                  AND (
                      NEW.state='relaunching'
                      OR (retry.ended_at IS NOT NULL AND retry.result!='preparing')
                  )
            )
        ) OR (
            NEW.state='verified' AND NOT EXISTS (
                SELECT 1 FROM run_verifications verification
                JOIN runs retry ON retry.id=verification.run_id
                WHERE verification.run_id=NEW.retry_run_id
                  AND verification.run_id=NEW.verification_id
                  AND verification.verdict='perfect'
                  AND retry.ended_at IS NOT NULL
                  AND verification.verified_at>=retry.ended_at
            )
        ) OR (
            NEW.state='acceptedWithIssues' AND NOT EXISTS (
                SELECT 1 FROM run_verifications verification
                JOIN runs retry ON retry.id=verification.run_id
                WHERE verification.run_id=NEW.retry_run_id
                  AND verification.run_id=NEW.verification_id
                  AND verification.verdict='playableWithIssues'
                  AND retry.ended_at IS NOT NULL
                  AND verification.verified_at>=retry.ended_at
            )
        ) OR (
            NEW.state='legacyAppliedUnverified'
            AND (NEW.before_fingerprint IS NOT NULL OR NEW.after_fingerprint IS NOT NULL)
        )
        BEGIN
            SELECT RAISE(ABORT, 'repair attempt lacks required evidence');
        END;

        CREATE TRIGGER IF NOT EXISTS repair_attempt_evidence_guard_update
        BEFORE UPDATE ON repair_attempts
        WHEN (
            NEW.state IN ('appliedAwaitingRelaunch','relaunching','awaitingVerification',
                          'verified','acceptedWithIssues','rollbackPending','rolledBack')
            AND (NEW.before_fingerprint IS NULL OR NEW.before_fingerprint=''
                 OR NEW.after_fingerprint IS NULL OR NEW.after_fingerprint=''
                 OR NEW.rollback_manifest_json IS NULL OR NEW.rollback_manifest_json=''
                 OR NEW.applied_at IS NULL OR NEW.applied_at='')
        ) OR (
            NEW.state IN ('awaitingVerification','verified','acceptedWithIssues')
            AND NEW.retry_run_id IS NULL
        ) OR (
            NEW.state IN ('verified','acceptedWithIssues') AND NEW.verification_id IS NULL
        ) OR (
            NEW.rollback_manifest_json IS NOT NULL AND json_valid(NEW.rollback_manifest_json)!=1
        ) OR (
            NEW.state IN ('relaunching','awaitingVerification','verified','acceptedWithIssues')
            AND NOT EXISTS (
                SELECT 1 FROM runs retry
                WHERE retry.id=NEW.retry_run_id AND retry.app_id=NEW.app_id
                  AND retry.backend='regression' AND retry.started_at>NEW.applied_at
                  AND (
                      lower(retry.executable)=NEW.executable
                      OR lower(retry.executable) LIKE '%/' || NEW.executable
                      OR lower(replace(retry.executable, char(92), '/'))
                         LIKE '%/' || NEW.executable
                  )
                  AND (
                      NEW.state='relaunching'
                      OR (retry.ended_at IS NOT NULL AND retry.result!='preparing')
                  )
            )
        ) OR (
            NEW.state='verified' AND NOT EXISTS (
                SELECT 1 FROM run_verifications verification
                JOIN runs retry ON retry.id=verification.run_id
                WHERE verification.run_id=NEW.retry_run_id
                  AND verification.run_id=NEW.verification_id
                  AND verification.verdict='perfect'
                  AND retry.ended_at IS NOT NULL
                  AND verification.verified_at>=retry.ended_at
            )
        ) OR (
            NEW.state='acceptedWithIssues' AND NOT EXISTS (
                SELECT 1 FROM run_verifications verification
                JOIN runs retry ON retry.id=verification.run_id
                WHERE verification.run_id=NEW.retry_run_id
                  AND verification.run_id=NEW.verification_id
                  AND verification.verdict='playableWithIssues'
                  AND retry.ended_at IS NOT NULL
                  AND verification.verified_at>=retry.ended_at
            )
        )
        BEGIN
            SELECT RAISE(ABORT, 'repair attempt lacks required evidence');
        END;

        CREATE TRIGGER IF NOT EXISTS repair_attempt_verification_revoked
        AFTER UPDATE OF verdict, verified_at ON run_verifications
        BEGIN
            UPDATE repair_attempts
            SET state='blocked', updated_at=NEW.verified_at
            WHERE verification_id=NEW.run_id AND (
                (state='verified' AND (
                    NEW.verdict!='perfect'
                    OR NEW.verified_at<(SELECT ended_at FROM runs WHERE id=NEW.run_id)
                ))
                OR (state='acceptedWithIssues' AND (
                    NEW.verdict!='playableWithIssues'
                    OR NEW.verified_at<(SELECT ended_at FROM runs WHERE id=NEW.run_id)
                ))
            );
        END;

        CREATE TRIGGER IF NOT EXISTS repair_attempt_retry_timeline_changed
        AFTER UPDATE OF ended_at ON runs
        BEGIN
            UPDATE repair_attempts
            SET state='blocked', updated_at=NEW.ended_at
            WHERE retry_run_id=NEW.id AND state IN ('verified','acceptedWithIssues')
              AND NOT EXISTS (
                  SELECT 1 FROM run_verifications verification
                  WHERE verification.run_id=NEW.id AND NEW.ended_at IS NOT NULL
                    AND verification.verified_at>=NEW.ended_at
              );
        END;
        """
}
