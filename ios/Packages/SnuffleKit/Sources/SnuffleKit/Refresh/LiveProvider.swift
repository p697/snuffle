import Foundation

/// Reads real accounts. Each platform is fetched concurrently and fails on its own: a broken RevenueCat key never
/// stops the PostHog numbers from updating.
public struct LiveProvider: DataProvider {
    public var tokens: TokenBroker
    public var http: HTTPClient
    public var now: @Sendable () -> Date

    public init(tokens: TokenBroker, http: HTTPClient = HTTPClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.tokens = tokens
        self.http = http
        self.now = now
    }

    // MARK: Clients

    /// Runs a PostHog call, retrying once with a refreshed token after a 401.
    func withPostHog<T: Sendable>(_ accountId: UUID, _ body: @Sendable (PostHogClient) async throws -> T) async throws -> T {
        do {
            let (host, token) = try await tokens.posthogToken(accountId)
            return try await body(PostHogClient(host: host, http: http) { token })
        } catch SourceError.unauthorized(.posthog) {
            let (host, token) = try await tokens.posthogToken(accountId, force: true)
            return try await body(PostHogClient(host: host, http: http) { token })
        }
    }

    func withGoogle<T: Sendable>(_ accountId: UUID, _ body: @Sendable (GooglePlayClient) async throws -> T) async throws -> T {
        do {
            let token = try await tokens.googleToken(accountId)
            return try await body(GooglePlayClient(http: http) { token })
        } catch SourceError.unauthorized(.googlePlay) {
            let token = try await tokens.googleToken(accountId, force: true)
            return try await body(GooglePlayClient(http: http) { token })
        }
    }

    func revenueCat(_ accountId: UUID) async throws -> RevenueCatClient {
        guard case .revenueCat(let key) = try await tokens.credential(accountId, platform: .revenueCat) else {
            throw SourceError.missingCredential(.revenueCat)
        }
        return RevenueCatClient(secretKey: key, http: http)
    }

    func appStore(_ accountId: UUID) async throws -> AppStoreConnectClient {
        guard case .appStoreConnect(let issuer, let keyId, let pem) = try await tokens.credential(accountId, platform: .appStore) else {
            throw SourceError.missingCredential(.appStore)
        }
        return AppStoreConnectClient(token: try AppStoreConnectToken(issuerId: issuer, keyId: keyId, privateKeyPEM: pem), http: http)
    }

    // MARK: Refresh

    private enum Part: Sendable {
        case posthog(PostHogParsing.Counts?, firstSeen: (Int?, Int?, [Int])?, online: Int?, active: Int?)
        case timeZone(String)
        case revenueCat(Double)
        case reviews([Review])
        case failure(SourceFailure)
    }

    public func refresh(_ project: Project) async -> RefreshResult {
        let clock = ProjectClock(now: now(), timeZoneIdentifier: project.posthog?.timeZone)
        let parts = await withTaskGroup(of: [Part].self) { group in
            if let link = project.posthog {
                group.addTask { await self.posthogPart(project, link: link, clock: clock) }
            }
            if let link = project.revenueCat, project.metrics.revenue == .revenueCat {
                group.addTask {
                    do {
                        let client = try await self.revenueCat(link.accountId)
                        let day = RevenueCatClient.utcDate(clock.now)
                        return [.revenueCat(try await client.revenue(projectId: link.projectId, from: day, to: day))]
                    } catch {
                        return [.failure(Self.failure(.revenueCat, error))]
                    }
                }
            }
            if let link = project.appStore {
                group.addTask {
                    do {
                        return [.reviews(try await self.appStore(link.accountId).reviews(appId: link.appId, projectId: project.id))]
                    } catch {
                        return [.failure(Self.failure(.appStore, error))]
                    }
                }
            }
            if let link = project.googlePlay {
                group.addTask {
                    do {
                        return [.reviews(try await self.withGoogle(link.accountId) { try await $0.reviews(packageName: link.packageName, projectId: project.id) })]
                    } catch {
                        return [.failure(Self.failure(.googlePlay, error))]
                    }
                }
            }
            var all: [Part] = []
            for await batch in group { all += batch }
            return all
        }
        return Self.assemble(parts, project: project, clock: clock)
    }

