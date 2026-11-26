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
        case previous([Metric: Double])
        case dailyActive([Int])
        case firstSeen(PostHogParsing.FirstSeen)
        case revenueSource(Platform)
        case timeZone(String)
        case surfaces(Set<Surface>)
        case userTally(UserTally)
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
        let parts = await read(project, wanted: wanted, clock: clock, readHourly: readHourly, reviews: project.hasStore, tally: current?.userTally)
        return Self.assemble(parts, project: project, clock: clock, readHourly: readHourly)
    }

    public func measure(_ project: Project, metrics: Set<Metric>) async throws -> [Metric: Double] {
        let clock = ProjectClock(now: now(), timeZoneIdentifier: project.posthog?.timeZone)
        let wanted = metrics.filter { $0.isAvailable(in: project) }
        let parts = await read(project, wanted: wanted, clock: clock, readHourly: true, reviews: wanted.contains(.reviewsToAnswer), tally: nil)
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
    private func read(_ project: Project, wanted: Set<Metric>, clock: ProjectClock, readHourly: Bool, reviews: Bool, tally: UserTally?) async -> [Part] {
        // A project whose surfaces were never chosen looks at its events once, before anything is counted by them.
        var found: Set<Surface>?
        if project.posthog != nil, project.metrics.excludedSurfaces == nil,
           let stats = try? await surfaces(for: project), !stats.isEmpty {
            found = Surface.defaultExcluded(seen: stats.filter { $0.people > 0 }.map(\.surface))
        }
        let scope = PeopleScope(project.metrics, excluding: found ?? project.metrics.surfacesLeftOut)
        // A tally read under other surfaces than this refresh found counts other people.
        let tally = found == nil ? tally : nil
        let parts = await withTaskGroup(of: [Part].self) { group in
            if let link = project.posthog {
                group.addTask { await self.posthogPart(project, link: link, wanted: wanted, clock: clock, scope: scope, tally: tally) }
                if readHourly, wanted.contains(.activeMonth) {
                    group.addTask { await self.posthogMonth(link: link, clock: clock, scope: scope) }
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

    /// Every PostHog number a refresh shows, in at most six queries run together: today's people, the last 14 days of
    /// activity, first use (new users and today's part of the total), event-based counts, and the total's tally when
    /// it is missing or a day behind. A failure fails them all, so the card never mixes old and new numbers.
    private func posthogPart(_ project: Project, link: PostHogLink, wanted: Set<Metric>, clock: ProjectClock, scope: PeopleScope, tally: UserTally?) async -> [Part] {
        do {
            let settings = project.metrics
            let events = wanted.filter { if case .event = $0 { true } else { false } }.sorted { $0.id < $1.id }
            let eventNewUsers: Bool = if case .event = settings.newUsers { true } else { false }
            let wantsTotal = wanted.contains(.totalUsers)
            let needsFirstSeen = wantsTotal || (!eventNewUsers && (wanted.contains(.newUsers) || wanted.contains(.newWeek)))
            // The tally is for the counting in effect; one older than a year is read from the start again.
            let yearAgo = clock.todayStart.addingTimeInterval(-Double(PostHogQueries.tallyLookbackDays) * 86_400)
            let tally = tally.flatMap { $0.before >= yearAgo && $0.before <= clock.todayStart ? $0 : nil }
            return try await withPostHog(link.accountId) { client in
                let countsQuery = PostHogQueries.counts(settings: settings, events: events, week: eventNewUsers && wanted.contains(.newWeek), clock: clock)
                async let countsRows: [[JSONValue]] = {
                    guard let countsQuery else { return [] }
                    return try await client.query(projectId: link.projectId, countsQuery.sql, name: "snuffle_counts")
                }()
                async let todayRows = client.query(projectId: link.projectId, PostHogQueries.peopleToday(scope, clock: clock), name: "snuffle_people_today")
                async let daysRows = client.query(projectId: link.projectId, PostHogQueries.peopleDays(scope, clock: clock), name: "snuffle_people_days")
                async let firstSeenRows: [[JSONValue]]? = {
                    guard needsFirstSeen else { return nil }
                    return try await client.query(projectId: link.projectId, PostHogQueries.firstSeen(scope, clock: clock), name: "snuffle_first_seen")
                }()
                async let tallyRows: [[JSONValue]]? = {
                    guard wantsTotal, tally?.before != clock.todayStart else { return nil }
                    if let tally {
                        return try await client.query(projectId: link.projectId, PostHogQueries.tallyMove(since: tally.before, scope, clock: clock), name: "snuffle_tally_move")
                    }
                    return try await client.query(projectId: link.projectId, PostHogQueries.tally(before: clock.todayStart, scope), name: "snuffle_tally")
                }()
                // Read alongside the queries, so it costs no extra wait; a failure here never fails the numbers.
                async let settingsRead = try? client.settings(projectId: link.projectId)

                var parts: [Part] = []
                if let countsQuery, let row = try await countsRows.first {
                    let counts = PostHogParsing.counts(row, columns: countsQuery.columns)
                    parts += [.values(counts.values), .previous(counts.previous)]
                    if case .posthogEvent = settings.revenue { parts.append(.revenueSource(.posthog)) }
                }
                let people = PostHogParsing.people(today: try await todayRows.first ?? [], days: try await daysRows.first ?? [])
                parts += [.values(people.values), .previous(people.previous), .dailyActive(people.daily)]
                if let rows = try await firstSeenRows { parts.append(.firstSeen(PostHogParsing.firstSeen(rows))) }
                if let rows = try await tallyRows {
                    let counts = PostHogParsing.platformCounts(rows)
                    parts.append(.userTally(tally.map { $0.moved(adding: counts, to: clock.todayStart) } ?? UserTally(byPlatform: counts, before: clock.todayStart)))
                } else if let tally {
                    parts.append(.userTally(tally))
                }
                if let zone = await settingsRead?.timeZone { parts.append(.timeZone(zone)) }
                return parts
            }
        } catch {
            return [.failure(Self.failure(.posthog, error))]
        }
    }

    /// People active over the last 30 days: a month's scan, so hourly only.
    private func posthogMonth(link: PostHogLink, clock: ProjectClock, scope: PeopleScope) async -> [Part] {
        do {
            let rows = try await withPostHog(link.accountId) {
                try await $0.query(projectId: link.projectId, PostHogQueries.month(scope, clock: clock), name: "snuffle_month")
            }
            return [.values([.activeMonth: rows.first?.first?.double ?? 0])]
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
        var firstSeen: PostHogParsing.FirstSeen?
        for part in parts {
            switch part {
            case .values(let values): snapshot.values.merge(values) { $1 }
            case .previous(let values): snapshot.previous.merge(values) { $1 }
            case .dailyActive(let days): snapshot.dailyActive = days
            case .firstSeen(let seen): firstSeen = seen
            case .revenueSource(let platform): snapshot.revenueSource = platform
            case .timeZone(let identifier): zone = identifier
            case .surfaces(let excluded): surfaces = excluded
            case .userTally(let tally): snapshot.userTally = tally
            case .reviews(let list): reviews = (reviews ?? []) + list
            case .hourlyFailed: hourlyFailed = true
            case .failure(let failure):
                snapshot.failures.append(failure)
                if failure.platform == .appStore || failure.platform == .googlePlay { storeFailed = true }
            }
        }
        if let firstSeen {
            if project.metrics.newUsers == .firstSeen {
                snapshot.values[.newUsers] = Double(firstSeen.today)
                snapshot.previous[.newUsers] = Double(firstSeen.yesterday)
                snapshot.values[.newWeek] = Double(firstSeen.week)
                snapshot.previous[.newWeek] = Double(firstSeen.weekBefore)
            }
            // Everyone counted before today, plus today's first-timers.
            if let tally = snapshot.userTally {
                snapshot.values[.totalUsers] = Double(tally.people + firstSeen.today)
                snapshot.previous[.totalUsers] = Double(tally.people)
                snapshot.platforms = PlatformCount.sorted(tally.byPlatform.merging(firstSeen.todayByPlatform, uniquingKeysWith: +))
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

    public func board(for project: Project, days: Int, total: [String: Int]?) async throws -> ProjectBoard {
        let clock = ProjectClock(now: now(), timeZoneIdentifier: project.posthog?.timeZone ?? "UTC")
        async let revenueByDay = revenueCatHistory(for: project, days: days)
        var board = try await posthogBoard(for: project, days: days, total: total, clock: clock)
            ?? ProjectBoard(days: clock.dayStarts(days: days).map { ProjectBoard.Day(day: $0) }, weeks: [], platforms: [])
        // RevenueCat reports by UTC date; days are matched by calendar date, as the 收入 tile says "(UTC)".
        if let revenue = await revenueByDay {
            for index in board.days.indices { board.days[index].revenue = revenue[clock.dayKey(board.days[index].day)] ?? 0 }
        }
        return board
    }

    private func posthogBoard(for project: Project, days: Int, total: [String: Int]?, clock: ProjectClock) async throws -> ProjectBoard? {
        guard let link = project.posthog else { return nil }
        let settings = project.metrics
        let scope = PeopleScope(settings, excluding: settings.surfacesLeftOut)
        return try await withPostHog(link.accountId) { client in
            let weekStartsMonday = (try? await client.settings(projectId: link.projectId))?.weekStartsMonday ?? false
            let firstWeek = Self.weekStart(of: clock.todayStart.addingTimeInterval(-11 * 7 * 86_400), mondays: weekStartsMonday, zone: clock.timeZone)
            async let active = client.query(projectId: link.projectId, PostHogQueries.boardActive(scope, clock: clock, days: days), name: "snuffle_board_active")
            async let firstSeen = client.query(projectId: link.projectId, PostHogQueries.boardFirstSeen(scope, clock: clock, days: days), name: "snuffle_board_first_seen")
            async let signups: [[JSONValue]]? = {
                guard case .event(let event) = settings.newUsers else { return nil }
                return try await client.query(projectId: link.projectId, PostHogQueries.boardSignups(event: event, platform: scope.platform, clock: clock, days: days), name: "snuffle_board_signups")
            }()
            async let revenue: [[JSONValue]]? = {
                guard case .posthogEvent(let event, let property) = settings.revenue else { return nil }
                return try await client.query(projectId: link.projectId, PostHogQueries.boardRevenue(event: event, valueProperty: property, clock: clock, days: days), name: "snuffle_board_revenue")
            }()
            async let weeks = client.query(projectId: link.projectId, PostHogQueries.weeks(scope, clock: clock, firstWeek: firstWeek, mode: weekStartsMonday ? 1 : 0), name: "snuffle_board_weeks")

            let activeByDay = PostHogParsing.dailyByPlatform(try await active)
            let firstByDay = PostHogParsing.dailyByPlatform(try await firstSeen)
            let signupsByDay = try await signups.map(PostHogParsing.dailyByPlatform)
            let revenueByDay = try await revenue.map(PostHogParsing.dailyAmounts)
            let starts = clock.dayStarts(days: days)
            let firstSeenDays = starts.map { firstByDay[clock.dayKey($0)] ?? [:] }
            let totals = total.map { ProjectBoard.totals(now: $0, firstSeen: firstSeenDays) }
            let boardDays = starts.enumerated().map { index, day in
                let key = clock.dayKey(day)
                return ProjectBoard.Day(
                    day: day,
                    active: activeByDay[key] ?? [:],
                    new: signupsByDay.map { $0[key] ?? [:] } ?? firstSeenDays[index],
                    total: totals?[index] ?? [:],
                    revenue: revenueByDay.map { $0[key] ?? 0 }
                )
            }
            let boardWeeks = try await weeks.compactMap { row -> ProjectBoard.Week? in
                guard row.count >= 3, let key = row[0].string, let start = DashboardReading.Counting.dayStart(String(key.prefix(10)), in: clock.timeZone) else { return nil }
                return ProjectBoard.Week(start: start, new: row[1].int ?? 0, returning: row[2].int ?? 0)
            }
            let mix = total ?? boardDays.reduce(into: [String: Int]()) { sum, day in sum.merge(day.active, uniquingKeysWith: +) }
            return ProjectBoard(days: boardDays, weeks: boardWeeks, platforms: ProjectBoard.order(mix))
        }
    }

    /// The start of the week holding `date`, weeks starting on Monday or Sunday.
    static func weekStart(of date: Date, mondays: Bool, zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = mondays ? 2 : 1
        return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Daily RevenueCat revenue for projects that take revenue from it; nil when not used or unavailable, so the
    /// chart simply leaves revenue out rather than failing the whole board.
    private func revenueCatHistory(for project: Project, days: Int) async -> [String: Double]? {
        guard let link = project.revenueCat, project.metrics.revenue == .revenueCat else { return nil }
        let today = now()
        let from = RevenueCatClient.utcDate(today.addingTimeInterval(-Double(days + 1) * 86_400))
        return try? await revenueCat(link.accountId).dailyRevenue(projectId: link.projectId, from: from, to: RevenueCatClient.utcDate(today))
    }

    // MARK: Dashboards

    public func dashboards(for project: Project) async throws -> [DashboardSummary] {
        guard let link = project.posthog else { return [] }
        return try await withPostHog(link.accountId) { try await $0.dashboards(projectId: link.projectId) }
    }

    public func dashboard(_ ref: DashboardRef, for project: Project) async throws -> DashboardDetail {
        guard let link = project.posthog else { return DashboardDetail(ref: ref, tiles: []) }
        return try await withPostHog(link.accountId) { try await $0.dashboard(projectId: link.projectId, ref: ref) }
    }

    public func dashboardCounting(for project: Project) async throws -> DashboardReading.Counting? {
        guard let link = project.posthog else { return nil }
        return try await withPostHog(link.accountId) { try await $0.dashboardCounting(projectId: link.projectId) }
    }

    public func run(_ tile: InsightTile, for project: Project) async throws -> InsightResult {
        guard let link = project.posthog, let query = tile.query else { return InsightResult(fetchedAt: now()) }
        let date = now()
        return try await withPostHog(link.accountId) { try await $0.run(projectId: link.projectId, query: query, now: date) }
    }

    public func check(condition: String, for project: Project) async throws -> (kept: Int, total: Int) {
        guard let link = project.posthog else { return (0, 0) }
        let clock = ProjectClock(now: now(), timeZoneIdentifier: link.timeZone)
        let rows = try await withPostHog(link.accountId) {
            try await $0.query(projectId: link.projectId, PostHogQueries.conditionCheck(condition, clock: clock), name: "snuffle_condition_check")
        }
        let row = rows.first ?? []
        return (row.first?.int ?? 0, row.count > 1 ? row[1].int ?? 0 : 0)
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
