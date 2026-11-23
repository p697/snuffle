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
        case values([Metric: Double])
        case newUsersDetail(yesterday: Int?, hourly: [Int])
        case revenueSource(Platform)
        case timeZone(String)
        case surfaces(Set<Surface>)
        case reviews([Review])
        case failure(SourceFailure)
        /// An hourly metric could not be read; the next refresh tries again, and the card keeps the last value.
        case hourlyFailed
    }

    public func refresh(_ project: Project, metrics: Set<Metric>, previous: ProjectSnapshot?) async -> RefreshResult {
        let clock = ProjectClock(now: now(), timeZoneIdentifier: project.posthog?.timeZone)
        let wanted = metrics.filter { $0.isAvailable(in: project) }
        // Hourly numbers read under other counting or scope are read again, not kept for the rest of the hour.
        let current = previous.flatMap { $0.countedAs == project.metrics.inEffect ? $0 : nil }
        let readHourly = current?.needsHourlyRead(wanted, at: clock.now) ?? wanted.contains(where: \.isHourly)
        let parts = await read(project, wanted: wanted, clock: clock, readHourly: readHourly, reviews: project.hasStore)
        return Self.assemble(parts, project: project, clock: clock, readHourly: readHourly)
    }

    public func measure(_ project: Project, metrics: Set<Metric>) async throws -> [Metric: Double] {
        let clock = ProjectClock(now: now(), timeZoneIdentifier: project.posthog?.timeZone)
        let wanted = metrics.filter { $0.isAvailable(in: project) }
        let parts = await read(project, wanted: wanted, clock: clock, readHourly: true, reviews: wanted.contains(.reviewsToAnswer))
        let result = Self.assemble(parts, project: project, clock: clock, readHourly: true)
        let values = result.snapshot.values.filter { wanted.contains($0.key) }
        if values.isEmpty, let failure = result.snapshot.failures.first { throw failure }
        return values
    }

    public func surfaces(for project: Project) async throws -> [SurfaceStat] {
        guard let link = project.posthog else { return [] }
        let clock = ProjectClock(now: now(), timeZoneIdentifier: link.timeZone)
        let rows = try await withPostHog(link.accountId) {
            try await $0.query(projectId: link.projectId, PostHogQueries.surfaceStats(clock: clock), name: "snuffle_surfaces")
        }
        return PostHogParsing.surfaceStats(rows)
    }

    public func events(for project: Project) async throws -> [EventStat] {
        guard let link = project.posthog else { return [] }
        let since = now().addingTimeInterval(-7 * 86_400)
        let rows = try await withPostHog(link.accountId) {
            try await $0.query(projectId: link.projectId, PostHogQueries.eventStats(since: since), name: "snuffle_event_stats")
        }
        return PostHogParsing.eventStats(rows)
    }

    /// Reads every source the wanted metrics need, at once; each fails on its own.
    private func read(_ project: Project, wanted: Set<Metric>, clock: ProjectClock, readHourly: Bool, reviews: Bool) async -> [Part] {
        // A project whose surfaces were never chosen looks at its events once, before anything is counted by them.
        var found: Set<Surface>?
        if project.posthog != nil, project.metrics.excludedSurfaces == nil,
           let stats = try? await surfaces(for: project), !stats.isEmpty {
            found = Surface.defaultExcluded(seen: stats.filter { $0.people > 0 }.map(\.surface))
        }
        let excluded = found ?? project.metrics.surfacesLeftOut
        let parts = await withTaskGroup(of: [Part].self) { group in
            if let link = project.posthog {
                group.addTask { await self.posthogPart(project, link: link, wanted: wanted, clock: clock, excluded: excluded) }
                if readHourly, wanted.contains(where: { $0.isHourly && $0.source == .posthog }) {
                    group.addTask { await self.posthogHourlyPart(link: link, wanted: wanted, clock: clock, excluded: excluded) }
                }
            }
            if let link = project.revenueCat {
                if project.metrics.revenue == .revenueCat {
                    group.addTask {
                        do {
                            let client = try await self.revenueCat(link.accountId)
                            let day = RevenueCatClient.utcDate(clock.now)
                            return [.values([.revenue: try await client.revenue(projectId: link.projectId, from: day, to: day)]), .revenueSource(.revenueCat)]
                        } catch {
                            return [.failure(Self.failure(.revenueCat, error))]
                        }
                    }
                }
                if readHourly, wanted.contains(where: { $0.source == .revenueCat }) {
                    group.addTask {
                        do {
                            let overview = try await self.revenueCat(link.accountId).overview(projectId: link.projectId)
                            var values: [Metric: Double] = [:]
                            values[.mrr] = overview.mrr
                            values[.activeSubscriptions] = overview.activeSubscriptions.map(Double.init)
                            values[.activeTrials] = overview.activeTrials.map(Double.init)
                            values[.revenueLast28Days] = overview.revenueLast28Days
                            return [.values(values)]
                        } catch {
                            // A failed overview is a RevenueCat failure like any other, but the card keeps the last value.
                            return [.failure(Self.failure(.revenueCat, error)), .hourlyFailed]
                        }
                    }
                }
            }
            if reviews, let link = project.appStore {
                group.addTask {
                    do {
                        return [.reviews(try await self.appStore(link.accountId).reviews(appId: link.appId, projectId: project.id))]
                    } catch {
                        return [.failure(Self.failure(.appStore, error))]
                    }
                }
            }
            if reviews, let link = project.googlePlay {
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
        return parts + (found.map { [Part.surfaces($0)] } ?? [])
    }

    /// Today's PostHog numbers: new users with their hours, people active and online, page views, event revenue and
    /// orders, and the event metrics asked for. Two or three queries over today and yesterday, whatever is shown.
    private func posthogPart(_ project: Project, link: PostHogLink, wanted: Set<Metric>, clock: ProjectClock, excluded: Set<Surface>) async -> [Part] {
        do {
            let settings = project.metrics
            let events = wanted.filter { if case .event = $0 { true } else { false } }.sorted { $0.id < $1.id }
            return try await withPostHog(link.accountId) { client in
                let countsQuery = PostHogQueries.counts(settings: settings, events: events, clock: clock)
                async let countsRow: [[JSONValue]] = {
                    guard let countsQuery else { return [] }
                    return try await client.query(projectId: link.projectId, countsQuery.sql, name: "snuffle_counts")
                }()
                async let presenceRow = client.query(projectId: link.projectId, PostHogQueries.presence(clock: clock, excluding: excluded), name: "snuffle_presence")
                async let firstSeenRow: [[JSONValue]] = {
                    guard settings.newUsers == .firstSeen else { return [] }
                    return try await client.query(projectId: link.projectId, PostHogQueries.firstSeen(clock: clock, excluding: excluded), name: "snuffle_first_seen")
                }()
                // Read alongside the queries, so it costs no extra wait; a failure here never fails the numbers.
                async let zone = try? client.timeZone(projectId: link.projectId)

                var values: [Metric: Double] = [:]
                var parts: [Part] = []
                if let countsQuery, let row = try await countsRow.first {
                    let counts = PostHogParsing.counts(row, columns: countsQuery.columns)
                    values.merge(counts.values) { $1 }
                    if case .event = settings.newUsers { parts.append(.newUsersDetail(yesterday: counts.newYesterday, hourly: counts.hourly)) }
                    if case .posthogEvent = settings.revenue { parts.append(.revenueSource(.posthog)) }
                }
                if let row = try await firstSeenRow.first {
                    let firstSeen = PostHogParsing.firstSeen(row)
                    values[.newUsers] = firstSeen.today.map(Double.init)
                    parts.append(.newUsersDetail(yesterday: firstSeen.yesterday, hourly: firstSeen.hourly))
                }
                let presence = try await presenceRow.first ?? []
                values[.online] = presence.first?.double
                values[.activeToday] = presence.count > 1 ? presence[1].double : nil
                values[.pageviews] = presence.count > 2 ? presence[2].double : nil
                parts.append(.values(values.compactMapValues { $0 }))
                if let identifier = await zone { parts.append(.timeZone(identifier)) }
                return parts
            }
        } catch {
            return [.failure(Self.failure(.posthog, error))]
        }
    }

    /// People active this week and month and the total: scans of 30 days and of the people table, so hourly only.
    private func posthogHourlyPart(link: PostHogLink, wanted: Set<Metric>, clock: ProjectClock, excluded: Set<Surface>) async -> [Part] {
        do {
            return try await withPostHog(link.accountId) { client in
                let needsActivity = wanted.contains(.activeWeek) || wanted.contains(.activeMonth)
                async let activityRow: [[JSONValue]] = {
                    guard needsActivity else { return [] }
                    return try await client.query(projectId: link.projectId, PostHogQueries.activity(clock: clock, month: wanted.contains(.activeMonth), excluding: excluded), name: "snuffle_activity")
                }()
                async let totalRow: [[JSONValue]] = {
                    guard wanted.contains(.totalUsers) else { return [] }
                    return try await client.query(projectId: link.projectId, PostHogQueries.totalUsers, name: "snuffle_total_users")
                }()
                var values: [Metric: Double] = [:]
                if let row = try await activityRow.first {
                    values[.activeWeek] = row.first?.double
                    if row.count > 1 { values[.activeMonth] = row[1].double }
                }
                if let row = try await totalRow.first { values[.totalUsers] = row.first?.double }
                return [.values(values)]
            }
        } catch {
            return [.hourlyFailed]
        }
    }

    private static func assemble(_ parts: [Part], project: Project, clock: ProjectClock, readHourly: Bool) -> RefreshResult {
        var snapshot = ProjectSnapshot(projectId: project.id, fetchedAt: clock.now, dayStart: clock.todayStart)
        var reviews: [Review]?
        var storeFailed = false
        var hourlyFailed = false
        var zone: String?
        var surfaces: Set<Surface>?
        for part in parts {
            switch part {
            case .values(let values): snapshot.values.merge(values) { $1 }
            case .newUsersDetail(let yesterday, let hourly):
                snapshot.newUsersYesterday = yesterday
                snapshot.hourlyNewUsers = hourly
            case .revenueSource(let platform): snapshot.revenueSource = platform
            case .timeZone(let identifier): zone = identifier
            case .surfaces(let excluded): surfaces = excluded
            case .reviews(let list): reviews = (reviews ?? []) + list
            case .hourlyFailed: hourlyFailed = true
            case .failure(let failure):
                snapshot.failures.append(failure)
                if failure.platform == .appStore || failure.platform == .googlePlay { storeFailed = true }
            }
        }
        if readHourly && !hourlyFailed { snapshot.hourlyReadAt = clock.now }
        // When one store answers and the other fails, count what is known; the card names the failed store,
        // and `fillingGaps` keeps the last count only when no store answered at all.
        if let reviews { snapshot.values[.reviewsToAnswer] = Double(reviews.filter(\.needsReply).count) }
        snapshot.failures.sort { $0.platform.rawValue < $1.platform.rawValue }
        // A partial list would drop the failed store's reviews from the inbox, so only a complete one replaces it.
        snapshot.countedAs = project.metrics.leaving(out: surfaces ?? project.metrics.surfacesLeftOut)
        return RefreshResult(snapshot: snapshot, reviews: storeFailed ? nil : reviews, posthogTimeZone: zone, excludedSurfaces: surfaces)
    }

    static func failure(_ platform: Platform, _ error: Error) -> SourceFailure {
        SourceFailure(platform: platform, message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, kind: FailureKind(error))
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
                return try await client.query(projectId: link.projectId, PostHogQueries.firstSeenHistory(clock: clock, days: days, excluding: metrics.surfacesLeftOut), name: "snuffle_first_seen_history")
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