    private func posthogPart(_ project: Project, link: PostHogLink, clock: ProjectClock) async -> [Part] {
        do {
            let metrics = project.metrics
            return try await withPostHog(link.accountId) { client in
                async let countsRow: [[JSONValue]] = {
                    guard let sql = PostHogQueries.eventCounts(metrics: metrics, clock: clock) else { return [] }
                    return try await client.query(projectId: link.projectId, sql, name: "snuffle_counts")
                }()
                async let presenceRow = client.query(projectId: link.projectId, PostHogQueries.presence(clock: clock), name: "snuffle_presence")
                async let firstSeenRow: [[JSONValue]] = {
                    guard metrics.newUsers == .firstSeen else { return [] }
                    return try await client.query(projectId: link.projectId, PostHogQueries.firstSeen(clock: clock), name: "snuffle_first_seen")
                }()
                // Read alongside the queries, so it costs no extra wait; a failure here never fails the numbers.
                async let zone = try? client.timeZone(projectId: link.projectId)
                let counts = try await countsRow.first.map { PostHogParsing.counts($0, metrics: metrics) }
                let presence = try await presenceRow.first ?? []
                let firstSeen = try await firstSeenRow.first.map(PostHogParsing.firstSeen)
                var parts = [Part.posthog(counts, firstSeen: firstSeen.map { ($0.today, $0.yesterday, $0.hourly) }, online: presence.first?.int, active: presence.count > 1 ? presence[1].int : nil)]
                if let identifier = await zone { parts.append(.timeZone(identifier)) }
                return parts
            }
        } catch {
            return [.failure(Self.failure(.posthog, error))]
        }
    }

    private static func assemble(_ parts: [Part], project: Project, clock: ProjectClock) -> RefreshResult {
        var snapshot = ProjectSnapshot(projectId: project.id, fetchedAt: clock.now, dayStart: clock.todayStart)
        var reviews: [Review]?
        var storeFailed = false
        var zone: String?
        for part in parts {
            switch part {
            case .posthog(let counts, let firstSeen, let online, let active):
                snapshot.online = online
                snapshot.active = active
                if let firstSeen {
                    snapshot.newUsers = firstSeen.0
                    snapshot.newUsersYesterday = firstSeen.1
                    snapshot.hourlyNewUsers = firstSeen.2
                } else if let counts {
                    snapshot.newUsers = counts.newToday
                    snapshot.newUsersYesterday = counts.newYesterday
                    snapshot.hourlyNewUsers = counts.hourly
                }
                if let counts {
                    if case .posthogEvent = project.metrics.revenue {
                        snapshot.revenue = counts.revenue
                        snapshot.sales = counts.sales
                        snapshot.revenueSource = .posthog
                    }
                    if let extra = counts.extra {
                        switch project.metrics.extra {
                        case .installs: snapshot.extra = ExtraCount(value: extra, label: "次安装")
                        case .event(_, let label): snapshot.extra = ExtraCount(value: extra, label: label)
                        case .none: break
                        }
                    }
                }
            case .timeZone(let identifier):
                zone = identifier
            case .revenueCat(let value):
                snapshot.revenue = value
                snapshot.sales = nil
                snapshot.revenueSource = .revenueCat
            case .reviews(let list):
                reviews = (reviews ?? []) + list
            case .failure(let failure):
                snapshot.failures.append(failure)
                if failure.platform == .appStore || failure.platform == .googlePlay { storeFailed = true }
            }
        }
        // When one store answers and the other fails, count what is known; the card names the failed store,
        // and `fillingGaps` keeps yesterday's count only when no store answered at all.
        snapshot.reviewsToAnswer = reviews.map { $0.filter(\.needsReply).count }
        snapshot.failures.sort { $0.platform.rawValue < $1.platform.rawValue }
        // A partial list would drop the failed store's reviews from the inbox, so only a complete one replaces it.
        return RefreshResult(snapshot: snapshot, reviews: storeFailed ? nil : reviews, posthogTimeZone: zone)
    }

