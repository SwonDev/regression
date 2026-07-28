import Foundation

/// Puerta pura y comprobable para promover un candidato. La selección automática permanece
/// desactivada; esta política expresa el mínimo que una futura acción explícita deberá cumplir.
public enum RuntimeSelectionPolicy {
    public static func promotionDecision(
        for candidate: RuntimeCandidate,
        assessments: [OptimizationAssessment],
        technology: RuntimeTechnology?
    ) -> RuntimePromotionDecision {
        var blockers: [String] = []

        if candidate.state != .validated && candidate.state != .promoted {
            blockers.append("El candidato todavía no ha alcanzado el estado validado.")
        }
        if candidate.scope != .perGame || candidate.appID == nil {
            blockers.append("El candidato debe estar aislado para un juego concreto.")
        }
        if technology == nil {
            blockers.append("La tecnología candidata no figura en el catálogo confiable.")
        } else if technology?.updatePolicy != .candidateOnly {
            blockers.append("Esta tecnología no admite promoción al motor propio.")
        } else if let technology, !trustedSourceURL(candidate.sourceURL, for: technology) {
            blockers.append("La fuente no pertenece al sitio oficial registrado para la tecnología.")
        }
        if candidate.sourceURL.scheme?.lowercased() != "https" {
            blockers.append("La fuente oficial debe usar HTTPS.")
        }
        if !candidate.sourceVerified || candidate.sourceFingerprint?.isEmpty != false {
            blockers.append("Falta verificar la fuente y su huella reproducible.")
        }
        if !candidate.isIsolated {
            blockers.append("El candidato no está aislado del motor estable.")
        }
        if candidate.rollbackReference?.isEmpty != false {
            blockers.append("Falta un rollback verificable.")
        }
        if candidate.baselineEngineFingerprint?.isEmpty != false
            || candidate.candidateEngineFingerprint?.isEmpty != false {
            blockers.append("Falta identificar el motor base o el candidato.")
        } else if candidate.baselineEngineFingerprint == candidate.candidateEngineFingerprint {
            blockers.append("El candidato debe tener una huella distinta del baseline.")
        }
        if !candidate.validationMatrixPassed {
            blockers.append("La matriz funcional completa todavía no está aprobada.")
        }

        let candidateAssessments = assessments.filter { assessment in
            assessment.candidateID == candidate.id
                && assessment.appID == candidate.appID
                && assessment.backend == .regression
                && assessment.engineFingerprint == candidate.candidateEngineFingerprint
                && assessment.state == .bestKnown
                && assessment.hasMeasuredPerformance
        }
        let baselineAssessments = assessments.filter { assessment in
            assessment.appID == candidate.appID
                && assessment.backend == .regression
                && assessment.engineFingerprint == candidate.baselineEngineFingerprint
                && [.baselineMeasured, .bestKnown].contains(assessment.state)
                && assessment.hasMeasuredPerformance
        }
        let performanceEvidence = candidateAssessments.contains { candidateAssessment in
            baselineAssessments.contains { baselineAssessment in
                hasComparableMeasuredImprovement(
                    candidate: candidateAssessment,
                    baseline: baselineAssessment
                )
            }
        }
        if !performanceEvidence {
            blockers.append(
                "Falta una comparación equivalente que demuestre una mejora medible sobre el baseline."
            )
        }

        return RuntimePromotionDecision(isEligible: blockers.isEmpty, blockers: blockers)
    }

    private static func hasComparableMeasuredImprovement(
        candidate: OptimizationAssessment,
        baseline: OptimizationAssessment
    ) -> Bool {
        guard let candidateResolution = normalized(candidate.resolution),
              let baselineResolution = normalized(baseline.resolution),
              !candidateResolution.isEmpty,
              candidateResolution == baselineResolution,
              let candidatePreset = normalized(candidate.qualityPreset),
              let baselinePreset = normalized(baseline.qualityPreset),
              !candidatePreset.isEmpty,
              candidatePreset == baselinePreset,
              hasSameMetricCoverage(candidate: candidate, baseline: baseline) else { return false }

        let averageFPSDoesNotRegress = doesNotRegress(
            candidate.averageFPS,
            baseline.averageFPS,
            higherIsBetter: true
        )
        let onePercentLowDoesNotRegress = doesNotRegress(
            candidate.onePercentLowFPS,
            baseline.onePercentLowFPS,
            higherIsBetter: true
        )
        let frameTimeDoesNotRegress = doesNotRegress(
            candidate.frameTimeP95Milliseconds,
            baseline.frameTimeP95Milliseconds,
            higherIsBetter: false
        )
        guard averageFPSDoesNotRegress,
              onePercentLowDoesNotRegress,
              frameTimeDoesNotRegress else { return false }

        return improves(candidate.averageFPS, baseline.averageFPS, higherIsBetter: true)
            || improves(candidate.onePercentLowFPS, baseline.onePercentLowFPS, higherIsBetter: true)
            || improves(
                candidate.frameTimeP95Milliseconds,
                baseline.frameTimeP95Milliseconds,
                higherIsBetter: false
            )
    }

    private static func normalized(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func trustedSourceURL(
        _ sourceURL: URL,
        for technology: RuntimeTechnology
    ) -> Bool {
        guard sourceURL.scheme?.lowercased() == "https",
              let sourceHost = sourceURL.host?.lowercased() else { return false }
        let trustedHosts = [technology.officialURL.host, technology.releaseURL?.host]
            .compactMap { $0?.lowercased() }
        return trustedHosts.contains(sourceHost)
    }

    private static func hasSameMetricCoverage(
        candidate: OptimizationAssessment,
        baseline: OptimizationAssessment
    ) -> Bool {
        (candidate.averageFPS == nil) == (baseline.averageFPS == nil)
            && (candidate.onePercentLowFPS == nil) == (baseline.onePercentLowFPS == nil)
            && (candidate.frameTimeP95Milliseconds == nil)
                == (baseline.frameTimeP95Milliseconds == nil)
    }

    private static func doesNotRegress(
        _ candidate: Double?,
        _ baseline: Double?,
        higherIsBetter: Bool
    ) -> Bool {
        guard let candidate, let baseline else { return true }
        return higherIsBetter ? candidate >= baseline : candidate <= baseline
    }

    private static func improves(
        _ candidate: Double?,
        _ baseline: Double?,
        higherIsBetter: Bool
    ) -> Bool {
        guard let candidate, let baseline else { return false }
        return higherIsBetter ? candidate > baseline : candidate < baseline
    }
}
