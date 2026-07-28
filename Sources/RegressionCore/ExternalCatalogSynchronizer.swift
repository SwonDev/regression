import Foundation

public enum ExternalCatalogSyncOutcome: Equatable, Sendable {
    case freshCache
    case updated(ExternalCompatibilityEntry)
    case noMatch
    case failed(String)
    case cancelled
}

public actor ExternalCatalogSynchronizer {
    private let repository: CompatibilityRepository
    private let provider: any ExternalCompatibilityProviding
    private let now: @Sendable () -> Date
    private let noMatchCacheLifetime: TimeInterval

    public init(
        repository: CompatibilityRepository,
        provider: any ExternalCompatibilityProviding = CodeWeaversCompatibilityProvider(),
        now: @escaping @Sendable () -> Date = Date.init,
        noMatchCacheLifetime: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.repository = repository
        self.provider = provider
        self.now = now
        self.noMatchCacheLifetime = noMatchCacheLifetime
    }

    public func refresh(game: SteamGame, force: Bool = false) async -> ExternalCatalogSyncOutcome {
        do {
            try Task.checkCancellation()
            try await repository.registerExternalSource(provider.source)
            let cached = try await repository.externalEntry(
                sourceID: provider.source.id,
                appID: game.appID
            )
            if !force, isFresh(cached) { return .freshCache }

            let initialURL = cached?.record?.canonicalURL
                ?? CodeWeaversCompatibilityProvider.knownDetailURL(forSteamAppID: game.appID)
                ?? CodeWeaversCompatibilityProvider.probableDetailURL(for: game.name)
            guard let initialURL else {
                try await saveNoMatch(game: game, message: "No se pudo construir una búsqueda segura")
                return .noMatch
            }

            if let outcome = try await fetchAndLink(
                game: game,
                detailURL: initialURL,
                cachedRecord: cached?.record,
                hinted: CodeWeaversCompatibilityProvider.knownDetailURL(forSteamAppID: game.appID) == initialURL
            ) {
                return outcome
            }

            try await waitForRequestSlot()
            let candidates = try await provider.search(named: game.name)
            try await repository.recordExternalSyncSuccess(sourceID: provider.source.id, at: now())
            guard let candidate = candidates.first(where: {
                CodeWeaversCompatibilityProvider.normalizedName($0.name)
                    == CodeWeaversCompatibilityProvider.normalizedName(game.name)
            }) else {
                try await saveNoMatch(game: game, message: "Sin coincidencia exacta en CodeWeavers")
                return .noMatch
            }

            if let outcome = try await fetchAndLink(
                game: game,
                detailURL: candidate.detailURL,
                cachedRecord: nil,
                hinted: false
            ) {
                return outcome
            }
            try await saveNoMatch(game: game, message: "La ficha encontrada no coincide con el juego")
            return .noMatch
        } catch is CancellationError {
            return .cancelled
        } catch {
            let detail = error.localizedDescription
            try? await repository.recordExternalSyncFailure(
                sourceID: provider.source.id,
                message: detail
            )
            try? await repository.recordExternalLookupStatus(
                sourceID: provider.source.id,
                game: game,
                status: .failed,
                message: detail,
                at: now()
            )
            return .failed(detail)
        }
    }

    private func fetchAndLink(
        game: SteamGame,
        detailURL: URL,
        cachedRecord: ExternalGameRecord?,
        hinted: Bool
    ) async throws -> ExternalCatalogSyncOutcome? {
        try await waitForRequestSlot()
        let validators: ExternalCatalogValidators?
        if cachedRecord?.canonicalURL == detailURL {
            validators = ExternalCatalogValidators(
                entityTag: cachedRecord?.entityTag,
                lastModified: cachedRecord?.lastModified
            )
        } else {
            validators = nil
        }
        let result = try await provider.fetchRecord(at: detailURL, validators: validators)
        try await repository.recordExternalSyncSuccess(sourceID: provider.source.id, at: now())

        switch result {
        case .notFound:
            return nil
        case let .notModified(updatedValidators):
            guard let cachedRecord else { return nil }
            let refreshed = ExternalGameRecord(
                sourceID: cachedRecord.sourceID,
                externalAppID: cachedRecord.externalAppID,
                canonicalURL: cachedRecord.canonicalURL,
                name: cachedRecord.name,
                company: cachedRecord.company,
                category: cachedRecord.category,
                steamAppID: cachedRecord.steamAppID,
                macOSRating: cachedRecord.macOSRating,
                linuxRating: cachedRecord.linuxRating,
                fetchedAt: now(),
                contentFingerprint: cachedRecord.contentFingerprint,
                entityTag: updatedValidators.entityTag ?? cachedRecord.entityTag,
                lastModified: updatedValidators.lastModified ?? cachedRecord.lastModified
            )
            try await repository.upsertExternalRecord(
                refreshed,
                for: game,
                matchMethod: matchMethod(record: refreshed, game: game, hinted: hinted),
                confidence: 1
            )
        case let .modified(record):
            guard isExactMatch(record: record, game: game) else { return nil }
            try await repository.upsertExternalRecord(
                record,
                for: game,
                matchMethod: matchMethod(record: record, game: game, hinted: hinted),
                confidence: 1
            )
        }

        guard let entry = try await repository.externalEntry(
            sourceID: provider.source.id,
            appID: game.appID
        ) else {
            throw RegressionCoreError.externalCatalog("La ficha se guardó sin vínculo local")
        }
        return .updated(entry)
    }

    private func waitForRequestSlot() async throws {
        while true {
            try Task.checkCancellation()
            let current = now()
            let reserved = try await repository.reserveExternalRequest(
                source: provider.source,
                now: current
            )
            let delay = reserved.timeIntervalSince(current)
            guard delay > 0 else { return }
            let milliseconds = max(1, Int64((delay * 1_000).rounded(.up)))
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
    }

    private func isFresh(_ entry: ExternalCompatibilityEntry?) -> Bool {
        guard let entry else { return false }
        let age: TimeInterval
        switch entry.status {
        case .linked:
            guard let fetchedAt = entry.record?.fetchedAt else { return false }
            age = now().timeIntervalSince(fetchedAt)
            return age >= 0 && age < provider.source.cacheLifetime
        case .noMatch:
            guard let attemptedAt = entry.lastAttemptAt else { return false }
            age = now().timeIntervalSince(attemptedAt)
            return age >= 0 && age < noMatchCacheLifetime
        case .pending, .unavailable, .failed:
            return false
        }
    }

    private func isExactMatch(record: ExternalGameRecord, game: SteamGame) -> Bool {
        if let steamAppID = record.steamAppID {
            return steamAppID == game.appID
        }
        return CodeWeaversCompatibilityProvider.normalizedName(record.name)
            == CodeWeaversCompatibilityProvider.normalizedName(game.name)
    }

    private func matchMethod(
        record: ExternalGameRecord,
        game: SteamGame,
        hinted: Bool
    ) -> ExternalCatalogMatchMethod {
        if record.steamAppID == game.appID { return .steamAppID }
        return hinted ? .knownMapping : .exactTitle
    }

    private func saveNoMatch(game: SteamGame, message: String) async throws {
        try await repository.recordExternalLookupStatus(
            sourceID: provider.source.id,
            game: game,
            status: .noMatch,
            message: message,
            at: now()
        )
    }
}