    static func failure(_ platform: Platform, _ error: Error) -> SourceFailure {
        SourceFailure(platform: platform, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    // MARK: Detail screens

    public func orders(for project: Project) async throws -> [Order] {
        guard let link = project.posthog, case .posthogEvent(let event, let property) = project.metrics.revenue else { return [] }
        let clock = ProjectClock(now: now(), timeZoneIdentifier: link.timeZone)
        let rows = try await withPostHog(link.accountId) {
            try await $0.query(projectId: link.projectId, PostHogQueries.orders(event: event, valueProperty: property, since: clock.todayStart), name: "snuffle_orders")
        }
        return PostHogParsing.orders(rows, projectId: project.id)
    }

    public func overview(for project: Project) async throws -> SubscriptionOverview? {
        guard let link = project.revenueCat else { return nil }
        return try await revenueCat(link.accountId).overview(projectId: link.projectId)
    }

    public func history(for project: Project, days: Int) async throws -> [DailyPoint] {
        async let posthogPoints = posthogHistory(for: project, days: days)
        async let revenueByDay = revenueCatHistory(for: project, days: days)
        let revenue = await revenueByDay
        var points = try await posthogPoints
        guard let revenue else { return points }
        // RevenueCat reports by UTC date; days are matched by calendar date, as the 收入 tile says "(UTC)".
        let clock = ProjectClock(now: now(), timeZoneIdentifier: project.posthog?.timeZone ?? "UTC")
        if points.isEmpty {
            points = clock.dayStarts(days: days).map { DailyPoint(day: $0, newUsers: nil, revenue: nil, active: nil) }
        }
        return points.map { point in
            var point = point
            point.revenue = revenue[clock.dayKey(point.day)] ?? 0
            return point
        }
    }

    private func posthogHistory(for project: Project, days: Int) async throws -> [DailyPoint] {
        guard let link = project.posthog else { return [] }
        let clock = ProjectClock(now: now(), timeZoneIdentifier: link.timeZone)
        let metrics = project.metrics
        let (rows, firstSeen) = try await withPostHog(link.accountId) { client in
            async let rows = client.query(projectId: link.projectId, PostHogQueries.history(metrics: metrics, clock: clock, days: days), name: "snuffle_history")
            async let firstSeen: [[JSONValue]]? = {
                guard metrics.newUsers == .firstSeen else { return nil }
                return try await client.query(projectId: link.projectId, PostHogQueries.firstSeenHistory(clock: clock, days: days), name: "snuffle_first_seen_history")
            }()
            return try await (rows, firstSeen)
        }
        let hasEventRevenue: Bool = if case .posthogEvent = metrics.revenue { true } else { false }
        return PostHogParsing.history(rows, firstSeen: firstSeen, clock: clock, days: days, hasRevenue: hasEventRevenue)
    }

    /// Daily RevenueCat revenue for projects that take revenue from it; nil when not used or unavailable, so the
    /// chart simply leaves revenue out rather than failing the whole history.
    private func revenueCatHistory(for project: Project, days: Int) async -> [String: Double]? {
        guard let link = project.revenueCat, project.metrics.revenue == .revenueCat else { return nil }
        let today = now()
        let from = RevenueCatClient.utcDate(today.addingTimeInterval(-Double(days + 1) * 86_400))
        return try? await revenueCat(link.accountId).dailyRevenue(projectId: link.projectId, from: from, to: RevenueCatClient.utcDate(today))
    }

    public func reply(to review: Review, text: String, in project: Project) async throws {
        switch review.platform {
        case .appStore:
            guard let link = project.appStore else { throw SourceError.missingCredential(.appStore) }
            try await appStore(link.accountId).reply(reviewId: review.storeId, text: text)
        case .googlePlay:
            guard let link = project.googlePlay else { throw SourceError.missingCredential(.googlePlay) }
            try await withGoogle(link.accountId) { try await $0.reply(packageName: link.packageName, reviewId: review.storeId, text: text) }
        default:
            break
        }
    }
}
